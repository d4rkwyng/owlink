import AppKit
import CedricCore

/// CEDRIC_CHECK=spellopen: an opened file's visible misspellings are
/// marked as soon as its first frame is up (EditorSpelling.checkVisibleNow,
/// before AppKit's own first pass, which comes about 1 s after layout),
/// only the visible text is checked, and AppKit's first pass over that
/// same text is skipped, once. Every later pass is AppKit's own: text
/// scrolled to is checked when it is shown, typing is checked, and an edit
/// after the first-frame check means AppKit's first pass runs. A data file
/// (JSON) gets no check at all.
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
        func occurrences(_ word: String, in r: NSRange, of v: EditorTextView) -> Int {
            let ns = v.string as NSString
            var n = 0, from = r.location
            while from < NSMaxRange(r) {
                let f = ns.range(of: word, range: NSRange(location: from, length: NSMaxRange(r) - from))
                guard f.location != NSNotFound else { break }
                n += 1
                from = NSMaxRange(f)
            }
            return n
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
                passes = tv.textCheckingPasses
                type(" wrnog ", at: (tv.string as NSString).length - 1, in: tv)
            },
            wait("a typed misspelling, marked", 6) { words(tab.primaryTextView).contains("wrnog") },
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
}
