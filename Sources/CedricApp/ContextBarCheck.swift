import AppKit
import CedricCore

/// CEDRIC_CHECK=contextbar (Scripts/contextbar-check.sh, also in
/// tools-check.sh): View › Show Context Bar driven with real events. On by
/// default, but the checks start with it off (no view); on, a Markdown tab gets the bar and a Swift tab
/// doesn't. A mouse click on Bold over a selection, then ⌘Z; ⌘2 on a
/// line; Checkbox over three lines; every other button once (one undo
/// step each); the heading pull-down; the preview toggle's state; labels
/// for VoiceOver, keyboard focus, both themes, right-to-left; the bar's
/// commands in the palette; off again drops the view. Then keystroke
/// timing in the same Markdown tab with the bar hidden and shown, rounds
/// alternating.
@MainActor
extension DevChecks {
    static func contextBarCheck(_ app: AppDelegate) {
        let start = "hello world\nTitle line\na\nb\nc\n"
        let tab = app.open(write("bar.md", start))!
        let code = app.open(write("bar.swift", "let x = 1\n"))!
        sized(tab)
        sized(code)
        var bar: ContextBarView? { tab.contextBar }
        func button(_ id: String) -> NSButton? { bar?.buttons[id] }
        func clickButton(_ id: String) {
            guard let b = button(id) else { expect(false, "the bar has a \(id) button"); return }
            // Laid out first: a click lands where the button is drawn.
            tab.window?.layoutIfNeeded()
            click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY))
        }
        func menuItem(_ action: Selector) -> NSMenuItem? { ContextBarView.menuItem(NSStringFromSelector(action)) }
        func toggleBar() {
            guard let i = menuItem(#selector(AppDelegate.toggleContextBarMenu(_:))) else { expect(false, "View › Show Context Bar exists"); return }
            NSApp.sendAction(i.action!, to: nil, from: i)
        }
        func undo() { key("z", [.command]) }
        /// One command on `select`ed text: `want` after it, `start` back after one ⌘Z.
        func roundTrip(_ id: String, select: String, _ want: String, caret: Bool = false) {
            if caret, let end = endOf(select, in: tab) {
                tab.textView.setSelectedRange(NSRange(location: end, length: 0))
            } else {
                selectText(select, in: tab)
            }
            clickButton(id)
            expect(tab.text == want, "bar \(id) on \(select.debugDescription)", tab.text.debugDescription)
            undo()
            expect(tab.text == start, "one ⌘Z undoes \(id)", tab.text.debugDescription)
        }

        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                expect(Settings.contextBarDefault, "View › Show Context Bar is on by default (UX review #3)")
                expect(Settings.shared.showContextBar == false, "the checks start with it off (no session saving)")
                expect(tab.contextBar == nil && code.contextBar == nil, "off: no bar view is built")
                expect(!tab.stack.arrangedSubviews.contains { $0 is ContextBarView }, "off: nothing in the window's stack")
                let item = menuItem(#selector(AppDelegate.toggleContextBarMenu(_:)))
                expect(item != nil && CommandPalette.validate(item!, in: tab.window) && item?.state == .off && item?.title == "Show Context Bar",
                       "the menu item is there: Show Context Bar, no checkmark", item?.title ?? "-")
                toggleBar()
                expect(Settings.shared.showContextBar, "the menu item turns it on")
                // With Full Keyboard Access the bar's pull-down is the first
                // view of the key-view loop; a new tab must still start in the text.
                expect(tab.window?.initialFirstResponder === tab.primaryTextView && code.window?.initialFirstResponder === code.primaryTextView,
                       "a new tab gives the text the keyboard first, not the bar")
                expect(bar != nil, "a Markdown tab shows the bar")
                expect(code.contextBar == nil, "a Swift tab has no bar (no set for code)")
                let stack = tab.stack.arrangedSubviews
                let bi = bar.flatMap { stack.firstIndex(of: $0) } ?? -1, si = stack.firstIndex(of: tab.split) ?? -1
                expect(bi >= 0 && bi == si - 1, "the bar sits just above the text", "bar \(bi), split \(si)")
                tab.window?.layoutIfNeeded()
                expect(abs((bar?.frame.height ?? 0) - ContextBarView.height) < 0.5, "one thin row", "\(bar?.frame.height ?? 0)")
                let ids = ContextBarSet.items(for: .markdown).map(\.id)
                expect(ids.allSatisfy { button($0) != nil }, "every Markdown item has a button", "\(bar?.buttons.keys.sorted() ?? [])")
                let item2 = menuItem(#selector(AppDelegate.toggleContextBarMenu(_:)))
                _ = item2.map { CommandPalette.validate($0, in: tab.window) }
                expect(item2?.title == "Hide Context Bar" && item2?.state == .off, "the menu item says Hide Context Bar now", item2?.title ?? "-")
            },
            snapshot("contextbar-dark.png"),
            sync {
                focus(tab)
                selectText("world", in: tab)
                clickButton("bold")
                expect(tab.text == "hello **world**\nTitle line\na\nb\nc\n", "a click on Bold wraps the selection", tab.text.debugDescription)
                expect((tab.text as NSString).substring(with: tab.textView.selectedRange()) == "world", "the word stays selected")
                expect(tab.window?.firstResponder === tab.textView, "the text keeps the keyboard after a click")
            },
            sync {
                undo()
                expect(tab.text == start, "one ⌘Z takes the bold off", tab.text.debugDescription)
            },
            sync {
                guard let end = endOf("Title", in: tab) else { return }
                tab.textView.setSelectedRange(NSRange(location: end, length: 0))
                key("2", [.command])
                expect(tab.text == "hello world\n## Title line\na\nb\nc\n", "⌘2 makes the caret's line a heading", tab.text.debugDescription)
                key("2", [.command])
                expect(tab.text == start, "⌘2 again makes it body text", tab.text.debugDescription)
                key("1", [.command])
                key("3", [.command])
                expect(tab.text == "hello world\n### Title line\na\nb\nc\n", "⌘3 replaces an H1, not stacks", tab.text.debugDescription)
            },
            sync {
                undo()
                undo()
                expect(tab.text == start, "each heading key is one undo step", tab.text.debugDescription)
            },
            sync {
                selectText("a\nb\nc", in: tab)
                clickButton("checkbox")
                expect(tab.text == "hello world\nTitle line\n- [ ] a\n- [ ] b\n- [ ] c\n", "Checkbox on 3 lines", tab.text.debugDescription)
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                clickButton("checkbox")
                expect(tab.text == "hello world\nTitle line\n- [x] a\n- [x] b\n- [x] c\n", "again: checked", tab.text.debugDescription)
            },
            sync {
                undo()
                expect(tab.text == "hello world\nTitle line\n- [ ] a\n- [ ] b\n- [ ] c\n", "⌘Z: unchecked", tab.text.debugDescription)
                undo()
                expect(tab.text == start, "⌘Z: the boxes go", tab.text.debugDescription)
            },
            sync { roundTrip("italic", select: "world", "hello *world*\nTitle line\na\nb\nc\n") },
            sync { roundTrip("strikethrough", select: "world", "hello ~~world~~\nTitle line\na\nb\nc\n") },
            sync { roundTrip("code", select: "world", "hello `world`\nTitle line\na\nb\nc\n") },
            sync { roundTrip("link", select: "world", "hello [world]()\nTitle line\na\nb\nc\n") },
            sync { roundTrip("bulletList", select: "a\nb\nc", "hello world\nTitle line\n- a\n- b\n- c\n") },
            sync { roundTrip("numberedList", select: "a\nb\nc", "hello world\nTitle line\n1. a\n2. b\n3. c\n") },
            sync { roundTrip("quote", select: "Title line", "hello world\n> Title line\na\nb\nc\n") },
            sync { roundTrip("codeBlock", select: "a\nb", "hello world\nTitle line\n```\na\nb\n```\nc\n") },
            sync { roundTrip("table", select: "Title line", "hello world\nTitle line\n\n|     |     |     |\n| --- | --- | --- |\n|     |     |     |\n|     |     |     |\n\na\nb\nc\n", caret: true) },
            sync { roundTrip("image", select: "world", "hello ![world]()\nTitle line\na\nb\nc\n") },
            sync {
                // The heading pull-down's items run the same menu commands.
                guard let p = button("heading") as? NSPopUpButton, let menu = p.menu else { expect(false, "the heading pull-down"); return }
                expect(menu.items.dropFirst().map(\.title) == ["Body", "Heading 1", "Heading 2", "Heading 3"], "the pull-down lists Body and H1–H3",
                       "\(menu.items.map(\.title))")
                expect(menu.items.dropFirst().map { MenuShortcuts.name($0) }.suffix(3) == ["⌘1", "⌘2", "⌘3"], "with their shortcuts")
                guard let end = endOf("Title", in: tab) else { return }
                tab.textView.setSelectedRange(NSRange(location: end, length: 0))
                menu.performActionForItem(at: 2)
                expect(tab.text == "hello world\n# Title line\na\nb\nc\n", "Heading 1 from the pull-down", tab.text.debugDescription)
                menu.performActionForItem(at: 1)
                expect(tab.text == start, "Body from the pull-down", tab.text.debugDescription)
            },
            sync {
                expect(button("preview")?.state == .off && !tab.previewVisible, "the preview toggle starts off")
                clickButton("preview")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() } },
            sync {
                expect(tab.previewVisible, "the preview button shows the preview")
                expect(button("preview")?.state == .on, "and shows as on")
                expect(button("preview")?.accessibilityValue() as? String == "on", "VoiceOver hears it is on")
            },
            // A click at Bold's real window point while the docked preview
            // has the keyboard. The web view must not take the hit.
            sync {
                focus(tab)
                selectText("world", in: tab)
                guard let web = tab.preview?.webView, let b = button("bold"), let w = tab.window else {
                    expect(false, "preview and bold button"); return
                }
                w.layoutIfNeeded()
                expect(w.makeFirstResponder(web) && w.firstResponder === web, "the preview's web view has the keyboard")
                let mid = NSPoint(x: b.bounds.midX, y: b.bounds.midY)
                let hit = w.contentView?.superview?.hitTest(b.convert(mid, to: nil))
                expect(hit === b, "the click lands on Bold, not the web view", hit?.identifier?.rawValue ?? "-")
                let before = tab.text
                click(b, at: mid)
                expect(tab.text != before, "a click on Bold while the preview is focused changes the text", tab.text.debugDescription)
                if tab.text != before { undo() }
                expect(tab.text == start, "the preview-focused Bold click is one undo step", tab.text.debugDescription)
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            snapshot("contextbar-preview.png"),
            sync {
                key("p", [.command, .option])
                expect(!tab.previewVisible && button("preview")?.state == .off, "⌥⌘P hides it, and the button follows")
            },
            sync {
                // VoiceOver: a toolbar, every button labelled with its menu command.
                expect(bar?.accessibilityRole() == .toolbar, "the bar is a toolbar for VoiceOver")
                let labels = ContextBarSet.items(for: .markdown).map { button($0.id)?.accessibilityLabel() ?? "" }
                print("check: contextbar labels: \(labels)")
                expect(labels.allSatisfy { !$0.isEmpty }, "every button has a VoiceOver label")
                expect(button("bold")?.accessibilityLabel() == "Bold" && button("bold")?.toolTip == "Bold (⌘B)", "Bold: label and tooltip with the key",
                       button("bold")?.toolTip ?? "-")
                // VoiceOver's press runs the command too.
                selectText("world", in: tab)
                _ = button("italic")?.accessibilityPerformPress()
                expect(tab.text == "hello *world*\nTitle line\na\nb\nc\n", "VoiceOver's press on Italic", tab.text.debugDescription)
                undo()
                // Keyboard focus (Full Keyboard Access): the buttons are in the window's key-view loop.
                let bold = button("bold")!
                var v: NSView? = tab.textView.nextKeyView, seen = 0, inLoop = false
                while let cur = v, seen < 200 { if cur === bold { inLoop = true; break }; v = cur.nextKeyView; seen += 1 }
                if !inLoop {
                    v = bold.nextKeyView; seen = 0
                    while let cur = v, seen < 200 { if cur === tab.textView { inLoop = true; break }; v = cur.nextKeyView; seen += 1 }
                }
                expect(inLoop, "the buttons are in the window's keyboard focus order")
                if NSApp.isFullKeyboardAccessEnabled {
                    expect(bold.canBecomeKeyView, "with Full Keyboard Access the buttons take focus")
                }
                selectText("world", in: tab)
                if let w = tab.window, w.isKeyWindow, w.makeFirstResponder(bold) {
                    key(" ")
                    expect(tab.text == "hello **world**\nTitle line\na\nb\nc\n", "Space on the focused Bold button", tab.text.debugDescription)
                    undo()
                    focus(tab)
                } else {
                    // AppKit only presses a focused button from the key window.
                    print("check: note: not the key window (or Full Keyboard Access off); Space on a focused button not exercised")
                    focus(tab)
                }
                expect(tab.text == start, "back to the start", tab.text.debugDescription)
            },
            sync {
                // The palette lists the bar's commands, with ⌘1–3.
                let rows = CommandPalette.collect(for: tab.window)
                let h2 = rows.first { $0.candidate.title == "Heading 2" }
                expect(h2?.shortcut == "⌘2" && h2?.candidate.path == "Format › Markdown" && h2?.candidate.enabled == true,
                       "the palette has Format › Markdown › Heading 2 (⌘2)", "\(h2?.shortcut ?? "-") \(h2?.candidate.path ?? "-")")
                for t in ["Bulleted List", "Numbered List", "Quote", "Code Block", "Insert Table", "Image Link", "Strikethrough", "Hide Context Bar"] {
                    expect(rows.contains { $0.candidate.title == t }, "the palette has \(t)")
                }
                // In a Swift tab the Markdown commands are disabled (⌘2 does nothing there).
                focus(code)
                let swiftRows = CommandPalette.collect(for: code.window)
                focus(tab)
                expect(swiftRows.first { $0.candidate.title == "Heading 2" }?.candidate.enabled == false, "⌘2 is disabled in a Swift tab")
            },
            sync {
                // Light theme: the bar follows it.
                TypingCheck.apply(TypingCheck.ThemeCase(name: "light", theme: .light, system: nil))
                let p = tab.palette
                expect(bar?.layer?.backgroundColor == NSColor(hex: p.statusBar).cgColor, "the bar takes the light theme's colour")
                expect(bar?.appearance?.name == .aqua, "light symbols in the light theme")
                // UX review #3: icons tinted from the palette, 3:1 on the bar.
                expect(button("bold")?.contentTintColor == NSColor(hex: p.contextBarIcon), "the icons take the theme's icon colour")
                let r = EditorPalettes.contrast(p.contextBarIcon, p.statusBar)
                print(String(format: "check: contextbar icon contrast light %.2f", r))
                expect(r >= 3, "icons reach 3:1 on the light bar", String(format: "%.2f", r))
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            snapshot("contextbar-light.png"),
            sync {
                TypingCheck.apply(TypingCheck.ThemeCase(name: "dark", theme: .dark, system: nil))
                expect(bar?.appearance?.name == .darkAqua, "dark symbols in the dark theme")
                // Right-to-left: the formatting buttons start at the right, the preview toggle is at the left.
                bar?.userInterfaceLayoutDirection = .rightToLeft
                bar?.layoutSubtreeIfNeeded()
                let bx = button("bold").map { $0.convert($0.bounds, to: bar).midX } ?? 0
                let px = button("preview").map { $0.convert($0.bounds, to: bar).midX } ?? 0
                expect(bx > px, "right-to-left mirrors the bar", "bold \(bx), preview \(px)")
                bar?.userInterfaceLayoutDirection = .leftToRight
                bar?.layoutSubtreeIfNeeded()
                let bx2 = button("bold").map { $0.convert($0.bounds, to: bar).midX } ?? 0
                let px2 = button("preview").map { $0.convert($0.bounds, to: bar).midX } ?? 0
                expect(bx2 < px2, "left-to-right: formatting on the left")
            },
            sync {
                // A tab switched to Markdown gets the bar; back to Swift, it goes.
                code.setLanguage(.markdown)
                expect(code.contextBar != nil, "a tab switched to Markdown gets the bar")
                code.setLanguage(.swift)
                expect(code.contextBar == nil, "and loses it back in Swift")
                // CSV / TSV: no Context Bar (its Preview eye is on the status bar: statuszoom).
                code.setLanguage(.csv)
                expect(code.contextBar == nil && !code.stack.arrangedSubviews.contains { $0 is ContextBarView },
                       "a tab switched to CSV / TSV gets no Context Bar")
                code.setLanguage(.swift)
            },
            sync { typingRounds(tab, toggle: toggleBar) },
            sync {
                if Settings.shared.showContextBar { toggleBar() }
                expect(tab.contextBar == nil && !tab.stack.arrangedSubviews.contains { $0 is ContextBarView }, "off again: the view is gone")
            },
            // On by default the bar is built in the tab's initializer, before
            // the window is current, which used to leave every button disabled.
            sync {
                focus(code)
                Settings.shared.contextBarOverride = true
                let fresh = app.open(write("launch.md", "hello world\n"))!
                sized(fresh)
                fresh.window?.layoutIfNeeded()
                let b = fresh.contextBar?.buttons["bold"]
                expect(b?.isEnabled == true, "Bold is enabled on a Markdown tab whose bar was built before the window was shown")
                selectText("world", in: fresh)
                if let b { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(fresh.text.contains("**world**"), "a click on Bold works on that tab", fresh.text.debugDescription)
            },
        ]
        steps += steps4
        run(steps)
    }

    /// Keystrokes into the Markdown tab, bar hidden and shown in
    /// alternating rounds: each key's keyDown handled and the window
    /// drawn, timed. Shown may not be slower than hidden by more than 10 %
    /// (and 0.5 ms).
    static func typingRounds(_ tab: EditorWindowController, toggle: () -> Void) {
        guard let w = tab.window else { return }
        focus(tab)
        var hidden: [Double] = [], shown: [Double] = []
        let line = "The quick brown fox jumps over the lazy dog "
        for round in 0..<6 {
            let wantShown = round % 2 == 1
            if (tab.contextBar != nil) != wantShown { toggle() }
            tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
            TypingCheck.settle(0.1)
            for ch in line {
                let t = CACurrentMediaTime()
                TypingCheck.key(w, String(ch))
                w.displayIfNeeded()
                let ms = (CACurrentMediaTime() - t) * 1000
                if wantShown { shown.append(ms) } else { hidden.append(ms) }
            }
        }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        let h = median(hidden), s = median(shown)
        print(String(format: "check: contextbar typing ms: hidden median %.3f, shown median %.3f (n=%d each)", h, s, hidden.count))
        expect(s <= h * 1.1 + 0.5, "typing with the bar shown is as fast as hidden", String(format: "%.3f vs %.3f", s, h))
    }
}
