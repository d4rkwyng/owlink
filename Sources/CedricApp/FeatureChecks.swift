import AppKit
import CedricCore

/// In-process checks of Fix Typos… (the spelling step-through), the
/// detachable preview and the CSV grid, run by Scripts/tools-check.sh like
/// the other DevChecks: the menus' key equivalents and real key events
/// sent to the step-through's panel, clicks on its buttons.
///
///   CEDRIC_CHECK=spellstep|detachpreview|csvpreview
@MainActor
extension DevChecks {
    static func featureCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "spellstep": spellStep(app)
        case "detachpreview": detachPreview(app)
        case "csvpreview": csvPreview(app)
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
        run([
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
        ])
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
        // Before the fix the editor was ordered back in front of it.
        let editorAt = tab.window.flatMap { ordered.firstIndex(of: $0) } ?? -1
        expect(editorAt > 0, "\(what): its editor window is behind it", "editor at \(editorAt)")
        if NSApp.isActive {
            expect(w.isKeyWindow && NSApp.keyWindow === w, "\(what): the detached preview window has the focus",
                   "key: \(NSApp.keyWindow?.title ?? "-")")
            expect(tab.window?.isKeyWindow == false, "\(what): the editor window gave up the focus")
        } else {
            // An inactive app (launched by a script, screen locked) has no key
            // window at all: AppKit makes the preview key on activation.
            print("check: note: \(what): Cedric isn't active, so no window is key; checked the order (preview in front) only")
        }
        expect(app.currentTab === tab, "\(what): the menus still act on its document")
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
        run([
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
        ])
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
        run([
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
        ])
    }
}
