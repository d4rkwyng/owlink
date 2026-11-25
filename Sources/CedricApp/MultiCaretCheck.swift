import AppKit
import CedricCore

/// CEDRIC_CHECK=multicaret (Scripts/tools-check.sh): multiple carets and
/// column selection, driven by real key and mouse events sent through the
/// window (NSTextView's keyDown → interpretKeyEvents → insertText /
/// doCommand, the menus' key equivalents, mouseDown with ⌥ or ⌘ and the
/// drag events the tracking loop reads from the queue). Each typing step
/// checks the text storage and that the typed glyphs draw (pixels, as
/// typing-check does); the extra carets are checked as drawn too.
@MainActor
extension DevChecks {
    // MARK: Event helpers

    /// A key press with an explicit key code, through the window (as typed).
    static func press(_ chars: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        guard let w = frontWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: keyCode) else { continue }
            w.sendEvent(e)
        }
    }

    static func escape() { press("\u{1b}", 53) }
    static func backspace() { press("\u{7f}", 51) }
    static func returnKey() { press("\r", 36) }
    static func arrow(_ fn: Int, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        press(String(UnicodeScalar(UInt16(fn))!), code, mods.union([.function, .numericPad]))
    }

    /// Where the caret at `offset` is drawn (text view coordinates, middle of the line).
    static func caretPoint(_ tv: EditorTextView, _ offset: Int) -> NSPoint {
        guard let tlm = tv.textLayoutManager, let r = tv.textRange(for: NSRange(location: offset, length: 0)) else { return .zero }
        tlm.ensureLayout(for: r)
        var p = NSPoint.zero
        tlm.enumerateTextSegments(in: r, type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
            p = NSPoint(x: f.minX + tv.textContainerOrigin.x, y: f.midY + tv.textContainerOrigin.y)
            return false
        }
        return p
    }

    /// A mouse press at `a` with `mods`, dragged to `b`, released (view
    /// coordinates). The drag and up events are queued first, so the text
    /// view's tracking loop reads them as it would a user's.
    static func drag(_ view: NSView, from a: NSPoint, to b: NSPoint, mods: NSEvent.ModifierFlags) {
        guard let w = view.window else { return }
        let pa = view.convert(a, to: nil), pb = view.convert(b, to: nil)
        let mid = NSPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
        let t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, _ dt: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: t + dt, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = ev(.leftMouseDown, pa, 0) else { return }
        if pa != pb {
            for (p, dt) in [(mid, 0.02), (pb, 0.04)] { if let e = ev(.leftMouseDragged, p, dt) { NSApp.postEvent(e, atStart: false) } }
        }
        if let up = ev(.leftMouseUp, pb, 0.06) { NSApp.postEvent(up, atStart: false) }
        if NSApp.isActive && w.isKeyWindow {
            w.sendEvent(down)
        } else {
            // As DevChecks.click: an inactive window can't take the click; give it to the view under the point.
            let root = w.contentView?.superview ?? w.contentView
            (root?.hitTest(pa) ?? view).mouseDown(with: down)
        }
    }

    static func ranges(_ tv: EditorTextView) -> [NSRange] { tv.allCarets.carets.map(\.range) }

    /// The typed text at each range is drawn: pixels stand out from the
    /// background and the current line, and TextKit's element views drew.
    static func expectDrawn(_ tab: EditorWindowController, _ rs: [NSRange], _ name: String) {
        let tv = tab.textView
        let p = tab.palette
        let rects = rs.flatMap { TypingCheck.glyphRects(tv, $0) }
        let ink = TypingCheck.ink(tv, rects, backgrounds: [p.background, p.currentLine, p.selection])
        expect(rects.count >= rs.count && TypingCheck.visible(ink, minPixels: 6 * rs.count), "\(name): typed text drawn at every caret",
               "rects=\(rects.count) " + TypingCheck.describe(ink))
        let sp = TypingCheck.screenPath(tv, rects)
        expect(sp.ok, "\(name): typed text has drawn screen layers", sp.detail)
    }

    /// The extra carets (not the primary, NSTextView's own) are drawn: a
    /// bar in the caret colour at each.
    static func expectCaretsDrawn(_ tab: EditorWindowController, _ name: String) {
        let tv = tab.textView
        guard let m = tv.multiCarets else { expect(false, "\(name): carets drawn", "no carets"); return }
        tv.needsDisplay = true
        tv.displayIfNeeded()
        let caretLum = TypingCheck.luminance(tv.insertionPointColor)
        var drawn = 0
        for (i, c) in m.enumerated() where i != tv.multiPrimary && c.isEmpty {
            let pt = caretPoint(tv, c.head)
            let box = NSRect(x: pt.x - 3, y: pt.y - 4, width: 6, height: 8)
            guard let rep = DevHooks.render(tv, box) else { continue }
            var hit = false
            for y in 0..<rep.pixelsHigh where !hit {
                for x in 0..<rep.pixelsWide {
                    if let col = rep.colorAt(x: x, y: y), TypingCheck.contrast(TypingCheck.luminance(col), caretLum) < 1.15,
                       abs((col.usingColorSpace(.sRGB)?.blueComponent ?? 0) - (tv.insertionPointColor.usingColorSpace(.sRGB)?.blueComponent ?? 0)) < 0.12 {
                        hit = true
                        break
                    }
                }
            }
            if hit { drawn += 1 }
        }
        let extras = m.enumerated().filter { $0.offset != tv.multiPrimary && $0.element.isEmpty }.count
        expect(extras > 0 && drawn == extras, "\(name): every extra caret is drawn", "\(drawn)/\(extras)")
    }

    // MARK: The check

    static func multiCaretCheck(_ app: AppDelegate) {
        let src = "let alpha = 1\nlet beta = 2\nlet gamma = 3\nlet delta = 4\n"
        let tab = app.open(write("multicaret.swift", src))!
        sized(tab)
        let tv = tab.textView
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        func line(_ i: Int) -> Int { tab.lineIndex.starts[i] }
        func put(_ text: String, caret: Int) {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            tv.insertText(text, replacementRange: tv.selectedRange())
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                for (sel, name, key, mods) in [(#selector(AppDelegate.addNextOccurrenceMenu(_:)), "Add Next Occurrence", "d", NSEvent.ModifierFlags.command),
                                               (#selector(AppDelegate.selectAllOccurrencesMenu(_:)), "Select All Occurrences", "g", [.control, .command]),
                                               (#selector(AppDelegate.addCaretAboveMenu(_:)), "Add Caret Above", up, [.control, .shift]),
                                               (#selector(AppDelegate.addCaretBelowMenu(_:)), "Add Caret Below", down, [.control, .shift])] {
                    let i = menuItem(action: sel)
                    expect(i?.keyEquivalent == key && i?.keyEquivalentModifierMask == mods, "Text › Selection › \(name) has its shortcut")
                    expect(i.map { app.validateMenuItem($0) } == true, "\(name) is enabled in a text tab")
                }
                let single = menuItem(action: #selector(AppDelegate.singleCaretMenu(_:)))
                expect(single?.keyEquivalent == "" && single.map { app.validateMenuItem($0) } == false,
                       "Single Caret has no key and is disabled with one caret")
                expect(tv.multiCarets == nil, "one caret: no multi-caret state (the zero-cost path)")
            },
            // ⌥-drag a 4×3 rectangle: "alp" "bet" "gam" "del".
            sync {
                let a = caretPoint(tv, line(0) + 4), b = caretPoint(tv, line(3) + 7)
                drag(tv, from: a, to: b, mods: [.option])
                let want = (0..<4).map { NSRange(location: line($0) + 4, length: 3) }
                expect(ranges(tv) == want, "⌥-drag selects a 4×3 column", "\(ranges(tv))")
                expect(tab.statusBar.position.stringValue == "4 carets", "the status bar counts carets", tab.statusBar.position.stringValue)
                let single = menuItem(action: #selector(AppDelegate.singleCaretMenu(_:)))
                expect(single.map { app.validateMenuItem($0) } == true, "Single Caret is enabled with several carets")
            },
            snapshot("multicaret-column-dark.png"),
            sync {
                type("X")
                expect(tab.text == "let Xha = 1\nlet Xa = 2\nlet Xma = 3\nlet Xta = 4\n", "typing replaces every column selection", tab.text)
                expect(ranges(tv) == (0..<4).map { NSRange(location: line($0) + 5, length: 0) }, "a caret after each typed X", "\(ranges(tv))")
                expectDrawn(tab, (0..<4).map { NSRange(location: line($0) + 4, length: 1) }, "column")
            },
            sync {
                key("z", [.command])
                expect(tab.text == src, "one ⌘Z undoes the edit at every caret", tab.text)
                expect(ranges(tv) == (0..<4).map { NSRange(location: line($0) + 4, length: 3) }, "…and puts the column selection back", "\(ranges(tv))")
            },
            sync {
                key("z", [.command, .shift])
                expect(tab.text == "let Xha = 1\nlet Xa = 2\nlet Xma = 3\nlet Xta = 4\n", "⇧⌘Z redoes it", tab.text)
                expect(tv.multiCarets?.count == 4, "…with the 4 carets", "\(ranges(tv))")
            },
            sync {
                escape()
                expect(tv.multiCarets == nil && tv.selectedRange().length == 0, "⎋ goes back to one caret", "\(ranges(tv))")
                expect(tab.statusBar.position.stringValue.hasPrefix("Ln"), "the status bar shows Ln/Col again", tab.statusBar.position.stringValue)
            },
            // A zero-width ⌥-drag straight down: 4 carets.
            sync { put(src, caret: 0) },
            sync {
                drag(tv, from: caretPoint(tv, line(0) + 4), to: caretPoint(tv, line(3) + 4), mods: [.option])
                expect(ranges(tv) == (0..<4).map { NSRange(location: line($0) + 4, length: 0) }, "a zero-width ⌥-drag makes 4 carets", "\(ranges(tv))")
                expectCaretsDrawn(tab, "zero-width column")
            },
            snapshot("multicaret-carets-dark.png"),
            sync {
                type("ab")
                expect(tab.text == "let abalpha = 1\nlet abbeta = 2\nlet abgamma = 3\nlet abdelta = 4\n", "typing at 4 carets", tab.text)
                expectDrawn(tab, (0..<4).map { NSRange(location: line($0) + 4, length: 2) }, "zero-width column")
                backspace()
                expect(tab.text == "let aalpha = 1\nlet abeta = 2\nlet agamma = 3\nlet adelta = 4\n", "Backspace at every caret", tab.text)
                arrow(NSLeftArrowFunctionKey, 123)
                type("[")
                expect(tab.text.hasPrefix("let [aalpha"), "← moves every caret; [ before a letter doesn't pair", tab.text)
                expect(tab.text.contains("let [adelta"), "…at every caret", tab.text)
                escape()
            },
            // ⌃⇧↓ ×3, type, Backspace, Return (indent kept per caret).
            sync { put("    one\n    two\n    three\n    four\n", caret: 7) },
            sync {
                for _ in 0..<3 { key(down, [.control, .shift]) }
                expect(tv.multiCarets?.count == 4, "⌃⇧↓ ×3 adds 3 carets below", "\(ranges(tv))")
                expect(ranges(tv) == [7, 15, 23, 33].map { NSRange(location: $0, length: 0) }, "…at the same column (line end when shorter)", "\(ranges(tv))")
                type("x")
                expect(tab.text == "    onex\n    twox\n    thrxee\n    fouxr\n", "x at every caret", tab.text.debugDescription)
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                backspace()
                expect(tab.text == "    one\n    two\n    three\n    four\n", "Backspace removes them", tab.text.debugDescription)
                returnKey()
                expect(tab.text == "    one\n    \n    two\n    \n    thr\n    ee\n    fou\n    r\n", "Return at 4 carets keeps the indent on each new line",
                       tab.text.debugDescription)
                key(up, [.control, .shift])
                expect(tv.multiCarets?.count == 5, "⌃⇧↑ adds a caret above the topmost", "\(ranges(tv))")
                escape()
            },
            // ⌘D ×2 on a word, type; ⌃⌘G.
            sync { put("foo bar foo baz foo\n", caret: 1) },
            sync {
                key("d", [.command])
                expect(ranges(tv) == [NSRange(location: 0, length: 3)], "⌘D on a bare caret selects the word", "\(ranges(tv))")
                key("d", [.command])
                expect(ranges(tv) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)], "⌘D again adds the next occurrence",
                       "\(ranges(tv))")
                type("Z")
                expect(tab.text == "Z bar Z baz foo\n", "typing replaces both", tab.text)
            },
            // ⌘Z in a step of its own: AppKit closes each event's undo group after it, as for a user.
            sync {
                key("z", [.command])
                expect(tab.text == "foo bar foo baz foo\n", "⌘Z", tab.text)
                escape()
                tv.setSelectedRange(NSRange(location: 9, length: 0))
                key("g", [.control, .command])
                expect(ranges(tv) == [0, 8, 16].map { NSRange(location: $0, length: 3) }, "⌃⌘G selects every occurrence", "\(ranges(tv))")
                expect(tv.occurrenceRanges.isEmpty, "occurrence highlighting is paused with several carets")
                type("q")
                expect(tab.text == "q bar q baz q\n", "typing at all occurrences", tab.text)
                expectDrawn(tab, [0, 6, 12].map { NSRange(location: $0, length: 1) }, "⌃⌘G")
                escape()
            },
            // ⌘-click adds and removes carets; plain click and ⎋ go back to one.
            sync { put("foo bar foo baz foo\n", caret: 0) },
            sync {
                click(tv, at: caretPoint(tv, 4))
                expect(tv.multiCarets == nil && tv.selectedRange() == NSRange(location: 4, length: 0), "a plain click leaves one caret",
                       "\(ranges(tv))")
                drag(tv, from: caretPoint(tv, 12), to: caretPoint(tv, 12), mods: [.command])
                expect(ranges(tv) == [4, 12].map { NSRange(location: $0, length: 0) }, "⌘-click adds a caret", "\(ranges(tv))")
                drag(tv, from: caretPoint(tv, 16), to: caretPoint(tv, 16), mods: [.command])
                expect(tv.multiCarets?.count == 3, "⌘-click adds another", "\(ranges(tv))")
                drag(tv, from: caretPoint(tv, 12), to: caretPoint(tv, 12), mods: [.command])
                expect(ranges(tv) == [4, 16].map { NSRange(location: $0, length: 0) }, "⌘-click on a caret removes it", "\(ranges(tv))")
                type("-")
                expect(tab.text == "foo -bar foo baz -foo\n", "typing at the ⌘-clicked carets", tab.text)
                click(tv, at: caretPoint(tv, 0))
                expect(tv.multiCarets == nil, "a plain click collapses to one caret")
            },
            // Paste 3 lines into 3 carets.
            sync { put("a\nb\nc\n", caret: 1) },
            sync {
                key(down, [.control, .shift])
                key(down, [.control, .shift])
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("1\r\n2\r\n3", forType: .string)
                key("v", [.command])
                expect(tab.text == "a1\nb2\nc3\n", "3 clipboard lines go one per caret", tab.text.debugDescription)
            },
            sync {
                key("z", [.command])
                expect(tab.text == "a\nb\nc\n", "⌘Z undoes the paste at every caret", tab.text.debugDescription)
                // Copy joins the selections.
                escape()
                tv.setSelectedRange(NSRange(location: 0, length: 1))
                drag(tv, from: caretPoint(tv, 4), to: caretPoint(tv, 5), mods: [.command])
                key("c", [.command])
                expect(NSPasteboard.general.string(forType: .string) == "a\nc", "⌘C copies every selection, joined by newlines",
                       NSPasteboard.general.string(forType: .string) ?? "-")
                escape()
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            // Dead key: ⌥E then E at 3 carets → é at each.
            sync { put("a\nb\nc\n", caret: 1) },
            sync {
                key(down, [.control, .shift])
                key(down, [.control, .shift])
                press("", 14, [.option], ignoring: "e")
                var how = "real ⌥E E key events"
                if !tv.hasMarkedText() {
                    // Synthetic key events don't reach the keyboard layout's dead-key state in every
                    // session: compose as the input method does (marked text, then the commit).
                    how = "setMarkedText + insertText (the input method's calls)"
                    tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                expect(tv.hasMarkedText() && tv.multiCarets?.count == 3, "composing keeps the 3 carets", "\(ranges(tv)) marked=\(tv.hasMarkedText())")
                if how.hasPrefix("real") { press("e", 14) } else { tv.insertText("é", replacementRange: tv.markedRange()) }
                print("check: note: dead key via \(how)")
                expect(tab.text == "aé\nbé\ncé\n", "dead key é at every caret", tab.text.debugDescription)
                expect(!tv.hasMarkedText() && tv.multiCarets?.count == 3, "…committed, carets kept", "\(ranges(tv))")
                expectDrawn(tab, [1, 4, 7].map { NSRange(location: $0, length: 1) }, "dead key")
            },
            sync {
                key("z", [.command])
                expect(tab.text == "a\nb\nc\n", "one ⌘Z undoes the composed é everywhere", tab.text.debugDescription)
                escape()
            },
            // Japanese IME: marked text at the primary, the commit at every caret.
            sync { put("a\nb\n", caret: 1) },
            sync {
                key(down, [.control, .shift])
                tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                expect(tv.multiCarets?.count == 2, "IME composing at the primary keeps the carets")
                tv.insertText("日本", replacementRange: tv.markedRange())
                expect(tab.text == "a日本\nb日本\n", "the IME's committed text goes in at every caret", tab.text.debugDescription)
                escape()
            },
            // Auto-close ( at 3 carets, then ) steps over.
            sync { put("f\ng\nh\n", caret: 1) },
            sync {
                key(down, [.control, .shift])
                key(down, [.control, .shift])
                type("(")
                expect(tab.text == "f()\ng()\nh()\n", "( pairs at every caret", tab.text.debugDescription)
                expect(ranges(tv) == [2, 6, 10].map { NSRange(location: $0, length: 0) }, "…carets between the pairs", "\(ranges(tv))")
                type("1)")
                expect(tab.text == "f(1)\ng(1)\nh(1)\n", ") steps over the closer at every caret", tab.text.debugDescription)
                type("{")
                returnKey()
                expect(tab.text.hasPrefix("f(1){\n    \n}\n"), "Return between braces opens an indented line at every caret", tab.text.debugDescription)
                expect(tab.text.components(separatedBy: "{\n    \n}").count == 4, "…all three", tab.text.debugDescription)
                expectDrawn(tab, [0, 1, 2].map { NSRange(location: tab.lineIndex.starts[$0 * 3] + 1, length: 3) }, "auto-close")
                escape()
            },
            // ⇧-arrows extend every caret; ⌘→ moves each to its line end.
            sync { put("one two\nthree four\n", caret: 0) },
            sync {
                key(down, [.control, .shift])
                arrow(NSRightArrowFunctionKey, 124, [.option, .shift])
                expect(ranges(tv) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)], "⌥⇧→ selects a word at every caret",
                       "\(ranges(tv))")
                arrow(NSLeftArrowFunctionKey, 123, [.shift])
                expect(ranges(tv) == [NSRange(location: 0, length: 2), NSRange(location: 8, length: 4)], "⇧← shrinks every selection",
                       "\(ranges(tv))")
                type("X")
                expect(tab.text == "Xe two\nXe four\n", "typing over the extended selections", tab.text.debugDescription)
                arrow(NSRightArrowFunctionKey, 124, [.command])
                type(";")
                expect(tab.text == "Xe two;\nXe four;\n", "⌘→ moves every caret to its line end", tab.text.debugDescription)
                escape()
            },
            // Informational: typing at 100 carets (perf-check gets the real metric on the 6 MB log).
            sync { put(String(repeating: "let value = compute(value) // padding text\n", count: 400), caret: 4) },
        ]
        steps += steps3
        let steps4: [Step] = [
            sync {
                key("d", [.command])
                key("g", [.control, .command])
                let n = tv.multiCarets?.count ?? 0
                let t0 = Date()
                type("abcde")
                let ms = Date().timeIntervalSince(t0) * 1000 / 5
                print(String(format: "check: note: typing at %d carets: %.1f ms per key (400-line file, this machine's load)", n, ms))
                expect(n == 800 && tab.text.components(separatedBy: "abcde").count == 801, "typing at 800 carets lands at each",
                       "carets=\(n)")
                escape()
            },
            // ⌘D in a save alert is its Don't Save button, not Add Next Occurrence.
            { next in
                put("foo foo\n", caret: 1)
                let alert = NSAlert()
                alert.messageText = "Save changes?"
                alert.addButton(withTitle: String(localized: "Save"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.addButton(withTitle: String(localized: "Don’t Save"))
                let t = Timer(timeInterval: 0.3, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let w = alert.window
                        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                       context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)
                        else { return }
                        if NSApp.isActive && w.isKeyWindow { NSApp.sendEvent(e) } else if !w.performKeyEquivalent(with: e) { NSApp.sendEvent(e) }
                    }
                }
                let stop = Timer(timeInterval: 3, repeats: false) { _ in MainActor.assumeIsolated { NSApp.abortModal() } }
                RunLoop.main.add(t, forMode: .modalPanel)
                RunLoop.main.add(stop, forMode: .modalPanel)
                let r = alert.runModal()
                stop.invalidate()
                expect(r == .alertThirdButtonReturn, "⌘D in a save alert presses Don’t Save", "\(r.rawValue)")
                expect(tv.multiCarets == nil && tv.selectedRange() == NSRange(location: 1, length: 0), "…and doesn't add an occurrence",
                       "\(ranges(tv))")
                next()
            },
            // Snapshots in the light theme too.
            sync {
                TypingCheck.apply(TypingCheck.themes.first { $0.name == "light" }!)
                put(src, caret: 0)
                drag(tv, from: caretPoint(tv, line(0) + 4), to: caretPoint(tv, line(3) + 7), mods: [.option])
                expect(tv.multiCarets?.count == 4, "light: column selection", "\(ranges(tv))")
            },
            snapshot("multicaret-column-light.png"),
            sync {
                escape()
                drag(tv, from: caretPoint(tv, line(0) + 4), to: caretPoint(tv, line(3) + 4), mods: [.option])
                expectCaretsDrawn(tab, "light")
            },
            snapshot("multicaret-carets-light.png"),
            sync {
                escape()
                tab.doc.markSaved()
            },
        ]
        steps += steps4
        run(steps)
    }
}
