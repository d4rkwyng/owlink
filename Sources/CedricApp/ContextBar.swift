import AppKit
import CedricCore

/// View › Show Context Bar (0.4.0): one thin row of buttons above the
/// editor, for file types that have a set (`ContextBarSet` in CedricCore;
/// only Markdown so far). On by default (UX review #3); the user's own
/// choice in the menu is kept. Nothing is built while it is off or for a
/// file type without a set: the tab has no view, no observer.
///
/// The icons are tinted from the palette (`contextBarIcon`, and
/// `contextBarIconOn` for a toggle that is on), not left to the system
/// grey, so they reach 3:1 on the bar in every theme (ThemeTests).
///
/// Every button runs a main-menu item, found by its action, validated
/// and sent the way the command palette does it (CommandPalette.target /
/// validate): the menus, the palette and the bar share one command, one
/// undo step and one enabled state. Labels and tooltips come from the
/// menu item's title and shortcut, so they are localized once.
@MainActor
final class ContextBarView: NSView {
    static let height: CGFloat = 28
    let language: Language
    let items: [ContextBarItem]
    /// The buttons by item id (the heading pull-down is an NSPopUpButton).
    private(set) var buttons: [String: NSButton] = [:]
    private let stack = NSStackView()
    private let rule = NSBox()
    private weak var tab: EditorWindowController?
    /// Clicks that ran a command (the check reads it).
    private(set) var runs = 0
    /// The theme's colours (icon tints), set by `applyPalette`.
    private(set) var palette: EditorPalette?

    init(language: Language, tab: EditorWindowController) {
        self.language = language
        self.items = ContextBarSet.items(for: language)
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        identifier = NSUserInterfaceItemIdentifier("contextbar")
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Context Bar"))
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(rule)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        var trailingStarted = false
        for item in items {
            if item.trailing && !trailingStarted {
                trailingStarted = true
                // Leading items on one side, view toggles on the other (mirrored in RTL).
                let spacer = NSView()
                spacer.setContentHuggingPriority(.init(1), for: .horizontal)
                stack.addView(spacer, in: .leading)
                let divider = NSBox()
                divider.boxType = .separator
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
                stack.addView(divider, in: .trailing)
            }
            let b = item.choices.isEmpty ? button(item) : pullDown(item)
            b.identifier = NSUserInterfaceItemIdentifier("contextbar.\(item.id)")
            buttons[item.id] = b
            stack.addView(b, in: item.trailing ? .trailing : .leading)
        }
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    /// "Bold (⌘B)", from the menu item.
    static func tooltip(_ i: NSMenuItem?) -> String {
        guard let i else { return "" }
        return i.keyEquivalent.isEmpty ? i.title : "\(i.title) (\(MenuShortcuts.name(i)))"
    }

    private func style(_ b: NSButton) {
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = true
        b.controlSize = .regular
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func button(_ item: ContextBarItem) -> NSButton {
        let menu = item.command.flatMap(Self.menuItem)
        let (label, tip) = item.toggle ? Self.toggleLabel(menu, fallback: item.id) : (menu?.title ?? item.id, Self.tooltip(menu))
        let b = NSButton(title: "", target: self, action: #selector(pressed(_:)))
        style(b)
        if item.toggle { b.setButtonType(.pushOnPushOff) }
        b.image = Self.symbol(item.symbol, label)
        if b.image == nil { b.title = label; b.imagePosition = .noImage }
        b.toolTip = tip
        b.setAccessibilityLabel(label)
        return b
    }

    /// A toggle is named for what it shows ("Preview"), its on/off is the
    /// value: the menu item's Show/Hide title changes with the state. The
    /// tooltip carries the menu's shortcut: "Preview (⌥⌘P)". Also the
    /// status bar's CSV / TSV Preview eye (Bars.swift).
    static func toggleLabel(_ menu: NSMenuItem?, fallback: String) -> (label: String, tooltip: String) {
        let label = toggleName(menu?.title ?? fallback)
        return (label, tooltip(menu).replacingOccurrences(of: menu?.title ?? "", with: label))
    }

    /// "Show Preview" / "Hide Preview" → "Preview".
    static func toggleName(_ title: String) -> String {
        for p in [String(localized: "Show "), String(localized: "Hide ")] where title.hasPrefix(p) { return String(title.dropFirst(p.count)) }
        return title
    }

    private func pullDown(_ item: ContextBarItem) -> NSButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.isBordered = false
        (p.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        p.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let label = String(localized: "Heading")
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = Self.symbol(item.symbol, label)
        p.menu?.addItem(head)
        for c in item.choices {
            let source = Self.menuItem(c.command)
            let i = NSMenuItem(title: source?.title ?? c.title, action: #selector(chose(_:)), keyEquivalent: source?.keyEquivalent ?? "")
            i.keyEquivalentModifierMask = source?.keyEquivalentModifierMask ?? []
            i.target = self
            i.representedObject = c.command
            p.menu?.addItem(i)
        }
        p.toolTip = String(localized: "Heading level (⌘1, ⌘2, ⌘3)")
        p.setAccessibilityLabel(label)
        return p
    }

    // MARK: Commands

    /// Main-menu items by action name (the menus are built once at launch).
    private static var menuCache: [String: NSMenuItem] = [:]

    static func menuItem(_ command: String) -> NSMenuItem? {
        if let i = menuCache[command] { return i }
        let action = NSSelectorFromString(command)
        var hit: NSMenuItem?
        func walk(_ m: NSMenu) {
            for i in m.items where hit == nil {
                if let s = i.submenu { walk(s) } else if i.action == action, !i.isHidden { hit = i }
            }
        }
        if let m = NSApp.mainMenu { walk(m) }
        if let hit { menuCache[command] = hit }
        return hit
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let item = items.first(where: { buttons[$0.id] === sender }), let c = item.command else { return }
        run(c)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? String else { return }
        run(c)
    }

    /// Runs the menu command `command` for this window, as the menu bar
    /// would (beeps when it is disabled there).
    func run(_ command: String) {
        guard let window, let item = Self.menuItem(command), let action = item.action else { NSSound.beep(); refreshStates(); return }
        guard CommandPalette.validate(item, in: window) else { NSSound.beep(); refreshStates(); return }
        NSApp.sendAction(action, to: CommandPalette.target(for: item, in: window), from: item)
        runs += 1
        refreshStates()
    }

    /// Enabled and on/off states, read from the menu items' validation
    /// (when shown, after each command, and on each selection change: the
    /// Explain and Rewrite buttons follow the selection, so this runs once
    /// per keystroke). One validation pass: the current tab is worked out
    /// once for all the buttons, not several times per button. Without a
    /// key window each lookup is a window-server round trip, about 55 of
    /// them per refresh, which made typing with the bar shown 1.2 ms
    /// slower per key than with it hidden.
    func refreshStates() {
        guard let window else { return }
        if let app = NSApp.delegate as? AppDelegate { app.withValidationPass { applyStates(in: window) } } else { applyStates(in: window) }
    }

    private func applyStates(in window: NSWindow) {
        for item in items {
            guard let b = buttons[item.id] else { continue }
            let commands = item.command.map { [$0] } ?? item.choices.map(\.command)
            let menus = commands.compactMap(Self.menuItem)
            b.isEnabled = menus.contains { CommandPalette.validate($0, in: window) }
            if item.toggle, let m = menus.first {
                // Show/Hide items (UX review #7) carry no checkmark: "Hide …" means on.
                let on = Self.isOn(m)
                b.state = on ? .on : .off
                b.setAccessibilityValue(on ? String(localized: "on") : String(localized: "off"))
            }
        }
        tint()
    }

    func refreshInlineSelectionStates() {
        refreshStates()
    }

    /// A view toggle's menu item is on when it is checked or offers "Hide".
    static func isOn(_ m: NSMenuItem) -> Bool { m.state == .on || m.title.hasPrefix(String(localized: "Hide")) }

    /// The icons' colours: the palette's, so they reach 3:1 on the bar.
    func tint() {
        guard let palette else { return }
        let off = NSColor(hex: palette.contextBarIcon), on = NSColor(hex: palette.contextBarIconOn)
        for item in items {
            guard let b = buttons[item.id] else { continue }
            b.contentTintColor = item.toggle && b.state == .on ? on : off
        }
    }

    // MARK: Look

    /// Right-to-left: the stack mirrors (leading items on the right).
    override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet { stack.userInterfaceLayoutDirection = userInterfaceLayoutDirection }
    }

    func applyPalette(_ p: EditorPalette) {
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: p.statusBar).cgColor
        // The symbols follow the editor's theme, not the system's.
        appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
        palette = p
        tint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Often before the window is current: the tab is built, then ordered
        // front. A disabled button never sends its action, so this first
        // pass can leave every button dead. windowDidBecomeKey and makeTab
        // refresh again once this document is the current one.
        if window != nil { refreshStates() }
    }
}

extension EditorWindowController {
    /// Shows, rebuilds or drops the bar for the setting and the file type.
    /// Off or no set: no view at all.
    func updateContextBar() {
        let want = Settings.shared.showContextBar && ContextBarSet.hasBar(doc.language)
        if !want {
            guard let bar = contextBar else { return }
            bar.removeFromSuperview()
            contextBar = nil
            return
        }
        if let bar = contextBar, bar.language == doc.language { return }
        contextBar?.removeFromSuperview()
        let bar = ContextBarView(language: doc.language, tab: self)
        bar.applyPalette(palette)
        // Just above the text (below the notices and the find bar).
        let at = stack.arrangedSubviews.firstIndex(of: split) ?? 0
        stack.insertArrangedSubview(bar, at: at)
        contextBar = bar
        window?.recalculateKeyViewLoop()
    }
}

extension AppDelegate {
    @objc func toggleContextBarMenu(_ sender: Any?) { Settings.shared.showContextBar.toggle() }
}

/// A view toggle's title: "Show X" while hidden, "Hide X" while shown, no
/// checkmark (HIG; UX review #7). Attribute toggles (Wrap Lines…) keep
/// their checkmarks.
@MainActor
func setShowHide(_ item: NSMenuItem, shown: Bool, show: String, hide: String) {
    item.title = shown ? hide : show
    item.state = .off
}
