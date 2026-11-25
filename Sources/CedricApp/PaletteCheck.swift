import AppKit
import CedricCore

/// CEDRIC_CHECK=palette (Scripts/palette-check.sh, also in tools-check.sh):
/// View › Command Palette driven with real key events. ⇧⌘P through the
/// menus, the query typed into the search field, ↓ and Return through the
/// field editor's key bindings, then the command is checked to have run.
/// Also: the open time (under 50 ms), disabled rows shown and inert,
/// recent-first, Esc, ⇧⌘P again to close, what is left out of the list,
/// VoiceOver announcements, and an image tab.
@MainActor
extension DevChecks {
    static func paletteCheck(_ app: AppDelegate) {
        let tab = app.open(write("palette.txt", "HELLO PALETTE\nSecond Line\n"))!
        sized(tab)
        var opens: [Double] = []
        var keyToOpen: [Double] = []
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        var palette: CommandPalette? { CommandPalette.shared }
        var panel: NSWindow? { CommandPalette.shared?.panel }

        func open() {
            let wasOpen = palette?.isOpen == true
            // Active (a key window): the ⇧⌘P keyDown through NSApp, timed
            // from the event to the palette drawn. Not active (screen
            // locked): DevChecks.key's fallback to the menu item, untimed
            // (it validates the whole menu first).
            if NSApp.isActive, let w = NSApp.keyWindow,
               let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                        characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35) {
                let t = CACurrentMediaTime()
                NSApp.sendEvent(e)
                if !wasOpen { keyToOpen.append((CACurrentMediaTime() - t) * 1000) }
            } else {
                key("p", [.command, .shift])
            }
            if !wasOpen {
                opens.append(CommandPalette.lastOpenMilliseconds)
                print("check: palette open phases: " + CommandPalette.lastOpenPhases.map { String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: ", "))
            }
        }
        func press(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            guard let panel else { expect(false, "palette panel exists"); return }
            TypingCheck.key(panel, chars, keyCode: code, mods: mods)
        }
        func typeQuery(_ s: String) { for c in s { press(String(c), keyCodes[Character(c.lowercased())] ?? 0) } }
        func arrowDown() { press(down, 125, [.numericPad, .function]) }
        func row(_ title: String) -> CommandPalette.Row? { palette?.shownRows.first { $0.candidate.title == title } }

        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                open()
                expect(palette?.isOpen == true, "⇧⌘P opens the command palette")
                expect(panel?.parent === tab.window, "it is attached to the tab's window")
                let n = palette?.shownRows.count ?? 0
                print("check: palette rows: \(n) (the whole menu tree)")
                expect(n > 150, "it lists the menu commands", "\(n)")
                expect(palette?.lastAnnouncement == "\(n) commands", "VoiceOver hears the count", palette?.lastAnnouncement ?? "-")
                let titles = palette?.shownTitles ?? []
                expect(!titles.contains("Command Palette…"), "the palette itself is left out")
                let windowRows = palette?.shownRows.filter { $0.candidate.path.hasPrefix("Window") }.map(\.candidate.title) ?? []
                // (File › Open Recent may list palette.txt from an earlier run: that one stays.)
                expect(!windowRows.contains("palette.txt"), "the Window menu's window list is left out", "\(windowRows)")
                expect(!titles.contains { $0.contains("Services") }, "the Services menu is left out")
                expect(row("UPPERCASE")?.shortcut == "⌃⌘U", "a Text Tool, with its shortcut", row("UPPERCASE")?.shortcut ?? "-")
                expect(row("UPPERCASE")?.candidate.path == "Text › Text Tools", "its menu path", row("UPPERCASE")?.candidate.path ?? "-")
                // The 0.4.1 Text menu and the moved View items are all still listed, under their new paths.
                for (title, path) in [("Add Next Occurrence", "Text › Selection"), ("Duplicate Line", "Text › Line"),
                                      ("Comment Selection", "Text › Line"), ("Bookmark Line", "Text › Bookmarks"),
                                      ("Fold All", "Text › Folding"), ("Indent Using Tabs", "Text › Indentation"),
                                      ("Compare With…", "File › Compare"), ("Next Difference", "File › Compare"), ("Follow File", "File")] {
                    expect(row(title)?.candidate.path == path, "\(title) is listed under \(path)", row(title)?.candidate.path ?? "-")
                }
                expect(row("Bold")?.candidate.path == "Format › Markdown", "Markdown commands are there", row("Bold")?.candidate.path ?? "-")
                expect(row("Page Setup…") != nil && row("Page Setup…")?.shortcut == "", "Page Setup… has no shortcut now")
                expect(row("Save")?.candidate.enabled == true, "Save is enabled in a text tab")
                let next = row("Next Difference")
                expect(next != nil && next?.candidate.enabled == false, "Next Difference (no comparison) is shown, disabled")
                expect(row("Export as PDF…")?.candidate.enabled == false, "Markdown export is disabled in a .txt tab")
            },
            { next in snapshot("palette-open.png", window: CommandPalette.shared?.panel)(next) },
            sync {
                typeQuery("case")
                let titles = palette?.shownTitles ?? []
                print("check: palette 'case': \(titles.prefix(6))")
                expect(palette?.lastAnnouncement == "\(titles.count) commands", "VoiceOver hears the new count",
                       palette?.lastAnnouncement ?? "-")
                let at = titles.firstIndex(of: "lowercase") ?? -1
                expect(at >= 1, "lowercase is listed below the first row", "\(titles)")
                for _ in 0..<max(at, 0) { arrowDown() }
                let sel = palette?.table.selectedRow ?? -1
                expect(sel == at, "↓ moves the selection to Lowercase", "\(sel)")
                expect(palette?.lastAnnouncement.hasPrefix("lowercase, ⌃⌘L, Text › Text Tools") == true, "VoiceOver hears the selected row",
                       palette?.lastAnnouncement ?? "-")
            },
            { next in snapshot("palette-query.png", window: CommandPalette.shared?.panel)(next) },
            sync {
                press("\r", 36)
                expect(palette?.isOpen == false, "Return closes the palette")
                expect(tab.text == "hello palette\nsecond line\n", "Return ran Text › Text Tools › Lowercase", tab.text)
                expect(CommandPalette.recents.ids.first == "Text › Text Tools › lowercase", "it is now a recent command")
                expect(tab.window?.firstResponder === tab.textView, "the text view has the keyboard back")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                key("z", [.command])
                expect(tab.text == "HELLO PALETTE\nSecond Line\n", "⌘Z undoes the palette's command", tab.text)
            },
            sync {
                open()
                expect(palette?.shownTitles.first == "lowercase", "reopened: the recent command is first", "\(palette?.shownTitles.prefix(3) ?? [])")
                expect(palette?.field.stringValue == "", "the query starts empty")
                press("\u{1b}", 53)
                expect(palette?.isOpen == false, "Esc closes it")
                expect(tab.text == "HELLO PALETTE\nSecond Line\n", "Esc runs nothing")
            },
            sync {
                open()
                typeQuery("nextdiff")
                expect(palette?.shownTitles.first == "Next Difference", "a disabled command is found", "\(palette?.shownTitles ?? [])")
                press("\r", 36)
                expect(palette?.isOpen == true, "Return on a disabled command does nothing")
                arrowDown()
                expect(palette?.lastAnnouncement.hasSuffix("dimmed") == true, "VoiceOver hears it is dimmed", palette?.lastAnnouncement ?? "-")
                open() // ⇧⌘P again
                expect(palette?.isOpen == false, "⇧⌘P again closes it")
            },
            sync {
                // Opening speed: several more opens on the full menu.
                for _ in 0..<5 { open(); press("\u{1b}", 53) }
                let sorted = opens.sorted()
                let median = sorted[sorted.count / 2]
                print(String(format: "check: palette open ms: first %.2f, median %.2f, max %.2f (n=%d)", opens[0], median, sorted.last!, opens.count))
                expect(sorted.last! < 50, "every open takes under 50 ms", "\(opens)")
                if keyToOpen.isEmpty {
                    print("check: note: not the active app, so the ⇧⌘P event to drawn time wasn't measured")
                } else {
                    print(String(format: "check: palette ⇧⌘P event to drawn ms: median %.2f, max %.2f (n=%d)",
                                 keyToOpen.sorted()[keyToOpen.count / 2], keyToOpen.max()!, keyToOpen.count))
                    expect(keyToOpen.max()! < 50, "⇧⌘P to the palette drawn under 50 ms", "\(keyToOpen)")
                }
            },
            sync {
                // A bigger tree: 300 more commands in a menu of their own (about 500 in all).
                let extra = NSMenu(title: "Palette Check")
                for i in 0..<300 {
                    let sub = i % 30 == 0 ? NSMenu(title: "Group \(i / 30)") : nil
                    let it = NSMenuItem(title: "Extra Command \(i)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
                    if let sub {
                        let parent = NSMenuItem(title: "Group \(i / 30)", action: nil, keyEquivalent: "")
                        parent.submenu = sub
                        extra.addItem(parent)
                    }
                    (extra.items.last?.submenu ?? extra).addItem(it)
                }
                let top = NSMenuItem(title: "Palette Check", action: nil, keyEquivalent: "")
                top.submenu = extra
                NSApp.mainMenu?.addItem(top)
                focus(tab)
                var big: [Double] = []
                var count = 0
                for _ in 0..<7 {
                    open()
                    big.append(CommandPalette.lastOpenMilliseconds)
                    count = palette?.shownRows.count ?? 0
                    press("\u{1b}", 53)
                }
                NSApp.mainMenu?.removeItem(top)
                big.sort()
                print(String(format: "check: palette open ms with %d commands: median %.2f, max %.2f (n=%d)", count, big[big.count / 2], big.last!, big.count))
                expect(count > 450, "the bigger tree is listed", "\(count)")
                expect(big.last! < 50, "opening over ~500 commands takes under 50 ms", "\(big)")
                opens.removeLast(big.count)
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                // Any file type: an image tab.
                let png = dir.appendingPathComponent("dot.png")
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                try? rep.representation(using: .png, properties: [:])?.write(to: png)
                _ = app.open(png)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let viewer = app.viewerTabs.first { $0.fileURL.lastPathComponent == "dot.png" }
                expect(viewer != nil, "the PNG opened in an image tab")
                viewer?.window?.makeKeyAndOrderFront(nil)
                open()
                expect(palette?.isOpen == true && panel?.parent === viewer?.window, "⇧⌘P opens the palette over an image tab")
                expect(row("Save")?.candidate.enabled == false, "Save is disabled there (validated for the image tab)")
                expect((palette?.shownRows.count ?? 0) > 150, "the same commands are listed")
                press("\u{1b}", 53)
                expect(palette?.isOpen == false, "Esc closes it there too")
            },
        ]
        steps += steps3
        run(steps)
    }
}
