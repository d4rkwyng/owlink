import AppKit
import CedricCore

/// CEDRIC_CHECK=spellopen: an opened file's visible misspellings are
/// marked as soon as its first frame is up (EditorSpelling.checkVisibleNow,
/// before AppKit's own first pass, which comes about 1 s after layout),
/// only the visible text is checked, and AppKit's first pass over that
/// same text is skipped, once. Every later pass is AppKit's own: text
/// scrolled to is checked when it is shown, typing is checked, and an edit
/// after the first-frame check means AppKit's first pass runs. Ignore,
/// edits and compositions: SpellOpenDictionaryCheck.swift. A data file
/// (JSON) gets no check at all. A mark counts when AppKit draws it (its
/// spelling attribute at the word, not beside it), and goes when the word
/// is corrected.
extension DevChecks {
    static func spellOpenCheck(_ app: AppDelegate) {
        let savedOverride = Settings.shared.checkSpellingOverride
        Settings.shared.checkSpellingOverride = true
        // A misspelling on each of 600 lines: many screens.
        let text = (0..<600).map { "Line \($0) has a tpyo in it." }.joined(separator: "\n") + "\n"
        let opened = Date()
        guard let tab = app.open(write("many.txt", text)) else { expect(false, "open many.txt"); finish(); return }
        sized(tab)
        focus(tab)
        var tv: EditorTextView { tab.primaryTextView }
        var firstMarks: TimeInterval = -1
        var visibleAtOpen = NSRange(location: 0, length: 0)
        var corrected = NSRange(location: 0, length: 0)
        var passes = 0

        func wait(_ what: String, _ seconds: Double = 6, _ cond: @escaping () -> Bool) -> Step {
            { next in
                let start = Date()
                @MainActor func poll() {
                    if cond() { next(); return }
                    if Date().timeIntervalSince(start) > seconds { expect(false, "waited for \(what)"); next(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { poll() } }
                }
                poll()
            }
        }
        func marks(_ v: EditorTextView) -> [NSRange] {
            let n = (v.string as NSString).length
            return v.markedMisspellings.filter { NSMaxRange($0) <= n }
        }
        func words(_ v: EditorTextView) -> Set<String> {
            let ns = v.string as NSString
            return Set(marks(v).map { ns.substring(with: $0) })
        }
        func ranges(of word: String, in r: NSRange, of v: EditorTextView) -> [NSRange] {
            let ns = v.string as NSString
            var found: [NSRange] = [], from = r.location
            while from < NSMaxRange(r) {
                let f = ns.range(of: word, options: [], range: NSRange(location: from, length: NSMaxRange(r) - from))
                guard f.location != NSNotFound else { break }
                found.append(f)
                from = NSMaxRange(f)
            }
            return found
        }
        func occurrences(_ word: String, in r: NSRange, of v: EditorTextView) -> Int { ranges(of: word, in: r, of: v).count }
        /// Every whole-word `word` in `r` carries AppKit's own spelling
        /// mark (spellingMarked), and the words either side of each don't.
        func nativeMarks(_ word: String, in r: NSRange, of v: EditorTextView) -> (marked: Int, of: Int, neighboursMarked: Int) {
            let ns = v.string as NSString
            let found = ranges(of: word, in: r, of: v)
            var neighbours = 0
            for f in found {
                // " has a tpyo in": "a" before, "in" after.
                let before = ns.rangeOfCharacter(from: .letters, options: .backwards, range: NSRange(location: 0, length: f.location))
                let after = ns.rangeOfCharacter(from: .letters, options: [], range: NSRange(location: NSMaxRange(f), length: ns.length - NSMaxRange(f)))
                for n in [before, after] where n.location != NSNotFound && spellingMarked(v, n) { neighbours += 1 }
            }
            return (found.filter { spellingMarked(v, $0) }.count, found.count, neighbours)
        }
        func type(_ s: String, at loc: Int, in v: EditorTextView) {
            v.window?.makeFirstResponder(v)
            v.setSelectedRange(NSRange(location: loc, length: 0))
            v.insertText(s, replacementRange: v.selectedRange())
        }

        var json: EditorWindowController?
        var edited: EditorWindowController?
        // Built in parts: one long literal of closures can time out in
        // Swift 6.1's type checker.
        var steps: [Step] = [
            // Polled from the open: the first marks, and who made them.
            wait("the visible misspellings marked", 4) {
                guard !marks(tab.primaryTextView).isEmpty else { return false }
                firstMarks = Date().timeIntervalSince(opened)
                return true
            },
            sync {
                expect(tv.skippedTextChecks == 0 && tv.textCheckingPasses == 1,
                       "the first marks come from the first-frame check, before AppKit's own pass",
                       "skipped=\(tv.skippedTextChecks) passes=\(tv.textCheckingPasses) after \(Int(firstMarks * 1000)) ms")
                print(String(format: "check: note first marks %.0f ms after open", firstMarks * 1000))
                visibleAtOpen = tv.visibleCharacterRange ?? visibleAtOpen
                let m = marks(tv)
                expect(words(tv) == ["tpyo"], "only the misspelling is marked", "\(words(tv))")
                expect(m.allSatisfy { NSMaxRange($0) <= NSMaxRange(visibleAtOpen) }, "only the visible text is checked",
                       "visible \(visibleAtOpen), last mark \(m.map(NSMaxRange).max() ?? -1) of \((tv.string as NSString).length)")
                let shown = occurrences("tpyo", in: visibleAtOpen, of: tv)
                expect(shown > 0 && m.count == shown, "every visible misspelling is marked", "\(m.count) of \(shown)")
                let n = nativeMarks("tpyo", in: visibleAtOpen, of: tv)
                expect(n.of > 0 && n.marked == n.of, "AppKit draws each one (its spelling attribute at the word)", "\(n.marked) of \(n.of)")
                expect(n.neighboursMarked == 0 && !spellingMarked(tv, ranges(of: "has", in: visibleAtOpen, of: tv).first ?? NSRange()),
                       "and not the words beside it", "\(n.neighboursMarked) neighbours marked")
            },
        ]
        steps += [
            // AppKit's first pass (about 1 s after layout) asks for the same text.
            wait("AppKit's first pass, skipped", 4) { tab.primaryTextView.skippedTextChecks > 0 },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() } },
            sync {
                expect(tv.skippedTextChecks == 1, "AppKit's first pass is skipped once", "\(tv.skippedTextChecks)")
                expect(tv.textCheckingPasses == 1, "the open's text is checked once, not twice", "\(tv.textCheckingPasses) passes")
                expect(tv.spellCoverage.isEmpty, "after it, nothing is skipped any more")
                passes = tv.textCheckingPasses
                tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length, length: 0))
            },
            wait("the misspellings scrolled to, marked by AppKit's pass", 6) {
                let v = tab.primaryTextView
                let n = (v.string as NSString).length
                return v.textCheckingPasses > passes && marks(v).contains { $0.location > n - 400 }
            },
        ]
        steps += [
            sync {
                expect(tv.skippedTextChecks == 1, "scrolling: AppKit's pass is not skipped", "\(tv.skippedTextChecks)")
                let ns = tv.string as NSString
                let near = marks(tv).filter { $0.location > ns.length - 400 }
                expect(!near.isEmpty && near.allSatisfy { ns.substring(with: $0) == "tpyo" },
                       "scrolled to: the misspellings marked where they are", near.map { ns.substring(with: $0) }.joined(separator: ","))
                let visible = tv.visibleCharacterRange ?? NSRange()
                expect(tv.visibleRect.minY > 0 && visible.location > 0, "(scrolled down)", "\(tv.visibleRect.minY) \(visible)")
                let n = nativeMarks("tpyo", in: NSRange(location: ns.length - 400, length: 400), of: tv)
                expect(n.of > 0 && n.marked == n.of && n.neighboursMarked == 0,
                       "scrolled to: AppKit draws them at the words, not beside them",
                       "\(n.marked) of \(n.of), \(n.neighboursMarked) neighbours")
                // Corrected: the last one is "typo" now.
                let lastTypo = ranges(of: "tpyo", in: NSRange(location: ns.length - 400, length: 400), of: tv).last ?? NSRange()
                corrected = lastTypo
                tv.window?.makeFirstResponder(tv)
                tv.insertText("typo", replacementRange: lastTypo)
            },
            // AppKit drops the mark with the edit; whatever it checks
            // after, the mark must not come back.
            wait("the corrected word's mark gone", 6) { !spellingMarked(tab.primaryTextView, corrected) },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() } },
            sync {
                let ns = tv.string as NSString
                expect(ns.substring(with: corrected) == "typo", "(corrected)", ns.substring(with: corrected))
                expect(!spellingMarked(tv, corrected), "corrected: AppKit's mark is gone, and stays gone")
                let n = nativeMarks("tpyo", in: NSRange(location: ns.length - 400, length: 400), of: tv)
                expect(n.of > 0 && n.marked == n.of, "the other lines' misspellings stay drawn", "\(n.marked) of \(n.of)")
                passes = tv.textCheckingPasses
                type(" wrnog ", at: (tv.string as NSString).length - 1, in: tv)
            },
            wait("a typed misspelling, marked", 6) {
                let v = tab.primaryTextView
                return words(v).contains("wrnog") && ranges(of: "wrnog", in: NSRange(location: 0, length: (v.string as NSString).length), of: v)
                    .allSatisfy { spellingMarked(v, $0) }
            },
            sync {
                expect(tv.skippedTextChecks == 1, "typing: AppKit's pass is not skipped", "\(tv.skippedTextChecks)")
                tab.doc.markSaved()
                edited = app.open(write("edited.txt", "A tpyo here.\nA second line.\n"))
                sized(edited)
                if let edited { focus(edited) }
            },
        ]
        steps += [
            // An edit after the first-frame check: AppKit's first pass runs.
            wait("the first-frame check of a second file", 4) { edited.map { words($0.primaryTextView) == ["tpyo"] } ?? true },
            sync {
                guard let e = edited?.primaryTextView else { expect(false, "open edited.txt"); return }
                expect(!e.spellCoverage.isEmpty, "the first-frame check is recorded")
                type("Thrid ", at: 0, in: e)
                expect(e.spellCoverage.isEmpty, "an edit clears it")
            },
            wait("AppKit's pass after the edit", 6) { edited.map { words($0.primaryTextView).contains("Thrid") } ?? true },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() } },
        ]
        steps += [
            sync {
                guard let e = edited?.primaryTextView else { return }
                expect(e.skippedTextChecks == 0, "after an edit nothing is skipped", "\(e.skippedTextChecks)")
                expect(words(e) == ["Thrid", "tpyo"], "both misspellings marked", "\(words(e))")
                edited?.doc.markSaved()
                edited?.window?.close()
            },
        ]
        steps += spellOpenDictionarySteps(app, marked: { v, word in
            // Recorded and drawn: every whole "word" in the text.
            let all = ranges(of: word, in: NSRange(location: 0, length: (v.string as NSString).length), of: v)
            return words(v).contains(word) && !all.isEmpty && all.allSatisfy { spellingMarked(v, $0) }
        }, drawn: { v, word in
            let all = ranges(of: word, in: NSRange(location: 0, length: (v.string as NSString).length), of: v)
            return (all.filter { spellingMarked(v, $0) }.count, all.count)
        })
        steps += [
            sync {
                json = app.open(write("data.json", "{\"tpyo\": \"wrnog\"}\n"))
                sized(json)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { next() } },
            sync {
                guard let j = json?.primaryTextView else { expect(false, "open data.json"); return }
                expect(j.textCheckingPasses == 0 && j.spellCoverage.isEmpty && j.markedMisspellings.isEmpty,
                       "JSON: no check at all", "passes=\(j.textCheckingPasses)")
                json?.window?.close()
                Settings.shared.checkSpellingOverride = savedOverride
            },
        ]
        steps.append(snapshot("spellopen.png", window: tab.window))
        run(steps, gap: 0.05)
    }

    /// AppKit's own spelling mark over any of `r`: on TextKit 2 the
    /// layout manager's `.spellingState` rendering attribute, which is
    /// what it draws the red underline from (not Owlink's record).
    static func spellingMarked(_ v: NSTextView, _ r: NSRange) -> Bool {
        guard r.length > 0, let tlm = v.textLayoutManager else { return false }
        let doc = tlm.documentRange.location
        guard let from = tlm.location(doc, offsetBy: r.location) else { return false }
        var hit = false
        tlm.enumerateRenderingAttributes(from: from, reverse: false) { lm, attrs, range in
            let a = lm.offset(from: doc, to: range.location), b = lm.offset(from: doc, to: range.endLocation)
            if a >= NSMaxRange(r) { return false }
            if b > r.location, let state = attrs[.spellingState] as? Int, state & NSAttributedString.SpellingState.spelling.rawValue != 0 {
                hit = true
                return false
            }
            return true
        }
        return hit
    }
}
