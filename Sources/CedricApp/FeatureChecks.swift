import AppKit
import CedricCore

/// In-process checks of Fix Typos… (the spelling step-through), the
/// detachable preview and the CSV grid, run by Scripts/tools-check.sh like
/// the other DevChecks: the menus' key equivalents and real key events
/// sent to the step-through's panel, clicks on its buttons.
///
///   CEDRIC_CHECK=spellstep|detachpreview|csvpreview|csvrownumber
@MainActor
extension DevChecks {
    static func featureCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "spellstep": spellStep(app)
        case "detachpreview": detachPreview(app)
        case "csvpreview": csvPreview(app)
        case "csvrownumber": csvRowNumberHeader(app)
        case "grammar": grammarCheck(app)
        case "cert": certificateCheck(app)
        default: return markdownCheck(name, app)
        }
        return true
    }

    /// A key press sent to `w` as an NSEvent (keyDown, keyUp).
    static func keyTo(_ w: NSWindow, _ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
    }

    /// A left click given straight to `view` (a table: with the app
    /// inactive, the window would give the event to the cell's label).
    static func clickDirect(_ view: NSView, at point: NSPoint) {
        guard let w = view.window else { return }
        let p = view.convert(point, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber,
                                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05, windowNumber: w.windowNumber,
                                          context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
    }

    static func press(_ b: NSButton) { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }

    // MARK: Fix Typos…

    static func spellStep(_ app: AppDelegate) {
        let text = "I beleive this. A mispeled word, teh dog and teh cat.\nverry good, verry nice.\nzqxlearnwrd is new.\n`codde` and [linkk](https://exmple.com/pth).\n"
        let md = app.open(write("typos.md", text))!
        let swift = app.open(write("typos.swift", "let mispeledName = 1 // a wrod in a comment\n"))!
        // Large mode (a 120 K-character line): checked only as far as needed.
        let big = String(repeating: "word ", count: 6_000) + "tpyo " + String(repeating: "word ", count: 18_000) + "\n"
        let large = app.open(write("large.txt", big))!
        let ns = text as NSString
        for t in [md, swift, large] { sized(t) }
        let tv = md.textView
        var s: SpellStepController? { md.spellStep }
        var guess = ""
        var learned: [String] = []
        var learnedThen = false
        func now() -> String { s?.current?.word ?? "-" }
        func progress() -> String { s?.progressLabel.stringValue ?? "-" }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(md)
                tv.setSelectedRange(NSRange(location: ns.range(of: "A mispeled").location, length: 0))
                key(";", [.command, .option])
                expect(s != nil && s!.panel.isVisible, "⌥⌘; opens the Fix Typos panel")
                expect(now() == "mispeled", "the first word is the one after the caret", now())
                expect(tv.selectedRange() == ns.range(of: "mispeled"), "and it is selected", "\(tv.selectedRange())")
                expect(s?.table.selectedRow == 0 && !(s?.guesses.isEmpty ?? true), "the first suggestion is preselected",
                       "\(s?.guesses ?? [])")
                // Panel sits next to the word, clear of it.
                if let s, let r = Optional(tv.firstRect(forCharacterRange: ns.range(of: "mispeled"), actualRange: nil)) {
                    expect(!s.panel.frame.intersects(r), "the panel doesn't cover the word", "\(s.panel.frame) \(r)")
                }
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(progress() == "1 of 7", "progress counts every word (scan done)", progress())
                guess = s?.guesses.first ?? ""
            },
            snapshot("spellstep-panel.png"),
            { next in
                guard let p = s?.panel else { next(); return }
                snapshot("spellstep-panel-only.png", window: p)(next)
            },
            sync {
                guard let p = s?.panel else { return }
                keyTo(p, "\r", code: 36)
                expect(md.text.contains("A \(guess) word"), "Return changes it to the first suggestion", md.text)
                expect(now() == "teh", "and moves on", now())
                expect(progress() == "2 of 7", "2 of 7", progress())
                guess = s?.guesses.first ?? ""
            },
            sync {
                guard let b = s?.changeAllButton else { return }
                press(b)
                expect(!md.text.contains("teh") && md.text.contains("\(guess) dog and \(guess) cat"), "Change All changes both", md.text)
                expect(now() == "verry", "then the next word", now())
                expect(progress() == "4 of 7", "4 of 7", progress())
            },
            sync {
                guard let p = s?.panel else { return }
                let first = s?.current?.range
                keyTo(p, String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), code: 124, [.command])
                expect(now() == "verry" && s?.current?.range != first, "⌘→ skips to the next one", "\(now()) \(String(describing: s?.current?.range))")
            },
            sync {
                guard let b = s?.ignoreButton else { return }
                press(b)
                expect(now() == "zqxlearnwrd", "Ignore All passes the rest of that word", now())
                expect(md.text.contains("verry good, verry nice"), "and changes nothing")
                // Learn Word goes to the user's dictionary: learned, checked, and forgotten again.
                s?.onLearn = { w in
                    NSSpellChecker.shared.learnWord(w)
                    learnedThen = NSSpellChecker.shared.hasLearnedWord(w)
                    NSSpellChecker.shared.unlearnWord(w)
                    learned.append(w)
                }
            },
            sync {
                guard let b = s?.learnButton else { return }
                press(b)
                expect(learned == ["zqxlearnwrd"] && learnedThen, "Learn Word learns it", "\(learned)")
                expect(!NSSpellChecker.shared.hasLearnedWord("zqxlearnwrd"), "(and the check forgot it again)")
                expect(now() == "beleive", "then wraps round to the top", now())
                expect(progress() == "7 of 7", "7 of 7", progress())
                expect(!md.text.contains("codde") || now() != "codde", "code spans and links are never stepped into")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                guard let p = s?.panel else { return }
                keyTo(p, "\t", code: 48)
                expect(s?.current == nil, "Tab skips the last one", now())
                expect(md.text.contains("I beleive this"), "skipping changes nothing")
            },
            snapshot("spellstep-done.png"),
            sync {
                guard let p = s?.panel else { return }
                keyTo(p, "\u{1b}", code: 53)
                expect(md.spellStep == nil && !p.isVisible, "Esc closes it")
                expect(md.window?.firstResponder === tv, "the text has the focus again")
            },
            sync {
                key("z", [.command])
                expect(md.text.contains("teh dog and teh cat") && !md.text.contains("mispeled"), "one ⌘Z undoes Change All", md.text)
            },
            sync {
                key("z", [.command])
                expect(md.text == text, "the next ⌘Z undoes the single Change", md.text)
            },
            // Typing in the document while the panel is open: the words still to come follow.
            sync {
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                key(";", [.command, .option])
                expect(now() == "beleive", "from the top: beleive", now())
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.insertText("Well, ", replacementRange: NSRange(location: 0, length: 0))
                s?.skip(nil)
                let r = s?.current?.range ?? NSRange(location: 0, length: 0)
                expect(now() == "mispeled" && (md.text as NSString).substring(with: r) == "mispeled",
                       "an edit above moves the words still to come", "\(now()) \(r)")
                s?.done(nil)
                md.textView.undoManager?.undo()
            },
            // Code: comments and strings only, never identifiers.
            sync {
                focus(swift)
                swift.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key(";", [.command, .option])
                expect(swift.spellStep?.current?.word == "wrod", "in code, only comments and strings", swift.spellStep?.current?.word ?? "-")
                swift.spellStep?.done(nil)
            },
            // Large mode: on demand, a few chunks at a time.
            sync {
                focus(large)
                expect(large.extrasPaused, "the long-line file is in large mode")
                large.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key(";", [.command, .option])
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let st = large.spellStep
                expect(st?.current?.word == "tpyo", "large mode: the word is found", st?.current?.word ?? "-")
                expect(!(st?.stepper.scanComplete ?? true), "but the rest of the file isn't checked",
                       "\(st?.stepper.unscanned.count ?? -1) chunks left")
                expect(st?.progressLabel.stringValue.hasSuffix("+") == true, "progress says more may come", st?.progressLabel.stringValue ?? "-")
                st?.done(nil)
                for t in [md, swift, large] { t.doc.markSaved() }
            },
        ]
        steps += steps2
        run(steps)
    }

    // MARK: Detached preview

    /// Waits (up to 5 s) until the web preview's text contains `needle`.
    static func waitForPreview(_ tab: EditorWindowController, contains needle: String, _ name: String) -> (@escaping () -> Void) -> Void {
        { next in
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                guard let web = tab.preview?.webView else { expect(false, name, "no web preview"); next(); return }
                web.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                    MainActor.assumeIsolated {
                        let text = result as? String ?? ""
                        if text.contains(needle) { expect(true, name); next() }
                        else if Date() > deadline { expect(false, name, "preview text=\(text.prefix(120).debugDescription)"); next() }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } } }
                    }
                }
            }
            poll()
        }
    }

    /// A just-detached preview's window is visible, in front of the
    /// app's other windows, and key (the focus moved there); the menus
    /// still act on its tab.
    static func expectDetachedInFront(_ tab: EditorWindowController, _ app: AppDelegate, _ what: String) {
        guard let w = tab.previewWindow?.window else { expect(false, "\(what): a detached preview window"); return }
        let ordered = NSApp.orderedWindows.filter(\.isVisible)
        expect(w.isVisible && ordered.first === w, "\(what): the detached preview is in front", "front: \(ordered.first?.title ?? "-")")
        let editorAt = tab.window.flatMap { ordered.firstIndex(of: $0) } ?? -1
        expect(editorAt > 0, "\(what): its editor window is behind it", "editor at \(editorAt)")
        if NSApp.isActive {
            expect(w.isKeyWindow && NSApp.keyWindow === w, "\(what): the detached preview window has the focus",
                   "key: \(NSApp.keyWindow?.title ?? "-")")
            expect(tab.window?.isKeyWindow == false, "\(what): the editor window gave up the focus")
            expect(tab.window?.isMainWindow == true && w.isMainWindow == false, "\(what): its editor stays the main window",
                   "main: \(NSApp.mainWindow?.title ?? "-")")
        } else {
            // An inactive app (launched by a script, screen locked) has no key
            // window at all: AppKit makes the preview key on activation.
            print("check: note: \(what): Cedric isn't active, so no window is key; checked the order (preview in front) only")
        }
        expect(w.canBecomeMain == false, "\(what): the preview window can be key but never main")
        expect(app.currentTab === tab, "\(what): the menus still act on its document")
    }

    /// Two editor windows; the older one's preview detached (and key): a
    /// new tab joins the preview's owner, not the newest window; Float on
    /// Top acts on the editor; ⌘F types into the editor's find field.
    static func detachedPreviewCommands(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        var older: EditorWindowController!
        var newer: EditorWindowController!
        var pw: NSWindow? { older.previewWindow?.window }
        func group(_ w: NSWindow?) -> [NSWindow] { w.map { $0.tabbedWindows ?? [$0] } ?? [] }
        return [
            sync {
                older = app.open(write("older.md", "# Older\n\nfind me here\n"))!
                newer = app.makeTab(EditorDocument(untitledName: "Newer"), text: "", newWindow: true)
                // A .preferred window can join a group as it is shown; Window › Move Tab to New Window, as a user would.
                if group(newer.window).count > 1 { newer.window?.moveTabToNewWindow(nil) }
                sized(older); sized(newer)
                expect(older.window !== newer.window && !group(newer.window).contains { $0 === older.window },
                       "two windows: two editor windows, not tabs of one")
                focus(older)
                older.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key("p", [.command, .option, .shift])
                expect(older.previewDetached, "two windows: ⇧⌥⌘P detaches the older window's preview")
                expectDetachedInFront(older, app, "two windows")
                // The routing itself, which needs no key window to check.
                expect(AppDelegate.documentWindow(for: pw) === older.window,
                       "two windows: a new tab's host for the detached preview is its own editor window",
                       AppDelegate.documentWindow(for: pw)?.title ?? "nil")
            },
            sync {
                guard NSApp.isActive, NSApp.keyWindow === pw else {
                    print("check: note: two windows: Cedric isn't active, so the preview isn't key; Float on Top and ⌘N with the preview key not checked")
                    return
                }
                expect(app.floatTargetWindow() === older.window, "two windows: Float on Top targets the editor, not the preview",
                       app.floatTargetWindow()?.title ?? "nil")
                if let i = menuItem(action: #selector(AppDelegate.toggleFloatOnTop(_:))) {
                    expect(app.validateMenuItem(i), "two windows: Window › Float on Top is enabled with the preview key")
                    NSApp.sendAction(i.action!, to: nil, from: i)
                    expect(older.window?.level == .floating && newer.window?.level == .normal, "two windows: it floats the editor's window")
                    NSApp.sendAction(i.action!, to: nil, from: i)
                    expect(older.window?.level == .normal, "two windows: and unfloats it")
                } else { expect(false, "two windows: Window › Float on Top") }
                let before = app.tabs.count
                key("n", [.command])
                let added = app.tabs.count == before + 1 ? app.tabs.last : nil
                expect(added.map { t in group(older.window).contains { $0 === t.window } } == true,
                       "two windows: ⌘N with the preview key opens the tab in the preview's owner window",
                       "older group \(group(older.window).map(\.title)), newer group \(group(newer.window).map(\.title))")
                expect(added.map { t in !group(newer.window).contains { $0 === t.window } } == true, "two windows: not in the newer window")
                expect(pw?.contentView?.subviews.contains { $0 is PreviewPane } == true && pw?.tabbedWindows == nil,
                       "two windows: the preview window hosts no tab")
                if let added { added.doc.markSaved(); added.window?.performClose(nil) }
            },
            sync {
                // The preview key (front) again, then ⌘F and typing.
                pw?.makeKeyAndOrderFront(nil)
                key("f", [.command])
                type("find")
                expect(!older.findBar.isHidden && older.findBar.findField.stringValue == "find",
                       "two windows: ⌘F with the preview key types into the editor's find field",
                       older.findBar.findField.stringValue.debugDescription)
                expect((older.window?.firstResponder as? NSText)?.delegate === older.findBar.findField,
                       "two windows: the find field has the keyboard")
                if NSApp.isActive {
                    expect(older.window?.isKeyWindow == true, "two windows: ⌘F makes the editor key",
                           "key: \(NSApp.keyWindow?.title ?? "-")")
                }
                older.hideFindBar()
                for t in [older!, newer!] { t.doc.markSaved(); t.window?.performClose(nil) }
                expect(older.previewWindow == nil, "two windows: the detached preview closes with its tab")
            },
        ]
    }

    static func detachPreview(_ app: AppDelegate) {
        let a = app.open(write("first.md", "# First\n\nhello\n"))!
        let b = app.open(write("second.md", "# Second\n\nother document\n"))!
        let csv = app.open(write("detach.csv", "name,city\nAnn,Oslo\nBo,Rome\n"))!
        let html = app.open(write("detach.html", "<!doctype html><title>t</title><p>html body</p>\n"))!
        let restored = app.open(write("restored.md", "# Restored\n\nsession\n"))!
        sized(a); sized(b); sized(csv); sized(html); sized(restored)
        let item = { menuItem(action: #selector(AppDelegate.toggleDetachPreview(_:))) }
        var pw: NSWindow? { a.previewWindow?.window }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(a)
                key("p", [.command, .option])
                expect(a.previewVisible && !a.previewDetached && a.previewPane?.superview === a.split, "⌥⌘P docks the preview beside the text")
                expect(a.previewPane?.detachButton.accessibilityLabel() == "Detach", "its header has Detach",
                       a.previewPane?.detachButton.accessibilityLabel() ?? "-")
                if let i = item() { _ = app.validateMenuItem(i); expect(i.title == "Detach Preview", "View › Detach Preview", i.title) }
            },
            waitForPreview(a, contains: "hello", "the docked preview shows the document"),
            sync {
                guard let button = a.previewPane?.detachButton else { return }
                press(button)
                expect(a.previewDetached && pw?.isVisible == true, "Detach moves it into its own window")
                expect(pw?.title == "first.md — Preview", "titled after its document", pw?.title ?? "-")
                expect(!a.split.arrangedSubviews.contains { $0 === a.previewPane } && a.split.arrangedSubviews.contains(a.editorArea),
                       "the preview left the editor's split", "\(a.split.arrangedSubviews.map { Swift.type(of: $0) })")
                expect(pw.map { $0.styleMask.contains(.resizable) } == true, "the window is resizable")
                expect(a.previewPane?.detachButton.accessibilityLabel() == "Attach", "its header now has Attach",
                       a.previewPane?.detachButton.accessibilityLabel() ?? "-")
                if let i = item() { _ = app.validateMenuItem(i); expect(i.title == "Attach Preview", "the menu says Attach Preview", i.title) }
                // Derek: detaching puts the preview window in focus.
                expectDetachedInFront(a, app, "Markdown, the header's Detach")
            },
            { next in
                guard let w = pw else { next(); return }
                snapshot("detached-preview-key.png", window: w)(next)
            },
            sync {
                focus(a)
                a.textView.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
                type("live typing")
            },
            waitForPreview(a, contains: "live typing", "typing updates the detached preview"),
            sync {
                pw?.setFrame(NSRect(x: 160, y: 140, width: 480, height: 400), display: true)
                expect(pw?.frame.size == NSSize(width: 480, height: 400), "it resizes", "\(pw?.frame ?? .zero)")
                // Another tab in front: the detached preview stays with its own document.
                focus(b)
                b.textView.setSelectedRange(NSRange(location: (b.text as NSString).length, length: 0))
                type("zzz")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() } },
            waitForPreview(a, contains: "live typing", "bound to its document while another tab is in front"),
            sync {
                expect(pw?.title == "first.md — Preview" && b.previewPane == nil, "the other tab has no preview of its own")
            },
            { next in
                guard let w = pw else { next(); return }
                snapshot("detached-preview.png", window: w)(next)
            },
            sync {
                // ⇧⌥⌘P from the editor: docked again.
                focus(a)
                key("p", [.command, .option, .shift])
                expect(!a.previewDetached && a.previewPane?.superview === a.split && a.previewVisible, "⇧⌥⌘P attaches it again")
                expect(a.previewWindow == nil, "and its window is gone")
            },
            waitForPreview(a, contains: "live typing", "the re-docked preview is live"),
            sync {
                key("p", [.command, .option, .shift])
                expect(a.previewDetached, "⇧⌥⌘P detaches it")
                expectDetachedInFront(a, app, "Markdown, ⇧⌥⌘P")
                // Closing the window closes the preview.
                pw?.performClose(nil)
                expect(a.previewPane == nil && !a.previewVisible, "closing its window closes the preview")
                focus(a)
                key("p", [.command, .option, .shift])
                expect(a.previewDetached && pw?.isVisible == true, "⇧⌥⌘P with no preview opens it detached")
                expectDetachedInFront(a, app, "Markdown, ⇧⌥⌘P with no preview")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync { focus(a) },
            snapshot("detached-preview-editor.png"),
            // Not Markdown only: a CSV grid (the header's Detach) and an
            // HTML preview (View › Detach Preview with no preview open).
            sync {
                focus(csv)
                key("p", [.command, .option])
                expect(csv.previewVisible && !csv.previewDetached, "CSV: ⌥⌘P docks the grid")
                guard let button = csv.previewPane?.detachButton else { expect(false, "CSV: the grid's header has Detach"); return }
                // Laid out first: the click lands where the button is drawn.
                csv.window?.layoutIfNeeded()
                press(button)
                expect(csv.previewDetached && csv.previewPane?.renderer is CSVPreview, "CSV: Detach moves the grid into its own window")
                expectDetachedInFront(csv, app, "CSV, the header's Detach")
            },
            { next in
                guard let w = csv.previewWindow?.window else { next(); return }
                snapshot("detached-csv-key.png", window: w)(next)
            },
            sync {
                focus(html)
                guard let i = item() else { expect(false, "View › Detach Preview"); return }
                _ = app.validateMenuItem(i)
                expect(i.title == "Detach Preview" && html.previewPane == nil, "HTML: the menu offers Detach Preview, no preview yet", i.title)
                NSApp.sendAction(i.action!, to: nil, from: i)
                expect(html.previewDetached, "HTML: View › Detach Preview opens it detached")
                expectDetachedInFront(html, app, "HTML, View › Detach Preview")
            },
            sync {
                // Session restore (activate: false) leaves the focus alone.
                focus(restored)
                key("p", [.command, .option])
                restored.detachPreview(frame: nil, activate: false)
                let rw = restored.previewWindow?.window
                expect(restored.previewDetached && rw?.isVisible == true, "restore: the preview opens detached")
                expect(rw?.isKeyWindow == false && restored.window?.firstResponder === restored.textView,
                       "restore (activate: false): the preview doesn't take the focus; the text keeps the keyboard",
                       "key \(NSApp.keyWindow?.title ?? "-")")
                if NSApp.isActive {
                    expect(restored.window?.isKeyWindow == true, "restore (activate: false): the editor stays the key window",
                           "key \(NSApp.keyWindow?.title ?? "-")")
                } else {
                    print("check: note: restore: Cedric isn't active, so no window is key; the editor's key status not checked")
                }
                for t in [csv, html, restored] { t.doc.markSaved(); t.window?.performClose(nil) }
                expect(csv.previewWindow == nil && html.previewWindow == nil && restored.previewWindow == nil, "their detached previews close with them")
            },
            sync {
                let w = pw
                a.doc.markSaved(); b.doc.markSaved()
                a.window?.performClose(nil)
                expect(w?.isVisible == false, "closing the tab closes its detached preview")
                expect(w?.delegate == nil && !(w?.contentView is PreviewPane) && w?.contentView?.subviews.contains { $0 is PreviewPane } != true,
                       "and cuts that window loose (no delegate, no pane)")
            },
        ]
        steps += steps2
        steps += detachedPreviewCommands(app)
        let steps3: [Step] = [
            // 20 rounds of detach, attach, detach again, close the tab (the
            // preview's WKWebView loaded each time): the windows are torn
            // down without swapping a content view under the web view
            // (tools-check fails on any new crash report).
            { next in
                var k = 0, ok = 0
                @MainActor func round() {
                    guard k < 20 else {
                        expect(ok == 20, "20 rounds of detach / attach / close tab with the preview loaded", "\(ok) of 20")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                        return
                    }
                    k += 1
                    let n = k
                    guard let t = app.open(write("loop-\(n).md", "# Loop \(n)\n\nround \(n)\n")) else { next(); return }
                    focus(t)
                    key("p", [.command, .option])
                    t.detachPreview()
                    let deadline = Date().addingTimeInterval(4)
                    @MainActor func loaded() {
                        let web = (t.previewPane?.renderer as? PreviewController)?.webView
                        web?.evaluateJavaScript("document.body ? document.body.innerText : ''") { r, _ in
                            MainActor.assumeIsolated {
                                if (r as? String)?.contains("round \(n)") == true || Date() > deadline { cycle() }
                                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { loaded() } } }
                            }
                        }
                        if web == nil { cycle() }
                    }
                    @MainActor func cycle() {
                        let w = t.previewWindow?.window
                        t.attachPreview()
                        let attached = t.previewPane?.superview === t.split && t.previewWindow == nil && w?.isVisible == false
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                t.detachPreview()
                                let w2 = t.previewWindow?.window
                                t.doc.markSaved()
                                t.window?.performClose(nil)
                                if attached, w2?.isVisible == false, w2?.delegate == nil, !app.tabs.contains(where: { $0 === t }) { ok += 1 }
                                DispatchQueue.main.async { MainActor.assumeIsolated { round() } }
                            }
                        }
                    }
                    loaded()
                }
                round()
            },
        ]
        steps += steps3
        run(steps)
    }

    // MARK: CSV grid

    /// Waits (up to 5 s) for the tab's grid to apply a render after `after`.
    static func waitForGrid(_ tab: EditorWindowController, after: @escaping () -> Int, _ name: String) -> (@escaping () -> Void) -> Void {
        { next in
            let start = after()
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                let g = tab.previewPane?.renderer as? CSVPreview
                if let g, g.renders > start { expect(true, name); next() }
                else if Date() > deadline { expect(false, name, "no render (\(g?.renders ?? -1))"); next() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
            }
            poll()
        }
    }

    /// The text drawn in a grid cell (the table's own view for it).
    static func shown(_ g: CSVPreview, _ row: Int, _ col: Int) -> String {
        (g.table.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? "<no cell>"
    }

    /// The grid's "#" cell (above the row numbers, level with the header
    /// row): plain in file order, lit once a column header click sorts,
    /// and a click on it (then VoiceOver's press) puts file order back;
    /// still level after the preview is resized; a click on it while an
    /// edit is being parsed shows the edited text in file order. Snapshots
    /// in light and dark.
    static func csvRowNumberHeader(_ app: AppDelegate) {
        let tab = app.open(write("ages.csv", "name,age\nzoe,30\nbob,20\namy,40\n"))!
        sized(tab)
        var g: CSVPreview? { tab.previewPane?.renderer as? CSVPreview }
        var before = 0
        let theme = Settings.shared.themeOverride
        func setTheme(_ t: EditorTheme) {
            Settings.shared.themeOverride = t
            NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
        }
        /// The cell's frame and the table header's, in window coordinates,
        /// as the window's own layout left them.
        func frames(_ g: CSVPreview) -> (cell: NSRect, header: NSRect)? {
            guard let hv = g.table.headerView else { return nil }
            return (g.ruler.header.convert(g.ruler.header.bounds, to: nil), hv.convert(hv.bounds, to: nil))
        }
        func level(_ g: CSVPreview, _ when: String) {
            guard let f = frames(g) else { expect(false, "the table has a header row"); return }
            expect(abs(f.cell.minY - f.header.minY) < 0.5 && abs(f.cell.height - f.header.height) < 0.5 && f.cell.height > 0,
                   "\(when): level with the header row, the same height", "cell \(f.cell) header \(f.header)")
            expect(abs(f.cell.maxX - f.header.minX) < 1.5 && f.cell.width > 0, "\(when): just left of the first column's header",
                   "cell \(f.cell) header \(f.header)")
        }
        /// Polls `cond` (up to 5 s), then goes on; `name` is checked.
        func wait(_ name: String, _ cond: @escaping () -> Bool) -> Step {
            { next in
                let deadline = Date().addingTimeInterval(5)
                @MainActor func poll() {
                    if cond() { expect(true, name); next() }
                    else if Date() > deadline { expect(false, name, "timed out"); next() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
                }
                poll()
            }
        }
        // The CSV queue held, so an edit's parse stays under way.
        let gate = DispatchSemaphore(value: 0)
        var held = false
        func release() { if held { held = false; gate.signal() } }
        var parseBefore = 0
        let edited = "name,age\nzoe,30\nbob,20\namy,40\nann,10\n"
        func inFileOrder(_ g: CSVPreview, _ how: String) {
            expect(!g.isSorted && g.cell(row: 0, column: 0) == "zoe" && g.cell(row: 2, column: 0) == "amy",
                   "\(how) puts the rows back in file order", "\(g.table.sortDescriptors.map { $0.key ?? "-" }) \(g.cell(row: 0, column: 0))")
            expect(g.ruler.number?(0) == 1, "row numbers are file order again", "\(String(describing: g.ruler.number?(0)))")
            expect(!g.ruler.header.isActive, "and the # cell is plain again")
            expect(g.ruler.header.accessibilityValue() as? String == "File order", "its value says file order",
                   "\(String(describing: g.ruler.header.accessibilityValue()))")
        }
        let steps: [Step] = [
            sync {
                setTheme(.light)
                focus(tab)
                key("p", [.command, .option])
                expect(g != nil, "⌥⌘P shows the grid")
            },
            waitForGrid(tab, after: { 0 }, "the grid renders"),
            sync {
                guard let g else { return }
                let cell = g.ruler.header
                expect(!cell.isHidden && cell.superview === g.ruler, "a # cell sits in the row-number ruler")
                level(g, "shown")
                expect(cell.titleCell().stringValue == "#", "it shows #", cell.titleCell().stringValue)
                expect(cell.titleCell().font == g.table.tableColumns.first?.headerCell.font, "in the header's font")
                expect(!cell.isActive && !g.isSorted, "plain in file order")
                expect(cell.isAccessibilityElement() && cell.accessibilityRole() == .button, "a button to VoiceOver")
                expect(cell.accessibilityLabel() == "Row number, click to restore file order", "its label",
                       cell.accessibilityLabel() ?? "-")
                expect(cell.accessibilityValue() as? String == "File order", "its value says file order")
            },
            snapshot("csv-rownumber-light.png"),
            sync {
                guard let g, let header = g.table.headerView else { return }
                before = g.renders
                let hr = header.headerRect(ofColumn: 1)
                click(header, at: NSPoint(x: hr.midX, y: hr.midY))
            },
            waitForGrid(tab, after: { before }, "a header click sorts"),
            sync {
                guard let g else { return }
                expect(g.isSorted && g.table.sortDescriptors.first?.key == "c1", "sorted by age",
                       "\(g.table.sortDescriptors.map { $0.key ?? "-" })")
                expect(g.cell(row: 0, column: 0) == "bob" && g.ruler.number?(0) == 2, "bob (row 2) first", g.cell(row: 0, column: 0))
                expect(g.ruler.header.isActive, "the # cell is lit while sorted")
                expect(g.ruler.header.accessibilityValue() as? String == "Sorted", "its value says sorted")
                expect(g.ruler.header.titleCell().attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                       == .controlAccentColor, "# in the accent colour")
            },
            snapshot("csv-rownumber-sorted-light.png"),
            sync { setTheme(.dark) },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            snapshot("csv-rownumber-sorted-dark.png"),
            sync {
                guard let g else { return }
                expect(g.ruler.header.isActive, "still lit after the theme changes")
                before = g.renders
                let cell = g.ruler.header
                if let w = cell.window {
                    let p = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
                    let root = w.contentView?.superview ?? w.contentView
                    let hit = root?.hitTest(root?.superview?.convert(p, from: nil) ?? p)
                    expect(hit === cell, "a click there reaches the # cell", "\(String(describing: hit))")
                }
                click(cell, at: NSPoint(x: cell.bounds.midX, y: cell.bounds.midY))
            },
            waitForGrid(tab, after: { before }, "clicking # re-renders"),
            sync {
                guard let g else { return }
                inFileOrder(g, "clicking #")
                expect(tab.text == "name,age\nzoe,30\nbob,20\namy,40\n" && !tab.doc.isDirty, "the text is untouched")
            },
            snapshot("csv-rownumber-dark.png"),
            sync {
                guard let g else { return }
                before = g.renders
                g.table.sortDescriptors = [NSSortDescriptor(key: "c0", ascending: false)]
            },
            waitForGrid(tab, after: { before }, "sorting by name re-renders"),
            sync {
                guard let g else { return }
                expect(g.isSorted && g.cell(row: 0, column: 0) == "zoe" && g.cell(row: 1, column: 0) == "bob" && g.ruler.header.isActive,
                       "sorted by name (descending), the cell lit", g.cell(row: 1, column: 0))
                before = g.renders
                expect(g.ruler.header.accessibilityPerformPress(), "VoiceOver can press it")
            },
            waitForGrid(tab, after: { before }, "the press re-renders"),
            sync {
                guard let g else { return }
                inFileOrder(g, "VoiceOver's press")
                // A smaller window: a smaller preview, laid out by the window.
                tab.window?.setContentSize(NSSize(width: 900, height: 520))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                guard let g else { return }
                level(g, "after the preview is resized")
                sized(tab)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                guard let g else { return }
                level(g, "resized back")
                before = g.renders
                g.table.sortDescriptors = [NSSortDescriptor(key: "c1", ascending: true)]
            },
            waitForGrid(tab, after: { before }, "sorted by age again"),
            sync {
                guard let g else { return }
                expect(g.isSorted && g.cell(row: 0, column: 0) == "bob", "sorted by age, bob first", g.cell(row: 0, column: 0))
                // Hold the CSV queue, then edit: the edit's parse waits.
                held = true
                CSVPreview.queue.async { gate.wait() }
                parseBefore = g.parseRevision
                before = g.renders
                focus(tab)
                tab.textView.insertText("ann,10\n", replacementRange: NSRange(location: (tab.text as NSString).length, length: 0))
            },
            wait("the edit starts a parse") { (g?.parseRevision ?? 0) > parseBefore },
            sync {
                guard let g else { release(); return }
                expect(g.renders == before && g.table.numberOfRows == 3, "the parse is still under way: the old table shown",
                       "\(g.renders - before) renders, \(g.table.numberOfRows) rows")
                let cell = g.ruler.header
                click(cell, at: NSPoint(x: cell.bounds.midX, y: cell.bounds.midY))
                expect(!g.isSorted, "# clicked while it parses: no sort")
                release()
            },
            wait("the edited text lands") { (g?.renders ?? 0) > before && g?.table.numberOfRows == 4 },
            // Anything late (the old table's sort) would land in this time.
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                guard let g else { return }
                expect(tab.text == edited, "the edit is in the text", tab.text)
                expect(g.table.numberOfRows == 4 && g.cell(row: 3, column: 0) == "ann", "the edited table is shown, not the one before",
                       "\(g.table.numberOfRows) rows, last \(g.cell(row: 3, column: 0))")
                inFileOrder(g, "clicking # while an edit parses")
                expect(g.ruler.number?(3) == 4, "ann is row 4", "\(String(describing: g.ruler.number?(3)))")
                // Click-to-caret uses the new table's offsets.
                g.selectField(row: 3, column: 1)
                let want = (edited as NSString).range(of: "10\n").location
                expect(tab.textView.selectedRange().location == want, "a click on ann's age puts the caret there",
                       "\(tab.textView.selectedRange().location), want \(want)")
                Settings.shared.themeOverride = theme
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
            },
        ]
        run(steps, gap: 0.4)
    }

    static func csvPreview(_ app: AppDelegate) {
        let csv = "name,city,score\n\"Smith, Jo\",\"Paris\nFrance\",12\nAl,Rome,9\nBea,\"Says \"\"hi\"\"\",100\nshort\n"
        let tab = app.open(write("people.csv", csv))!
        let tsv = app.open(write("cols.tsv", "a\tb\n1,5\t2\n"))!
        let many = app.open(write("many.csv", "n,sq\n" + (1...60_000).map { "\($0),\($0 * $0)" }.joined(separator: "\n") + "\n"))!
        let wide = app.open(write("wide.csv", "id,blob\n1," + String(repeating: "x", count: 30_000) + "\n2,short\n"))!
        // Comma then a space (the owner's build 7 report), quoted fields after the space.
        let spacedText = "name, age, city\nAlice, 30, Paris\n\"Smith, J\", 41, \"Rome, IT\"\nBob, 25,  \" Oslo \"\n"
        let spaced = app.open(write("spaced.csv", spacedText))!
        // An unclosed quote on line 3 (build 7: it swallowed rows 4 and 5).
        let tricky = app.open(write("tricky.csv", "name,note\nann,ok\nbob,\"never closed\ncat,x\ndan,y\n"))!
        for t in [tab, tsv, many, wide, spaced, tricky] { sized(t) }
        var g: CSVPreview? { tab.previewPane?.renderer as? CSVPreview }
        let ns = csv as NSString
        var before = 0
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                expect(tab.doc.language == .csv, "a .csv file opens as CSV / TSV", tab.doc.language.rawValue)
                key("p", [.command, .option])
                expect(g != nil, "⌥⌘P shows the grid")
            },
            waitForGrid(tab, after: { 0 }, "the grid renders"),
            sync {
                guard let g else { return }
                expect(g.table.tableColumns.map(\.title) == ["name", "city", "score"], "the first line is the header",
                       "\(g.table.tableColumns.map(\.title))")
                expect(g.table.numberOfRows == 4, "four data rows (ragged one included)", "\(g.table.numberOfRows)")
                expect(shown(g, 0, 0) == "Smith, Jo", "quoted comma kept in one cell", shown(g, 0, 0))
                expect(shown(g, 0, 1) == "Paris⏎France", "embedded line break, shown on one line", shown(g, 0, 1))
                expect(shown(g, 2, 1) == "Says \"hi\"", "doubled quotes", shown(g, 2, 1))
                expect(shown(g, 3, 0) == "short" && shown(g, 3, 2) == "", "a short row is padded", shown(g, 3, 2))
                expect(g.data.delimiter == 44, "comma sniffed")
                expect(g.table.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) }, "columns resize")
                expect(g.scroll.rulersVisible && g.ruler.number?(0) == 1, "row numbers at the left", "\(String(describing: g.ruler.number?(0)))")
            },
            snapshot("csv-grid.png"),
            sync {
                // A click on Rome: the caret goes to that field.
                guard let g else { return }
                let rect = g.table.frameOfCell(atColumn: 1, row: 1)
                clickDirect(g.table, at: NSPoint(x: rect.midX, y: rect.midY))
            },
            sync {
                let want = ns.range(of: "Rome").location
                expect(tab.textView.selectedRange() == NSRange(location: want, length: 0), "clicking a cell puts the caret in that field",
                       "\(tab.textView.selectedRange()) want \(want)")
                g?.selectField(row: 0, column: 1)
                expect(tab.textView.selectedRange().location == ns.range(of: "Paris").location, "inside a quoted field too")
                before = g?.renders ?? 0
                // A click on the score header sorts the grid, not the text.
                guard let g, let header = g.table.headerView else { return }
                let hr = header.headerRect(ofColumn: 2)
                click(header, at: NSPoint(x: hr.midX, y: hr.midY))
            },
            waitForGrid(tab, after: { before }, "sorting re-renders"),
            sync {
                guard let g else { return }
                expect(g.table.sortDescriptors.first?.key == "c2", "the header click sorted by score",
                       "\(g.table.sortDescriptors.map { $0.key ?? "-" })")
                let col = (0..<4).map { shown(g, $0, 2) }
                expect(col == ["9", "12", "100", ""], "numbers by value, blanks last", "\(col)")
                expect(tab.text == csv && !tab.doc.isDirty, "the text is untouched")
                expect(g.ruler.number?(0) == 2, "row numbers follow the rows", "\(String(describing: g.ruler.number?(0)))")
                g.table.sortDescriptors = []
                before = g.renders
                // Live: type a row.
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: ns.length, length: 0))
                type("zed,Oslo,7")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            waitForGrid(tab, after: { before }, "typing updates the grid"),
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() } },
            sync {
                guard let g else { return }
                expect(g.table.numberOfRows == 5 && shown(g, 4, 1) == "Oslo", "the typed row is in the grid", "\(g.table.numberOfRows) \(shown(g, 4, 1))")
                // Detached: the grid in its own window.
                key("p", [.command, .option, .shift])
                expect(tab.previewDetached && g === (tab.previewPane?.renderer as? CSVPreview), "the grid detaches")
                expectDetachedInFront(tab, app, "csvpreview, ⇧⌥⌘P")
                expect(shown(g, 4, 1) == "Oslo", "and still shows the rows")
            },
            { next in
                guard let w = tab.previewWindow?.window else { next(); return }
                snapshot("csv-grid-detached.png", window: w)(next)
            },
            sync {
                key("p", [.command, .option, .shift])
                tab.doc.markSaved()
                focus(tsv)
                key("p", [.command, .option])
            },
            waitForGrid(tsv, after: { 0 }, "the TSV grid renders"),
            sync {
                guard let t = tsv.previewPane?.renderer as? CSVPreview else { return }
                expect(t.data.delimiter == 9 && shown(t, 0, 0) == "1,5", ".tsv is tab-separated", shown(t, 0, 0))
                focus(many)
                key("p", [.command, .option])
            },
            waitForGrid(many, after: { 0 }, "the 60,000-row grid renders"),
            sync {
                guard let m = many.previewPane?.renderer as? CSVPreview else { return }
                expect(m.table.numberOfRows == CSVPreview.maxRows, "only the first 50,000 rows", "\(m.table.numberOfRows)")
                expect(!m.note.isHidden && m.note.stringValue.contains("50,000"), "with a note", m.note.stringValue)
                expect(shown(m, 49_999, 1) == "2500000000", "the last shown row", shown(m, 49_999, 1))
                // Typing stays quick: a render's main-thread part is a copy, the parse is elsewhere.
                let t0 = Date()
                many.renderPreview()
                let ms = Date().timeIntervalSince(t0) * 1000
                expect(ms < 30, "a render costs the main thread \(Int(ms)) ms", "\(ms)")
                focus(wide)
                expect(wide.extrasPaused, "the wide file is in large mode")
                key("p", [.command, .option])
            },
            waitForGrid(wide, after: { 0 }, "large mode: the grid renders"),
            sync {
                guard let w = wide.previewPane?.renderer as? CSVPreview else { return }
                expect(w.table.numberOfRows == 2 && shown(w, 1, 1) == "short", "large mode: rows shown", "\(w.table.numberOfRows)")
                focus(spaced)
                key("p", [.command, .option])
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            snapshot("csv-grid-large.png", window: wide.window),
            waitForGrid(spaced, after: { 0 }, "comma-space: the grid renders"),
            sync {
                guard let g = spaced.previewPane?.renderer as? CSVPreview else { return }
                let header = g.table.tableColumns.map(\.title)
                expect(header == ["name", "age", "city"], "comma-space: header without leading spaces", "\(header)")
                let cells = (0..<g.table.numberOfRows).map { r in (0..<3).map { shown(g, r, $0) } }
                expect(cells == [["Alice", "30", "Paris"], ["Smith, J", "41", "Rome, IT"], ["Bob", "25", " Oslo "]],
                       "comma-space: cells trimmed, quoted fields after the space whole, spaces inside quotes kept", "\(cells)")
                expect(g.data.dialect.skipInitialSpace && g.data.delimiter == 44, "comma-space: sniffed as comma + space")
                let rect = g.table.frameOfCell(atColumn: 2, row: 1)
                clickDirect(g.table, at: NSPoint(x: rect.midX, y: rect.midY))
            },
            sync {
                let want = (spacedText as NSString).range(of: "Rome, IT").location
                expect(spaced.textView.selectedRange() == NSRange(location: want, length: 0),
                       "comma-space: clicking a quoted cell puts the caret inside its quotes", "\(spaced.textView.selectedRange()) want \(want)")
                for t in [tab, tsv, many, wide, spaced] { t.doc.markSaved() }
            },
            snapshot("csv-grid-spaced.png"),
            sync {
                focus(tricky)
                key("p", [.command, .option])
                expect(tricky.previewPane?.renderer is CSVPreview, "the unclosed-quote grid opens")
            },
            waitForGrid(tricky, after: { 0 }, "unclosed quote: the grid renders"),
            sync {
                guard let g = tricky.previewPane?.renderer as? CSVPreview else { return }
                let cells = (0..<g.table.numberOfRows).map { r in (0..<2).map { shown(g, r, $0) } }
                expect(cells == [["ann", "ok"], ["bob", "never closed"], ["cat", "x"], ["dan", "y"]],
                       "unclosed quote: the field stops at its line, later rows still show", "\(cells)")
                expect(!g.note.isHidden && g.note.stringValue.hasPrefix("Unclosed quote on line 3."),
                       "unclosed quote: a warning says where", g.note.stringValue)
                expect(tricky.text.contains("\"never closed\ncat"), "the text is untouched")
                tricky.doc.markSaved()
            },
            snapshot("csv-grid-unclosed.png", window: tricky.window),
        ]
        steps += steps3
        run(steps)
    }
}
