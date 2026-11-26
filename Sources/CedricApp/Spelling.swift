import AppKit
import CedricCore

/// Spell checking while typing, with the system's own checker
/// (NSSpellChecker: nothing downloaded, nothing sent anywhere).
///
/// NSTextView's continuous checking does the work (and gives the standard
/// right-click suggestions, Learn Spelling and Ignore Spelling), but every
/// batch of results passes through `EditorTextView.handleTextCheckingResults`,
/// which keeps only misspellings inside `SpellScope`: prose in Plain Text
/// and Markdown (not code spans or links), only comments and strings in
/// code, never identifiers. The marks are the text view's spelling state,
/// a drawing attribute: the text's colours are never touched.
@MainActor
final class EditorSpelling {
    /// Weak: a timer can fire after the tab is gone.
    private weak var tab: EditorWindowController?

    init(tab: EditorWindowController) {
        self.tab = tab
    }

    /// The parts of `range` the checker may flag.
    func scope(for range: NSRange) -> [NSRange] {
        guard let tab else { return [] }
        let ns = tab.textView.string as NSString
        let range = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let index = tab.lineIndex
        guard index.lineCount > 0 else { return [] }
        let first = index.line(containing: range.location)
        let last = index.line(containing: NSMaxRange(range))
        let tokens = tab.colorizer.engine.tokens(forLines: first..<(last + 1), in: ns, index: index)
        return SpellScope.ranges(language: tab.doc.language, tokens: tokens, in: range)
    }

    func scopeContains(_ r: NSRange, in scope: [NSRange]) -> Bool {
        scope.contains { $0.location <= r.location && NSMaxRange(r) <= NSMaxRange($0) }
    }

    /// Turns checking on or off for the tab (View › Check Spelling While Typing).
    func apply() {
        // Large mode: no checking passes over a huge line.
        guard let tab else { return }
        let on = Settings.shared.checkSpellingWhileTyping && !tab.extrasPaused && checksThisDocument
        let tv = tab.primaryTextView
        tv.spelling = self
        // Whatever changed, AppKit's next pass is its own.
        tv.spellCoverage.clear()
        Self.setChecking(tv, on: on, spells: true)
        // A split's second pane never marks misspellings (they're the
        // primary pane's) but has AppKit's checking types of its own:
        // they go and come back with the primary pane's, each pane's
        // set aside on its own view.
        if let second = tab.splitEditor?.second.textView { Self.setChecking(second, on: on, spells: false) }
    }

    /// One view's checking. `spells`: continuous spell checking follows
    /// `on` (the primary pane); otherwise it is left off.
    private static func setChecking(_ tv: EditorTextView, on: Bool, spells: Bool) {
        // Back on: the checking types set aside below come back first.
        if on, let saved = tv.savedCheckingTypes {
            tv.enabledTextCheckingTypes = saved
            tv.savedCheckingTypes = nil
        }
        if spells, tv.isContinuousSpellCheckingEnabled != on { tv.isContinuousSpellCheckingEnabled = on }
        // Off: nothing left to check, so no AppKit text-checking pass
        // (orthography, data detectors) about 1 s after every layout.
        // AppKit's automatic text completion (bit 13 of the default
        // types) goes too: on its own it still schedules that pass.
        if !on, tv.enabledTextCheckingTypes != 0 {
            tv.savedCheckingTypes = tv.enabledTextCheckingTypes
            tv.enabledTextCheckingTypes = 0
        }
    }

    /// Checks the visible text as soon as the first frame is up, through
    /// the view's own continuous checking (the same request, results and
    /// marks as AppKit's pass). AppKit schedules its first pass about 1 s
    /// after the first layout; that pass is then skipped if it asks for
    /// nothing more (`SpellCheckCoverage`), so the marks show about a
    /// second sooner and the text is checked once, not twice. Visible text
    /// only, as AppKit's pass: the rest is checked when it is scrolled to.
    func checkVisibleNow() {
        guard let tab else { return }
        let tv = tab.primaryTextView
        guard tv.isContinuousSpellCheckingEnabled, tv.window?.isVisible == true,
              let r = tv.visibleCharacterRange, r.length > 0 else { return }
        let types = SpellCheckCoverage.earlyTypes(enabled: tv.enabledTextCheckingTypes)
        tv.spellCoverage.checked(r, types: types)
        tv.checkingVisibleNow = true
        tv.checkText(in: r, types: types, options: [:])
        tv.checkingVisibleNow = false
    }

    /// Not data (JSON, YAML, TOML/INI/.env, XML, CSV/TSV): no underlines, no typo hints there.
    private var checksThisDocument: Bool {
        guard let tab else { return false }
        return SpellScope.checks(language: tab.doc.language, fileName: tab.doc.fileURL?.lastPathComponent)
    }

    /// "Fix N typos?" runs on the owl's own schedule (OwlHub.fire): only
    /// once typing has paused for the owl's pause (3 s) and at most once
    /// per query interval (30 s), after an edit or an open, when the rules
    /// had nothing to say. Never while typing, and at most one typo bubble
    /// per `policy.minInterval` (10 min, like grammar) across the app.
    static var policy = GrammarPopupPolicy(
        minInterval: DevEnvironment.values["CEDRIC_TYPO_INTERVAL"].flatMap(Double.init) ?? 600,
        typingPause: 3)

    /// Whether the typo offer may look at this tab at all (cheap, no text
    /// read). Never over the auto-review cap: the offer is automatic.
    var mayOffer: Bool {
        guard let tab, tab.owl != nil, !tab.extrasPaused, !tab.autoReviewCapped, SpellScope.isProse(tab.doc.language), checksThisDocument,
              Settings.shared.checkSpellingWhileTyping else { return false }
        return true
    }

    /// Called by the owl's scheduled query when the rules found nothing:
    /// offers the typo fix if the pause and the rate limit allow.
    /// `skipPause`: the checks, which have just opened the tab.
    @discardableResult
    func offerAfterPause(skipPause: Bool = false) -> Bool {
        guard mayOffer, let tab, let owl = tab.owl else { return false }
        Self.policy.typingPause = OwlHub.shared.coordinator.typingPause
        guard Self.policy.mayPopUp(now: Date(), lastTyping: skipPause ? nil : owl.lastTyping) else { return false }
        guard owl.offerTypoFix(self, tab: tab) else { return false }
        Self.policy.noteShown(Date())
        return true
    }

    /// Misspellings in scope within `range` (the visible lines by default).
    func misspellings(in range: NSRange? = nil) -> [NSRange] {
        guard checksThisDocument, let tv = tab?.primaryTextView else { return [] }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return [] }
        let r = range ?? tv.visibleCharacterRange ?? NSRange(location: 0, length: min(ns.length, 20_000))
        var found: [NSRange] = []
        for s in scope(for: r) where s.length > 0 {
            let results = NSSpellChecker.shared.check(tv.string, range: s, types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                                      options: nil, inSpellDocumentWithTag: tv.spellCheckerDocumentTag,
                                                      orthography: nil, wordCount: nil)
            found += results.map(\.range).filter { $0.length > 0 && NSMaxRange($0) <= NSMaxRange(s) }
        }
        return found
    }

    /// The owl's "Fix N typos?": the fixable misspellings with a first
    /// suggestion, as one replacement over the span they cover.
    func typoFix(_ ranges: [NSRange]) -> (range: NSRange, replacement: String, count: Int)? {
        guard let tv = tab?.textView else { return nil }
        let ns = tv.string as NSString
        var fixes: [(range: NSRange, replacement: String)] = []
        for r in ranges where NSMaxRange(r) <= ns.length {
            let word = ns.substring(with: r)
            guard SpellScope.isFixable(word, in: ns, at: r),
                  let guess = NSSpellChecker.shared.guesses(forWordRange: r, in: tv.string, language: nil,
                                                            inSpellDocumentWithTag: tv.spellCheckerDocumentTag)?.first else { continue }
            fixes.append((r, guess))
        }
        guard fixes.count >= 3, let c = SpellScope.combinedFix(ns, fixes) else { return nil }
        return (c.range, c.replacement, fixes.count)
    }

    /// Edit › Spelling and Grammar › Check Document Now: the next
    /// misspelling after the selection (in scope), selected and shown in
    /// the spelling panel. The system's own checkSpelling: would stop on
    /// identifiers.
    func selectNext() {
        guard let tv = tab?.textView else { return }
        let ns = tv.string as NSString
        let all = misspellings(in: NSRange(location: 0, length: min(ns.length, 500_000)))
        let after = NSMaxRange(tv.selectedRange())
        guard let next = all.first(where: { $0.location >= after }) ?? all.first else { NSSound.beep(); return }
        tv.setSelectedRange(next)
        tv.scrollRangeToVisible(next)
        NSSpellChecker.shared.updateSpellingPanel(withMisspelledWord: ns.substring(with: next))
    }
}

extension EditorTextView {
    /// AppKit's scheduled checking (NSTextCheckingController) and Check
    /// Document Now come through here. The first request after the
    /// first-frame check is skipped when that check already did it.
    override func checkText(in range: NSRange, types checkingTypes: NSTextCheckingTypes,
                            options: [NSSpellChecker.OptionKey: Any] = [:]) {
        if !checkingVisibleNow, !spellCoverage.isEmpty, spellCoverage.take(range, types: checkingTypes) {
            skippedTextChecks += 1
            return
        }
        super.checkText(in: range, types: checkingTypes, options: options)
    }

    /// Every batch of continuous-checking results: only misspellings in
    /// scope are kept (see EditorSpelling). Recorded for the checks.
    /// The results' ranges can be relative to `range` (TextKit 2 hands
    /// them over so when the pass doesn't start at the top of the text;
    /// TextKit 1 as document offsets; TextCheckingOffset tells them apart):
    /// the scope and the record use document offsets, AppKit gets the
    /// results it handed over.
    override func handleTextCheckingResults(_ results: [NSTextCheckingResult], forRange range: NSRange,
                                            types checkingTypes: NSTextCheckingTypes,
                                            options: [NSSpellChecker.OptionKey: Any] = [:],
                                            orthography: NSOrthography, wordCount: Int) {
        textCheckingPasses += 1
        spellCoverage.resultsArrived(for: range)
        guard let spelling else {
            super.handleTextCheckingResults(results, forRange: range, types: checkingTypes, options: options,
                                            orthography: orthography, wordCount: wordCount)
            return
        }
        let scope = spelling.scope(for: range)
        let ns = string as NSString
        let inDocument = TextCheckingOffset.documentRanges(checked: range, results: results.map(\.range),
                                                           spelling: results.map { $0.resultType == .spelling }, text: ns,
                                                           expected: textLayoutManager != nil ? .relative : .document)
        var kept: [NSTextCheckingResult] = []
        var marked: [NSRange] = []
        for (r, d) in zip(results, inDocument) {
            guard r.resultType == .spelling else { kept.append(r); continue }
            guard spelling.scopeContains(d, in: scope) else { continue }
            kept.append(r)
            marked.append(d)
        }
        let length = ns.length
        markedMisspellings.removeAll { NSIntersectionRange($0, range).length > 0 || NSMaxRange($0) > length }
        markedMisspellings += marked
        super.handleTextCheckingResults(kept, forRange: range, types: checkingTypes, options: options,
                                        orthography: orthography, wordCount: wordCount)
    }
}
