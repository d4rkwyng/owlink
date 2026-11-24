import AppKit
import CedricCore

/// In-process checks of the editor tools (Open Recent, Text Tools, Find
/// in Files, Compare, Follow File). Each one builds its own files in a
/// temp folder, drives the app with real key and mouse NSEvents sent
/// through NSApp (so they go through the menus' key equivalents and the
/// responder chain), checks the result, writes PNG snapshots and exits 0
/// (all passed) or 1. Scripts/tools-check.sh runs them all.
///
///   CEDRIC_CHECK=texttool|findinfiles|compare|follow|recent|large|replaceinfiles|folder|multicaret|folding|split|palette|quickopen|readable|contextbar|settings|…
///   CEDRIC_CHECK_OUT=/dir      where snapshots go (default: the temp folder)
@MainActor
enum DevChecks {
    static var passed = 0, failed = 0
    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static var dir = URL(fileURLWithPath: NSTemporaryDirectory())

    static func expect(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("check: PASS \(name)") } else { failed += 1; print("check: FAIL \(name) \(detail())") }
        fflush(stdout)
    }

    /// As `finish`, but through a normal quit (the session is saved), for
    /// checks that relaunch on what this run left.
    static func finishAndQuit() {
        print("check: done \(passed) passed, \(failed) failed")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    static func finish() {
        print("check: done \(passed) passed, \(failed) failed")
        fflush(stdout)
        exit(failed == 0 && passed > 0 ? 0 : 1)
    }

    // MARK: Events

    static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46, "\r": 36, " ": 49, "/": 44, "(": 25, ")": 29, "{": 33, "}": 30,
        "[": 33, "]": 30, "\\": 42, "\"": 39, "'": 39, "\t": 48, "\u{7f}": 51, ";": 41,
        Character(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!): 126, Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!): 125,
        Character(UnicodeScalar(UInt16(NSF2FunctionKey))!): 120,
    ]

    static var frontWindow: NSWindow? {
        // Cedric's own windows (not, say, the Writing Tools affordance window).
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.windowController != nil }
    }

    static var notedInactive = false

    /// The main-menu item with this key equivalent, as AppKit matches it.
    static func menuItem(_ ch: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        var hit: NSMenuItem?
        func walk(_ m: NSMenu) {
            m.update()
            for i in m.items where hit == nil {
                if i.keyEquivalent.lowercased() == ch.lowercased(),
                   i.keyEquivalentModifierMask.union(i.keyEquivalent != i.keyEquivalent.lowercased() ? .shift : []) == mods {
                    hit = i
                }
                if let s = i.submenu { walk(s) }
            }
        }
        if let m = NSApp.mainMenu { walk(m) }
        return hit
    }

    /// A key press. With modifiers: a key equivalent. When Cedric is the
    /// active app the NSEvent goes through NSApp.sendEvent (menus, then
    /// the responder chain). When it isn't (screen locked, launched from a
    /// script) there is no key window and AppKit won't route a synthetic
    /// chord, so the matching menu item (checked to exist, and validated
    /// like AppKit does) sends its action along the front window's
    /// responder chain, as it would if that window were key. Without
    /// modifiers: the event goes to the front window's first responder.
    @discardableResult
    static func key(_ ch: String, _ mods: NSEvent.ModifierFlags = []) -> Bool {
        let w = frontWindow
        let code = keyCodes[Character(ch.lowercased())] ?? 0
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: w?.windowNumber ?? 0, context: nil, characters: ch, charactersIgnoringModifiers: ch.lowercased(),
                             isARepeat: false, keyCode: code)
        }
        // A function key (F2…) with no modifiers is a menu key equivalent too.
        let functionKey = ch.utf16.first.map { $0 >= 0xF700 && $0 <= 0xF8FF } ?? false
        if mods.isEmpty && !functionKey {
            guard let w, let down = event(.keyDown) else { return false }
            // Return in a sheet or alert: its default button.
            if ch == "\r", w.performKeyEquivalent(with: down) { return true }
            w.sendEvent(down)
            if let up = event(.keyUp) { w.sendEvent(up) }
            return true
        }
        guard let item = menuItem(ch, mods) else { expect(false, "a menu item has this shortcut", "\(mods.rawValue)+\(ch)"); return false }
        if NSApp.isActive, NSApp.keyWindow != nil, let down = event(.keyDown) {
            NSApp.sendEvent(down)
            if let up = event(.keyUp) { NSApp.sendEvent(up) }
            return true
        }
        if !notedInactive {
            notedInactive = true
            print("check: note: Cedric isn't the active app (no key window); shortcuts are matched to their menu item and sent along the front window's responder chain")
        }
        guard let action = item.action else { return false }
        var r: NSResponder? = w?.firstResponder
        while let cur = r, !cur.responds(to: action) {
            r = cur.nextResponder
            if r == nil, cur === w { r = w?.delegate as? NSResponder ?? w?.windowController }
        }
        let target: AnyObject? = item.target ?? r ?? NSApp.target(forAction: action, to: nil, from: item) as AnyObject?
        // Validate against that target, as AppKit does for the key window.
        if let v = target as? NSMenuItemValidation, !v.validateMenuItem(item) { return false }
        if let v = target as? NSUserInterfaceValidations, !v.validateUserInterfaceItem(item) { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    /// Return in a sheet or alert: the key equivalent of its default
    /// button; when the window can't be key, a click on that button.
    static func pressReturn(in w: NSWindow) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36) else { return }
        if w.isKeyWindow, w.performKeyEquivalent(with: e) { return }
        var buttons: [NSButton] = []
        func collect(_ v: NSView) {
            if let b = v as? NSButton, !(b is NSPopUpButton), b.bezelStyle == .push || b.keyEquivalent == "\r" { buttons.append(b) }
            v.subviews.forEach(collect)
        }
        w.contentView.map(collect)
        // The default button (an NSAlert's first button: the one that isn't Escape, until the sheet has been key).
        if let b = buttons.first(where: { $0.keyEquivalent == "\r" }) ?? buttons.first(where: { $0.keyEquivalent != "\u{1b}" }) {
            click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY))
        }
    }

    static func type(_ s: String) { for c in s { key(String(c)) } }

    /// A left click at `point` (view coordinates). The mouse-up is queued
    /// first so a control's tracking loop finds it.
    static func click(_ view: NSView, at point: NSPoint) {
        guard let w = view.window else { return }
        let p = view.convert(point, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber,
                                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05, windowNumber: w.windowNumber,
                                          context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
        NSApp.postEvent(up, atStart: false)
        if NSApp.isActive && w.isKeyWindow {
            w.sendEvent(down)
        } else {
            // An inactive window takes the first click to become key, which
            // it can't while the app isn't active: give the event to the view
            // under the point, as the window would.
            let root = w.contentView?.superview ?? w.contentView
            let hit = root?.hitTest(p)
            (hit ?? view).mouseDown(with: down)
        }
    }

    /// Runs `steps` one after another, `gap` seconds apart (each step may
    /// be async: it calls `next` when done).
    static func run(_ steps: [(@escaping () -> Void) -> Void], gap: Double = 0.3, quit: Bool = false) {
        var i = 0
        func step() {
            guard i < steps.count else { if quit { finishAndQuit() } else { finish() }; return }
            let s = steps[i]
            i += 1
            // An event through the app's event loop between steps: AppKit
            // closes the undo group of the previous step after it, as it
            // does after each key press a user types.
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(e, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { s(step) }
        }
        step()
    }

    static func sync(_ f: @escaping () -> Void) -> (@escaping () -> Void) -> Void { { next in f(); next() } }

    static func snapshot(_ name: String, window: NSWindow? = nil) -> (@escaping () -> Void) -> Void {
        { next in
            guard let w = window ?? frontWindow else { expect(false, "snapshot \(name)", "no window"); next(); return }
            let path = out.appendingPathComponent(name).path
            DevHooks.write(window: w, to: path) {
                expect(FileManager.default.fileExists(atPath: path), "snapshot \(name)", path)
                print("check: snapshot \(path)")
                next()
            }
        }
    }

    static func write(_ name: String, _ s: String) -> URL {
        let u = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    // MARK: Entry

    static func start(_ name: String, _ app: AppDelegate) {
        let env = DevEnvironment.values
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-check-\(name)-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        out = env["CEDRIC_CHECK_OUT"].map { URL(fileURLWithPath: $0) } ?? dir
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        for t in app.tabs { t.window?.setContentSize(NSSize(width: 1200, height: 720)) }
        switch name {
        case "texttool": textTool(app)
        case "findinfiles": findInFiles(app)
        case "compare": compare(app)
        case "follow": follow(app)
        case "recent": recent(app)
        case "large": largeDocument(app)
        case "git": gitCheck(app)
        case "replaceinfiles": replaceInFilesCheck(app)
        case "folder": folderCheck(app)
        case "multicaret": multiCaretCheck(app)
        case "statuszoom": statusZoomCheck(app)
        case "folding": foldingCheck(app)
        case "split": splitCheck(app)
        case "defaulteditor": defaultEditorCheck(app)
        case "palette": paletteCheck(app)
        case "quickopen": quickOpenCheck(app)
        case "contextbar": contextBarCheck(app)
        case "writing": writingCheck(app)
        case "readable": readableWidthCheck(app)
        case "writingrestore": writingRestoreCheck(app)
        case "settings": settingsCheck(app)
        default:
            if !editingCheck(name, app), !pdfCheck(name, app), !imageCheck(name, app), !binaryCheck(name, app), !readOnlyCheck(name, app), !bigFileCheck(name, app), !bigOpenCheck(name, app) { print("check: unknown check \(name)"); exit(2) }
        }
    }

    static func sized(_ tab: EditorWindowController?) {
        tab?.window?.setContentSize(NSSize(width: 1200, height: 720))
    }

    // MARK: Text tools

    static func textTool(_ app: AppDelegate) {
        let json = #"{"name":"cedric","version":2,"tools":["sort","json",{"nested":true,"n":1.50}],"empty":{}}"#
        let list = app.open(write("list.txt", "pear\nzebra\napple\nmango\npear\n"))!
        let data = app.open(write("data.json", json + "\n"))!
        sized(data)
        let pretty = try! TextTools.apply(.jsonPrettyPrint, to: json + "\n")
        run([
            sync {
                data.window?.makeKeyAndOrderFront(nil)
                data.window?.makeFirstResponder(data.textView)
                key("j", [.control, .option, .command])
                expect(data.text == pretty, "⌃⌥⌘J pretty-prints JSON", data.text)
                expect(data.doc.isDirty, "the tab is now unsaved")
                expect(data.textView.undoManager?.undoActionName == TextTool.jsonPrettyPrint.displayName, "undo is named after the tool",
                       data.textView.undoManager?.undoActionName ?? "-")
            },
            sync {
                key("z", [.command])
                expect(data.text == json + "\n", "one ⌘Z restores the original", data.text)
                key("z", [.command, .shift])
                expect(data.text == pretty, "⇧⌘Z redoes it")
            },
            sync {
                list.window?.makeKeyAndOrderFront(nil)
                list.window?.makeFirstResponder(list.textView)
                // A partial selection from inside line 2 to inside line 3: widened to lines 2–3.
                list.textView.setSelectedRange(NSRange(location: 7, length: 6))
                key("s", [.control, .command])
                expect(list.text == "pear\napple\nzebra\nmango\npear\n", "⌃⌘S sorts the selected lines only", list.text)
                list.textView.setSelectedRange(NSRange(location: 0, length: 0))
            },
            // One step per key press, as when typed (each event is its own undo group).
            sync {
                key("r", [.control, .command])
                expect(list.text == "pear\napple\nzebra\nmango\n", "⌃⌘R removes duplicate lines (whole document)", list.text)
            },
            sync {
                key("u", [.control, .command])
                expect(list.text == "PEAR\nAPPLE\nZEBRA\nMANGO\n", "⌃⌘U upper-cases")
            },
            sync { key("z", [.command]); expect(list.text == "pear\napple\nzebra\nmango\n", "⌘Z undoes only the upper-casing", list.text) },
            sync { key("z", [.command]); expect(list.text == "pear\napple\nzebra\nmango\npear\n", "⌘Z again undoes only the de-duplication", list.text) },
            sync { key("z", [.command]); expect(list.text == "pear\nzebra\napple\nmango\npear\n", "⌘Z again undoes the sort", list.text) },
            sync {
                // Invalid JSON: an alert sheet, the text untouched.
                let before = list.text
                key("j", [.control, .option, .command])
                let sheet = list.window?.attachedSheet
                let alertText = sheet.flatMap { s in
                    (s.contentView?.subviews ?? []).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ")
                } ?? ""
                print("check: alert: \(alertText)")
                expect(sheet != nil && alertText.contains("Not valid JSON"), "invalid JSON shows an alert", alertText)
                expect(list.text == before, "invalid JSON leaves the text as it was")
                if let sheet { list.window?.endSheet(sheet) }
            },
            sync { data.window?.makeKeyAndOrderFront(nil) },
            snapshot("texttool-json-pretty.png"),
            // Tool output in a dark theme with a coloured palette: the
            // inserted text must be drawn in visible ink (the typing fix's
            // styling path), immediately and after highlighting.
            sync {
                TypingCheck.apply(TypingCheck.themes.first { $0.name == "dracula" }!)
                let dark = app.open(write("dracula.json", json + "\n"))!
                sized(dark)
                dark.window?.makeKeyAndOrderFront(nil)
                dark.window?.makeFirstResponder(dark.textView)
                TypingCheck.settle()
                key("j", [.control, .option, .command])
                expect(dark.text == pretty, "Dracula: ⌃⌥⌘J pretty-prints JSON", dark.text)
                expect(dark.textView.selectedRange() == NSRange(location: 0, length: 0),
                       "a whole-document tool leaves the caret at the start", "\(dark.textView.selectedRange())")
                let p = dark.palette
                let bgs = [p.background, p.currentLine]
                let tv = dark.textView
                let rects = TypingCheck.glyphRects(tv, NSRange(location: 0, length: (pretty as NSString).length))
                let now = TypingCheck.ink(tv, rects, backgrounds: bgs)
                expect(TypingCheck.visible(now, minPixels: 200), "Dracula: pretty-printed text visible immediately", TypingCheck.describe(now))
                TypingCheck.settle(0.3)
                let later = TypingCheck.ink(tv, rects, backgrounds: bgs,
                                            shot: out.appendingPathComponent("texttool-dracula-ink.png").path)
                expect(TypingCheck.visible(later, minPixels: 200), "Dracula: pretty-printed text visible after highlighting", TypingCheck.describe(later))
                TypingCheck.settle(0.2)
                let sp = TypingCheck.screenPath(tv, rects)
                expect(sp.ok, "Dracula: pretty-printed text has drawn screen layers", sp.detail)
            },
            snapshot("texttool-json-pretty-dracula.png"),
        ])
    }

    // MARK: Find in Files

    static func findInFiles(_ app: AppDelegate) {
        _ = write("src/main.swift", "import Foundation\n\nlet needle = \"haystack\"\nprint(needle)\n")
        _ = write("src/util/strings.swift", "// Needle helpers\nfunc findNeedle(in s: String) -> Bool { s.contains(\"needle\") }\n")
        _ = write("docs/notes.md", "# Notes\n\nA needle in the docs.\nNo match here.\n")
        _ = write("node_modules/dep/index.js", "module.exports = 'needle'\n")
        _ = write(".git/HEAD", "needle\n")
        _ = write("build/out.txt", "needle\n")
        var bin = Data("needle".utf8); bin.append(contentsOf: [0, 0, 1, 2])
        try? bin.write(to: dir.appendingPathComponent("src/blob.bin"))
        try? Data(repeating: 110, count: 21 * 1024 * 1024).write(to: dir.appendingPathComponent("docs/huge.log"))
        guard let main = app.open(dir.appendingPathComponent("src/main.swift")) else {
            expect(false, "src/main.swift opens"); finish(); return
        }
        main.window?.setContentSize(NSSize(width: 1300, height: 720))
        run([
            sync {
                main.window?.makeKeyAndOrderFront(nil)
                key("f", [.command, .shift])
                if app.findInFiles?.isShown != true {
                    // The VMs (app active) sometimes drop a synthetic shifted ⌘-key; a real ⇧⌘F works there.
                    print("check: note: synthetic ⇧⌘F not taken; sending Find in Files…'s action")
                    app.findInFilesMenu(nil)
                }
                let p = app.findInFiles
                expect(p?.isShown == true && p?.window === main.window, "⇧⌘F docks the panel in the tab")
                expect(p?.folderField.stringValue == dir.appendingPathComponent("src").path, "folder defaults to the file's folder",
                       p?.folderField.stringValue ?? "-")
                // Search the whole tree.
                p?.folderField.stringValue = dir.path
                expect(main.window?.firstResponder is NSTextView && p.map { (main.window?.firstResponder as? NSView)?.isDescendant(of: $0) == true } == true,
                       "the query field has focus")
            },
            sync { type("needle") },
            { next in
                guard let p = app.findInFiles else { expect(false, "Find in Files is open"); next(); return }
                p.onFinished = { p.onFinished = nil; next() }
                key("\r")
            },
            sync {
                guard let p = app.findInFiles else { expect(false, "Find in Files is open"); return }
                let rows = p.results.map { "\($0.relativePath):\($0.line)" }
                print("check: results \(rows)")
                expect(p.queryField.stringValue == "needle", "typed query reached the field", p.queryField.stringValue)
                expect(rows == ["docs/notes.md:3", "src/main.swift:3", "src/main.swift:4", "src/util/strings.swift:1", "src/util/strings.swift:2"],
                       "results skip .git, node_modules, build, the binary and the 21 MB file", "\(rows)")
                expect(p.lastSummary?.skippedBinary == 1 && p.lastSummary?.skippedLarge == 1, "binary and big file counted as skipped")
                // Three file rows, each followed by its matches.
                expect(p.table.numberOfRows == 8, "three files and five matches in the list", "\(p.table.numberOfRows)")
            },
            snapshot("findinfiles-results.png"),
            { next in
                guard let p = app.findInFiles else { expect(false, "Find in Files is open"); next(); return }
                // Click row 6 (src/util/strings.swift:1, under its file row at 5).
                p.table.scrollRowToVisible(6)
                let r = p.table.rect(ofRow: 6)
                click(p.table, at: NSPoint(x: r.midX, y: r.midY))
                if p.table.selectedRow != 6 {
                    // NSTableView ignores a synthetic click in a window that
                    // can't become key (app inactive): select the row and send
                    // the table's click action, as the click would.
                    print("check: note: synthetic click not taken by the inactive table; sending its action for row 6")
                    p.table.selectRowIndexes([6], byExtendingSelection: false)
                    if let action = p.table.action { NSApp.sendAction(action, to: p.table.target, from: p.table) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
            },
            sync {
                let t = app.tabs.first { $0.doc.fileURL?.lastPathComponent == "strings.swift" }
                expect(t != nil, "clicking a result opens the file")
                if let t {
                    let sel = t.textView.selectedRange()
                    expect(t.lineIndex.line(containing: sel.location) == 0, "…at the matching line")
                    expect((t.text as NSString).substring(with: sel) == "Needle", "…with the match selected",
                           (t.text as NSString).substring(with: sel))
                    expect(app.findInFiles?.window === t.window, "the panel follows to the new tab")
                    t.window?.setContentSize(NSSize(width: 1300, height: 720))
                }
            },
            snapshot("findinfiles-opened.png"),
            { next in
                // Cancel: a big tree, stopped at once.
                for k in 0..<400 { _ = write("many/f\(k).txt", String(repeating: "needle line\n", count: 200)) }
                guard let p = app.findInFiles else { expect(false, "Find in Files is open"); next(); return }
                p.folderField.stringValue = dir.appendingPathComponent("many").path
                p.onFinished = {
                    p.onFinished = nil
                    expect(p.lastSummary?.cancelled == true || p.lastSummary?.truncated == true, "Stop cancels (or the 10,000 cap stops) a search",
                           "\(String(describing: p.lastSummary))")
                    expect(p.results.count <= 10_000, "never more than 10,000 results", "\(p.results.count)")
                    next()
                }
                p.startSearch()
                p.stopSearch()
            },
            { next in
                guard let p = app.findInFiles else { expect(false, "Find in Files is open"); next(); return }
                p.onFinished = {
                    p.onFinished = nil
                    expect(p.lastSummary?.truncated == true && p.results.count == 10_000, "80,000 hits cap at 10,000", "\(p.results.count)")
                    next()
                }
                p.startSearch()
            },
        ])
    }

    // MARK: Compare

    static func compare(_ app: AppDelegate) {
        let a = """
        import Foundation

        struct Owl {
            let name: String
            var hoots = 0
            func greet() -> String { "Hoot, \\(name)" }
        }

        let owl = Owl(name: "Cedric")
        print(owl.greet())
        // end
        """
        let b = """
        import Foundation
        import AppKit

        struct Owl {
            let name: String
            var hoots = 3
            func greet() -> String { "Hoot hoot, \\(name)!" }
        }

        let owl = Owl(name: "Cedric")
        // end
        """
        let left = app.open(write("owl-v1.swift", a))!
        let right = app.open(write("owl-v2.swift", b))!
        _ = right
        run([
            sync {
                left.window?.makeKeyAndOrderFront(nil)
                key("c", [.command, .option])
                expect(left.window?.attachedSheet != nil, "⌥⌘C asks which tab to compare with")
            },
            sync {
                // Return picks the default (the other tab).
                if let sheet = left.window?.attachedSheet { pressReturn(in: sheet) }
            },
            sync {
                let c = app.compareWindows.last
                expect(c != nil, "a compare tab opened")
                guard let c else { return }
                c.window?.setContentSize(NSSize(width: 1200, height: 420))
                let kinds = c.diffView.rows.map(\.kind)
                let count = { (k: LineDiff.RowKind) in kinds.filter { $0 == k }.count }
                print("check: rows \(c.diffView.rows)")
                expect(count(.added) == 1 && count(.removed) == 1 && count(.changed) == 2, "1 added, 1 removed, 2 changed",
                       "added \(count(.added)) removed \(count(.removed)) changed \(count(.changed))")
                expect(c.window?.title == "owl-v1.swift ↔ owl-v2.swift", "titled with both names", c.window?.title ?? "-")
                expect(c.window?.tabGroup === left.window?.tabGroup, "opens as a tab beside the document")
            },
            { next in snapshot("compare.png", window: app.compareWindows.last?.window)(next) },
        ])
    }

    // MARK: Follow

    static func follow(_ app: AppDelegate) {
        let log = write("app.log", (1...300).map { "2026-11-17 12:00:\(String(format: "%02d", $0 % 60)) INFO line \($0)" }.joined(separator: "\n") + "\n")
        let tab = app.open(log)!
        sized(tab)
        func append(_ s: String) {
            let fh = try! FileHandle(forWritingTo: log)
            fh.seekToEndOfFile()
            fh.write(Data(s.utf8))
            fh.closeFile()
        }
        run([
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                key("t", [.command, .option])
                expect(tab.isFollowing, "⌥⌘T follows the file")
                expect(!tab.textView.isEditable, "the tab is read-only while following")
                expect(tab.isScrolledToBottom, "…and scrolled to the end")
            },
            { next in
                append("2026-11-17 12:01:00 WARN appended one\n2026-11-17 12:01:01 ERROR appended two\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
            },
            sync {
                expect(tab.text.hasSuffix("ERROR appended two\n"), "appended lines show up", String(tab.text.suffix(60)))
                expect(tab.lineIndex.lineCount == 303, "line index follows", "\(tab.lineIndex.lineCount)")
                expect(!tab.doc.isDirty, "the tab stays clean")
                expect(tab.isScrolledToBottom, "still at the bottom after the append")
            },
            snapshot("follow-appended.png"),
            { next in
                // Scrolled up: an append must not move the view.
                tab.scrollToLine(10)
                let top = tab.topLine
                append("2026-11-17 12:02:00 INFO while scrolled up\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    expect(tab.text.hasSuffix("while scrolled up\n"), "appended while scrolled up")
                    expect(tab.topLine == top && !tab.isScrolledToBottom, "the view stays where the user scrolled", "top \(tab.topLine) was \(top)")
                    tab.scrollToBottom()
                    next()
                }
            },
            { next in
                let fh = try! FileHandle(forWritingTo: log)
                fh.truncateFile(atOffset: 0)
                fh.write(Data("restarted after truncate\n".utf8))
                fh.closeFile()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
            },
            sync { expect(tab.text == "restarted after truncate\n", "truncate reloads the file", tab.text) },
            { next in
                try? FileManager.default.moveItem(at: log, to: dir.appendingPathComponent("app.log.1"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    try? "rotated: new file\n".write(to: log, atomically: false, encoding: .utf8)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
                }
            },
            sync { expect(tab.text == "rotated: new file\n", "rotation (rename + new file) is followed", tab.text) },
            sync {
                key("t", [.command, .option])
                expect(!tab.isFollowing && tab.textView.isEditable, "⌥⌘T again stops following")
            },
            // Closing a followed tab stops the watcher: no descriptor left
            // on the file (0.2.1 review M5).
            sync {
                key("t", [.command, .option])
                expect(tab.isFollowing, "following again before closing the tab")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(FileTail.descriptorsOpen(on: log) == 1, "the followed file has one descriptor open",
                       "\(FileTail.descriptorsOpen(on: log))")
                _ = app.open(write("keep-a-window.txt", "x\n"))
                tab.window?.close()
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                expect(tab.tail == nil, "closing the tab drops its tail")
                expect(FileTail.descriptorsOpen(on: log) == 0, "…and no descriptor is left on the file",
                       "\(FileTail.descriptorsOpen(on: log))")
            },
        ] + followHeldBytes(app))
    }

    /// Waits (polling every 50 ms, at most `seconds`) for `cond`; a
    /// timeout is a failed check named `what`, and the run goes on.
    static func waitFor(_ what: String, _ seconds: Double = 5, _ cond: @escaping () -> Bool) -> (@escaping () -> Void) -> Void {
        { next in
            let deadline = Date().addingTimeInterval(seconds)
            @MainActor func poll() {
                if cond() { next(); return }
                guard Date() < deadline else { expect(false, "\(what) (waited \(seconds) s)"); next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
            poll()
        }
    }

    /// Codex 0.5.4 review 2: a UTF-16 file with an odd byte count (the
    /// writer mid-character) followed and then stopped: the tab showed
    /// only the whole characters but was stamped with the whole file, so
    /// ⌘S wrote it back without the last byte. Now the stamp covers only
    /// the bytes shown and ⌘S asks. Once for Follow started on the odd
    /// file, once for an odd append while following.
    /// Review 3: the stamp is the one the tail read the bytes at, not the
    /// path's when the event reaches the main thread (a same-size file
    /// put there in between); and stopping Follow catches up off the
    /// main thread.
    static func followHeldBytes(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        let u16 = { (s: String) in Data([0xFF, 0xFE]) + s.data(using: .utf16LittleEndian)! }
        let started = dir.appendingPathComponent("odd-start.log"), appended = dir.appendingPathComponent("odd-append.log")
        let raced = dir.appendingPathComponent("raced.log")
        try? u16("one\n").write(to: started)
        try? u16("one\n").write(to: appended)
        try? Data("one\n".utf8).write(to: raced)
        let odd = u16("one\nab").dropLast()   // half of "b"
        var tabs: [String: EditorWindowController] = [:]
        func addBytes(_ url: URL, _ bytes: Data) {
            let fh = try! FileHandle(forWritingTo: url)
            fh.seekToEndOfFile()
            fh.write(bytes)
            fh.closeFile()
        }
        /// Opens and follows `url` (its watcher armed before the step ends).
        func follow(_ url: URL, _ name: String, before: () -> Void = {}) {
            guard let tab = app.open(url) else { expect(false, "\(name) opens"); return }
            tabs[name] = tab
            before()
            tab.toggleFollow()
            _ = tab.tail?.isWatching   // its queue has run start()
        }
        /// Stop following, ⌘S: nothing written, the conflict sheet asks.
        func stopAndSave(_ name: String, _ url: URL, _ want: String, _ onDisk: Data) {
            guard let tab = tabs[name] else { expect(false, "\(name): has its tab"); return }
            tab.toggleFollow()
            expect(!tab.isFollowing, "\(name): Follow stopped")
            expect(tab.text == want, "\(name): the tab shows what Follow showed", tab.text.debugDescription)
            let saved = tab.save()
            let now = (try? Data(contentsOf: url)) ?? Data()
            expect(!saved && now == onDisk, "\(name): ⌘S doesn't write over bytes it never showed",
                   "saved \(saved), \(now.count) bytes, want \(onDisk.count)")
            expect(tab.window?.attachedSheet != nil || tab.diskBar != nil, "\(name): …it says the file differs")
            if let sheet = tab.window?.attachedSheet { tab.window?.endSheet(sheet) }
        }
        let tail = odd.suffix(odd.count - u16("one\n").count)
        return [
            sync {
                // Opened whole; the writer then adds "a" and half of "b".
                follow(started, "started odd") { addBytes(started, tail) }
                expect(tabs["started odd"]?.isFollowing == true && tabs["started odd"]?.text == "one\na",
                       "Follow on an odd UTF-16 file shows the whole characters", (tabs["started odd"]?.text).debugDescription)
            },
            sync { stopAndSave("started odd", started, "one\na", odd) },
            sync {
                follow(appended, "appended odd")
                expect(tabs["appended odd"]?.text == "one\n", "following the even file")
                addBytes(appended, tail)
            },
            waitFor("appended odd: the whole characters show") { tabs["appended odd"]?.text == "one\na" },
            sync { stopAndSave("appended odd", appended, "one\na", odd) },
            sync {
                // An append read by the tail, then (before its event
                // reaches the main thread) the file rewritten in place at
                // the same size: no event of its own (nothing appended),
                // a new date. (FileTailTests race an atomic replace.)
                follow(raced, "raced")
                guard let tab = tabs["raced"], let t = tab.tail else { return }
                addBytes(raced, Data("two\n".utf8))
                t.poll()
                _ = t.isWatching   // read and queued for the main thread
                let read = DiskStamp.of(raced)
                let fh = try! FileHandle(forWritingTo: raced)
                fh.write(Data("ONE\nTWO\n".utf8))
                fh.closeFile()
                // Both writes can fall in one clock tick: the date moved on
                // as a later write's would.
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: raced.path)
                expect(DiskStamp.changed(known: read, current: DiskStamp.of(raced)), "raced: the rewrite is a change on disk")
            },
            waitFor("raced: the append shows") { tabs["raced"]?.text == "one\ntwo\n" },
            sync {
                // Stopped and saved in one turn: the catch-up read (off
                // the main thread) can't have landed.
                stopAndSave("raced", raced, "one\ntwo\n", Data("ONE\nTWO\n".utf8))
                expect(tabs["raced"]?.catchUpReads == 1, "raced: stopping Follow reads the file off the main thread",
                       "\(tabs["raced"]?.catchUpReads ?? -1)")
            },
            waitFor("raced: the catch-up shows the file now") {
                tabs["raced"]?.catchUpReads == 0 && tabs["raced"]?.text == "ONE\nTWO\n"
            },
            sync {
                guard let tab = tabs["raced"] else { return }
                expect(!tab.doc.isDirty && tab.diskBar == nil, "raced: …clean, no bar")
                expect(tab.save(), "raced: ⌘S after the catch-up saves")
            },
        ]
    }

    // MARK: Open Recent

    static func recent(_ app: AppDelegate) {
        let dc = NSDocumentController.shared
        let saved = dc.recentDocumentURLs
        let f1 = write("recent-one.txt", "one\n"), f2 = write("recent-two.md", "# two\n")
        run([
            sync {
                app.open(f1)
                app.open(f2)
                let titles = app.recentMenu?.items.map(\.title) ?? []
                print("check: recent menu \(titles)")
                expect(titles.first == "recent-two.md" && titles.dropFirst().first == "recent-one.txt", "File › Open Recent lists the files, newest first")
                expect(app.recentMenu?.items.first?.keyEquivalent == "1" && app.recentMenu?.items.first?.keyEquivalentModifierMask == [.command, .option],
                       "the newest is ⌥⌘1")
                expect(titles.last == "Clear Menu", "ends with Clear Menu")
                app.tabs.first { $0.doc.fileURL?.lastPathComponent == "recent-one.txt" }?.window?.close()
            },
            sync {
                key("2", [.command, .option])
                expect(app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "recent-one.txt" }, "⌥⌘2 reopens the second recent file")
            },
            sync {
                guard let m = app.recentMenu, let i = m.items.firstIndex(where: { $0.title == "Clear Menu" }) else {
                    expect(false, "Clear Menu item"); return
                }
                m.performActionForItem(at: i)
                expect(dc.recentDocumentURLs.isEmpty, "Clear Menu empties the system list")
                expect(app.recentMenu?.items.map(\.title) == ["Clear Menu"], "…and the menu")
                // Put the machine's list back as it was.
                for u in saved.reversed() { dc.noteNewRecentDocumentURL(u) }
                app.rebuildRecentMenu()
            },
        ])
    }

    // MARK: Shortcuts

    /// Prints every key equivalent in the main menu; returns false on a
    /// clash, or on one the system takes before the app sees it.
    static func dumpShortcuts() -> Bool {
        (NSApp.delegate as? AppDelegate)?.rebuildRecentMenu()
        var seen: [String: String] = [:]
        var ok = true
        let reserved: [String: String] = [
            "⌃⌘Q": "Lock Screen", "⌃⌘D": "Look Up", "⌃⌘␣": "Emoji & Symbols", "⌥⌘D": "Dock hiding", "⌘␣": "Spotlight",
            "⌥⌘⎋": "Force Quit", "⇧⌘3": "Screenshot", "⇧⌘4": "Screenshot", "⇧⌘5": "Screenshot", "⌘⇥": "App switcher",
            // Mission Control and App Exposé (default settings); ⌃⇧↑/↓ (Add Caret Above/Below) stay free.
            "⌃↑": "Mission Control", "⌃↓": "App Exposé",
        ]
        for (k, p) in MenuShortcuts.list() {
            print(String(format: "shortcut %-8@ %@", k as NSString, p as NSString))
            if let other = seen[k] { print("CONFLICT \(k): \(other) and \(p)"); ok = false }
            if let sys = reserved[k] { print("CONFLICT \(k): \(p) and the system's \(sys)"); ok = false }
            seen[k] = p
        }
        print(ok ? "shortcuts: \(seen.count), no conflicts" : "shortcuts: conflicts found")
        return ok
    }
}
