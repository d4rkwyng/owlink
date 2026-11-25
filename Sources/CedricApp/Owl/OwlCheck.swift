import AppKit
import CedricCore

/// CEDRIC_OWL_CHECK=/out/dir: an end-to-end check of the owl, in process,
/// driven by real NSEvents through the window and the menus. Open a file
/// with one-line JSON (CEDRIC_OPEN) and the owl on (CEDRIC_OWL=1); it
///
///   1. waits for the owl to offer "Format it?" and snapshots the bubble,
///   2. clicks Apply (mouse down/up on the button) and checks the text is
///      the pretty-printed JSON,
///   3. ⌘Z once: the original is back (Apply is one undo step); ⇧⌘Z: formatted again,
///   4. types at the end of the file until the caret reaches the owl, and
///      checks the owl has faded,
///   5. ⌘S: the owl flaps,
///
/// writes PNGs to the directory, prints "owlcheck: ok|FAIL …" lines and exits
/// 0 when every step passed.
@MainActor
enum OwlCheck {
    static var failures = 0
    /// Set by the bubble's button actions (for the click fallback).
    static var clicked = false
    static func check(_ ok: Bool, _ what: String) {
        print("owlcheck: \(ok ? "ok  " : "FAIL") \(what)")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    static func run(_ app: AppDelegate, out: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        guard let tab = app.currentTab ?? app.tabs.last, let window = tab.window else { print("owlcheck: no tab"); exit(1) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.textView)
        let visible = NSApp.isActive && window.occlusionState.contains(.visible)
        if !visible, let owl = tab.owl {
            // Locked screen / background launch: the owl must not tick.
            check(!owl.canAnimate && !owl.timerScheduled, "no idle timer while the window is occluded or the app inactive")
            check(OwlHub.shared.coordinator.queryCount == 0, "no hint queries while hidden")
            print("owlcheck: (screen not visible: treating the window as visible from here on)")
            OwlController.assumeVisible = true
            owl.updateTimer()
            OwlHub.shared.schedule()
        }
        let env = DevEnvironment.values
        if env["CEDRIC_OWL_CHECK_RULES"] == "1" { OwlRulesCheck.run(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_RULES"] == "markdown" { OwlRulesCheck.runMarkdown(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_RULES"] == "style" { OwlRulesCheck.runStyle(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_AI"] == "1" { OwlRulesCheck.runAI(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "1" { OwlChatCheck.run(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT_OFF"] == "1" { OwlChatCheck.runDefaultOff(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "grammar" { OwlChatCheck.runGrammar(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "default" { OwlChatCheck.runDefaultOn(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "script" { OwlChatCheck.runScript(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "panel-tabs" { PanelTabsCheck.run(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "picture" { OwlChatCheck.runPicture(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CHAT"] == "wholedoc" { OwlWholeDocCheck.run(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_TYPOS"] == "1" { OwlTypoCheck.run(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_HISTORY"] == "1" { OwlHistoryCapCheck.runHistory(tab, out: out); return }
        if env["CEDRIC_OWL_CHECK_CAP"] == "1" { OwlHistoryCapCheck.runCap(tab, out: out); return }
        #if DEBUG
        if env["CEDRIC_OWL_CHECK_BUILTIN"] == "1" { BuiltInGateCheck.run(tab, out: out); return }
        #endif
        let original = tab.text
        let deadline = Date().addingTimeInterval(20)
        OwlHub.shared.onPresent = { t, hint in
            guard t === tab else { return }
            OwlHub.shared.onPresent = nil
            check(hint.id == RulesHintProvider.jsonID, "first hint is the JSON hint (got \(hint.id))")
            after(0.4) { step2(tab, original: original, out: out) }
        }
        func wait() {
            if OwlHub.shared.onPresent == nil { return }
            if Date() > deadline { check(false, "a hint appeared within 20 s"); finish(out) ; return }
            after(0.25) { wait() }
        }
        wait()
    }

    static func step2(_ tab: EditorWindowController, original: String, out: String) {
        guard let owl = tab.owl, let bubble = owl.bubble, let window = tab.window else { check(false, "bubble shown"); finish(out); return }
        check(owl.owl.pose == .talking, "owl is in the talking pose")
        snapshot(window, "\(out)/1-bubble.png") {
            guard let apply = bubble.buttons.first(where: { $0.title == String(localized: "Fix it") }) else {
                check(false, "bubble has Apply"); finish(out); return
            }
            click(apply)
            let expected = JSONFormatter.prettyIfMinified(original)
            check(expected != nil && tab.text == expected, "Apply formatted the JSON (\(tab.lineIndex.lineCount) lines)")
            check(owl.bubble == nil, "bubble closed after Apply")
            snapshot(window, "\(out)/2-applied.png") {
                key(window, "z", code: 6, [.command])
                check(tab.text == original, "one ⌘Z restores the original text")
                key(window, "z", code: 6, [.command, .shift])
                check(tab.text == expected, "⇧⌘Z reapplies the formatting")
                step4(tab, out: out)
            }
        }
    }

    static func step4(_ tab: EditorWindowController, out: String) {
        guard let owl = tab.owl, let window = tab.window else { return }
        check(!owl.owlFaded, "owl not faded with the caret at the top")
        let tv = tab.textView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        key(window, "\r", code: 36, [])
        var typed = 0
        func type() {
            if owl.owlFaded || typed > 400 {
                check(owl.owlFaded, "owl fades when the caret comes near (after \(typed) keys)")
                snapshot(window, "\(out)/3-typing-near.png") { step5(tab, out: out) }
                return
            }
            for _ in 0..<5 { key(window, "x", code: 7, []); typed += 1 }
            after(0.02) { type() }
        }
        type()
    }

    static func step5(_ tab: EditorWindowController, out: String) {
        guard let owl = tab.owl, let window = tab.window else { return }
        // Away from the owl again.
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        after(0.3) {
            check(!owl.owlFaded, "owl back when the caret leaves")
            key(window, "s", code: 1, [.command])
            check(owl.owl.isPlaying, "⌘S makes the owl flap")
            after(0.15) {
                snapshot(window, "\(out)/4-flap.png") { finish(out) }
            }
        }
    }

    static func finish(_ out: String) {
        print("owlcheck: \(failures == 0 ? "PASS" : "FAILED (\(failures))")")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Events

    static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }

    static func snapshot(_ window: NSWindow, _ path: String, then: @escaping @MainActor () -> Void) {
        window.displayIfNeeded()
        DevHooks.write(window: window, to: path) {
            print("owlcheck: wrote \(path)")
            then()
        }
    }

    /// A real mouse click on a control: mouse-up queued, then mouse-down
    /// sent through the app (the button's tracking loop picks the up).
    static func click(_ v: NSView) {
        guard let w = v.window else { return }
        let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return }
        let hit = w.contentView?.superview?.hitTest(p)
        print("owlcheck: click at \(p) hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        NSApp.postEvent(up, atStart: false)
        w.sendEvent(down)
        // An inactive window (locked screen) can swallow the first click
        // in NSWindow.sendEvent; then hand the same events to the control
        // that the hit test found.
        if let hit, NSApp.keyWindow == nil, (v as? NSButton)?.target != nil, clicked == false {
            print("owlcheck: (window didn't deliver the click; sending it to \(type(of: hit)))")
            NSApp.postEvent(up, atStart: false)
            hit.mouseDown(with: down)
        }
    }

    /// A real key press through the app: key equivalents reach the menus,
    /// plain keys the first responder. With no key window (locked screen)
    /// the menu can't route a key equivalent, so the check performs the
    /// menu item that matches it, on the first of the window's responder
    /// chain or the app delegate that handles it.
    static func key(_ w: NSWindow, _ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags) {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: mods.contains(.shift) ? chars.uppercased() : chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            if t == .keyDown, !mods.contains(.command) {
                w.sendEvent(e)
            } else if t == .keyDown, NSApp.keyWindow == nil {
                guard let item = menuItem(NSApp.mainMenu, chars, mods), let action = item.action else {
                    check(false, "menu item for ⌘\(chars)"); continue
                }
                var chain: [NSResponder] = []
                var r: NSResponder? = w.firstResponder
                while let x = r { chain.append(x); r = x.nextResponder }
                let target: AnyObject? = chain.first { $0.responds(to: action) } ?? (NSApp.delegate?.responds(to: action) == true ? NSApp.delegate : nil)
                NSApp.sendAction(action, to: target, from: item)
            } else {
                NSApp.sendEvent(e)
            }
        }
    }

    static func menuItem(_ menu: NSMenu?, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        for i in menu?.items ?? [] {
            if let s = menuItem(i.submenu, key, mods) { return s }
            if i.keyEquivalent == key, i.keyEquivalentModifierMask == mods { return i }
        }
        return nil
    }
}
