import AppKit
import CedricCore

/// In-process checks of the 0.1 gap features, run by Scripts/tools-check.sh
/// like the other DevChecks: real key events where a key does it (Tab,
/// ⇧Tab and the menus' key equivalents), menu items' actions otherwise.
///
///   CEDRIC_CHECK=indent|print|macbasics|filterlines|encodings|cli|dropfile
@MainActor
extension DevChecks {
    static func gapCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "indent": indent(app)
        case "print": printing(app)
        case "macbasics": macBasics(app)
        case "filterlines": filterLinesCheck(app)
        case "encodings": encodings(app)
        case "cli": cli(app)
        case "dropfile": dropFile(app)
        default: return featureCheck(name, app)
        }
        return true
    }

    /// A key straight to the front window (keys that are no menu's
    /// shortcut, such as ⇧Tab).
    static func rawKey(_ chars: String, _ mods: NSEvent.ModifierFlags, code: UInt16) {
        guard let w = frontWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
    }

    static func backtab() { rawKey(String(UnicodeScalar(UInt8(NSBackTabCharacter))), [.shift], code: 48) }

    /// The main-menu item with this action (and represented object).
    static func menuItem(action: Selector, represented: AnyHashable? = nil) -> NSMenuItem? {
        var hit: NSMenuItem?
        func walk(_ m: NSMenu) {
            for i in m.items where hit == nil {
                if i.action == action, represented == nil || (i.representedObject as? AnyHashable) == represented { hit = i }
                if let s = i.submenu { walk(s) }
            }
        }
        NSApp.mainMenu.map(walk)
        return hit
    }

    /// Chooses a menu item (validated as AppKit does): for commands
    /// without a shortcut.
    @discardableResult
    static func choose(_ action: Selector, _ represented: AnyHashable? = nil) -> Bool {
        guard let item = menuItem(action: action, represented: represented) else {
            expect(false, "a menu item exists for \(action)"); return false
        }
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        if !app.validateMenuItem(item) { return false }
        return NSApp.sendAction(action, to: app, from: item)
    }

    /// Saves the user's own values for these defaults keys; the returned
    /// closure puts them back exactly (removing keys that weren't set).
    static func keepDefaults(_ keys: [String]) -> () -> Void {
        let d = UserDefaults.standard
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        return { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
    }

    // MARK: Indent and outdent

    static func indent(_ app: AppDelegate) {
        let src = "func f() {\n    a()\n    b()\n}\n"
        let tab = app.open(write("ind.swift", src))!
        let tabs = app.open(write("tabs.c", "int f() {\n\treturn 1;\n\tif (x) {\n\t\ty();\n\t}\n}\n"))!
        let restore = keepDefaults(["tabWidth", "indentWithTabs"])
        sized(tab)
        let tv = tab.textView
        func sel(_ loc: Int, _ len: Int = 0) { tv.setSelectedRange(NSRange(location: loc, length: len)) }
        run([
            sync {
                focus(tab)
                expect(tab.indentation == Indentation(usesTabs: false, width: 4), "a 4-space file is detected as such", "\(tab.indentation)")
                // Lines 2–3 selected, Tab.
                sel(11, 16)
                key("\t")
                expect(tab.text == "func f() {\n        a()\n        b()\n}\n", "Tab on two selected lines indents both", tab.text)
                expect(tv.selectedRange() == NSRange(location: 11, length: 24), "they stay selected", "\(tv.selectedRange())")
            },
            sync {
                backtab()
                expect(tab.text == src, "⇧Tab outdents them", tab.text)
            },
            sync {
                backtab()
                expect(tab.text == "func f() {\na()\nb()\n}\n", "⇧Tab again, to the margin", tab.text)
            },
            sync { key("z", [.command]) },
            sync {
                key("z", [.command])
                expect(tab.text == "func f() {\n        a()\n        b()\n}\n", "each ⌘Z undoes one shift", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text == src, "and back to the original", tab.text)
            },
            sync {
                sel(2)
                key("]", [.command])
                expect(tab.text == "    func f() {\n    a()\n    b()\n}\n", "⌘] indents the caret's line", tab.text)
                expect(tv.selectedRange().location == 6, "the caret moves with its text", "\(tv.selectedRange())")
                key("[", [.command])
                expect(tab.text == src, "⌘[ outdents it", tab.text)
                expect(tv.undoManager?.undoActionName == "Outdent", "undo is named", tv.undoManager?.undoActionName ?? "-")
            },
            sync {
                // No selection: Tab inserts spaces to the next stop.
                sel(13)
                key("\t")
                expect(tab.text == "func f() {\n      a()\n    b()\n}\n", "Tab at column 3 inserts 2 spaces (to the next stop)", tab.text)
                key("z", [.command])
            },
            sync {
                // Text › Indentation: tabs, width 2.
                choose(#selector(AppDelegate.indentUsingTabsMenu(_:)))
                choose(#selector(AppDelegate.tabWidthMenu(_:)), 2)
                expect(tab.indentation == Indentation(usesTabs: true, width: 2), "the tab's indentation is picked from the menu", "\(tab.indentation)")
                sel(11)
                key("\t")
                expect(tab.text.hasPrefix("func f() {\n\t    a()"), "Tab now inserts a tab", tab.text)
                let para = tv.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                let two = ("  " as NSString).size(withAttributes: [.font: Settings.shared.font]).width
                expect(abs((para?.defaultTabInterval ?? 0) - two) < 0.01, "tabs are drawn 2 columns wide",
                       "\(para?.defaultTabInterval ?? 0) vs \(two)")
                let item = menuItem(action: #selector(AppDelegate.tabWidthMenu(_:)), represented: 2)!
                _ = app.validateMenuItem(item)
                expect(item.state == .on, "the menu shows Tab Width: 2 checked")
                key("z", [.command])
            },
            sync {
                choose(#selector(AppDelegate.convertIndentationToSpacesMenu(_:)))
                expect(tab.text == "func f() {\n    a()\n    b()\n}\n", "Convert to Spaces keeps the columns", tab.text)
                expect(tab.indentation == Indentation(usesTabs: false, width: 2), "and indents with spaces from then on")
            },
            sync {
                // A tab-indented file: Tab inserts a tab; Return after "{" indents with a tab.
                focus(tabs)
                expect(tabs.indentation.usesTabs, "a tab-indented file is detected as such", "\(tabs.indentation)")
                tabs.textView.setSelectedRange(NSRange(location: 9, length: 0))
                key("\r")
                expect(tabs.text.hasPrefix("int f() {\n\t\n"), "Return after { indents with a tab", tabs.text)
                key("\t")
                expect(tabs.text.hasPrefix("int f() {\n\t\t\n"), "and Tab inserts a tab", tabs.text)
            },
            snapshot("indent.png"),
            sync {
                // Settings' default applies to a new tab (put back after).
                Settings.shared.defaultIndentation = Indentation(usesTabs: false, width: 3)
                app.newTab(nil)
                let t = app.tabs.last!
                expect(t.indentation == Indentation(usesTabs: false, width: 3), "a new tab uses the default from Settings", "\(t.indentation)")
                expect(t.tabKeyInsertsSpaces, "a saved spaces default: Tab types spaces")
                UserDefaults.standard.removeObject(forKey: "indentWithTabs")
                UserDefaults.standard.removeObject(forKey: "tabWidth")
                expect(!t.tabKeyInsertsSpaces, "no default saved: Tab types a tab character, as before")
                restore()
            },
        ])
    }

    // MARK: Print

    static func printing(_ app: AppDelegate) {
        let long = String(repeating: "wrap me ", count: 40)
        let src = "first line\n\tindented\n" + long + "\nlast\n"
        let tab = app.open(write("print.txt", src))!
        sized(tab)
        let pdf = dir.appendingPathComponent("print.pdf")
        let restore = keepDefaults([PrintOptions.lineNumbersKey])
        run([
            sync {
                focus(tab)
                let item = menuItem("p", [.command])
                expect(item?.action == #selector(AppDelegate.printDocument(_:)), "⌘P is File › Print…", item?.title ?? "-")
                let palette = menuItem("p", [.command, .shift])
                expect(palette?.action == #selector(AppDelegate.showCommandPalette(_:)), "⇧⌘P is View › Command Palette…", palette?.title ?? "-")
                let setup = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.first { $0.action == #selector(AppDelegate.pageSetup(_:)) }
                expect(setup != nil && setup?.keyEquivalent == "", "File › Page Setup… is there, with no shortcut", setup?.keyEquivalent ?? "-")
                // ⌘P: the print panel comes up as a sheet on the tab (then cancelled).
                key("p", [.command])
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() } },
            sync {
                let sheet = tab.window?.attachedSheet
                expect(sheet != nil, "⌘P shows the print panel", "\(String(describing: tab.window?.sheets))")
                if let sheet { tab.window?.endSheet(sheet, returnCode: .cancel) }
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                // To a PDF, without panels: with line numbers.
                let info = NSPrintInfo()
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = pdf
                let (op, view, _) = tab.makePrintOperation(lineNumbers: true, info: info)
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                let ok = op.run()
                expect(ok, "printing to a PDF succeeds")
                let printed = view.textStorage?.string ?? ""
                expect(printed.hasPrefix("\t1\tfirst line\n\t2\t\tindented\n\t3\twrap"), "line numbers lead each line", printed.prefix(60).debugDescription)
                expect(!printed.contains("\t5\t"), "the empty line after the final newline isn't numbered")
                expect((view.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.fontName == Settings.shared.font.fontName,
                       "in the editor's font", "\(String(describing: view.textStorage?.attribute(.font, at: 4, effectiveRange: nil)))")
                var fragments = 0
                if let lm = view.layoutManager {
                    lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in fragments += 1 }
                }
                expect(fragments > 4, "the long line wraps to the page width", "\(fragments) line fragments for 4 lines")
                let doc = CGPDFDocument(pdf as CFURL)
                expect((doc?.numberOfPages ?? 0) >= 1, "the PDF has a page", "\(doc?.numberOfPages ?? 0)")
                // The page is the paper's white, not the theme's background (dark).
                if let page = doc?.page(at: 1) {
                    let box = page.getBoxRect(.mediaBox)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width), pixelsHigh: Int(box.height), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                    NSGraphicsContext.current = ctx
                    NSColor.white.setFill()
                    box.fill()
                    ctx.cgContext.drawPDFPage(page)
                    NSGraphicsContext.restoreGraphicsState()
                    var dark = 0, total = 0
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                            total += 1
                            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 { dark += 1 }
                        }
                    }
                    expect(total > 0 && dark * 20 < total, "the page is mostly white (text only, no theme background)", "\(dark)/\(total) dark samples")
                    expect(dark > 0, "and has text on it")
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("print-page1.png"))
                }
                // Without line numbers: the plain text.
                let (_, plain, _) = tab.makePrintOperation(lineNumbers: false, info: NSPrintInfo())
                expect(plain.textStorage?.string == src, "without line numbers, the text as it is")
                restore()
            },
        ])
    }

    // MARK: Settings, Save All, Revert, Close Window, Services

    static func macBasics(_ app: AppDelegate) {
        let restore = keepDefaults(["fontName", "fontSize", EditorTheme.defaultsKey, "wrapLines", "showInvisibles", "showLineNumbers",
                                    "highlightOccurrences", "autoCloseBrackets", "checkSpellingWhileTyping", "tabWidth", "indentWithTabs",
                                    "quitWhenLastWindowCloses", "reopenFilesFromLastSession", SettingsPane.defaultsKey])
        let a = app.open(write("a.txt", "alpha\n"))!
        let b = app.open(write("b.txt", "beta\n"))!
        sized(a)
        var settings: SettingsWindowController? { SettingsWindowController.shared }
        func allSubviews(_ v: NSView?) -> [NSView] { guard let v else { return [] }; return v.subviews + v.subviews.flatMap { allSubviews($0) } }
        func disk(_ t: EditorWindowController) -> String { (try? String(contentsOf: t.doc.fileURL!, encoding: .utf8)) ?? "-" }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                let appMenu = NSApp.mainMenu?.items.first?.submenu
                let services = appMenu?.items.first { $0.title == "Services" }
                expect(services?.submenu != nil && services?.submenu === NSApp.servicesMenu, "the app menu has a Services submenu (NSApp.servicesMenu)")
                expect(SettingsWindowController.shared == nil, "the Settings window isn't built at launch")
                focus(a)
                key(",", [.command])
            },
            sync {
                expect(settings?.window?.isVisible == true, "⌘, opens Settings")
                guard let s = settings else { return }
                // Font: Menlo from the popup.
                s.fontPopup.selectItem(withTitle: "Menlo")
                s.changed(s.fontPopup)
                expect(Settings.shared.fontName?.hasPrefix("Menlo") == true, "picking Menlo sets the font", Settings.shared.fontName ?? "nil")
                let f = a.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                expect(f?.familyName == "Menlo", "open tabs use it", f?.fontName ?? "-")
                s.fontSize.integerValue = 15
                s.changed(s.fontSize)
                expect(Settings.shared.fontSize == 15 && a.textView.font?.pointSize == 15, "the size field sets the size", "\(Settings.shared.fontSize)")
                s.fontPopup.selectItem(at: 0)
                s.changed(s.fontPopup)
                expect(Settings.shared.fontName == nil && a.textView.font?.fontName == NSFont.monospacedSystemFont(ofSize: 15, weight: .regular).fontName,
                       "SF Mono (System) goes back to the system font", a.textView.font?.fontName ?? "-")
                // 0.4.1 (UX review #1): the View and Edit menu toggles are
                // checkboxes in Settings too, bound to the same settings.
                var titles = Set<String>()
                for p in SettingsPane.allCases {
                    s.select(p)
                    titles.formUnion(allSubviews(s.window?.contentView).compactMap { ($0 as? NSButton)?.title })
                }
                let moved = ["Wrap lines", "Show invisibles", "Show line numbers", "Highlight occurrences",
                             "Auto-close brackets and quotes", "Check spelling while typing", "Check grammar in prose"]
                expect(moved.allSatisfy(titles.contains), "Settings has checkboxes for the View and Edit menu toggles", "\(titles.sorted())")
                expect(["Show git changes in the gutter", "Ask Cedric", "Quit when the last window closes",
                        "Reopen files from last session"].allSatisfy(titles.contains),
                       "…and keeps the preferences without a menu")
                expect(!titles.contains("Save") && !titles.contains("Cancel"), "no Save or Cancel anywhere in Settings")
                let viewTitles = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.map(\.title) ?? []
                expect(!viewTitles.contains("Theme") && viewTitles.contains("Wrap Lines")
                       && (viewTitles.contains("Show Invisibles") || viewTitles.contains("Hide Invisibles")),
                       "View has no Theme submenu (Settings has it) and keeps its toggles", "\(viewTitles)")
                let wrap = Settings.shared.wrapLines
                key("z", [.command, .option])
                expect(Settings.shared.wrapLines == !wrap, "View › Wrap Lines (⌥⌘Z) still toggles the same setting")
                expect(s.toggles[.wrapLines]?.state == (wrap ? .off : .on), "…and Settings › Editor's Wrap lines box follows it")
                s.toggles[.wrapLines]?.performClick(nil)
                expect(Settings.shared.wrapLines == wrap, "the box toggles it back")
                UserDefaults.standard.removeObject(forKey: "quitWhenLastWindowCloses")
                s.refresh()
                expect(Settings.shared.quitWhenLastWindowCloses && s.quitOnLastClose.state == .on, "Quit when the last window closes: on by default")
                s.quitOnLastClose.performClick(nil)
                expect(!Settings.shared.quitWhenLastWindowCloses, "its checkbox turns it off")
                UserDefaults.standard.removeObject(forKey: "reopenFilesFromLastSession")
                s.refresh()
                expect(Settings.shared.reopenFilesFromLastSession && s.reopenLastSession.state == .on,
                       "Reopen files from last session: on by default, whatever macOS's quit setting")
                s.reopenLastSession.performClick(nil)
                expect(!Settings.shared.reopenFilesFromLastSession, "its checkbox turns it off")
                expect(!app.quitsOnLastClose, "the checks themselves never quit on a last close")
                s.indentKind.selectItem(at: 1)
                s.changed(s.indentKind)
                s.tabWidth.selectItem(withTag: 8)
                s.changed(s.tabWidth)
                expect(Settings.shared.defaultIndentation == Indentation(usesTabs: true, width: 8), "indentation default: tabs, 8",
                       "\(Settings.shared.defaultIndentation)")
                s.theme.selectItem(withTitle: EditorTheme.light.displayName)
                s.changed(s.theme)
                expect(UserDefaults.standard.string(forKey: EditorTheme.defaultsKey) == EditorTheme.light.rawValue, "the theme popup sets the theme")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            snapshot("settings.png", window: settings?.window),
            sync {
                settings?.window?.close()
                restore()
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                // Save All: two tabs typed into.
                focus(a)
                a.textView.setSelectedRange(NSRange(location: 5, length: 0))
                type("1")
            },
            sync {
                focus(b)
                b.textView.setSelectedRange(NSRange(location: 4, length: 0))
                type("2")
            },
            sync {
                expect(a.doc.isDirty && b.doc.isDirty, "both tabs have unsaved changes")
                key("s", [.command, .option])
                expect(!a.doc.isDirty && !b.doc.isDirty, "⌥⌘S saves them all")
                expect(disk(a) == "alpha1\n" && disk(b) == "beta2\n", "both files are written", disk(a) + "|" + disk(b))
            },
            sync {
                // Revert to Saved: typed text goes; ⌘Z brings it back.
                focus(a)
                a.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("xy")
            },
            sync {
                expect(a.doc.isDirty, "typing makes it unsaved")
                let ok = choose(#selector(AppDelegate.revertToSaved(_:)))
                expect(ok && a.text == "alpha1\n" && !a.doc.isDirty, "File › Revert to Saved restores the file's text", a.text)
                expect(a.textView.undoManager?.undoActionName == "Revert to Saved", "as one undoable edit",
                       a.textView.undoManager?.undoActionName ?? "-")
            },
            sync {
                key("z", [.command])
                expect(a.text == "xyalpha1\n", "⌘Z undoes the revert", a.text)
            },
            { next in DispatchQueue.main.async { next() } },
            sync {
                let item = menuItem(action: #selector(AppDelegate.revertToSaved(_:)))!
                expect(app.validateMenuItem(item), "Revert is enabled with unsaved changes",
                       "dirty \(a.doc.isDirty) current \(app.currentTab?.doc.displayName ?? "-")")
                choose(#selector(AppDelegate.revertToSaved(_:)))
                expect(!app.validateMenuItem(item), "and disabled when there are none")
            },
            sync {
                // Undo after a save makes the tab unsaved again (it didn't: undo never reached textDidChange).
                a.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("q")
                _ = a.save()
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                key("z", [.command])
            },
            { next in DispatchQueue.main.async { next() } },
            sync {
                expect(a.text == "alpha1\n" && a.doc.isDirty, "⌘Z after a save leaves the tab unsaved", "dirty \(a.doc.isDirty) \(a.text.debugDescription)")
                key("z", [.command, .shift])
            },
            { next in DispatchQueue.main.async { next() } },
            sync {
                expect(a.text == "qalpha1\n" && !a.doc.isDirty, "⇧⌘Z redoes it, back to the saved text: clean again",
                       "dirty \(a.doc.isDirty) \(a.text.debugDescription)")
            },
            sync {
                // Close Window: a second window with two tabs.
                app.newTab(nil)
                let w2 = app.tabs.last!.window!
                w2.moveTabToNewWindow(nil)
                app.makeTab(EditorDocument(untitledName: "Extra"), text: "", in: w2)
                expect(w2.tabbedWindows?.count == 2, "a second window with two tabs", "\(w2.tabbedWindows?.count ?? 0)")
                w2.makeKeyAndOrderFront(nil)
                let before = app.tabs.count
                key("w", [.command, .shift])
                expect(app.tabs.count == before - 2, "⇧⌘W closes the window's tabs", "\(before) → \(app.tabs.count)")
                expect(a.window?.isVisible == true && b.window != nil, "the other window stays")
            },
        ]
        steps += steps3
        run(steps)
    }

    // MARK: Keep / Delete Lines Matching, bookmarked lines

    /// The editable text field in a sheet (the prompt's pattern).
    static func field(in w: NSWindow) -> NSTextField? {
        var hit: NSTextField?
        func walk(_ v: NSView) {
            if hit == nil, let f = v as? NSTextField, f.isEditable { hit = f }
            v.subviews.forEach(walk)
        }
        w.contentView.map(walk)
        return hit
    }

    static func filterLinesCheck(_ app: AppDelegate) {
        let restore = keepDefaults(["filterLinesPattern", "filterLinesRegex", "filterLinesMatchCase"])
        let src = "INFO start\nDEBUG x=1\nWARN disk\nDEBUG y=2\nINFO done\n"
        let tab = app.open(write("app.log", src))!
        sized(tab)
        let pb = NSPasteboard.general
        let savedClipboard = pb.string(forType: .string)
        UserDefaults.standard.set(false, forKey: "filterLinesRegex")
        UserDefaults.standard.set(true, forKey: "filterLinesMatchCase")
        run([
            sync {
                focus(tab)
                // Bookmark lines 3 and 5 (WARN, INFO done), then delete the DEBUG lines from the prompt.
                tab.toggleBookmark(line: 2)
                tab.toggleBookmark(line: 4)
                tab.textView.setSelectedRange(NSRange(location: 11, length: 5)) // "DEBUG"
                choose(#selector(AppDelegate.deleteLinesMatchingMenu(_:)))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                guard let sheet = tab.window?.attachedSheet, let f = field(in: sheet) else { expect(false, "the prompt is a sheet with a field"); return }
                expect(f.stringValue == "DEBUG", "the prompt starts with the selection", f.stringValue)
                pressReturn(in: sheet)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                expect(tab.text == "INFO start\nWARN disk\nINFO done\n", "Delete Lines Matching removes the DEBUG lines", tab.text)
                expect(tab.editing.bookmarks.lines == [1, 2], "bookmarks follow their lines", "\(tab.editing.bookmarks.lines)")
                expect(tab.textView.undoManager?.undoActionName == "Delete Lines Matching", "one named undo step",
                       tab.textView.undoManager?.undoActionName ?? "-")
                choose(#selector(AppDelegate.copyBookmarkedLinesMenu(_:)))
                expect(pb.string(forType: .string) == "WARN disk\nINFO done\n", "Copy Bookmarked Lines", pb.string(forType: .string) ?? "-")
                choose(#selector(AppDelegate.deleteBookmarkedLinesMenu(_:)))
                expect(tab.text == "INFO start\n", "Delete Bookmarked Lines", tab.text)
                expect(tab.editing.bookmarks.isEmpty, "their bookmarks go with them")
            },
            sync { key("z", [.command]) },
            sync {
                key("z", [.command])
                expect(tab.text == src, "two ⌘Z: back to the original", tab.text)
                // Keep Lines Matching with a regular expression.
                UserDefaults.standard.set(true, forKey: "filterLinesRegex")
                UserDefaults.standard.set(#"y=\d|^WARN"#, forKey: "filterLinesPattern")
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                choose(#selector(AppDelegate.keepLinesMatchingMenu(_:)))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                guard let sheet = tab.window?.attachedSheet else { expect(false, "the Keep prompt is a sheet"); return }
                pressReturn(in: sheet)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                expect(tab.text == "WARN disk\nDEBUG y=2\n", "Keep Lines Matching (regex) keeps only matching lines", tab.text)
                expect(tab.filterLines(pattern: "nothing", regex: false, caseSensitive: true, keepMatching: false) == nil,
                       "no match: nothing changes (beep)")
                if let savedClipboard { pb.clearContents(); pb.setString(savedClipboard, forType: .string) }
                restore()
            },
            snapshot("filter-lines.png"),
        ])
    }

    // MARK: Windows-1252 and Mac Roman

    static func encodings(_ app: AppDelegate) {
        let url = dir.appendingPathComponent("mac.txt")
        // "café, don’t" in Mac Roman.
        // Appended in parts: as one `Data + Data + ...` it took 150-170 ms to type-check.
        var macRoman = Data("caf".utf8)
        macRoman.append(0x8E)
        macRoman.append(contentsOf: Data(", don".utf8))
        macRoman.append(0xD5)
        macRoman.append(contentsOf: Data("t\n".utf8))
        try? macRoman.write(to: url)
        let tab = app.open(url)!
        sized(tab)
        run([
            sync {
                focus(tab)
                expect(tab.text == "café, don’t\n", "a Mac Roman file opens as such", tab.text)
                // Not UTF-8: a guess until kept (FileNotices.swift); Keep on its bar.
                expect(tab.statusBar.encodingButton.title == "Mac Roman (guessed)", "…marked as a guess", tab.statusBar.encodingButton.title)
                if let b = tab.encodingBar?.button("Keep") { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(tab.doc.encoding == .macRoman && tab.statusBar.encodingButton.title == "Mac Roman",
                       "the status bar says Mac Roman", tab.statusBar.encodingButton.title)
                choose(#selector(AppDelegate.pickEncodingMenu(_:)), TextEncoding.windows1252.rawValue)
                expect(tab.doc.encoding == .windows1252 && tab.doc.isDirty, "Format › Encoding › Windows-1252 converts (on save)")
                key("s", [.command])
                let bytes = (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? []
                expect(bytes == [0x63, 0x61, 0x66, 0xE9, 0x2C, 0x20, 0x64, 0x6F, 0x6E, 0x92, 0x74, 0x0A], "saved as Windows-1252 bytes",
                       bytes.map { String($0, radix: 16) }.joined(separator: " "))
                // Reopen with Encoding › Mac Roman reads those bytes the Mac way (é → È).
                tab.reopen(with: .macRoman)
                expect(tab.text.hasPrefix("cafÈ"), "Reopen with Mac Roman decodes as Mac Roman", tab.text)
                let menu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Format" }?.submenu?.items.first { $0.title == "Encoding" }?.submenu
                expect(menu?.items.map(\.title).contains("Mac Roman") == true && menu?.items.map(\.title).contains("Windows-1252 (Western)") == true,
                       "both are in Format › Encoding")
            },
        ])
    }

    // MARK: cedric -w and file:line:col (the URLs Scripts/cedric sends)

    /// As the cedric script sends it: with the user's token (`token: false`: as a web page would, without).
    static func openURL(_ app: AppDelegate, _ url: String, token: Bool = true) {
        // The checks' own token file, not the user's (set in-process; release builds ignore the env hook).
        if CLIToken.overrideURL == nil { CLIToken.overrideURL = dir.appendingPathComponent("cli-token") }
        // The token in a 0600 hand-off file, as the script sends it (never on the command line).
        var url = url
        if token {
            let auth = NSTemporaryDirectory() + "cedric-auth.chk\(getpid())\(Int.random(in: 100_000...999_999))"
            try? PrivateDirectory.writePrivateFile(Data(((CLIToken.ensure() ?? "") + "\n").utf8), to: URL(fileURLWithPath: auth))
            url += "&auth=" + (auth.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? auth)
        }
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                       targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        e.setParam(NSAppleEventDescriptor(string: url), forKeyword: keyDirectObject)
        app.handleURL(e, reply: NSAppleEventDescriptor.null())
    }

    static func cli(_ app: AppDelegate) {
        let file = write("cli.txt", "one\ntwo\nthree is here\nfour\n")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-wait.check\(getpid())").path
        FileManager.default.createFile(atPath: marker, contents: nil)
        let outside = dir.appendingPathComponent("cedric-wait.outside").path
        FileManager.default.createFile(atPath: outside, contents: nil)
        var tab: EditorWindowController?
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                openURL(app, "cedric://open?path=\(enc(file.path))&line=3&col=7&wait=\(enc(marker))")
                tab = app.tabs.first { $0.doc.fileURL?.standardizedFileURL == file.standardizedFileURL }
                expect(tab != nil, "the URL opens the file")
                let sel = tab?.textView.selectedRange()
                expect(sel == NSRange(location: 14, length: 0), "line=3&col=7 puts the caret at line 3, column 7", "\(String(describing: sel))")
                expect(tab.map { app.waitMarkers(for: $0) } == [CLIHandoff.realpath(marker)!], "the tab holds the -w marker")
                // A marker outside the temp folder (or not named cedric-wait.*) is never taken.
                openURL(app, "cedric://open?path=\(enc(file.path))&wait=\(enc(outside))")
                openURL(app, "cedric://open?path=\(enc(file.path))&wait=\(enc(file.path))")
                expect(tab.map { app.waitMarkers(for: $0) } == [CLIHandoff.realpath(marker)!], "markers elsewhere are ignored")
                expect(FileManager.default.fileExists(atPath: marker), "the marker stays while the tab is open")
                tab?.window?.performClose(nil)
            },
            sync {
                expect(!FileManager.default.fileExists(atPath: marker), "closing the tab deletes the marker (cedric -w returns)")
                expect(FileManager.default.fileExists(atPath: outside) && FileManager.default.fileExists(atPath: file.path),
                       "nothing else is deleted")
                // Quitting releases every waiter too.
                let m2 = marker + "b"
                FileManager.default.createFile(atPath: m2, contents: nil)
                openURL(app, "cedric://open?path=\(enc(file.path))&wait=\(enc(m2))")
                app.releaseAllWaiters()
                expect(!FileManager.default.fileExists(atPath: m2), "quitting releases waiting scripts")
                // `cedric -w some/dir`: the folder opens in the sidebar and the
                // script isn't left waiting on a tab that never comes.
                let folder = dir.appendingPathComponent("cli-folder", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let m3 = marker + "c"
                FileManager.default.createFile(atPath: m3, contents: nil)
                let before = app.tabs.count
                openURL(app, "cedric://open?path=\(enc(folder.path))&wait=\(enc(m3))")
                expect(!FileManager.default.fileExists(atPath: m3), "cedric -w on a folder returns at once (its marker is deleted)")
                expect(app.tabs.count == before, "and opens no tab", "\(app.tabs.count - before)")
                // The sidebar opens after the first frame (passed by now).
                expect(FolderSidebar.shared?.rootURL.standardizedFileURL.path == folder.standardizedFileURL.path,
                       "the folder opens in the folder sidebar", FolderSidebar.shared?.rootURL.path ?? "none")
                // A marker that isn't the script's is still never deleted.
                openURL(app, "cedric://open?path=\(enc(folder.path))&wait=\(enc(outside))")
                expect(FileManager.default.fileExists(atPath: outside), "a folder URL never deletes a file that isn't a cedric-wait marker")
                app.closeFolder()
            },
            sync {
                // cedric://open?untitled= from a web page: `..` out of a temp-looking prefix to a victim file.
                let victim = dir.appendingPathComponent("victim.txt")
                try? "precious\n".write(to: victim, atomically: true, encoding: .utf8)
                let before = app.tabs.count
                for u in ["cedric://open?untitled=" + enc("/private/.." + victim.path),
                          "cedric://open?untitled=" + enc(NSTemporaryDirectory() + "../../../.." + victim.path)] {
                    openURL(app, u, token: false)
                    openURL(app, u)
                }
                // A correctly named symlink in the temp folder pointing at it, with the token.
                let link = NSTemporaryDirectory() + "cedric-stdin.link\(getpid())"
                try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: victim.path)
                openURL(app, "cedric://open?untitled=" + enc(link))
                expect(FileManager.default.fileExists(atPath: victim.path) && (try? String(contentsOf: victim, encoding: .utf8)) == "precious\n",
                       "the malicious untitled= URLs leave the victim file alone")
                expect(app.tabs.count == before, "and open nothing", "\(app.tabs.count - before)")
                try? FileManager.default.removeItem(atPath: link)
                // A hard link to it under a valid name (nlink 2), with the token.
                let hard = NSTemporaryDirectory() + "cedric-stdin.hard\(getpid())"
                try? FileManager.default.linkItem(atPath: victim.path, toPath: hard)
                openURL(app, "cedric://open?untitled=" + enc(hard))
                expect(FileManager.default.fileExists(atPath: hard) && (try? String(contentsOf: victim, encoding: .utf8)) == "precious\n"
                       && app.tabs.count == before, "a hard link to the victim is refused: nothing read, nothing deleted")
                try? FileManager.default.removeItem(atPath: hard)
                // A tokenless path= (a link): asked first; declined here (CEDRIC_URL_ASK_ANSWER=no), nothing opens.
                AppDelegate.linkAnswerForChecks = false
                openURL(app, "cedric://open?path=" + enc(victim.path), token: false)
                AppDelegate.linkAnswerForChecks = nil
                expect(!app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "victim.txt" }, "a tokenless path= link opens nothing unless allowed")
                // The real hand-off, as `cedric -` makes it: read, then deleted.
                let tmp = NSTemporaryDirectory() + "cedric-stdin.ok\(getpid())"
                try? "piped in\n".write(toFile: tmp, atomically: false, encoding: .utf8)
                openURL(app, "cedric://open?untitled=" + enc(tmp))
                expect(app.tabs.last?.text == "piped in\n" && app.tabs.last?.doc.fileURL == nil, "cedric - still opens stdin in an untitled tab",
                       app.tabs.last?.text ?? "-")
                expect(!FileManager.default.fileExists(atPath: tmp), "and deletes its temp file")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // The token travels in a 0600 hand-off file, never on argv
                // (security review 0.2.1), and rotates.
                let victim = dir.appendingPathComponent("victim.txt")
                let enc2 = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
                AppDelegate.linkAnswerForChecks = false
                // The old way, token= on the URL: no longer trusted (asked, declined here).
                openURL(app, "cedric://open?path=" + enc(victim.path) + "&token=" + (CLIToken.ensure() ?? ""), token: false)
                expect(!app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "victim.txt" }, "token= on the command line is not trusted")
                // A hand-off file others can read: refused, and deleted.
                let loose = NSTemporaryDirectory() + "cedric-auth.loose\(getpid())"
                FileManager.default.createFile(atPath: loose, contents: Data(((CLIToken.ensure() ?? "") + "\n").utf8),
                                               attributes: [.posixPermissions: 0o644])
                openURL(app, "cedric://open?path=" + enc(victim.path) + "&auth=" + enc2(loose), token: false)
                expect(!app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "victim.txt" }, "a world-readable auth file is not trusted")
                AppDelegate.linkAnswerForChecks = nil
                try? FileManager.default.removeItem(atPath: loose)
                // The real hand-off: trusted, used once (deleted).
                let before = Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("cedric-auth.") })
                openURL(app, "cedric://open?path=" + enc(victim.path))
                let t = app.tabs.first { $0.doc.fileURL?.lastPathComponent == "victim.txt" }
                expect(t != nil, "auth= with the token opens without asking")
                let after = Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("cedric-auth.") })
                expect(after.isSubset(of: before), "the auth file is deleted once read", "\(after.subtracting(before))")
                t?.window?.performClose(nil)
                // Rotation: a new token each launch, the file stays 0600.
                let old = CLIToken.ensure()
                let new = CLIToken.rotate(at: CLIToken.defaultURL)
                var st = stat()
                expect(new != nil && new != old && CLIToken.ensure() == new && stat(CLIToken.defaultURL.path, &st) == 0 && st.st_mode & 0o777 == 0o600,
                       "the token rotates (new value, still 0600)")
            },
            sync { cliScriptWithCustomTMPDIR(app) },
        ]
        steps += steps2
        run(steps)
    }

    /// The bundled `cedric` script itself, run with TMPDIR pointing
    /// somewhere else (Nix, tmux): its hand-off file must still land in
    /// the folder the app accepts, so the file opens without the link
    /// question (release review 0.2.1 S4). `open` is a stand-in that
    /// records the URL, which is then handed to the app as Launch Services
    /// would; HOME is the check's folder, so the script makes the check's
    /// token, not the user's.
    ///
    /// The script must never reach the system `open`: it would start or
    /// message the registered Owlink (maybe an installed release, with the
    /// user's data). So its PATH is only the check's own bin folder: the
    /// recorder as `open`, plus links to the few tools the script runs,
    /// with neither /usr/bin nor /bin on it. Every setup step is checked,
    /// and a probe must resolve `open` to the recorder and see it record
    /// before the script runs. If any of that fails, the check fails
    /// without running the script. Not a dry run: the check needs the real
    /// hand-off file (the shell-level CLI checks in tools-check.sh are the
    /// dry runs).
    static func cliScriptWithCustomTMPDIR(_ app: AppDelegate) {
        guard let script = Bundle.main.url(forResource: "cedric", withExtension: nil) else {
            expect(false, "the cedric script is in the app's Resources"); return
        }
        let home = dir.appendingPathComponent("cli-home", isDirectory: true)
        let bin = dir.appendingPathComponent("cli-bin", isDirectory: true)
        let custom = "/tmp/custom.cedric-check\(getpid())"
        let log = dir.appendingPathComponent("cli-open.log")
        let fm = FileManager.default
        let fakeOpen = bin.appendingPathComponent("open")
        // What Scripts/cedric runs besides bash builtins, linked in by absolute path.
        let tools = ["dirname", "readlink", "getconf", "mkdir", "stat", "chmod", "date", "mktemp", "head", "xxd",
                     "tr", "ln", "rm", "sleep", "python3", "cat", "sed"]
        do {
            if fm.fileExists(atPath: bin.path) { try fm.removeItem(at: bin) }
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: custom, withIntermediateDirectories: true)
            try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done >> \"$CEDRIC_CHECK_OPEN_LOG\"\n"
                .write(to: fakeOpen, atomically: true, encoding: .utf8)
            guard chmod(fakeOpen.path, 0o755) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
            for t in tools {
                guard let src = ["/usr/bin/\(t)", "/bin/\(t)"].first(where: { fm.isExecutableFile(atPath: $0) }) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: t])
                }
                try fm.createSymbolicLink(atPath: bin.appendingPathComponent(t).path, withDestinationPath: src)
            }
        } catch {
            expect(false, "the cli check's recorder and bin folder are set up (else the script is not run)", "\(error)")
            try? fm.removeItem(atPath: custom)
            return
        }
        defer { try? fm.removeItem(atPath: custom) }
        try? fm.removeItem(at: log)
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = custom + "/"
        env["HOME"] = home.path
        env["PATH"] = bin.path  // only the check's folder: no /usr/bin (the system open), no /bin
        env["CEDRIC_CHECK_OPEN_LOG"] = log.path
        env.removeValue(forKey: "CEDRIC_DRY_RUN")
        // The probe: with this environment `open` is the recorder, and it records.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/bash")
        probe.arguments = ["-c", "command -v open; open cedric-check-probe"]
        probe.environment = env
        let probeOut = Pipe()
        probe.standardOutput = probeOut
        do { try probe.run() } catch {
            expect(false, "the cli check's probe runs (else the script is not run)", "\(error)"); return
        }
        let resolved = String(decoding: probeOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        probe.waitUntilExit()
        let recorded = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard probe.terminationStatus == 0, resolved == fakeOpen.path, recorded == "cedric-check-probe\n" else {
            expect(false, "with the check's PATH, open is the recorder and records (else the script is not run)",
                   "status \(probe.terminationStatus), open: \(resolved), log: \(recorded.debugDescription)")
            return
        }
        expect(true, "the cli check's open is its recorder (PATH has no /usr/bin)", resolved)
        try? fm.removeItem(at: log)
        let victim = write("cli-custom-tmp.txt", "from a custom TMPDIR\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, victim.path]
        p.environment = env
        do { try p.run() } catch { expect(false, "the cedric script runs", "\(error)"); return }
        p.waitUntilExit()
        expect(p.terminationStatus == 0, "the cedric script exits 0 with TMPDIR=\(custom)", "\(p.terminationStatus)")
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        guard let url = lines.first(where: { $0.hasPrefix("cedric://open?path=") }) else {
            expect(false, "the script sends a cedric://open URL", lines.joined(separator: " ")); return
        }
        let auth = URLComponents(string: url)?.queryItems?.first { $0.name == "auth" }?.value ?? ""
        let leftInCustom = ((try? fm.contentsOfDirectory(atPath: custom)) ?? []).filter { $0.hasPrefix("cedric-") }
        expect(!auth.hasPrefix(custom) && leftInCustom.isEmpty, "the hand-off isn't written to the custom TMPDIR", auth)
        // The script made its own token under the check's HOME: trust that one.
        let saved = CLIToken.overrideURL
        CLIToken.overrideURL = home.appendingPathComponent("Library/Application Support/Cedric/cli-token")
        defer { CLIToken.overrideURL = saved }
        AppDelegate.linkAnswerForChecks = false  // a link question would be declined: nothing would open
        openURL(app, url, token: false)
        AppDelegate.linkAnswerForChecks = nil
        let t = app.tabs.first { $0.doc.fileURL?.lastPathComponent == victim.lastPathComponent }
        expect(t != nil, "with TMPDIR=\(custom) the script's hand-off is accepted: opened without asking", auth)
        expect(!fm.fileExists(atPath: auth), "and its auth file is used once (deleted)")
        t?.window?.performClose(nil)
    }

    // MARK: Dropping a file onto the text

    /// A drag as AppKit hands it to the destination view: a pasteboard and a point.
    final class FakeDrag: NSObject, NSDraggingInfo {
        let pb: NSPasteboard
        let window: NSWindow?
        let point: NSPoint
        init(_ pb: NSPasteboard, window: NSWindow?, point: NSPoint) { self.pb = pb; self.window = window; self.point = point }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
        var draggingLocation: NSPoint { point }
        var draggedImageLocation: NSPoint { point }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
            let objects = pb.readObjects(forClasses: classArray, options: searchOptions) ?? []
            var stop: ObjCBool = false
            for (i, o) in objects.enumerated() {
                guard let w = o as? NSPasteboardWriting else { continue }
                block(NSDraggingItem(pasteboardWriter: w), i, &stop)
                if stop.boolValue { break }
            }
        }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static func drop(_ pb: NSPasteboard, on tab: EditorWindowController) -> (NSDragOperation, Bool) {
        let tv = tab.textView
        let p = tv.convert(NSPoint(x: 40, y: 10), to: nil)
        let info = FakeDrag(pb, window: tab.window, point: p)
        let op = tv.draggingEntered(info)
        _ = tv.draggingUpdated(info)
        guard op != [] else { tv.draggingExited(info); return (op, false) }
        let ok = tv.prepareForDragOperation(info) && tv.performDragOperation(info)
        tv.concludeDragOperation(info)
        return (op, ok)
    }

    static func dropFile(_ app: AppDelegate) {
        let target = app.open(write("target.txt", "existing text\n"))!
        let dropped = write("dropped.swift", "let dropped = 1\n")
        sized(target)
        let pb = NSPasteboard(name: NSPasteboard.Name("cedric-check-drop-\(getpid())"))
        var before = 0
        run([
            sync {
                focus(target)
                pb.clearContents()
                pb.writeObjects([dropped as NSURL])
                let (op, ok) = drop(pb, on: target)
                expect(op != [] && ok, "the text view takes a dropped file", "op \(op.rawValue) ok \(ok)")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(target.text == "existing text\n", "the file's path isn't inserted into the text", target.text)
                let opened = app.tabs.first { $0.doc.fileURL?.standardizedFileURL == dropped.standardizedFileURL }
                expect(opened != nil, "the dropped file opens in a tab")
                expect(opened?.text == "let dropped = 1\n" && opened?.doc.language == .swift, "with its text and language")
                // Text isn't taken over: it goes to NSTextView's own drop handling (not opened as a file).
                pb.clearContents()
                pb.setString("plain words", forType: .string)
                before = app.tabs.count
                _ = drop(pb, on: target)
                expect(app.tabs.count == before, "a text drop opens nothing")
                // A folder isn't opened as a file: it opens in the folder sidebar.
                let folder = dir.appendingPathComponent("dropped-folder", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = write("dropped-folder/inside.txt", "inside\n")
                pb.clearContents()
                pb.writeObjects([folder as NSURL])
                let (op, ok) = drop(pb, on: target)
                expect(op != [] && ok, "the text view takes a dropped folder", "op \(op.rawValue) ok \(ok)")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(app.tabs.count == before, "a folder drop opens no tab")
                expect(FolderSidebar.shared?.rootURL.standardizedFileURL.path == dir.appendingPathComponent("dropped-folder").standardizedFileURL.path,
                       "a folder dropped on the text opens in the folder sidebar", FolderSidebar.shared?.rootURL.path ?? "none")
                expect(FolderSidebar.shared?.isShown == true && app.tabs.contains { FolderSidebar.shared?.superview === $0.split }, "and shown, docked in a tab")
                app.closeFolder()
                // Beside the text (the window's content view: gutter, status bar).
                guard let stack = target.stack as? FileDropStackView else { expect(false, "the window's content view takes drops"); return }
                let info = FakeDrag(pb, window: target.window, point: target.statusBar.convert(NSPoint(x: 5, y: 5), to: nil))
                let op = stack.draggingEntered(info)
                let ok = op != [] && stack.prepareForDragOperation(info) && stack.performDragOperation(info)
                expect(op == .copy && ok, "the window takes a dropped folder beside the text", "op \(op.rawValue) ok \(ok)")
                // Plain text dropped there is refused, not opened.
                let tpb = NSPasteboard(name: NSPasteboard.Name("cedric-check-drop-text-\(getpid())"))
                tpb.clearContents()
                tpb.setString("words", forType: .string)
                expect(stack.draggingEntered(FakeDrag(tpb, window: target.window, point: .zero)) == [], "the window refuses a text drop")
                tpb.releaseGlobally()
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(app.tabs.count == before, "a folder dropped on the window opens no tab")
                expect(FolderSidebar.shared?.rootURL.lastPathComponent == "dropped-folder", "a folder dropped on the window opens in the folder sidebar")
                // A file dropped on the window still opens in a tab.
                let another = write("dropped-beside.txt", "beside\n")
                pb.clearContents()
                pb.writeObjects([another as NSURL])
                if let stack = target.stack as? FileDropStackView {
                    let info = FakeDrag(pb, window: target.window, point: .zero)
                    _ = stack.draggingEntered(info) != [] && stack.performDragOperation(info)
                }
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "dropped-beside.txt" }, "a file dropped on the window opens in a tab")
                app.closeFolder()
                pb.releaseGlobally()
            },
        ])
    }
}
