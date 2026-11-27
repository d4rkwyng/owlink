import AppKit
import CedricCore

/// Every key equivalent in the main menu, as "⇧⌘T" and its menu path
/// ("File › Reopen Closed Tab"). Used by Help › Keyboard Shortcuts and by
/// CEDRIC_DUMP_SHORTCUTS (which fails on a clash).
@MainActor
enum MenuShortcuts {
    static func name(_ i: NSMenuItem) -> String {
        var s = ""
        let m = i.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || i.keyEquivalent != i.keyEquivalent.lowercased() { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch i.keyEquivalent.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey?: s += "↑"
        case NSDownArrowFunctionKey?: s += "↓"
        case NSLeftArrowFunctionKey?: s += "←"
        case NSRightArrowFunctionKey?: s += "→"
        case 32?: s += "␣"
        case NSF2FunctionKey?: s += "F2"
        default: s += i.keyEquivalent.uppercased()
        }
        return s
    }

    static func list(_ menu: NSMenu? = NSApp.mainMenu) -> [(String, String)] {
        var out: [(String, String)] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for i in menu.items {
                let p = path.isEmpty ? i.title : "\(path) › \(i.title)"
                // Items AppKit adds to Edit (Emoji & Symbols, Dictation) are the system's own.
                let systemAdded = [Selector(("orderFrontCharacterPalette:")), Selector(("startDictation:"))].contains { $0 == i.action }
                if !i.keyEquivalent.isEmpty && !systemAdded { out.append((name(i), p)) }
                if let sub = i.submenu { walk(sub, p) }
            }
        }
        if let menu { walk(menu, "") }
        return out
    }

    /// Shortcuts that aren't menu key equivalents (mouse gestures, and ⎋,
    /// which stays the text view's unless there are several carets):
    /// listed after the menus' in Help › Keyboard Shortcuts.
    static let extraRows: [(String, String)] = [
        ("⌥-drag", String(localized: "Text › Selection: column selection")),
        ("⌘-click", String(localized: "Text › Selection: add or remove a caret (on a [[wiki link]]: open its note)")),
        ("⎋", String(localized: "Text › Selection › Single Caret (with several carets)")),
        ("click ▾ / ▸", String(localized: "Text › Folding: fold or unfold (the triangles beside the line numbers)")),
    ]
}

/// Help › Owlink Help (the manual, docs/MANUAL.md on GitHub, at this
/// version's release tag), Keyboard Shortcuts (a window listing every menu
/// shortcut), Owlink on GitHub and Report an Issue…. NSApp.helpMenu is
/// set, so macOS adds its menu search field to Help.
extension AppDelegate {
    static var helpURL: URL { AboutInfo.help }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }

    @objc func showGitHub(_ sender: Any?) {
        NSWorkspace.shared.open(AboutInfo.repository)
    }

    @objc func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(AboutInfo.newIssue)
    }

    @objc func showAbout(_ sender: Any?) {
        AboutPanel.show()
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        if let w = ShortcutsWindow.shared { w.makeKeyAndOrderFront(nil); return }
        let rows = MenuShortcuts.list() + MenuShortcuts.extraRows
        let width = rows.map(\.0.count).max() ?? 4
        let body = rows.map { k, p in k.padding(toLength: max(width, 6) + 2, withPad: " ", startingAt: 0) + p }.joined(separator: "\n")
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        w.title = String(localized: "Keyboard Shortcuts")
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            tv.textContainerInset = NSSize(width: 10, height: 10)
            tv.string = body
            tv.setAccessibilityLabel(String(localized: "Keyboard Shortcuts"))
        }
        w.contentView = scroll
        w.center()
        ShortcutsWindow.shared = w
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum ShortcutsWindow {
    static var shared: NSWindow?
}

/// Owlink › About Owlink: the standard panel with Tankard's layout:
/// "Version X" (no build number), the author, the repository, the licence
/// on one line, the credits, a short tribute line and the copyright.
@MainActor
enum AboutPanel {
    static func show() {
        let versions = AboutInfo.panelVersions(bundle: Bundle.main.infoDictionary)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options(versions))
    }

    static func options(_ versions: (application: String, build: String)) -> [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationName: "Owlink",
            .applicationVersion: versions.application,
            .version: versions.build,
            .credits: credits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AboutInfo.copyright,
        ]
    }

    static func credits() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 3
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
        ]
        let s = NSMutableAttributedString(string: AboutInfo.author + "\n", attributes: base)
        var a = base
        a[.link] = AboutInfo.repository
        s.append(NSAttributedString(string: "github.com/d4rkwyng/owlink", attributes: a))
        s.append(NSAttributedString(string: "\n", attributes: base))
        var dim = base
        dim[.foregroundColor] = NSColor.secondaryLabelColor
        s.append(NSAttributedString(string: AboutInfo.licence + "\n", attributes: dim))
        var small = dim
        small[.font] = NSFont.systemFont(ofSize: 10)
        let llama = NSMutableAttributedString(string: AboutInfo.llamaCredit + "\n", attributes: small)
        if let r = AboutInfo.llamaCredit.range(of: "llama.cpp") {
            llama.addAttribute(.link, value: AboutInfo.llamaCpp, range: NSRange(r, in: AboutInfo.llamaCredit))
        }
        s.append(llama)
        s.append(NSAttributedString(string: AboutInfo.modelsCredit + "\n" + AboutInfo.tribute, attributes: small))
        return s
    }
}
