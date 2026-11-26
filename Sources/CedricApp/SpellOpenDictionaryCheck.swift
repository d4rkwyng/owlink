import AppKit
import CedricCore

/// Part of CEDRIC_CHECK=spellopen: what must stop AppKit's first pass from
/// being skipped. Each opens its own file with two misspellings.
///
/// - Fix Typos' Ignore All, between the first-frame check's reply and
///   AppKit's first pass (it toggles continuous checking off and on): the
///   ignored word's mark goes, the other word's stays.
/// - A word ignored straight through the spell checker (as the spelling
///   panel does) in the same interval: AppKit's pass runs and rebuilds the
///   marks.
/// - An edit, and an input method's composition, before the queued
///   first-frame check runs: it doesn't run, and AppKit's pass marks.
extension DevChecks {
    static func spellOpenDictionarySteps(_ app: AppDelegate, marked: @escaping (EditorTextView, String) -> Bool) -> [Step] {
        var panelTab: EditorWindowController?
        var directTab: EditorWindowController?
        var typedTab: EditorWindowController?
        var imeTab: EditorWindowController?

        func wait(_ what: String, _ seconds: Double, _ cond: @escaping () -> Bool) -> Step {
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
        func pause(_ s: Double) -> Step { { next in DispatchQueue.main.asyncAfter(deadline: .now() + s) { next() } } }
        func early(_ t: EditorWindowController?) -> Bool {
            guard let v = t?.primaryTextView else { return true }
            return marked(v, "tpyo") && marked(v, "wrnog")
        }
        /// The early reply is in and AppKit's first pass hasn't come yet.
        func inTheInterval(_ t: EditorWindowController?, _ what: String) {
            guard let v = t?.primaryTextView else { expect(false, "open \(what)"); return }
            expect(v.earlyTextChecks == 1 && v.textCheckingPasses == 1 && v.skippedTextChecks == 0 && !v.spellCoverage.isEmpty,
                   "\(what): after the first-frame check's reply, before AppKit's pass",
                   "early=\(v.earlyTextChecks) passes=\(v.textCheckingPasses) skipped=\(v.skippedTextChecks)")
        }
        func rebuilt(_ t: EditorWindowController?, _ what: String) {
            guard let v = t?.primaryTextView else { return }
            expect(v.skippedTextChecks == 0, "\(what): AppKit's pass is not skipped", "\(v.skippedTextChecks)")
            expect(!marked(v, "tpyo"), "\(what): the ignored word's mark goes")
            expect(marked(v, "wrnog"), "\(what): the other misspelling stays marked")
        }
        func close(_ t: EditorWindowController?) {
            t?.doc.markSaved()
            t?.window?.close()
        }

        var steps: [Step] = [
            sync {
                panelTab = app.open(write("ignore-panel.txt", "A tpyo and a wrnog here.\n"))
                sized(panelTab)
                if let panelTab { focus(panelTab) }
            },
            wait("the first-frame marks (Ignore All)", 4) { early(panelTab) },
            sync {
                inTheInterval(panelTab, "Ignore All")
                guard let t = panelTab else { return }
                t.textView.setSelectedRange(NSRange(location: 0, length: 0))
                t.startSpellStep()
                expect(t.spellStep?.current?.word == "tpyo", "Fix Typos is on the first misspelling", t.spellStep?.current?.word ?? "-")
                if let b = t.spellStep?.ignoreButton { press(b) }
            },
            wait("Ignore All's mark removed", 4) { panelTab.map { !marked($0.primaryTextView, "tpyo") } ?? true },
            pause(1.5),
            sync {
                rebuilt(panelTab, "Ignore All")
                panelTab?.spellStep?.done(nil)
                close(panelTab)
            },
        ]
        steps += [
            sync {
                directTab = app.open(write("ignore-direct.txt", "A tpyo and a wrnog there.\n"))
                sized(directTab)
                if let directTab { focus(directTab) }
            },
            wait("the first-frame marks (ignored directly)", 4) { early(directTab) },
            sync {
                inTheInterval(directTab, "ignored directly")
                guard let v = directTab?.primaryTextView else { return }
                // The spelling panel's Ignore: the dictionary changes, nothing toggles.
                NSSpellChecker.shared.ignoreWord("tpyo", inSpellDocumentWithTag: v.spellCheckerDocumentTag)
            },
            wait("AppKit's pass after the word was ignored", 4) { directTab.map { !marked($0.primaryTextView, "tpyo") } ?? true },
            pause(1.5),
            sync {
                rebuilt(directTab, "ignored directly")
                close(directTab)
            },
        ]
        steps += [
            // Typed before the queued first-frame check runs.
            sync {
                typedTab = app.open(write("typed-first.txt", "A tpyo and a wrnog.\n"))
                sized(typedTab)
                guard let t = typedTab else { return }
                focus(t)
                let v = t.primaryTextView
                v.setSelectedRange(NSRange(location: 0, length: 0))
                v.insertText("So ", replacementRange: v.selectedRange())
            },
            pause(0.3),
            sync {
                guard let v = typedTab?.primaryTextView else { expect(false, "open typed-first.txt"); return }
                expect(v.earlyTextChecks == 0 && v.spellCoverage.isEmpty, "an edit before the first-frame check: it doesn't run",
                       "early=\(v.earlyTextChecks)")
            },
            wait("AppKit's pass after the early edit", 6) { typedTab.map { marked($0.primaryTextView, "tpyo") && marked($0.primaryTextView, "wrnog") } ?? true },
            sync {
                guard let v = typedTab?.primaryTextView else { return }
                expect(v.skippedTextChecks == 0, "after the early edit nothing is skipped", "\(v.skippedTextChecks)")
                close(typedTab)
            },
        ]
        steps += [
            // An input method composing before the queued check runs.
            sync {
                imeTab = app.open(write("ime-first.txt", "A tpyo and a wrnog.\n"))
                sized(imeTab)
                guard let t = imeTab else { return }
                focus(t)
                let v = t.primaryTextView
                v.setSelectedRange(NSRange(location: 0, length: 0))
                v.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            },
            pause(0.3),
            sync {
                guard let v = imeTab?.primaryTextView else { expect(false, "open ime-first.txt"); return }
                expect(v.hasMarkedText(), "(the composition is still going)")
                expect(v.earlyTextChecks == 0 && v.spellCoverage.isEmpty, "composing before the first-frame check: it doesn't run",
                       "early=\(v.earlyTextChecks)")
                v.unmarkText()
            },
            wait("AppKit's pass after the composition", 6) { imeTab.map { marked($0.primaryTextView, "tpyo") && marked($0.primaryTextView, "wrnog") } ?? true },
            sync {
                guard let v = imeTab?.primaryTextView else { return }
                expect(v.skippedTextChecks == 0, "after the composition nothing is skipped", "\(v.skippedTextChecks)")
                close(imeTab)
            },
        ]
        return steps
    }
}
