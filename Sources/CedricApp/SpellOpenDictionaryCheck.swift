import AppKit
import CedricCore

/// Part of CEDRIC_CHECK=spellopen: what must stop AppKit's first pass from
/// being skipped. Each opens its own file with two misspellings.
///
/// - Fix Typos' Ignore All, between the first-frame check's reply and
///   AppKit's first pass (it toggles continuous checking off and on): the
///   ignored word's mark goes, the other word's stays.
/// - A word ignored straight through the spelling dictionary (as the
///   spelling panel does) in the same interval: AppKit's pass runs and
///   rebuilds the marks.
/// - A word learned straight through it in Owlink (the spelling panel's
///   Learn): its notice clears the record, and the same.
/// - A word learned in Owlink through the spelling panel with no notice
///   (AppKit's Learn need not post one), the panel shown after the early
///   check and closed again before AppKit's pass, Owlink (or the lock
///   screen) in front throughout: AppKit's pass asks about the marked
///   words, and the same. Last of the dictionary steps: once loaded, the
///   panel makes every later first pass ask.
/// - A word learned in another app after another app came to the front
///   (no notice): AppKit's pass asks, and the same. The lock screen coming
///   to the front doesn't count as another app.
///
/// The dictionary is the check's own (RecordingSpellDictionary): nothing
/// here learns or ignores a word in the user's real one. The view drops
/// the real spell checker's marks on that dictionary's words, as the real
/// one would never have made them, so the underlines still show whether
/// AppKit's pass ran.
/// - An edit, and an input method's composition, before the queued
///   first-frame check runs: it doesn't run, and AppKit's pass marks.
extension DevChecks {
    /// `marked`: recorded by Owlink and drawn by AppKit. `drawn`: how many
    /// of the word's occurrences carry AppKit's own `.spellingState`, of
    /// how many (the underline itself, whatever Owlink recorded).
    static func spellOpenDictionarySteps(_ app: AppDelegate, marked: @escaping (EditorTextView, String) -> Bool,
                                         drawn: @escaping (EditorTextView, String) -> (marked: Int, of: Int)) -> [Step] {
        var panelTab: EditorWindowController?
        var directTab: EditorWindowController?
        var learnTab: EditorWindowController?
        var elsewhereTab: EditorWindowController?
        var lockTab: EditorWindowController?
        var silentTab: EditorWindowController?
        // Made up, and learned only in the check's own dictionary.
        let learnedWord = "zqxfakelrn", elsewhereWord = "zqxfakeelse"
        let silentWord = "zqxfakesil"
        let dictionary = EditorTextView.spellDictionary as? RecordingSpellDictionary
        /// Another app (or the lock screen) activated, as NSWorkspace says
        /// it: only Owlink's own observer hears this in-process notice.
        func activated(_ bundleID: String) -> Bool {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                                       userInfo: [NSWorkspace.applicationUserInfoKey: app])
            return true
        }
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
        func early(_ t: EditorWindowController?, _ word: String = "tpyo") -> Bool {
            guard let v = t?.primaryTextView else { return true }
            return marked(v, word) && marked(v, "wrnog")
        }
        /// The early reply is in and AppKit's first pass hasn't come yet.
        func inTheInterval(_ t: EditorWindowController?, _ what: String) {
            guard let v = t?.primaryTextView else { expect(false, "open \(what)"); return }
            expect(v.earlyTextChecks == 1 && v.textCheckingPasses == 1 && v.skippedTextChecks == 0 && !v.spellCoverage.isEmpty,
                   "\(what): after the first-frame check's reply, before AppKit's pass",
                   "early=\(v.earlyTextChecks) passes=\(v.textCheckingPasses) skipped=\(v.skippedTextChecks)")
        }
        /// No occurrence of `word` carries AppKit's underline any more.
        func undrawn(_ v: EditorTextView, _ word: String) -> Bool {
            let d = drawn(v, word)
            return d.of > 0 && d.marked == 0
        }
        func rebuilt(_ t: EditorWindowController?, _ what: String, _ word: String = "tpyo") {
            guard let v = t?.primaryTextView else { return }
            expect(v.skippedTextChecks == 0, "\(what): AppKit's pass is not skipped", "\(v.skippedTextChecks)")
            let ignored = drawn(v, word), other = drawn(v, "wrnog")
            expect(ignored.of > 0 && ignored.marked == 0, "\(what): AppKit's underline on the \(word == "tpyo" ? "ignored" : "learned") word goes",
                   "\(ignored.marked) of \(ignored.of) drawn")
            expect(other.of > 0 && other.marked == other.of, "\(what): AppKit still draws the other misspelling",
                   "\(other.marked) of \(other.of) drawn")
            expect(marked(v, "wrnog"), "\(what): the other misspelling stays marked")
        }
        func close(_ t: EditorWindowController?) {
            t?.doc.markSaved()
            t?.window?.close()
        }

        guard let dictionary else {
            return [sync { expect(false, "spellopen uses the check's own spelling dictionary", "\(Swift.type(of: EditorTextView.spellDictionary))") }]
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
            sync { expect(dictionary.ignoreCalls.last == "tpyo", "Ignore All: ignored in the check's dictionary", "\(dictionary.ignoreCalls)") },
            wait("Ignore All's mark removed", 4) { panelTab.map { undrawn($0.primaryTextView, "tpyo") } ?? true },
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
                dictionary.ignoreWord("tpyo", inSpellDocumentWithTag: v.spellCheckerDocumentTag)
            },
            wait("AppKit's pass after the word was ignored", 4) { directTab.map { undrawn($0.primaryTextView, "tpyo") } ?? true },
            pause(1.5),
            sync {
                rebuilt(directTab, "ignored directly")
                close(directTab)
            },
        ]
        steps += [
            sync {
                learnTab = app.open(write("learn-direct.txt", "A \(learnedWord) and a wrnog there.\n"))
                sized(learnTab)
                if let learnTab { focus(learnTab) }
            },
            wait("the first-frame marks (learned directly)", 4) { early(learnTab, learnedWord) },
            sync {
                inTheInterval(learnTab, "learned directly")
                guard let v = learnTab?.primaryTextView else { return }
                // The spelling panel's Learn: the dictionary's notice clears the
                // record whether or not Owlink is the active app (inactive, AppKit's
                // pass would ask about the marked words anyway).
                dictionary.learnWord(learnedWord)
                expect(v.spellCoverage.isEmpty, "learned directly: the spell checker's notice clears the record",
                       "app active=\(NSApp.isActive) asksLearned=\(v.spellCoverage.asksLearned)")
            },
            wait("AppKit's pass after the word was learned", 4) { learnTab.map { undrawn($0.primaryTextView, learnedWord) } ?? true },
            pause(1.5),
            sync {
                expect(!NSSpellChecker.shared.hasLearnedWord(learnedWord), "(and the user's own dictionary doesn't have it)")
                rebuilt(learnTab, "learned directly", learnedWord)
                close(learnTab)
            },
        ]
        steps += [
            sync {
                elsewhereTab = app.open(write("learn-elsewhere.txt", "A \(elsewhereWord) and a wrnog there.\n"))
                sized(elsewhereTab)
                if let elsewhereTab { focus(elsewhereTab) }
            },
            wait("the first-frame marks (learned in another app)", 4) { early(elsewhereTab, elsewhereWord) },
            sync {
                inTheInterval(elsewhereTab, "learned in another app")
                guard let v = elsewhereTab?.primaryTextView else { return }
                expect(activated("com.apple.dock"), "(the Dock is running)")
                expect(v.spellCoverage.asksLearned, "another app in front: AppKit's pass will ask about the marked words")
                // Learned over there: nothing in Owlink hears of it.
                dictionary.learnElsewhere(elsewhereWord)
                expect(!v.spellCoverage.isEmpty, "learned in another app: no notice, the record stays")
            },
            wait("AppKit's pass after the word was learned in another app", 4) {
                elsewhereTab.map { undrawn($0.primaryTextView, elsewhereWord) } ?? true
            },
            pause(1.5),
            sync {
                expect(dictionary.asked.contains(elsewhereWord), "AppKit's pass asked about it", "\(dictionary.asked)")
                rebuilt(elsewhereTab, "learned in another app", elsewhereWord)
                close(elsewhereTab)
            },
        ]
        steps += [
            sync {
                lockTab = app.open(write("lock-screen.txt", "A tpyo and a wrnog there.\n"))
                sized(lockTab)
                if let lockTab { focus(lockTab) }
            },
            wait("the first-frame marks (lock screen)", 4) { early(lockTab) },
            sync {
                inTheInterval(lockTab, "lock screen")
                guard let v = lockTab?.primaryTextView else { return }
                if v.spellCoverage.asksLearned {
                    // Owlink wasn't in front at the early check: it asks anyway.
                    print("check: note: lock screen: Owlink not in front at the early check, the pass asks regardless")
                } else {
                    expect(activated(SpellFrontApp.lockScreen), "(the lock screen's process is running)")
                    expect(!v.spellCoverage.asksLearned, "the lock screen in front: not another app")
                }
                expect(activated("com.apple.dock"), "(the Dock is running)")
                expect(v.spellCoverage.asksLearned, "then another app: it asks")
            },
            wait("AppKit's pass (lock screen)", 4) { lockTab.map { $0.primaryTextView.spellCoverage.isEmpty } ?? true },
            pause(1.5),
            sync {
                guard let v = lockTab?.primaryTextView else { return }
                expect(v.skippedTextChecks == 1, "nothing learned or ignored: AppKit's pass is still skipped", "\(v.skippedTextChecks)")
                close(lockTab)
            },
        ]
        /// Owlink in front at the early check, as spellopen needs it for the
        /// silent-learn steps: otherwise the pass asks regardless.
        func inFrontWithNoUI(_ v: EditorTextView, _ what: String) {
            guard !v.spellCoverage.asksLearned else {
                print("check: note: \(what): Owlink not in front at the early check (active=\(NSApp.isActive)), the pass asks regardless")
                return
            }
            expect(!SpellingPanel.inUse, "\(what): AppKit's spelling panel not loaded at the early check")
        }
        steps += [
            sync {
                silentTab = app.open(write("learn-silent.txt", "A \(silentWord) and a wrnog there.\n"))
                sized(silentTab)
                if let silentTab { focus(silentTab) }
            },
            wait("the first-frame marks (learned silently in the spelling panel)", 4) { early(silentTab, silentWord) },
            sync {
                inTheInterval(silentTab, "learned silently in the spelling panel")
                guard let v = silentTab?.primaryTextView else { return }
                inFrontWithNoUI(v, "learned silently in the spelling panel")
                // Edit › Show Spelling and Grammar, on the view (AppKit's
                // panel: shows it, reads only).
                v.showGuessPanel(nil)
                expect(SpellingPanel.inUse, "the spelling panel is loaded")
                expect(v.spellCoverage.asksLearned, "spelling panel shown: AppKit's pass will ask about the marked words")
                // Its Learn, with no notice: nothing in Owlink hears of it.
                dictionary.learnSilently(silentWord)
                expect(!v.spellCoverage.isEmpty, "learned silently: no notice, the record stays")
                // Closed again before the pass.
                NSSpellChecker.shared.spellingPanel.orderOut(nil)
                expect(!NSSpellChecker.shared.spellingPanel.isVisible, "(the panel is closed again)")
                if let t = silentTab { focus(t) }
            },
            wait("AppKit's pass after the word was learned silently in the spelling panel", 4) {
                silentTab.map { undrawn($0.primaryTextView, silentWord) } ?? true
            },
            pause(1.5),
            sync {
                expect(dictionary.asked.contains(silentWord), "AppKit's pass asked about the silently learned word", "\(dictionary.asked)")
                expect(!NSSpellChecker.shared.hasLearnedWord(silentWord), "(and the user's own dictionary doesn't have it)")
                rebuilt(silentTab, "learned silently in the spelling panel", silentWord)
                close(silentTab)
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
