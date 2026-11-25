import AppKit
import CedricCore

/// In-process check of grammar in prose (Grammar.swift), run by
/// Scripts/tools-check.sh: an email typed with real key events into a
/// .txt tab with the owl on; after the typing pause the system checker's
/// finding ("a elephant") is underlined and offered by the owl, Fix it is
/// one undo step; then with the fake checker (the system's flags nothing
/// in "Their going too the store … we was late") the right-click menu,
/// the rate limit, the owl's "Grammar Hint", "Not in This File" and Fix
/// Grammar…; and the same sentences in a Swift comment, a JSON string, a
/// .log file and a .txt full of log lines get no underline and no hint.
///
///   CEDRIC_CHECK=grammar
@MainActor
extension DevChecks {
    static func grammarCheck(_ app: AppDelegate) {
        let restore = keepDefaults([OwlCoordinator.neverKey, "checkGrammarInProse", "owlPlacement"])
        Settings.shared.checkGrammar = true
        OwlHub.shared.coordinator.resetNeverShown()
        Settings.shared.owlOverride = true
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        OwlController.assumeVisible = true
        let system = EditorGrammar.checker
        let fake = FakeGrammarChecker()
        let email = "Hi Sam,\n\nWe saw a elephant at the zoo today. Their going too the store tomorrow and we was late.\n\nThanks,\nDerek\n"
        let tab = app.open(write("email.txt", ""))!
        sized(tab)
        let tv = tab.textView
        var owl: OwlController? { tab.owl }
        var title: String { owl?.bubble?.hint.title ?? "-" }
        var g: EditorGrammar { tab.grammar }
        func ns() -> NSString { tab.text as NSString }
        func wait(_ seconds: Double, until: @escaping () -> Bool) -> (@escaping () -> Void) -> Void {
            { next in
                let end = Date().addingTimeInterval(seconds)
                @MainActor func poll() { if until() || Date() > end { next() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } } } }
                poll()
            }
        }
        var bubbleWhileTyping = false
        var shownAfter: TimeInterval?
        var passesBefore = 0
        var original = ""
        var negatives: [EditorWindowController] = []
        let sentence = "Their going too the store tomorrow and we was late."
        run([
            sync {
                focus(tab)
                expect(owl != nil, "the owl is on")
                expect(g.mayCheck, "a .txt tab may be checked")
                // Typed with real key events, as a user would.
                if let w = tab.window { TypingCheck.type(w, email) }
                bubbleWhileTyping = owl?.bubble != nil
                expect(tab.text == email, "the email was typed", tab.text.debugDescription)
            },
            sync { expect(owl?.bubble == nil && !bubbleWhileTyping, "no grammar bubble while typing") },
            wait(8) {
                if owl?.bubble != nil, shownAfter == nil, let o = owl { shownAfter = Date().timeIntervalSince(o.lastTyping) }
                return owl?.bubble != nil
            },
            sync {
                expect((shownAfter ?? 0) >= 3, "the bubble waits for the owl's 3 s typing pause",
                       "shown \(String(format: "%.2f", shownAfter ?? -1)) s after the last key")
                let a = ns().range(of: "a elephant")
                expect(g.lastSawProse == true, "the email reads as prose")
                expect(tv.grammarRanges.contains(NSRange(location: a.location, length: 1)), "system checker: ‘a elephant’ underlined",
                       "\(tv.grammarRanges) issues=\(g.issues.map(\.original))")
                expect(title == "Grammar: ‘a’ → ‘an’?", "the owl offers it after the pause", "bubble=\(title)")
                expect(owl?.bubble?.hint.detail?.contains("an") == true, "with the checker's words", owl?.bubble?.hint.detail ?? "-")
                let buttons = owl?.bubble?.buttons.map(\.title) ?? []
                expect(buttons == ["Fix it", "Fix Grammar…", "Not in This File", "Don’t show again"], "bubble buttons", "\(buttons)")
                if g.issues.contains(where: { $0.original == "Their going" || $0.original == "we was" }) {
                    print("check: note: the system checker flagged the owner's example sentence too")
                } else {
                    print("check: note: the system checker flags nothing in “\(sentence)” (it does flag ‘a elephant’); the fake checker covers it below")
                }
                original = tab.text
            },
            snapshot("grammar-owl-offer.png"),
            sync {
                guard let fix = owl?.bubble?.buttons.first(where: { $0.title == "Fix it" }) else { expect(false, "Fix it button"); return }
                press(fix)
                expect(tab.text.contains("We saw an elephant"), "Fix it applies ‘an’", tab.text.debugDescription)
                expect(!tv.grammarRanges.contains { NSIntersectionRange($0, ns().range(of: "an elephant")).length > 0 }, "and its underline goes")
                focus(tab)
                tv.undoManager?.undo()
                expect(tab.text == original, "one ⌘Z undoes it", tab.text.debugDescription)
                tv.undoManager?.redo()
                expect(tab.text.contains("We saw an elephant"), "⇧⌘Z redoes it")
                // The fake checker from here on: it flags the owner's example.
                EditorGrammar.checker = fake
                passesBefore = g.passes
                g.schedule(after: 0.1)
            },
            wait(5) { g.passes > passesBefore && g.issues.contains { $0.original == "Their going" } },
            sync {
                let names = g.issues.map(\.original)
                expect(names.contains("Their going") && names.contains("too the") && names.contains("we was"),
                       "fake checker: three issues underlined", "\(names)")
                expect(owl?.bubble == nil, "rate limit: no second grammar bubble within the interval", "bubble=\(title)")
                // Right-click on "too the": the suggestion first.
                let r = ns().range(of: "too the")
                let screen = tv.firstRect(forCharacterRange: NSRange(location: r.location + 1, length: 1), actualRange: nil)
                guard let w = tab.window else { return }
                let p = w.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
                guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                      let menu = tv.menu(for: e) else { expect(false, "right-click menu"); return }
                let titles = menu.items.prefix(4).map(\.title)
                expect(titles.count >= 3 && titles[0] == "Use ‘to’ here, not ‘too’." && titles[1] == "Change to “to the”" && titles[2] == "Ignore Grammar",
                       "right-click on the underline shows the suggestion", "\(titles)")
                let before = tab.text
                if let item = menu.items.first(where: { $0.title == "Change to “to the”" }), let a = item.action {
                    NSApp.sendAction(a, to: item.target, from: item)
                }
                expect(tab.text.contains("going to the store"), "Change to applies it", tab.text.debugDescription)
                tv.undoManager?.undo()
                expect(tab.text == before, "one undo step")
                tv.undoManager?.redo()
            },
            snapshot("grammar-underlines.png"),
            sync {
                // Clicking the owl: "Grammar Hint" in his popover ignores the rate limit.
                owl?.owl.onClick?()
                expect(owl?.popoverButton("Grammar Hint") != nil, "the owl's popover offers Grammar Hint")
                owl?.grammarHintNow()
                expect(title.hasPrefix("Grammar: "), "Grammar Hint shows one now", "bubble=\(title)")
            },
            snapshot("grammar-bubble-buttons.png"),
            sync {
                if let b = owl?.bubble?.buttons.first(where: { $0.title == "Not in This File" }) { press(b) }
                expect(g.hintsOffHere && owl?.bubble == nil, "Not in This File")
                EditorGrammar.policy = GrammarPopupPolicy(minInterval: 0, typingPause: 3)
                passesBefore = g.passes
                g.schedule(after: 0.1)
            },
            wait(3) { g.passes > passesBefore },
            sync {
                expect(owl?.bubble == nil, "no bubbles in this file after Not in This File", "bubble=\(title)")
                expect(!g.issues.isEmpty, "the underlines stay")
                // Fix Grammar… from the menu.
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                app.fixGrammarMenu(nil)
            },
            wait(5) { tab.grammarStep?.current != nil },
            sync {
                guard let s = tab.grammarStep else { expect(false, "Fix Grammar… opens its panel"); return }
                expect(s.panel.isVisible, "Fix Grammar… opens its panel")
                expect(s.current?.original == "Their going", "it starts at the first issue after the caret", s.current?.original ?? "-")
                expect(s.progressLabel.stringValue == "1 of 2", "1 of 2", s.progressLabel.stringValue)
                expect(tv.selectedRange() == s.current?.range, "and selects it")
            },
            snapshot("grammar-step.png"),
            sync {
                guard let s = tab.grammarStep else { return }
                keyTo(s.panel, "\r", code: 36)
                expect(tab.text.contains("They’re going to the store"), "Return changes it", tab.text.debugDescription)
                expect(s.current?.original == "we was", "and moves on", s.current?.original ?? "-")
                expect(s.progressLabel.stringValue == "2 of 2", "2 of 2", s.progressLabel.stringValue)
                keyTo(s.panel, "\t", code: 48)
                expect(s.current == nil, "Tab skips the last one")
                keyTo(s.panel, "\u{1b}", code: 53)
                expect(tab.grammarStep == nil, "Esc closes it")
                tab.doc.markSaved()
            },
            // The same sentence in code and data: no underline, no hint.
            sync {
                EditorGrammar.policy = GrammarPopupPolicy(minInterval: 0, typingPause: 0)
                tab.window?.close()
                let lines = (0..<6).map { "2026-11-18 10:42:0\($0) INFO worker \($0): \(sentence)" }.joined(separator: "\n")
                negatives = [
                    app.open(write("Note.swift", "// \(sentence)\nlet x = 1 // \(sentence)\n"))!,
                    app.open(write("data.json", "{\"note\": \"\(sentence)\", \"other\": \"\(sentence)\"}\n"))!,
                    app.open(write("server.log", "\(sentence)\n\(sentence)\n"))!,
                    app.open(write("events.txt", lines + "\n"))!,
                ]
                for t in negatives { sized(t); focus(t); t.grammar.schedule(after: 0.1) }
            },
            wait(3) { false },
            sync {
                for t in negatives {
                    let name = t.doc.fileURL?.lastPathComponent ?? "-"
                    expect(t.grammar.issues.isEmpty && t.textView.grammarRanges.isEmpty, "\(name): no grammar underline",
                           "\(t.grammar.issues.map(\.original))")
                    expect(!(t.owl?.presentedHint.map { GrammarMap.isGrammarHint($0.hint.id) } ?? false), "\(name): no grammar hint")
                }
                expect(!negatives[0].grammar.mayCheck && !negatives[1].grammar.mayCheck && !negatives[2].grammar.mayCheck,
                       "Swift, JSON and .log are never checked")
                expect(negatives[3].grammar.passes > 0 && negatives[3].grammar.lastSawProse == false,
                       "a .txt of log lines is looked at and isn't prose", "passes=\(negatives[3].grammar.passes) prose=\(String(describing: negatives[3].grammar.lastSawProse))")
                // Large mode: never.
                let big = String(repeating: "We saw a elephant. ", count: 7_000) + "\n"
                let large = app.open(write("large.txt", big))!
                expect(large.extrasPaused && !large.grammar.mayCheck, "large mode: never checked")
                // Over 1 MB (not large mode): never checked either.
                let mb = String(repeating: "We saw a elephant at the zoo today, and it was a fine day.\n", count: 18_000)
                let long = app.open(write("long.txt", mb))!
                expect(!long.extrasPaused && !long.grammar.mayCheck, "over 1 MB: never checked",
                       "large=\(long.extrasPaused) length=\((mb as NSString).length)")
                // Setting off: the underlines go.
                let t2 = app.open(write("email2.txt", email))!
                negatives.append(t2)
                t2.grammar.schedule(after: 0.05)
            },
            wait(3) { negatives.last?.grammar.issues.isEmpty == false },
            sync {
                let t2 = negatives.last!
                expect(!t2.grammar.issues.isEmpty, "an opened email is checked without typing")
                Settings.shared.checkGrammar = false
                t2.grammar.apply()
                expect(t2.grammar.issues.isEmpty && t2.textView.grammarRanges.isEmpty, "Check grammar in prose off: no underlines")
                expect(!t2.grammar.mayCheck, "and no checking")
                EditorGrammar.checker = system
                Settings.shared.owlOverride = false
                restore()
            },
        ])
    }
}
