import AppKit
import CedricCore
import CedricAI

/// Grammar in prose: the system's grammar checker (NSSpellChecker, local,
/// nothing sent anywhere) on documents that are writing for people
/// (ProseDetector: Plain Text or Markdown that reads as sentences), never
/// on code, data or logs, and never in large mode.
///
/// After typing pauses (`pause`, 1.2 s) the owl's context window (the
/// visible lines ±40, at most 8 KB) is copied, masked (ProseMask: code,
/// tables, URLs blanked) and measured off the main thread; if it reads as
/// prose, the masked text goes to `requestChecking` (asynchronous, its
/// results come back on a background queue). The findings become
/// `GrammarIssue`s: green dotted underlines (EditorTextView) with the
/// suggestion in the right-click menu, and, with the owl on, at most one
/// "Grammar: ‘a’ → ‘an’?" bubble per `GrammarPopupPolicy.minInterval`
/// (10 min), never while typing.
protocol GrammarChecking: AnyObject {
    /// Grammar results for `text` (sentence ranges in `text`); `completion` on any queue.
    @MainActor func check(_ text: String, tag: Int, completion: @escaping @Sendable ([GrammarResult]) -> Void)
}

/// macOS's own checker. Grammar results come only when spelling is asked
/// for too (macOS 26: `.grammar` alone returns nothing), so both are asked
/// for and the spelling results dropped (continuous checking shows those).
/// The language is the checker's: identified per text when the user has
/// "Automatic by Language" on, else their chosen spelling language.
final class SystemGrammarChecker: GrammarChecking {
    @MainActor func check(_ text: String, tag: Int, completion: @escaping @Sendable ([GrammarResult]) -> Void) {
        let sc = NSSpellChecker.shared
        var options: [NSSpellChecker.OptionKey: Any] = [:]
        if !sc.automaticallyIdentifiesLanguages {
            options[.orthography] = NSOrthography.defaultOrthography(forLanguage: sc.language())
        }
        let types = NSTextCheckingResult.CheckingType.grammar.rawValue | NSTextCheckingResult.CheckingType.spelling.rawValue
        sc.requestChecking(of: text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
                           options: options, inSpellDocumentWithTag: tag, completionHandler: Self.handler(completion))
    }

    /// The completion handler, made outside the main actor: a closure
    /// written inside the @MainActor `check` is main-actor isolated, and
    /// NSSpellChecker calls it on a background queue ("data race detected"
    /// at runtime; the same pattern crashed Tankard). This one is nonisolated
    /// and only hands the results on (`completion` runs on any queue).
    nonisolated static func handler(_ completion: @escaping @Sendable ([GrammarResult]) -> Void)
        -> @Sendable (Int, [NSTextCheckingResult], NSOrthography, Int) -> Void {
        { _, results, _, _ in
            completion(results.filter { $0.resultType == .grammar }.map(SystemGrammarChecker.result))
        }
    }

    /// NSGrammarRange (relative to the sentence), NSGrammarUserDescription, NSGrammarCorrections.
    static func result(_ r: NSTextCheckingResult) -> GrammarResult {
        let details: [GrammarDetail] = (r.grammarDetails ?? []).compactMap { d in
            guard let range = (d[NSGrammarRange] as? NSValue)?.rangeValue else { return nil }
            return GrammarDetail(range: range, description: d[NSGrammarUserDescription] as? String ?? "",
                                 corrections: d[NSGrammarCorrections] as? [String] ?? [])
        }
        return GrammarResult(sentence: r.range, details: details)
    }
}

/// CEDRIC_GRAMMAR_FAKE=1 (checks only): a few fixed patterns, for when the
/// system checker flags nothing (it misses "Their going", "too the" and
/// "we was" on macOS 26).
final class FakeGrammarChecker: GrammarChecking {
    static let patterns: [(String, String, String)] = [
        (#"\bTheir going\b"#, "They’re going", "Use ‘they’re’ (they are) here, not ‘their’."),
        (#"\btoo the\b"#, "to the", "Use ‘to’ here, not ‘too’."),
        (#"\bwe was\b"#, "we were", "Use ‘were’ with ‘we’."),
        (#"\ba (?=[aeiouAEIOU])"#, "an ", "Consider ‘an’ instead."),
    ]

    @MainActor func check(_ text: String, tag: Int, completion: @escaping @Sendable ([GrammarResult]) -> Void) {
        let ns = text as NSString
        var out: [GrammarResult] = []
        for (p, fix, why) in Self.patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let sentence = ns.paragraphRange(for: m.range)
                out.append(GrammarResult(sentence: sentence, details: [GrammarDetail(
                    range: NSRange(location: m.range.location - sentence.location, length: m.range.length),
                    description: why, corrections: [fix.trimmingCharacters(in: .whitespaces)])]))
            }
        }
        DispatchQueue.global().async { completion(out) }
    }
}

extension Notification.Name {
    /// A tab's grammar issues changed (the checks wait for it).
    static let cedricGrammarChecked = Notification.Name("CedricGrammarChecked")
}

@MainActor
final class EditorGrammar {
    private weak var tab: EditorWindowController?
    private var timer: Timer?
    /// Issues found, document ranges, sorted. Drawn as underlines.
    private(set) var issues: [GrammarIssue] = [] {
        didSet {
            // Nothing to redraw when nothing changed (opening a large file
            // must not invalidate its whole, huge text view); otherwise
            // only what is on screen.
            guard let tv = tab?.primaryTextView else { return }
            let ranges = issues.map(\.range)
            guard ranges != tv.grammarRanges else { return }
            tv.grammarRanges = ranges
            tv.setNeedsDisplay(tv.visibleRect)
        }
    }
    /// Whether the last pass found the text to be prose (nil: not looked yet).
    private(set) var lastSawProse: Bool?
    /// Passes run (checks).
    private(set) var passes = 0
    /// Not in This File: no grammar bubbles for this tab (the underlines stay).
    var hintsOffHere = false
    /// Right-click › Ignore: these words stay unmarked in this tab.
    private var ignored = Set<String>()
    private var offerTimer: Timer?
    private var running = false
    private var rerun = false

    static var checker: GrammarChecking = DevEnvironment.values["CEDRIC_GRAMMAR_FAKE"] == "1"
        ? FakeGrammarChecker() : SystemGrammarChecker()
    static let pause: TimeInterval = DevEnvironment.values["CEDRIC_GRAMMAR_PAUSE"].flatMap(Double.init) ?? 3
    /// One bubble per 10 minutes across the app (CEDRIC_GRAMMAR_INTERVAL for the checks).
    static var policy = GrammarPopupPolicy(
        minInterval: DevEnvironment.values["CEDRIC_GRAMMAR_INTERVAL"].flatMap(Double.init) ?? 600,
        typingPause: 3)

    init(tab: EditorWindowController) {
        self.tab = tab
    }

    /// Documents longer than this (UTF-16 units) are never checked: an
    /// email or a letter is far shorter, and a pass starts on the main
    /// thread (copying the owl's window), which a multi-megabyte log
    /// shouldn't pay for.
    static let maxLength = 1_000_000

    /// The setting, the language and file name, not large mode, not a
    /// PDF, at most `maxLength`.
    var mayCheck: Bool {
        guard let tab, Settings.shared.checkGrammar, !tab.extrasPaused, tab.textView.isEditable,
              (tab.textView.textStorage?.length ?? 0) <= Self.maxLength else { return false }
        return ProseDetector.languageAllows(tab.doc.language, fileName: tab.doc.fileURL?.lastPathComponent)
    }

    /// After a "not prose" verdict: the length then, and when. The next
    /// pass waits until the text has grown or shrunk by `recheckChars`
    /// or `recheckAfter` seconds have passed, so typing in a log or a
    /// list doesn't start a pass at every pause.
    private var notProseAt: (length: Int, date: Date)?
    static let recheckChars = 200
    static let recheckAfter: TimeInterval = 20

    /// Settings, language or large mode changed: check again, or clear.
    func apply() {
        notProseAt = nil
        if mayCheck { schedule(after: 1.0) } else { stop(); if !issues.isEmpty { issues = [] }; lastSawProse = nil }
    }

    /// The text changed or a file opened: look again once typing pauses
    /// (a timer, nothing else, here). Scrolling never starts a pass.
    func schedule(after delay: TimeInterval? = nil) {
        guard mayCheck else {
            if !issues.isEmpty { issues = [] }
            return
        }
        timer?.invalidate()
        let t = Timer(timeInterval: delay ?? Self.pause, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        offerTimer?.invalidate()
        offerTimer = nil
    }

    /// Edits move the underlines with their words; touched ones go.
    func textEdited(_ oldRange: NSRange, newLength: Int) {
        guard !issues.isEmpty else { return }
        issues = GrammarMap.shift(issues, oldRange: oldRange, newLength: newLength)
    }

    func issue(at offset: Int) -> GrammarIssue? {
        issues.first { NSLocationInRange(offset, $0.range) || (offset == NSMaxRange($0.range) && $0.range.length > 0 && offset > $0.range.location) }
    }

    func ignore(_ issue: GrammarIssue) {
        ignored.insert(issue.original.lowercased())
        issues.removeAll { $0.original.lowercased() == issue.original.lowercased() }
    }

    /// One pass over the owl's context window.
    private func run() {
        timer = nil
        guard let tab, mayCheck else { return }
        if running { rerun = true; return }
        if let n = notProseAt, let length = tab.textView.textStorage?.length,
           abs(length - n.length) < Self.recheckChars, Date().timeIntervalSince(n.date) < Self.recheckAfter { return }
        let window = tab.owlContextWindow()
        let ctx = window.context
        let generation = tab.doc.changeCount
        let language = tab.doc.language
        let text = ctx.text
        let start = ctx.textStart
        let checked = NSRange(location: start, length: (text as NSString).length)
        let tag = tab.textView.spellCheckerDocumentTag
        let lead = Self.markdownLead(tab, start: start)
        running = true
        passes += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let masked = ProseMask.masked(text as NSString, language: language, openFence: lead.fence, blankPrefix: lead.frontMatter)
            let sample = (masked as NSString).length > ProseDetector.sampleLimit
                ? (masked as NSString).substring(to: ProseDetector.sampleLimit) : masked
            let prose = ProseDetector.signals(sample).readsAsProse
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard prose else { self.finish(prose: false, fresh: [], checked: checked, generation: generation); return }
                    Self.checker.check(masked, tag: tag) { [weak self] results in
                        let fresh = GrammarMap.issues(results, text: masked as NSString, offset: start)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.finish(prose: true, fresh: fresh, checked: checked, generation: generation)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finish(prose: Bool, fresh: [GrammarIssue], checked: NSRange, generation: Int) {
        running = false
        defer {
            if rerun { rerun = false; schedule(after: 0.05) }
        }
        guard let tab, mayCheck else { issues = []; return }
        // Edited meanwhile: the next pass (already scheduled by the edit) decides.
        guard tab.doc.changeCount == generation else { return }
        lastSawProse = prose
        notProseAt = prose ? nil : (tab.textView.textStorage?.length ?? 0, Date())
        let ns = tab.textView.string as NSString
        let kept = fresh.filter { i in
            NSMaxRange(i.range) <= ns.length && ns.substring(with: i.range) == i.original && !ignored.contains(i.original.lowercased())
        }
        issues = prose ? GrammarMap.merge(issues, fresh: kept, checked: checked) : []
        NotificationCenter.default.post(name: .cedricGrammarChecked, object: tab)
        if prose { offerHint(userAsked: false) }
        // Automatic AI grammar only where automatic AI checks are on (never
        // on Intel by default), at most once per the AI's interval, and
        // never over the auto-review cap.
        // The built-in engine only once the user has loaded its model this
        // session (or "Load model at launch"): this pass never loads it.
        if prose, !tab.autoReviewCapped, Settings.shared.owlChat, OwlHub.shared.ai.isActive, OwlHub.shared.ai.isAutomatic,
           Self.automaticAIAllowed(),
           Date().timeIntervalSince(lastAIPass ?? .distantPast) >= AIStore.load().minInterval {
            checkWithAI(userAsked: false)
        }
    }

    /// Automatic AI grammar may run: not on the built-in engine before its
    /// model was loaded by the user (or at launch) this session, nor after
    /// a load hung. Other engines: as before.
    static func automaticAIAllowed() -> Bool {
        guard AskCedricEngine.fakeDelay == nil, AskCedricEngine.settings()?.backend == .builtIn else { return true }
        return BuiltInModelHost.shared.session.allowsAutomatic
    }

    // MARK: Check Grammar with Cedric

    /// AI passes started (checks).
    private(set) var aiPasses = 0
    private(set) var aiRunning = false
    private var lastAIPass: Date?

    /// An AI engine is on (or the test fake), Owl chat is on, and the text
    /// may be prose (not already found not to be).
    var mayCheckWithAI: Bool {
        guard mayCheck, Settings.shared.owlChat, lastSawProse != false, !aiRunning else { return false }
        return AskCedricEngine.isAvailable
    }

    /// Asks the AI engine about the prose in the owl's window (masked like
    /// the system pass). Its findings join the issues as the same green
    /// underlines (where the system checker has none), with Fix it and Fix
    /// Grammar…; asked for, the owl offers the first at once.
    func checkWithAI(userAsked: Bool, done: (@MainActor (Int) -> Void)? = nil) {
        guard let tab, mayCheckWithAI else { done?(0); return }
        let window = tab.owlContextWindow()
        let ctx = window.context
        let generation = tab.doc.changeCount
        let language = tab.doc.language
        let text = ctx.text
        let start = ctx.textStart
        let lead = Self.markdownLead(tab, start: start)
        aiRunning = true
        aiPasses += 1
        lastAIPass = Date()
        tab.owl?.setThinking(true)
        // Asked for: may load the built-in model. Automatic: may not
        // (BuiltInModelHost refuses; `automaticAIAllowed` already checked).
        BuiltInLoad.$intent.withValue(userAsked ? .userAsked : .automatic) { Task { @MainActor [weak self] in
            let masked = await Task.detached(priority: .utility) {
                ProseMask.masked(text as NSString, language: language, openFence: lead.fence, blankPrefix: lead.frontMatter)
            }.value
            var results: [GrammarResult] = []
            if let engine = await OwlChatStore.shared.engine() {
                results = (try? await AIGrammar.check(masked, engine: engine)) ?? []
            }
            guard let self else { return }
            self.aiRunning = false
            guard let tab = self.tab else { return }
            tab.owl?.setThinking(false)
            guard tab.doc.changeCount == generation, self.mayCheck else { done?(0); return }
            let ns = tab.textView.string as NSString
            let found = GrammarMap.issues(results, text: masked as NSString, offset: start).filter { i in
                NSMaxRange(i.range) <= ns.length && ns.substring(with: i.range) == i.original && !self.ignored.contains(i.original.lowercased())
                    && !self.issues.contains { NSIntersectionRange($0.range, i.range).length > 0 }
            }
            if !found.isEmpty {
                self.issues = (self.issues + found).sorted { $0.range.location < $1.range.location }
                NotificationCenter.default.post(name: .cedricGrammarChecked, object: tab)
            }
            if userAsked {
                if !found.isEmpty, let owl = tab.owl, owl.bubble == nil {
                    let hint = GrammarMap.hint(found[0], textStart: ctx.textStart)
                    owl.present(hint, context: ctx)
                } else if found.isEmpty {
                    tab.owl?.shake()
                }
            }
            done?(found.count)
        } }
    }

    /// The owl's bubble for the issue nearest after the caret in view, if
    /// the rate limit and the user's choices allow. Over the auto-review
    /// cap only when asked (the popover's Grammar Hint).
    @discardableResult
    func offerHint(userAsked: Bool) -> Bool {
        guard let tab, let owl = tab.owl, !tab.owlIdleForSpeed, owl.bubble == nil, userAsked || !owl.chatBusy else { return false }
        guard userAsked || !tab.autoReviewCapped else { return false }
        let hub = OwlHub.shared
        guard userAsked || (!hintsOffHere && !hub.coordinator.isQuiet && !hub.coordinator.never.contains(GrammarMap.globalID)) else { return false }
        // The owl's typing pause (3 s, CEDRIC_OWL_PAUSE in checks): never while typing.
        Self.policy.typingPause = hub.coordinator.typingPause
        let now = Date()
        guard Self.policy.mayPopUp(now: now, lastTyping: owl.lastTyping, userAsked: userAsked) else {
            // Only the pause is in the way: ask again when it is over (typing re-arms the pass anyway).
            let left = hub.coordinator.typingPause - now.timeIntervalSince(owl.lastTyping)
            if !userAsked, left > 0, Self.policy.mayPopUp(now: now.addingTimeInterval(left + 0.05), lastTyping: owl.lastTyping) {
                offerTimer?.invalidate()
                let t = Timer(timeInterval: left + 0.05, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.offerTimer = nil; self?.offerHint(userAsked: false) }
                }
                RunLoop.main.add(t, forMode: .common)
                offerTimer = t
            }
            return false
        }
        let ctx = tab.owlContextWindow().context
        let inView = NSRange(location: ctx.textStart, length: (ctx.text as NSString).length)
        let candidates = issues.filter { $0.range.location >= inView.location && NSMaxRange($0.range) <= NSMaxRange(inView) }
        let caret = tab.textView.selectedRange().location
        guard let issue = GrammarMap.pick(candidates, caret: caret, eligible: { [hub] i in
            userAsked || hub.coordinator.isEligible(GrammarMap.hint(i, textStart: 0), documentID: tab.doc.id)
        }) else { return false }
        let hint = GrammarMap.hint(issue, textStart: ctx.textStart)
        hub.coordinator.markShown(hint, documentID: tab.doc.id, context: ctx)
        Self.policy.noteShown(Date())
        owl.present(hint, context: ctx)
        return true
    }

    /// Issues in the owl's view now (the popover's "Grammar Hint").
    var issuesInView: Int {
        guard let tab else { return 0 }
        let ctx = tab.owlContextWindow().context
        let inView = NSRange(location: ctx.textStart, length: (ctx.text as NSString).length)
        return issues.filter { NSIntersectionRange($0.range, inView).length > 0 && !GrammarMap.isDoubledWord($0) }.count
    }

    /// Fix Grammar…: checks from the document (at most `stepLimit`
    /// characters around the caret, off the main thread) and calls back
    /// with every issue found.
    static let stepLimit = 200_000

    /// For a slice of a Markdown document starting at `start` (> 0): the
    /// fence open there (the tab's FenceIndex, cached) and how much of the
    /// slice is still front matter, so fenced code and front matter are
    /// never checked as prose when the slice starts inside them.
    static func markdownLead(_ tab: EditorWindowController, start: Int) -> (fence: String?, frontMatter: Int) {
        guard tab.doc.language == .markdown, start > 0 else { return (nil, 0) }
        let ns = tab.textView.string as NSString
        let fm = ProseMask.frontMatterEnd(ns).map { max(0, $0 - start) } ?? 0
        let index = tab.lineIndex
        guard index.length == ns.length, start <= ns.length else { return (nil, fm) }
        return (tab.fences.openFence(ns, index: index, line: index.line(containing: start)), fm)
    }

    func checkForStep(_ done: @escaping @MainActor ([GrammarIssue]) -> Void) {
        guard let tab, mayCheck else { done([]); return }
        let ns = tab.textView.string as NSString
        let caret = tab.textView.selectedRange().location
        var range = NSRange(location: 0, length: ns.length)
        if ns.length > Self.stepLimit {
            let s = ns.lineRange(for: NSRange(location: max(0, min(caret, ns.length) - Self.stepLimit / 4), length: 0)).location
            range = NSRange(location: s, length: min(Self.stepLimit, ns.length - s))
        }
        let text = ns.substring(with: range)
        let checked = range
        let language = tab.doc.language
        let generation = tab.doc.changeCount
        let tag = tab.textView.spellCheckerDocumentTag
        let lead = Self.markdownLead(tab, start: checked.location)
        DispatchQueue.global(qos: .userInitiated).async {
            let masked = ProseMask.masked(text as NSString, language: language, openFence: lead.fence, blankPrefix: lead.frontMatter)
            let sample = (masked as NSString).length > ProseDetector.sampleLimit
                ? (masked as NSString).substring(to: ProseDetector.sampleLimit) : masked
            let prose = ProseDetector.signals(sample).readsAsProse
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard prose else { done([]); return }
                    Self.checker.check(masked, tag: tag) { [weak self] results in
                        let found = GrammarMap.issues(results, text: masked as NSString, offset: checked.location)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, let tab = self.tab, tab.doc.changeCount == generation else { done([]); return }
                                let now = tab.textView.string as NSString
                                let kept = found.filter { i in
                                    NSMaxRange(i.range) <= now.length && now.substring(with: i.range) == i.original
                                        && !self.ignored.contains(i.original.lowercased())
                                }
                                self.issues = GrammarMap.merge(self.issues, fresh: kept, checked: checked)
                                done(kept)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Replaces an issue's words with `replacement`, one undo step.
    @discardableResult
    func fix(_ issue: GrammarIssue, with replacement: String) -> Bool {
        guard let tab else { return false }
        let ns = tab.textView.string as NSString
        guard NSMaxRange(issue.range) <= ns.length, ns.substring(with: issue.range) == issue.original else { NSSound.beep(); return false }
        return tab.replaceAsOneStep(issue.range, with: replacement, actionName: String(localized: "Fix Grammar"))
    }
}

// MARK: - Fix Grammar… (step-through)

/// Edit › Spelling and Grammar › Fix Grammar… and the owl's "Fix
/// Grammar…": one issue at a time in a small panel beside it (the Fix
/// Typos panel's pattern): what the checker says, its suggestions (the
/// first picked), Change, Skip and Done, and "2 of 5". Return changes,
/// Tab or ⌘→ skips, Esc is done. Each change is one undo step.
@MainActor
final class GrammarStepController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var tab: EditorWindowController?
    private(set) var stepper = GrammarStepper(issues: [], caret: 0)
    let panel: SpellStepPanel
    let wordLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let progressLabel = NSTextField(labelWithString: "")
    let table = NSTableView()
    private(set) var changeButton: NSButton!
    private(set) var skipButton: NSButton!
    private(set) var doneButton: NSButton!
    private var applying = false
    var onClose: (() -> Void)?

    var current: GrammarIssue? { stepper.current }
    var suggestions: [String] { stepper.current?.corrections ?? [] }

    init(tab: EditorWindowController) {
        self.tab = tab
        panel = SpellStepPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 220),
                               styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        panel.title = String(localized: "Fix Grammar")
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        panel.onClose = { [weak self] in self?.finish(closePanel: false) }
        wordLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        wordLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 300
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [wordLabel, progressLabel])
        table.addTableColumn(NSTableColumn(identifier: .init("s")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.style = .plain
        table.target = self
        table.doubleAction = #selector(change(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 60).isActive = true
        func button(_ t: String, _ a: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: a)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        changeButton = button(String(localized: "Change"), #selector(change(_:)))
        changeButton.keyEquivalent = "\r"
        skipButton = button(String(localized: "Skip"), #selector(skip(_:)))
        doneButton = button(String(localized: "Done"), #selector(done(_:)))
        let row = NSStackView(views: [changeButton, skipButton, NSView(), doneButton])
        let hint = NSTextField(labelWithString: String(localized: "Return: Change   Tab or ⌘→: Skip   Esc: Done"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [top, detailLabel, scroll, row, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        panel.contentView = stack
        for v in [top, scroll, row] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch e.keyCode {
        case 36, 76 where mods.isEmpty: change(nil); return true
        case 48 where mods.isEmpty: skip(nil); return true
        case 124 where mods == .command: skip(nil); return true
        case 53 where mods.isEmpty: done(nil); return true
        default: return false
        }
    }

    func start() {
        guard let tab, let w = tab.window else { return }
        w.addChildWindow(panel, ordered: .above)
        wordLabel.stringValue = String(localized: "Checking…")
        update()
        panel.makeKeyAndOrderFront(nil)
        tab.grammar.checkForStep { [weak self] found in
            guard let self, let tab = self.tab else { return }
            self.stepper = GrammarStepper(issues: found, caret: tab.textView.selectedRange().location)
            self.showNext()
        }
    }

    private func showNext() {
        stepper.next()
        update()
        if let c = stepper.current, let tab {
            tab.textView.setSelectedRange(c.range)
            tab.reveal(c.range)
            position()
        }
        panel.makeFirstResponder(table)
    }

    private func update() {
        if let c = stepper.current {
            wordLabel.stringValue = "“\(c.original)”"
            detailLabel.stringValue = c.description
            progressLabel.stringValue = stepper.progress
        } else if stepper.total > 0 || wordLabel.stringValue != String(localized: "Checking…") {
            wordLabel.stringValue = String(localized: "No more grammar suggestions.")
            detailLabel.stringValue = ""
            progressLabel.stringValue = ""
        }
        table.reloadData()
        if !suggestions.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        changeButton.isEnabled = stepper.current != nil && !suggestions.isEmpty
        skipButton.isEnabled = stepper.current != nil
        if stepper.current == nil { doneButton.keyEquivalent = "\r"; changeButton.keyEquivalent = "" }
        else { doneButton.keyEquivalent = "\u{1b}"; changeButton.keyEquivalent = "\r" }
    }

    func position() {
        guard let tab, let c = stepper.current, let w = tab.window else { return }
        let tv = tab.textView
        var rect = tv.firstRect(forCharacterRange: c.range, actualRange: nil)
        if rect.isEmpty || rect.origin == .zero { rect = w.convertToScreen(tv.convert(tv.visibleRect, to: nil)) }
        let size = panel.frame.size
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
        var origin = NSPoint(x: rect.minX - 20, y: rect.minY - size.height - 6)
        if origin.y < screen.minY { origin.y = rect.maxY + 6 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrameOrigin(origin)
    }

    @objc func change(_ sender: Any?) {
        guard let c = stepper.current else { if stepper.isFinished { done(nil) }; return }
        let r = table.selectedRow
        guard let rep = suggestions.indices.contains(r) ? suggestions[r] : suggestions.first,
              let edit = stepper.change(to: rep), let tab else { NSSound.beep(); return }
        applying = true
        let ok = tab.grammar.fix(c, with: edit.replacement)
        applying = false
        if ok { stepper.textEdited(edit.range, newLength: (edit.replacement as NSString).length) }
        showNext()
    }

    @objc func skip(_ sender: Any?) {
        guard stepper.current != nil else { NSSound.beep(); return }
        showNext()
    }

    @objc func done(_ sender: Any?) { finish(closePanel: true) }

    func finish(closePanel: Bool) {
        guard let tab else { return }
        if closePanel { panel.onClose = nil; panel.close() }
        tab.window?.removeChildWindow(panel)
        tab.window?.makeKeyAndOrderFront(nil)
        tab.window?.makeFirstResponder(tab.textView)
        onClose?()
    }

    func closeWithTab() {
        panel.onClose = nil
        tab?.window?.removeChildWindow(panel)
        panel.close()
        onClose?()
    }

    /// The user's own edits while the panel is open move what is to come.
    func textEdited(_ oldRange: NSRange, newLength: Int) {
        guard !applying else { return }
        let had = stepper.current != nil
        stepper.textEdited(oldRange, newLength: newLength)
        if had && stepper.current == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stepper.current == nil, self.panel.parent != nil else { return }
                self.showNext()
            }
        } else {
            update()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(labelWithString: suggestions[row])
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}

extension EditorWindowController {
    /// Edit › Spelling and Grammar › Fix Grammar…
    func startGrammarStep() {
        guard grammar.mayCheck else { NSSound.beep(); return }
        if let s = grammarStep, s.panel.parent != nil { s.panel.makeKeyAndOrderFront(nil); return }
        let s = GrammarStepController(tab: self)
        grammarStep = s
        s.onClose = { [weak self, weak s] in
            if let self, self.grammarStep === s { self.grammarStep = nil }
        }
        owl?.hideBubble()
        s.start()
    }
}

// MARK: - Underlines and the right-click menu

extension EditorPalette {
    /// Grammar underlines: green, distinct from spelling's red, lighter on dark themes.
    var grammarMark: UInt32 { isDark ? 0x5ccf86 : 0x1e8a3e }
}

extension EditorTextView {
    /// Right-click on a grammar underline: the suggestion first, then the usual menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let g = grammar, !grammarRanges.isEmpty else { return menu }
        let p = convert(event.locationInWindow, from: nil)
        let at = characterIndexForInsertion(at: p)
        guard let issue = g.issue(at: at) else { return menu }
        let m = menu ?? NSMenu()
        var items: [NSMenuItem] = []
        let head = NSMenuItem(title: issue.description, action: nil, keyEquivalent: "")
        head.isEnabled = false
        items.append(head)
        for c in issue.corrections.prefix(5) {
            let it = NSMenuItem(title: String(localized: "Change to “\(c)”"), action: #selector(grammarMenuFix(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = GrammarMenuChoice(issue: issue, replacement: c)
            items.append(it)
        }
        let ignore = NSMenuItem(title: String(localized: "Ignore Grammar"), action: #selector(grammarMenuIgnore(_:)), keyEquivalent: "")
        ignore.target = self
        ignore.representedObject = GrammarMenuChoice(issue: issue, replacement: nil)
        items.append(ignore)
        items.append(.separator())
        for (i, it) in items.enumerated() { m.insertItem(it, at: i) }
        lastGrammarMenu = m
        return m
    }

    @objc func grammarMenuFix(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? GrammarMenuChoice, let r = c.replacement else { return }
        grammar?.fix(c.issue, with: r)
    }

    @objc func grammarMenuIgnore(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? GrammarMenuChoice else { return }
        grammar?.ignore(c.issue)
    }
}

final class GrammarMenuChoice: NSObject {
    let issue: GrammarIssue
    let replacement: String?
    init(issue: GrammarIssue, replacement: String?) { self.issue = issue; self.replacement = replacement }
}
