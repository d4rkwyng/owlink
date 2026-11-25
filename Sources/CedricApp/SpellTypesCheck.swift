import AppKit
import CedricCore

/// CEDRIC_CHECK=spell: with spell checking off for a tab, the primary
/// text view checks nothing (`enabledTextCheckingTypes == 0`, so AppKit
/// runs no orthography pass about 1 s after every layout), and every way
/// back on restores the types it had: the setting (run-local override,
/// nothing saved), a language change (Plain Text → JSON → Plain Text),
/// and large mode's "Turn On Anyway". Spelling marks come back. The other
/// text-input switches (Writing Tools, inline predictions, the automatic
/// substitutions) don't move, nor does the view's answer to the Writing
/// Tools action (a probe: see writingTools). A split's second pane (it
/// never marks misspellings) has its types set aside and restored with
/// the primary pane's, on its own view.
/// The synchronous mask assertions are the regression check; the "no
/// pass within 2.5 s" ones are a smoke check of AppKit's callback.
/// AppKit's automatic text completion (completion candidates) is the
/// default types' bit 13 and on its own still schedules the pass, so it
/// is off while spelling is off and back with it.
extension DevChecks {
    static func spellTypesCheck(_ app: AppDelegate) {
        let savedOverride = Settings.shared.checkSpellingOverride
        let savedDefault = UserDefaults.standard.object(forKey: "checkSpellingWhileTyping") as? Bool
        Settings.shared.checkSpellingOverride = true
        let spellingBit = NSTextCheckingResult.CheckingType.spelling.rawValue
        let orthographyBit = NSTextCheckingResult.CheckingType.orthography.rawValue
        let fresh = EditorTextView.make()
        let freshTypes = fresh.enabledTextCheckingTypes

        /// Everything else a text view decides about text input.
        func traits(_ tv: NSTextView) -> [String] {
            var t = ["quote=\(tv.isAutomaticQuoteSubstitutionEnabled)", "dash=\(tv.isAutomaticDashSubstitutionEnabled)",
                     "replace=\(tv.isAutomaticTextReplacementEnabled)", "correct=\(tv.isAutomaticSpellingCorrectionEnabled)",
                     "links=\(tv.isAutomaticLinkDetectionEnabled)", "data=\(tv.isAutomaticDataDetectionEnabled)",
                     "grammar=\(tv.isGrammarCheckingEnabled)",
                     "smartInsert=\(tv.smartInsertDeleteEnabled)", "inlinePrediction=\(tv.inlinePredictionType.rawValue)"]
            if #available(macOS 15.0, *) {
                t += ["writingTools=\(tv.writingToolsBehavior.rawValue)",
                      "writingToolsResults=\(tv.allowedWritingToolsResultOptions.rawValue)",
                      "math=\(tv.mathExpressionCompletionType.rawValue)"]
            }
            return t
        }
        let freshTraits = traits(fresh)
        func hex(_ t: NSTextCheckingTypes) -> String { "0x" + String(t, radix: 16) }
        /// Writing Tools, as the view answers for it with a selection:
        /// it takes the action, its menu item validates, and the text it
        /// reads and writes (what Writing Tools hands back) is the same.
        /// A probe only: AppKit validates the action even with
        /// writingToolsBehavior .none (the traits catch that), and the
        /// panel itself, like inline predictions, needs Apple
        /// Intelligence and a person. "-" before macOS 15.2.
        func writingTools(_ tv: NSTextView) -> String {
            guard #available(macOS 15.2, *) else { return "-" }
            tv.setSelectedRange(NSRange(location: 0, length: min(13, (tv.string as NSString).length)))
            let action = #selector(NSResponder.showWritingTools(_:))
            let item = NSMenuItem(title: "Writing Tools", action: action, keyEquivalent: "")
            return "responds=\(tv.responds(to: action)) valid=\(tv.validateMenuItem(item)) "
                + "read=\(tv.readablePasteboardTypes.map(\.rawValue)) write=\(tv.writablePasteboardTypes.map(\.rawValue))"
        }
        var onWritingTools = ""
        /// The second pane's own types for the second round: orthography only.
        let secondOwn = orthographyBit

        let text = "This sentense has a tpyo in it.\nAnd a second line.\n"
        guard let tab = app.open(write("notes.txt", text)) else { expect(false, "open notes.txt"); finish(); return }
        sized(tab)
        var tv: EditorTextView { tab.primaryTextView }
        var onTypes: NSTextCheckingTypes = 0
        var onTraits: [String] = []

        func wait(_ what: String, _ seconds: Double = 8, _ cond: @escaping () -> Bool) -> (@escaping () -> Void) -> Void {
            { next in
                let start = Date()
                @MainActor func poll() {
                    if cond() { next(); return }
                    if Date().timeIntervalSince(start) > seconds { expect(false, "waited for \(what)"); next(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
                }
                poll()
            }
        }
        var marked: [String] {
            let ns = tv.string as NSString
            return tv.markedMisspellings.filter { NSMaxRange($0) <= ns.length }.map { ns.substring(with: $0) }.sorted()
        }
        /// Spelling is on and back to the types it had.
        func expectOn(_ how: String) {
            expect(tv.isContinuousSpellCheckingEnabled, "\(how): spell checking is on")
            expect(tv.enabledTextCheckingTypes == onTypes, "\(how): the checking types are restored",
                   "\(hex(tv.enabledTextCheckingTypes)) vs \(hex(onTypes))")
            expect(tv.savedCheckingTypes == nil, "\(how): nothing left set aside", tv.savedCheckingTypes.map(hex) ?? "nil")
            expect(traits(tv) == onTraits, "\(how): the other switches are as they were", "\(traits(tv)) vs \(onTraits)")
            expect(tv.isAutomaticTextCompletionEnabled, "\(how): text completion is back")
            expect(writingTools(tv) == onWritingTools, "\(how): the Writing Tools action and text types as before", "\(writingTools(tv)) vs \(onWritingTools)")
        }
        /// Spelling is off and nothing is checked.
        func expectOff(_ how: String) {
            expect(!tv.isContinuousSpellCheckingEnabled, "\(how): spell checking is off")
            expect(tv.enabledTextCheckingTypes == 0, "\(how): no text checking at all", hex(tv.enabledTextCheckingTypes))
            expect(tv.savedCheckingTypes != nil && tv.savedCheckingTypes != 0, "\(how): the types are set aside",
                   tv.savedCheckingTypes.map(hex) ?? "nil")
            expect(traits(tv) == onTraits, "\(how): Writing Tools, inline predictions and the substitutions don't move",
                   "\(traits(tv)) vs \(onTraits)")
            expect(!tv.isAutomaticTextCompletionEnabled, "\(how): text completion (bit 13) goes with the types")
            expect(writingTools(tv) == onWritingTools, "\(how): the Writing Tools action and text types don't move", "\(writingTools(tv)) vs \(onWritingTools)")
        }

        /// An edit at the end of the first line, undone at once (what
        /// schedules AppKit's text checking there), then 2.5 s: with
        /// spelling off no pass reaches the view; on, one does and the
        /// first line's misspellings are marked again.
        var passes = 0
        func poke(_ v: EditorTextView?) -> (@escaping () -> Void) -> Void {
            { next in
                guard let v else { next(); return }
                passes = v.textCheckingPasses
                v.markedMisspellings = []
                v.window?.makeFirstResponder(v)
                let end = ((v.string as NSString).range(of: "\n")).location
                v.setSelectedRange(NSRange(location: end, length: 0))
                v.insertText(" z", replacementRange: v.selectedRange())
                v.deleteBackward(nil)
                v.deleteBackward(nil)
                v.window?.displayIfNeeded()
                next()
            }
        }
        func quiet(_ how: String, _ v: @escaping @autoclosure () -> EditorTextView?) -> [(@escaping () -> Void) -> Void] {
            [{ next in poke(v())(next) },
             { next in DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { next() } },
             sync {
                 expect(v()?.enabledTextCheckingTypes == 0, "\(how): nothing to check after the edit", v().map { hex($0.enabledTextCheckingTypes) } ?? "-")
                 let n = v()?.textCheckingPasses ?? -1
                 // Smoke: a callback later than 2.5 s would be missed here.
                 expect(n == passes, "\(how): no text-checking pass after an edit (smoke, 2.5 s)", "\(n - passes) passes")
                 expect(v()?.markedMisspellings.isEmpty == true, "\(how): no marks")
             }]
        }
        func checked(_ how: String, _ v: @escaping @autoclosure () -> EditorTextView?) -> [(@escaping () -> Void) -> Void] {
            [{ next in poke(v())(next) },
             wait("\(how): a text-checking pass after an edit, and the marks") {
                 guard let tv = v() else { return true }
                 let ns = tv.string as NSString
                 let words = Set(tv.markedMisspellings.filter { NSMaxRange($0) <= ns.length }.map { ns.substring(with: $0) })
                 return tv.textCheckingPasses > passes && words.isSuperset(of: ["sentense", "tpyo"])
             }]
        }

        var big: EditorWindowController?
        // Built in parts: one `[...] + f() + [...] + ...` expression
        // timed out in Swift 6.1's type checker (CI, macOS 15).
        var steps: [(@escaping () -> Void) -> Void] = [
            sync { focus(tab) },
            wait("the first spelling marks") { marked == ["sentense", "tpyo"] },
            sync {
                expect(freshTypes != 0 && freshTypes & orthographyBit != 0, "a new text view checks orthography by default", hex(freshTypes))
                expect(tab.doc.language == .plain, "notes.txt is Plain Text", tab.doc.language.rawValue)
                onTypes = tv.enabledTextCheckingTypes
                onTraits = traits(tv)
                onWritingTools = writingTools(tv)
                if #available(macOS 15.2, *) {
                    expect(onWritingTools.hasPrefix("responds=true valid=true read=["), "spelling on: the Writing Tools action validates with a selection", onWritingTools)
                }
                expect(tv.isContinuousSpellCheckingEnabled, "spelling on: continuous checking on")
                expect(onTypes & spellingBit != 0 && onTypes & orthographyBit != 0 && onTypes == freshTypes | spellingBit,
                       "spelling on: the default types plus spelling", hex(onTypes))
                expect(tv.savedCheckingTypes == nil, "spelling on: nothing set aside")
                expect(onTraits == freshTraits, "spelling on: the other switches are a new view's", "\(onTraits) vs \(freshTraits)")
                expect(fresh.isAutomaticTextCompletionEnabled && tv.isAutomaticTextCompletionEnabled, "spelling on: text completion on, as a new view's")
            },
        ]
        steps += checked("spelling on", tv)
        steps += [
            sync { Settings.shared.checkSpellingWhileTyping = false },
            sync {
                expectOff("the setting off")
                expect(Settings.shared.checkSpellingOverride == false, "the setting goes to the run-local override")
                expect(UserDefaults.standard.object(forKey: "checkSpellingWhileTyping") as? Bool == savedDefault,
                       "the saved setting is left as it was")
            },
        ]
        steps += quiet("the setting off", tv)
        steps += [
            sync {
                // A split while spelling is off: the second pane's own types go too.
                tab.splitPanes(focusSecond: false)
            },
            sync {
                let second = tab.splitEditor?.second.textView
                expect(second != nil && second !== tv, "split: a second pane")
                expect(second?.isContinuousSpellCheckingEnabled == false && second?.enabledTextCheckingTypes == 0
                       && second?.savedCheckingTypes == freshTypes, "split, spelling off: the second pane checks nothing, a new view's types set aside",
                       second.map { "\(hex($0.enabledTextCheckingTypes)) saved=\($0.savedCheckingTypes.map(hex) ?? "nil")" } ?? "-")
                expect(second?.isAutomaticTextCompletionEnabled == false, "split, spelling off: no text completion in the second pane either")
                expect(second.map { traits($0) == onTraits } == true, "split, spelling off: the second pane's other switches are a new view's",
                       second.map { "\(traits($0))" } ?? "-")
                expect(second.map { writingTools($0) == onWritingTools } == true, "split, spelling off: the second pane's Writing Tools action and text types are the primary's",
                       second.map { writingTools($0) } ?? "-")
                expectOff("split, spelling off")
            },
        ]
        steps += quiet("split, spelling off: the second pane", tab.splitEditor?.second.textView)
        steps += [
            sync {
                expectOff("split, after the second pane's edit")
                Settings.shared.checkSpellingWhileTyping = true
            },
            sync {
                expectOn("the setting on again")
                let second = tab.splitEditor?.second.textView
                expect(second?.isContinuousSpellCheckingEnabled == false, "split, spelling on: the second pane still marks nothing (the primary's)")
                expect(second?.enabledTextCheckingTypes == freshTypes && second?.savedCheckingTypes == nil,
                       "split, spelling on: the second pane's types are back", second.map { hex($0.enabledTextCheckingTypes) } ?? "-")
                expect(second?.isAutomaticTextCompletionEnabled == true, "split, spelling on: text completion back in the second pane")
                // Off again while split: each pane sets its own types aside
                // (the second pane's made different from the primary's).
                second?.enabledTextCheckingTypes = secondOwn
                Settings.shared.checkSpellingWhileTyping = false
            },
            sync {
                expectOff("split, the setting off again")
                // Continuous checking goes first, taking the spelling bit with it.
                expect(tv.savedCheckingTypes == onTypes & ~spellingBit, "split: the primary pane set its own types aside",
                       tv.savedCheckingTypes.map(hex) ?? "nil")
                let second = tab.splitEditor?.second.textView
                expect(second?.enabledTextCheckingTypes == 0 && second?.savedCheckingTypes == secondOwn,
                       "split: the second pane set its own aside", second.map { "\(hex($0.enabledTextCheckingTypes)) saved=\($0.savedCheckingTypes.map(hex) ?? "nil")" } ?? "-")
                Settings.shared.checkSpellingWhileTyping = true
            },
            sync {
                expectOn("split, the setting on again")
                let second = tab.splitEditor?.second.textView
                expect(second?.enabledTextCheckingTypes == secondOwn && second?.savedCheckingTypes == nil,
                       "split: the second pane's own types back", second.map { "\(hex($0.enabledTextCheckingTypes)) vs \(hex(secondOwn))" } ?? "-")
                tab.unsplit()
                // A split while spelling is on: a new view's types, nothing set aside.
                tab.splitPanes(focusSecond: false)
            },
            sync {
                let second = tab.splitEditor?.second.textView
                expect(second?.enabledTextCheckingTypes == freshTypes && second?.savedCheckingTypes == nil
                       && second?.isContinuousSpellCheckingEnabled == false, "split, spelling on: the second pane has a new view's types",
                       second.map { hex($0.enabledTextCheckingTypes) } ?? "-")
                expectOn("split, spelling on")
                tab.unsplit()
            },
        ]
        steps += checked("the setting on again", tv)
        steps += [
            sync {
                expect(tab.splitEditor == nil, "unsplit")
                expectOn("unsplit")
                tab.setLanguage(.json)
            },
            sync {
                expectOff("Plain Text → JSON")
                expect(tv.markedMisspellings.isEmpty, "JSON: no marks")
            },
        ]
        steps += quiet("JSON", tv)
        steps += [
            sync { tab.setLanguage(.plain) },
            sync { expectOn("JSON → Plain Text") },
        ]
        steps += checked("JSON → Plain Text", tv)
        steps += [
            sync {
                // Large mode: off at open, back with Turn On Anyway.
                var rng = SystemRandomNumberGenerator()
                let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
                let blob = String((0..<636_000).map { _ in alphabet[Int(rng.next() % 64)] })
                big = app.open(write("big.txt", text + blob + "\n"))
                if let big { sized(big); focus(big) }
            },
            sync {
                guard let b = big else { expect(false, "open big.txt"); return }
                let btv = b.primaryTextView
                expect(b.isLargeDocument && b.extrasPaused, "big.txt: large mode on")
                expect(!btv.isContinuousSpellCheckingEnabled, "large mode: spell checking off")
                expect(btv.enabledTextCheckingTypes == 0, "large mode: no text checking at all", hex(btv.enabledTextCheckingTypes))
                expect(btv.savedCheckingTypes == freshTypes, "large mode: a new view's types set aside", btv.savedCheckingTypes.map(hex) ?? "nil")
                expect(traits(btv) == onTraits, "large mode: the other switches don't move", "\(traits(btv)) vs \(onTraits)")
                expect(!btv.isAutomaticTextCompletionEnabled, "large mode: text completion goes with the types")
            },
        ]
        steps += quiet("large mode", big?.primaryTextView)
        steps += [
            sync {
                guard let b = big else { return }
                click(b.largeBar.button, at: NSPoint(x: b.largeBar.button.bounds.midX, y: b.largeBar.button.bounds.midY))
            },
            sync {
                guard let b = big else { return }
                let btv = b.primaryTextView
                expect(!b.extrasPaused && b.largeBar.isHidden, "Turn On Anyway: the extras are back")
                expect(btv.isContinuousSpellCheckingEnabled, "Turn On Anyway: spell checking on")
                expect(btv.enabledTextCheckingTypes == onTypes, "Turn On Anyway: the checking types are a small file's",
                       "\(hex(btv.enabledTextCheckingTypes)) vs \(hex(onTypes))")
                expect(btv.savedCheckingTypes == nil, "Turn On Anyway: nothing left set aside")
                expect(traits(btv) == onTraits, "Turn On Anyway: the other switches don't move")
                expect(btv.isAutomaticTextCompletionEnabled, "Turn On Anyway: text completion is back")
            },
        ]
        steps += checked("Turn On Anyway", big?.primaryTextView)
        steps += [
            sync {
                big?.doc.markSaved()
                big?.window?.close()
                Settings.shared.checkSpellingOverride = savedOverride
                expect(UserDefaults.standard.object(forKey: "checkSpellingWhileTyping") as? Bool == savedDefault,
                       "the end: the saved setting is left as it was")
            },
        ]
        run(steps)
    }
}
