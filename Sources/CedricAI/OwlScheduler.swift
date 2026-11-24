import Foundation
import CedricCore

/// "Only checks so often." Decides when a provider is asked, per document:
///
/// - only after typing pauses for `pauseDelay` (5 s), and only once the
///   document has been open and untouched for `minIdle` (10 s in the app);
/// - never for a document marked large (`setLargeDocument`): its text
///   isn't sent and, for the built-in engine, no model is loaded;
/// - never on its own for a document over the auto-review cap
///   (`setAutoReviewCapped`, `AutoReviewCap`: 100 KB or 2,000 lines): no
///   timer is armed for it, so no model is loaded because it was opened,
///   saved or left idle. `checkNow` (the user asking, after the app's
///   confirmation) still works;
/// - never when the text has fewer than `HintPrompt.minimumHintCharacters`
///   non-whitespace characters: an empty document has nothing to check,
///   and asking invents a problem;
/// - at most once per `minInterval` (90 s) per document;
/// - never while the app is inactive, in Low Power Mode, or on battery
///   below `minimumBattery` (20 %);
/// - never twice for the same `editGeneration`;
/// - each request is hard-capped at `timeout` (20 s) and cancelled as soon
///   as the document is edited again.
///
/// Results for a generation that is no longer current are dropped.
///
/// With `Config.automatic` off (the default on Intel Macs) none of the
/// above fires on its own: nothing is armed and only `checkNow` (the user
/// asking) starts a request.
public actor OwlScheduler {
    public struct Config: Sendable, Equatable {
        public var pauseDelay: TimeInterval
        public var minInterval: TimeInterval
        public var timeout: TimeInterval
        public var minimumBattery: Int
        /// The document must have been open, and untouched, at least this
        /// long (whichever of this and `pauseDelay` is longer applies to edits).
        public var minIdle: TimeInterval
        /// False: no timers at all; only `checkNow` starts a request
        /// (Intel's default, `LocalAISettings.automaticChecks`).
        public var automatic: Bool

        public init(pauseDelay: TimeInterval = 5, minInterval: TimeInterval = 90,
                    timeout: TimeInterval = 20, minimumBattery: Int = 20, minIdle: TimeInterval = 0, automatic: Bool = true) {
            self.automatic = automatic
            self.pauseDelay = pauseDelay
            self.minIdle = minIdle
            self.minInterval = minInterval
            self.timeout = timeout
            self.minimumBattery = minimumBattery
        }
    }

    public enum Gate: Sendable, Equatable {
        case fire
        case typing(remaining: TimeInterval)
        case throttled(remaining: TimeInterval)
        case inactive
        case power
        case alreadyAsked
        case busy
        case unknownDocument
        /// Marked large (too big or with very long lines): never asked.
        case largeDocument
        /// Empty, or under `HintPrompt.minimumHintCharacters` non-whitespace
        /// characters: never asked, by any engine.
        case tooShort
        /// Over `AutoReviewCap`: never asked on its own; `checkNow` only.
        case autoReviewCapped
    }

    public enum Outcome: Sendable, Equatable {
        case delivered(count: Int)
        case timedOut
        case cancelled
        case stale
    }

    struct Doc {
        var context: OwlContext
        var opened: TimeInterval
        var lastEdit: TimeInterval
        var lastFire: TimeInterval?
        var askedGeneration: Int?
        var timer: Task<Void, Never>?
        var inflight: Task<Void, Never>?
    }

    let provider: any OwlHintProvider
    public private(set) var config: Config
    let clock: any OwlClock
    let power: any PowerSource
    let deliver: @Sendable (OwlContext, [OwlHint]) async -> Void
    let onOutcome: (@Sendable (UUID, Outcome) -> Void)?
    /// Called when a request starts (the owl's "thinking" pose); every
    /// start is followed by exactly one `onOutcome`.
    let onStart: (@Sendable (OwlContext) -> Void)?

    var docs: [UUID: Doc] = [:]
    /// Documents in large mode: ignored until unmarked.
    public private(set) var largeDocuments: Set<UUID> = []
    /// Documents over the auto-review cap: no timer, only `checkNow`.
    public private(set) var autoReviewCapped: Set<UUID> = []
    public private(set) var appActive = true
    /// How many requests were started, for tests and the budget log.
    public private(set) var requestCount = 0

    public init(provider: any OwlHintProvider, config: Config = Config(),
                clock: any OwlClock = SystemClock(), power: any PowerSource = SystemPowerSource(),
                onOutcome: (@Sendable (UUID, Outcome) -> Void)? = nil,
                onStart: (@Sendable (OwlContext) -> Void)? = nil,
                deliver: @escaping @Sendable (OwlContext, [OwlHint]) async -> Void) {
        self.provider = provider
        self.config = config
        self.clock = clock
        self.power = power
        self.onOutcome = onOutcome
        self.onStart = onStart
        self.deliver = deliver
    }

    // MARK: Inputs from the app

    /// Call on every edit (new generation) and on scroll (same generation,
    /// new visible text). An edit cancels the document's in-flight request
    /// and restarts the pause timer; a scroll only refreshes the context.
    public func contextChanged(_ context: OwlContext) {
        let now = clock.now
        let id = context.documentID
        if largeDocuments.contains(id) { return }
        if autoReviewCapped.contains(id) {
            // Never armed. Only an asked-for check's context is kept up to
            // date, so an edit still cancels it.
            guard var doc = docs[id] else { return }
            if context.editGeneration != doc.context.editGeneration {
                doc.lastEdit = now
                doc.inflight?.cancel()
                doc.inflight = nil
            }
            doc.context = context
            doc.timer?.cancel()
            doc.timer = nil
            docs[id] = doc
            return
        }
        if var doc = docs[id] {
            let isEdit = context.editGeneration != doc.context.editGeneration
            doc.context = context
            if isEdit {
                doc.lastEdit = now
                doc.inflight?.cancel()
                doc.inflight = nil
            }
            docs[id] = doc
            if isEdit || doc.timer == nil { arm(id, after: isEdit ? idleDelay : remainingWait(doc, now)) }
        } else {
            docs[id] = Doc(context: context, opened: now, lastEdit: now)
            arm(id, after: idleDelay)
        }
    }

    /// Typing must pause this long.
    private var idleDelay: TimeInterval { max(config.pauseDelay, config.minIdle) }

    /// Large mode on: forget the document (cancelling anything in flight)
    /// and ignore its contexts until it's unmarked.
    public func setLargeDocument(_ id: UUID, _ large: Bool) {
        if large {
            documentClosed(id)
            largeDocuments.insert(id)
        } else {
            largeDocuments.remove(id)
        }
    }

    /// Over the auto-review cap (`AutoReviewCap`) or back under it. Going
    /// over (on open, or an edit made it so, which cancels a check anyway)
    /// forgets the document, cancelling its timer and anything in flight,
    /// as for large mode. Back under: its next context is a fresh open.
    public func setAutoReviewCapped(_ id: UUID, _ capped: Bool) {
        if capped {
            guard !autoReviewCapped.contains(id) else { return }
            docs[id]?.timer?.cancel()
            docs[id]?.inflight?.cancel()
            docs[id] = nil
            autoReviewCapped.insert(id)
        } else {
            guard autoReviewCapped.remove(id) != nil else { return }
            if docs[id]?.inflight == nil { docs[id]?.timer?.cancel(); docs[id] = nil }
        }
    }

    /// From NSApplication didBecomeActive / didResignActive. Going inactive
    /// cancels everything in flight; coming back re-arms the timers.
    public func setAppActive(_ active: Bool) {
        appActive = active
        for id in docs.keys {
            if active {
                if autoReviewCapped.contains(id) { continue }
                if docs[id]?.askedGeneration != docs[id]?.context.editGeneration {
                    arm(id, after: config.pauseDelay)
                }
            } else {
                docs[id]?.timer?.cancel(); docs[id]?.timer = nil
                if let task = docs[id]?.inflight {
                    // Interrupted before an answer: that generation may be asked again.
                    task.cancel()
                    docs[id]?.inflight = nil
                    docs[id]?.askedGeneration = nil
                }
            }
        }
    }

    public func documentClosed(_ id: UUID) {
        largeDocuments.remove(id)
        autoReviewCapped.remove(id)
        docs[id]?.timer?.cancel()
        docs[id]?.inflight?.cancel()
        docs[id] = nil
    }

    /// New pause, interval, timeout or automatic flag. In-flight checks keep
    /// running. Pause timers are armed again from the new config, or dropped
    /// when automatic checks are off.
    public func updateConfig(_ config: Config) {
        self.config = config
        let now = clock.now
        for id in Array(docs.keys) {
            docs[id]?.timer?.cancel()
            docs[id]?.timer = nil
            guard config.automatic, !autoReviewCapped.contains(id), let doc = docs[id], doc.inflight == nil else { continue }
            guard doc.askedGeneration != doc.context.editGeneration else { continue }
            arm(id, after: remainingWait(doc, now))
        }
    }

    /// The provider is going away (AI switched off, settings changed):
    /// cancel every timer and request and forget the documents.
    public func shutdown() {
        for id in Array(docs.keys) { documentClosed(id) }
    }

    /// Asked for (the user clicked "Ask AI Now"): starts a request for
    /// `context` now, whatever the typing pause, the interval, the power
    /// state or `minIdle` say, and also for a document over the
    /// auto-review cap (the app confirms with the user first). Still never
    /// for a large document or one with almost no text, and an edit still
    /// cancels it. False when it
    /// didn't start (large, too short, or a request for this generation
    /// is already running).
    @discardableResult
    public func checkNow(_ context: OwlContext) -> Bool {
        let id = context.documentID
        if largeDocuments.contains(id) { return false }
        if !HintPrompt.hasEnoughText(context.text) { return false }
        let now = clock.now
        var doc = docs[id] ?? Doc(context: context, opened: now, lastEdit: now)
        if doc.inflight != nil, doc.context.editGeneration == context.editGeneration { return false }
        doc.inflight?.cancel()
        doc.inflight = nil
        doc.timer?.cancel()
        doc.timer = nil
        doc.context = context
        docs[id] = doc
        start(id)
        return true
    }

    // MARK: Decisions

    /// The gate for `id` right now. Pure apart from reading the clock and
    /// the power source, so tests drive it with fakes.
    public func gate(for id: UUID) -> Gate {
        if largeDocuments.contains(id) { return .largeDocument }
        if autoReviewCapped.contains(id) { return .autoReviewCapped }
        guard let doc = docs[id] else { return .unknownDocument }
        if !HintPrompt.hasEnoughText(doc.context.text) { return .tooShort }
        let now = clock.now
        if !appActive { return .inactive }
        if doc.askedGeneration == doc.context.editGeneration { return .alreadyAsked }
        if doc.inflight != nil { return .busy }
        let sinceEdit = now - doc.lastEdit
        if sinceEdit < idleDelay { return .typing(remaining: idleDelay - sinceEdit) }
        let sinceOpen = now - doc.opened
        if sinceOpen < config.minIdle { return .typing(remaining: config.minIdle - sinceOpen) }
        if let last = doc.lastFire, now - last < config.minInterval {
            return .throttled(remaining: config.minInterval - (now - last))
        }
        if !power.current().allowsChecks(minimumBattery: config.minimumBattery) { return .power }
        return .fire
    }

    private func remainingWait(_ doc: Doc, _ now: TimeInterval) -> TimeInterval {
        var wait = max(0, idleDelay - (now - doc.lastEdit), config.minIdle - (now - doc.opened))
        if let last = doc.lastFire { wait = max(wait, config.minInterval - (now - last)) }
        return wait
    }

    private func arm(_ id: UUID, after delay: TimeInterval) {
        docs[id]?.timer?.cancel()
        docs[id]?.timer = nil
        guard config.automatic, !autoReviewCapped.contains(id) else { return }   // asked for only
        let clock = self.clock
        docs[id]?.timer = Task { [weak self] in
            do { try await clock.sleep(seconds: delay) } catch { return }
            await self?.timerFired(id)
        }
    }

    /// Evaluate the gate and act on it. The timer calls this; tests may too.
    @discardableResult
    public func timerFired(_ id: UUID) -> Gate {
        docs[id]?.timer = nil
        let g = gate(for: id)
        switch g {
        case .fire: start(id)
        case .typing(let r), .throttled(let r): arm(id, after: r)
        case .power: arm(id, after: config.minInterval)   // re-check the battery later
        case .inactive, .alreadyAsked, .busy, .unknownDocument, .largeDocument, .tooShort, .autoReviewCapped: break
        }
        return g
    }

    private func start(_ id: UUID) {
        guard var doc = docs[id], HintPrompt.hasEnoughText(doc.context.text) else { return }
        let context = doc.context
        doc.lastFire = clock.now
        doc.askedGeneration = context.editGeneration
        requestCount += 1
        onStart?(context)
        let provider = self.provider, clock = self.clock, timeout = config.timeout
        doc.inflight = Task { [weak self] in
            let result = await Self.race(provider: provider, context: context, clock: clock, timeout: timeout)
            await self?.finish(context, result)
        }
        docs[id] = doc
    }

    /// nil = timed out or cancelled.
    static func race(provider: any OwlHintProvider, context: OwlContext,
                     clock: any OwlClock, timeout: TimeInterval) async -> [OwlHint]? {
        await withTaskGroup(of: [OwlHint]?.self) { group in
            group.addTask { await provider.hints(for: context) }
            group.addTask {
                try? await clock.sleep(seconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func finish(_ context: OwlContext, _ result: [OwlHint]?) async {
        let id = context.documentID
        guard var doc = docs[id] else { onOutcome?(id, .cancelled); return }   // closed meanwhile
        let current = doc.context.editGeneration == context.editGeneration
        if current { doc.inflight = nil; docs[id] = doc }
        let outcome: Outcome
        if Task.isCancelled || (!current && result == nil) {
            outcome = .cancelled
        } else if !current {
            outcome = .stale
        } else if let hints = result {
            outcome = .delivered(count: hints.count)
            await deliver(context, hints)
        } else {
            outcome = .timedOut
        }
        onOutcome?(id, outcome)
    }
}
