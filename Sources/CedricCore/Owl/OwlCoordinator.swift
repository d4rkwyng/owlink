import Foundation

/// Where hints come from: the rules only, or the rules and an AI provider.
public enum OwlHintSource: String, Sendable, CaseIterable {
    case rules
    case rulesAndAI

    /// Rules + AI is selected only when the AI goes from off to on.
    /// A later change (the interval, the model, the address) leaves a
    /// Rules choice made in Cedric's Hints.
    public func afterAIApply(wasActive: Bool, isActive: Bool) -> OwlHintSource {
        isActive && !wasActive ? .rulesAndAI : self
    }
}

/// The providers the owl asks, in order. The rules register at launch; an
/// AI provider (the ai-owl branch) registers with `isAI: true`, which
/// enables the "Rules + AI" setting.
@MainActor
public final class OwlProviderRegistry {
    public private(set) var entries: [(provider: any OwlHintProvider, isAI: Bool)] = []
    /// Called after a provider registers or unregisters.
    public var onChange: (() -> Void)?

    public init() {}

    public func register(_ provider: any OwlHintProvider, isAI: Bool = false) {
        entries.removeAll { $0.provider.name == provider.name }
        entries.append((provider, isAI))
        onChange?()
    }

    public func unregister(name: String) {
        entries.removeAll { $0.provider.name == name }
        onChange?()
    }

    public var hasAIProvider: Bool { entries.contains { $0.isAI } }

    public func providers(for source: OwlHintSource) -> [any OwlHintProvider] {
        entries.filter { !$0.isAI || source == .rulesAndAI }.map(\.provider)
    }
}

/// Decides when to ask the providers and which hint to show.
///
/// - Asks at most once per `queryInterval` (30 s), and only once typing
///   has paused for `typingPause` (3 s) after some activity (an edit, an
///   open, a save, the app coming back).
/// - Shows each hint once per document (dedupe by `id`).
/// - "Not now" snoozes a hint id for `snoozeInterval` (1 h), after which it
///   may come back; "Don't show this again" is saved in UserDefaults.
/// - "Quiet for 1 hour" stops all queries until then.
///
/// No timers here: `nextDueDate` says when the app's single timer should
/// fire. The clock is injected so the tests run on a fake one.
@MainActor
public final class OwlCoordinator {
    public static let neverKey = "owlNeverShowHints"
    /// Hints that are shown once ever (the letter easter egg).
    public static let onceEver: Set<String> = [RulesHintProvider.letterID]

    /// A hint the owl showed, kept for the popover's "Recent hints" so it
    /// can be shown again without asking any provider.
    public struct Shown: Equatable, Sendable {
        public let hint: OwlHint
        public let documentID: UUID
        public let date: Date
        /// The hint's range in the document when it was shown (nil: none,
        /// or no context was given).
        public let documentRange: NSRange?
        /// The text in `documentRange` then: a replay highlights and
        /// applies only while the document still has it there.
        public let expected: String?

        public init(hint: OwlHint, documentID: UUID, date: Date, documentRange: NSRange? = nil, expected: String? = nil) {
            self.hint = hint
            self.documentID = documentID
            self.date = date
            self.documentRange = documentRange
            self.expected = expected
        }
    }

    /// What showing a recent hint again gives the bubble.
    public struct Replay: Equatable, Sendable {
        /// The stored hint; without its range and replacement when stale.
        public let hint: OwlHint
        /// Where it is in the document now (nil: no range, or stale).
        public let documentRange: NSRange?
        public let expected: String?
        /// The hint had a range, and the text there has changed (or the
        /// document is gone): title and detail only, no highlight, no Fix it.
        public let isStale: Bool
    }

    /// A recent hint, again. Never asks a provider and ignores `isEligible`
    /// (it was shown, so it is in `shownKeys`), the quiet hour and snoozes:
    /// the user asked for it. `document` is the document's text now (nil:
    /// it is closed). With the range still holding the text it had, the
    /// hint is returned as it was (highlight, Fix it); otherwise its title
    /// and detail alone.
    public static func replay(_ shown: Shown, document: NSString?) -> Replay {
        let h = shown.hint
        guard h.range != nil else { return Replay(hint: h, documentRange: nil, expected: nil, isStale: false) }
        if let doc = document, let r = shown.documentRange, let expected = shown.expected,
           r.location >= 0, NSMaxRange(r) <= doc.length, doc.substring(with: r) == expected {
            return Replay(hint: h, documentRange: r, expected: expected, isStale: false)
        }
        let bare = OwlHint(id: h.id, kind: h.kind, title: h.title, detail: h.detail, source: h.source)
        return Replay(hint: bare, documentRange: nil, expected: nil, isStale: true)
    }

    public let registry: OwlProviderRegistry
    public var source: OwlHintSource = .rules
    public var queryInterval: TimeInterval = 30
    public var typingPause: TimeInterval = 3
    public var snoozeInterval: TimeInterval = 3600
    public let clock: () -> Date
    private let defaults: UserDefaults

    public private(set) var lastActivity: Date?
    public private(set) var lastQuery: Date?
    public private(set) var pending = false
    public private(set) var quietUntil: Date?
    public private(set) var never: Set<String>
    private var shownKeys = Set<String>()
    private var snoozedUntil: [String: Date] = [:]
    /// Most recent first, at most `recentLimit`.
    public private(set) var recent: [Shown] = []
    public var recentLimit = 8
    /// How many times the providers were asked (tests, perf).
    public private(set) var queryCount = 0

    public init(registry: OwlProviderRegistry = OwlProviderRegistry(), defaults: UserDefaults = .standard,
                clock: @escaping () -> Date = { Date() }) {
        self.registry = registry
        self.defaults = defaults
        self.clock = clock
        never = Set(defaults.stringArray(forKey: Self.neverKey) ?? [])
    }

    // MARK: When to ask

    /// Typing, an open, a save: a query becomes due after the pause.
    public func noteActivity() {
        lastActivity = clock()
        pending = true
    }

    /// When a query may run (nil: nothing pending).
    public var nextDueDate: Date? {
        guard pending, let act = lastActivity else { return nil }
        var due = act.addingTimeInterval(typingPause)
        if let q = lastQuery { due = max(due, q.addingTimeInterval(queryInterval)) }
        if let quiet = quietUntil { due = max(due, quiet) }
        return due
    }

    public var isDue: Bool { nextDueDate.map { $0 <= clock() } ?? false }

    public var isQuiet: Bool { quietUntil.map { $0 > clock() } ?? false }

    public func quiet(for seconds: TimeInterval) { quietUntil = clock().addingTimeInterval(seconds) }
    public func endQuiet() { quietUntil = nil }

    // MARK: Asking

    /// Asks the providers if a query is due and returns the first hint not
    /// yet shown for this document (marked shown). Nil when not due or
    /// nothing new.
    /// `current` reports the document's length and edit generation once the
    /// providers have answered; a hint whose range (moved by `textStart`)
    /// falls outside the document, or that refers to text edited since the
    /// context was taken, is dropped.
    public func queryIfDue(_ window: OwlContextWindow, facts: OwlDocumentFacts,
                           current: () -> (length: Int, generation: Int)) async -> OwlHint? {
        guard isDue else { return nil }
        return await query(window, facts: facts, source: source, current: current)
    }

    /// Asked for (the owl clicked in a large document): the rules only,
    /// now, whatever the schedule; same filtering as a scheduled query.
    public func queryNow(_ window: OwlContextWindow, facts: OwlDocumentFacts,
                         current: () -> (length: Int, generation: Int)) async -> OwlHint? {
        await query(window, facts: facts, source: .rules, current: current)
    }

    private func query(_ window: OwlContextWindow, facts: OwlDocumentFacts, source: OwlHintSource,
                       current: () -> (length: Int, generation: Int)) async -> OwlHint? {
        lastQuery = clock()
        pending = false
        queryCount += 1
        var hints: [OwlHint] = []
        for p in registry.providers(for: source) {
            if let f = p as? any OwlFactsAwareProvider {
                hints += await f.hints(for: window.context, facts: facts)
            } else {
                hints += await p.hints(for: window.context)
            }
        }
        // Only now: the window may have gone quiet while a provider ran.
        let now = current()
        return accept(hints, context: window.context, length: now.length, generation: now.generation)
    }

    /// Hints that arrive on their own (the AI scheduler's): the same
    /// filtering as a query — in the document, not edited since, not
    /// quiet, not shown/snoozed/never — then the first is marked shown and
    /// returned. `length`/`generation` describe the document now. Nil when
    /// the source is Rules or nothing is left.
    public func accept(_ hints: [OwlHint], context: OwlContext, length: Int, generation: Int) -> OwlHint? {
        let ok = hints.filter { Self.matchesDocument($0, context: context, length: length, generation: generation) }
        guard !isQuiet, let hint = ok.first(where: { isEligible($0, documentID: context.documentID) }) else { return nil }
        markShown(hint, documentID: context.documentID, context: context)
        return hint
    }

    /// `accept` for hints from an AI source: dropped unless "Rules + AI" is on.
    public func acceptAI(_ hints: [OwlHint], context: OwlContext, length: Int, generation: Int) -> OwlHint? {
        guard source == .rulesAndAI, registry.hasAIProvider else { return nil }
        return accept(hints, context: context, length: length, generation: generation)
    }

    /// The hint's range, converted to the document (`location + textStart`).
    public static func documentRange(_ hint: OwlHint, context: OwlContext) -> NSRange? {
        hint.range.map { NSRange(location: $0.location + context.textStart, length: $0.length) }
    }

    /// A hint without a range always matches; one with a range must lie
    /// inside both the context text and the document, and the document
    /// must not have been edited since the context was taken.
    public static func matchesDocument(_ hint: OwlHint, context: OwlContext, length: Int, generation: Int) -> Bool {
        guard let r = hint.range else { return true }
        guard r.location >= 0, r.length >= 0, NSMaxRange(r) <= (context.text as NSString).length else { return false }
        guard let d = documentRange(hint, context: context), NSMaxRange(d) <= length else { return false }
        return generation == context.editGeneration
    }

    public func isEligible(_ hint: OwlHint, documentID: UUID) -> Bool {
        if never.contains(hint.id) { return false }
        if let until = snoozedUntil[hint.id], until > clock() { return false }
        return !shownKeys.contains(key(hint.id, documentID))
    }

    /// `context`: the one the hint's range is relative to, kept (as a
    /// document range and the text there) so the popover can show it again.
    public func markShown(_ hint: OwlHint, documentID: UUID, context: OwlContext? = nil) {
        shownKeys.insert(key(hint.id, documentID))
        recent.removeAll { $0.hint.id == hint.id && $0.documentID == documentID }
        var docRange: NSRange?, expected: String?
        if let context, let r = hint.range {
            let ctx = context.text as NSString
            if r.location >= 0, NSMaxRange(r) <= ctx.length {
                docRange = Self.documentRange(hint, context: context)
                expected = ctx.substring(with: r)
            }
        }
        recent.insert(Shown(hint: hint, documentID: documentID, date: clock(), documentRange: docRange, expected: expected), at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        if Self.onceEver.contains(hint.id) { neverShowAgain(hint.id) }
    }

    // MARK: Answers

    /// "Not now": not for `snoozeInterval`; then it may come back, in any document.
    public func snooze(_ id: String) {
        snoozedUntil[id] = clock().addingTimeInterval(snoozeInterval)
        shownKeys = shownKeys.filter { !$0.hasSuffix("|" + id) }
    }

    /// "Don't show this again" (saved).
    public func neverShowAgain(_ id: String) {
        guard never.insert(id).inserted else { return }
        defaults.set(never.sorted(), forKey: Self.neverKey)
    }

    public func resetNeverShown() {
        never = []
        defaults.removeObject(forKey: Self.neverKey)
    }

    private func key(_ id: String, _ doc: UUID) -> String { doc.uuidString + "|" + id }
}
