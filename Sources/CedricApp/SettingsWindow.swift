import AppKit
import CedricCore

/// One tab of the Settings window: its view is built the first time the
/// tab is shown (`make`), so a tab nobody opens costs nothing.
@MainActor
final class SettingsPaneController: NSViewController {
    let pane: SettingsPane
    private let make: () -> NSView

    init(pane: SettingsPane, title: String, make: @escaping () -> NSView) {
        self.pane = pane
        self.make = make
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = make() }

    /// The view's natural size (the window takes it when the tab is shown).
    var fittingContentSize: NSSize {
        view.layoutSubtreeIfNeeded()
        let s = view.fittingSize
        return NSSize(width: max(s.width, SettingsWindowController.minimumWidth), height: s.height)
    }
}

/// The toolbar tabs; reports each selection (saved, and the window fits it).
@MainActor
final class SettingsTabController: NSTabViewController {
    var onSelect: ((SettingsPaneController) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let pane = tabViewItem?.viewController as? SettingsPaneController { onSelect?(pane) }
    }
}

/// Owlink › Settings… (⌘,), 0.4.1 (UX review #1): one window with toolbar
/// tabs (General, Editor, Writing, Cedric), every control applied the
/// moment it changes, no Save or Cancel. The View and Edit menu toggles
/// (wrap, invisibles, line numbers, occurrences, auto-close, spelling,
/// grammar) are checkboxes here too, bound to the same settings, so either
/// place updates the other. The Cedric tab holds what was the separate
/// Cedric AI window (`AISettingsSection`); Cedric › Cedric AI Settings…
/// opens it. The window is built the first time it is opened, never at
/// launch, and each tab when it is first shown. It reopens on the tab it
/// was left on.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var shared: SettingsWindowController?
    static let minimumWidth: CGFloat = 520

    /// The checks (no session saving) keep the last tab in memory only.
    private static let savesPane = DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1"
    private static var paneInMemory: SettingsPane?

    /// The tab Settings was last on (General the first time).
    static var savedPane: SettingsPane {
        get { savesPane ? SettingsPane.restored(UserDefaults.standard.string(forKey: SettingsPane.defaultsKey)) : paneInMemory ?? .general }
        set { if savesPane { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsPane.defaultsKey) } else { paneInMemory = newValue } }
    }

    /// Shows the window on `pane`, or on the tab it was left on.
    static func show(pane: SettingsPane? = nil) {
        let target = pane ?? savedPane
        let c = shared ?? SettingsWindowController()
        let first = shared == nil
        shared = c
        c.select(target)
        c.refresh()
        if first { c.window?.center() }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    // General
    let theme = NSPopUpButton()
    let fontPopup = NSPopUpButton()
    let fontSize = NSTextField()
    let fontStepper = NSStepper()
    let quitOnLastClose = NSButton(checkboxWithTitle: String(localized: "Quit when the last window closes"), target: nil, action: nil)
    let reopenLastSession = NSButton(checkboxWithTitle: String(localized: "Reopen files from last session"), target: nil, action: nil)
    /// Default editor for… (0.3.0), built with the General tab.
    private(set) var defaultEditor: DefaultEditorPane?
    // Editor
    let indentKind = NSPopUpButton()
    let tabWidth = NSPopUpButton()
    let gitChanges = NSButton(checkboxWithTitle: String(localized: "Show git changes in the gutter"), target: nil, action: nil)
    /// The menu toggles as checkboxes (Editor and Writing tabs).
    let toggles: [MenuToggleSetting: NSButton]
    // Writing
    /// View › Readable Width's column, in characters (ReadableWidthView.swift).
    let readableColumns = NSTextField()
    /// The default for tabs that have not chosen (off).
    let readableWidthDefault = NSButton(checkboxWithTitle: String(localized: "Readable Width"), target: nil, action: nil)
    let readableStepper = NSStepper()
    /// Style Check (0.4.0) and its two lists, comma-separated.
    let styleCheck = NSButton(checkboxWithTitle: String(localized: "Style Check: filler words, redundancies, clichés"), target: nil, action: nil)
    let styleExtra = NSTextField()
    let styleExceptions = NSTextField()
    /// The prose font (0.4.1, UX review #9): Markdown and plain-text tabs
    /// in their own font, usually proportional; off by default.
    let useProseFont = NSButton(checkboxWithTitle: String(localized: "Use a prose font for Markdown and plain text"), target: nil, action: nil)
    let proseFontPopup = NSPopUpButton()
    let proseFontSize = NSTextField()
    let proseFontStepper = NSStepper()
    // Cedric
    let showOwl = NSButton(checkboxWithTitle: String(localized: "Show Cedric"), target: nil, action: nil)
    let owlChat = NSButton(checkboxWithTitle: String(localized: "Ask Cedric"), target: nil, action: nil)
    let styleTips = NSButton(checkboxWithTitle: String(localized: "Style tips in code"), target: nil, action: nil)
    /// Cedric AI (was its own window with Save/Cancel until 0.4.1): built
    /// with the Cedric tab.
    private(set) var ai: AISettingsSection?

    let tabs = SettingsTabController()
    private(set) var panes: [SettingsPane: SettingsPaneController] = [:]
    private var observers: [NSObjectProtocol] = []

    /// The font menu's families: fixed-pitch fonts installed (read when the
    /// General tab is built). Tag 0 is the system's monospaced font.
    private var fontNames: [String?] = [nil]

    static func toggleTitle(_ t: MenuToggleSetting) -> String {
        switch t {
        case .wrapLines: return String(localized: "Wrap lines")
        case .showInvisibles: return String(localized: "Show invisibles")
        case .showLineNumbers: return String(localized: "Show line numbers")
        case .highlightOccurrences: return String(localized: "Highlight occurrences")
        case .autoCloseBrackets: return String(localized: "Auto-close brackets and quotes")
        case .checkSpellingWhileTyping: return String(localized: "Check spelling while typing")
        case .checkGrammar: return String(localized: "Check grammar in prose")
        }
    }

    static func paneTitle(_ p: SettingsPane) -> String {
        switch p {
        case .general: return String(localized: "General")
        case .editor: return String(localized: "Editor")
        case .writing: return String(localized: "Writing")
        case .cedric: return String(localized: "Cedric")
        }
    }

    init() {
        var t: [MenuToggleSetting: NSButton] = [:]
        for k in MenuToggleSetting.allCases { t[k] = NSButton(checkboxWithTitle: Self.toggleTitle(k), target: nil, action: nil) }
        toggles = t
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.identifier = NSUserInterfaceItemIdentifier("CedricSettings")
        w.autorecalculatesKeyViewLoop = true
        super.init(window: w)
        w.delegate = self
        for p in SettingsPane.allCases {
            let vc = SettingsPaneController(pane: p, title: Self.paneTitle(p)) { [unowned self] in self.build(p) }
            panes[p] = vc
            let item = NSTabViewItem(viewController: vc)
            item.label = vc.title ?? ""
            item.identifier = p.rawValue
            item.image = NSImage(systemSymbolName: p.symbolName, accessibilityDescription: item.label)
                ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: item.label)
            item.toolTip = item.label
            tabs.addTabViewItem(item)
        }
        tabs.onSelect = { [weak self] vc in
            Self.savedPane = vc.pane
            self?.fit(vc)
        }
        for name in [Notification.Name.cedricAppearanceChanged, .cedricSettingsChanged, .cedricOwlSettingsChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for b in [gitChanges, owlChat, showOwl, styleTips, styleCheck, quitOnLastClose, reopenLastSession, useProseFont, readableWidthDefault] + Array(toggles.values) {
            b.target = self; b.action = #selector(changed(_:))
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The selected tab.
    var selectedPane: SettingsPane {
        (tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.viewController as? SettingsPaneController)?.pane ?? .general
    }

    func select(_ pane: SettingsPane) {
        guard let i = SettingsPane.allCases.firstIndex(of: pane) else { return }
        if tabs.selectedTabViewItemIndex != i { tabs.selectedTabViewItemIndex = i }
        if let vc = panes[pane] { fit(vc) }
    }

    /// The window takes the tab's natural size, its top edge kept.
    func fit(_ vc: SettingsPaneController) {
        guard let w = window, tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.viewController === vc else { return }
        let size = vc.fittingContentSize
        var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
        if f.size != w.frame.size { w.setFrame(f, display: true, animate: false) }
        w.recalculateKeyViewLoop()
    }

    // MARK: Building

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    /// A grid row: "Name:" and its control, which VoiceOver reads by that name.
    private func row(_ name: String, _ control: NSView, spoken: String? = nil) -> [NSView] {
        control.setAccessibilityLabel(spoken ?? name.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        return [label(name), control]
    }

    private func note(_ s: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: s)
        n.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        n.textColor = .secondaryLabelColor
        n.preferredMaxLayoutWidth = 320
        return n
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 8
        g.columnSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .firstBaseline
        return g
    }

    /// The tab's view: `parts` stacked, 20 pt from the top, 24 from the sides.
    private func page(_ parts: [NSView]) -> NSView {
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        for p in parts where p is NSBox { p.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let bottom = stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bottom,
        ])
        return content
    }

    private func rule() -> NSBox {
        let r = NSBox()
        r.boxType = .separator
        return r
    }

    private func build(_ pane: SettingsPane) -> NSView {
        let v: NSView
        switch pane {
        case .general: v = buildGeneral()
        case .editor: v = buildEditor()
        case .writing: v = buildWriting()
        case .cedric: v = buildCedric()
        }
        refresh()
        return v
    }

    private func buildGeneral() -> NSView {
        for t in EditorTheme.allCases { theme.addItem(withTitle: t.displayName); theme.lastItem?.representedObject = t.rawValue }
        theme.target = self; theme.action = #selector(changed(_:))

        let fm = NSFontManager.shared
        let mono = (fm.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { NSFont(name: $0, size: 13) }
            .filter { ($0.fontDescriptor.symbolicTraits.contains(.monoSpace)) }
        // One entry per family: its regular face.
        var byFamily: [String: NSFont] = [:]
        for f in mono {
            let fam = f.familyName ?? f.fontName
            if let cur = byFamily[fam], cur.fontName.count <= f.fontName.count { continue }
            byFamily[fam] = f
        }
        fontPopup.addItem(withTitle: String(localized: "SF Mono (System)"))
        for fam in byFamily.keys.sorted() where fam != "SF Mono" {
            fontPopup.addItem(withTitle: fam)
            fontNames.append(byFamily[fam]!.fontName)
        }
        // A font chosen elsewhere (or no longer fixed-pitch) still shows.
        if let cur = Settings.shared.fontName, !fontNames.contains(cur) {
            fontPopup.addItem(withTitle: NSFont(name: cur, size: 13)?.displayName ?? cur)
            fontNames.append(cur)
        }
        fontPopup.target = self; fontPopup.action = #selector(changed(_:))
        fontSize.alignment = .right
        fontSize.target = self; fontSize.action = #selector(changed(_:))
        fontSize.cell?.sendsActionOnEndEditing = true
        fontSize.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fontSize.setAccessibilityLabel(String(localized: "Font size in points"))
        fontStepper.minValue = 6; fontStepper.maxValue = 72; fontStepper.increment = 1
        fontStepper.target = self; fontStepper.action = #selector(stepped(_:))
        fontStepper.setAccessibilityLabel(String(localized: "Font size"))
        let fontRow = NSStackView(views: [fontPopup, fontSize, fontStepper, NSTextField(labelWithString: "pt")])
        fontRow.spacing = 6
        fontPopup.setAccessibilityLabel(String(localized: "Font"))
        let appRow = NSStackView(views: [quitOnLastClose, reopenLastSession])
        appRow.orientation = .vertical
        appRow.alignment = .leading
        appRow.spacing = 4

        let pane = DefaultEditorPane()
        defaultEditor = pane
        let paneView = pane.view
        return page([
            grid([
                row(String(localized: "Theme:"), theme),
                [label(String(localized: "Font:")), fontRow],
                [label(String(localized: "App:")), appRow],
            ]),
            rule(),
            paneView,
        ])
    }

    private func buildEditor() -> NSView {
        indentKind.addItems(withTitles: [String(localized: "Spaces"), String(localized: "Tabs")])
        indentKind.target = self; indentKind.action = #selector(changed(_:))
        indentKind.setAccessibilityLabel(String(localized: "Default indent"))
        for wdt in Indentation.widths { tabWidth.addItem(withTitle: "\(wdt)"); tabWidth.lastItem?.tag = wdt }
        tabWidth.target = self; tabWidth.action = #selector(changed(_:))
        tabWidth.setAccessibilityLabel(String(localized: "Indent width"))
        let indentRow = NSStackView(views: [indentKind, NSTextField(labelWithString: String(localized: "width")), tabWidth])
        indentRow.spacing = 6
        let t = toggles
        return page([grid([
            [label(String(localized: "Default indent:")), indentRow],
            [NSGridCell.emptyContentView, note(String(localized: "For new files and files that don't indent yet; a file's own indentation wins. Text › Indentation changes one tab."))],
            [label(String(localized: "View:")), t[.wrapLines]!],
            [NSGridCell.emptyContentView, t[.showInvisibles]!],
            [NSGridCell.emptyContentView, t[.showLineNumbers]!],
            [NSGridCell.emptyContentView, t[.highlightOccurrences]!],
            [label(String(localized: "Typing:")), t[.autoCloseBrackets]!],
            [label(String(localized: "Gutter:")), gitChanges],
            [NSGridCell.emptyContentView, note(String(localized: "Also in the View and Edit menus; a change in either place shows in both."))],
        ])])
    }

    private func buildWriting() -> NSView {
        readableColumns.alignment = .right
        readableColumns.target = self; readableColumns.action = #selector(changed(_:))
        readableColumns.cell?.sendsActionOnEndEditing = true
        readableColumns.widthAnchor.constraint(equalToConstant: 44).isActive = true
        readableColumns.toolTip = String(localized: "How wide View › Readable Width's column is, in characters (\(ReadableWidth.columnRange.lowerBound)–\(ReadableWidth.columnRange.upperBound)).")
        readableColumns.setAccessibilityLabel(String(localized: "Readable width in characters"))
        readableStepper.minValue = Double(ReadableWidth.columnRange.lowerBound)
        readableStepper.maxValue = Double(ReadableWidth.columnRange.upperBound)
        readableStepper.increment = 1
        readableStepper.target = self; readableStepper.action = #selector(stepped(_:))
        readableStepper.setAccessibilityLabel(String(localized: "Readable width"))
        readableWidthDefault.toolTip = String(localized: "Centre the text in a column. Off until you turn it on. View › Readable Width switches the current tab and keeps that choice; this is the default for every other tab.")
        let readableRow = NSStackView(views: [readableColumns, readableStepper, NSTextField(labelWithString: String(localized: "characters"))])
        readableRow.spacing = 6
        for (f, hint, spoken) in [(styleExtra, String(localized: "Also flag: words or phrases, comma-separated"), String(localized: "Also flag")),
                                  (styleExceptions, String(localized: "Never flag: words or phrases, comma-separated"), String(localized: "Never flag"))] {
            f.placeholderString = hint
            f.target = self; f.action = #selector(changed(_:))
            f.cell?.sendsActionOnEndEditing = true
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
            f.setAccessibilityLabel(spoken)
            f.setAccessibilityHelp(hint)
        }
        // The prose font: every installed family (the system's two faces first).
        let pm = proseFontPopup.menu ?? NSMenu()
        for (title, rep) in [(String(localized: "System Font (SF Pro)"), ""), (String(localized: "New York (System Serif)"), ProseFont.systemSerif)] {
            proseFontPopup.addItem(withTitle: title)
            proseFontPopup.lastItem?.representedObject = rep
        }
        pm.addItem(.separator())
        for fam in NSFontManager.shared.availableFontFamilies where !fam.hasPrefix(".") {
            let i = NSMenuItem(title: fam, action: nil, keyEquivalent: "")
            i.representedObject = "family:" + fam
            pm.addItem(i)
        }
        proseFontPopup.target = self; proseFontPopup.action = #selector(changed(_:))
        proseFontPopup.setAccessibilityLabel(String(localized: "Prose font"))
        proseFontSize.alignment = .right
        proseFontSize.target = self; proseFontSize.action = #selector(changed(_:))
        proseFontSize.cell?.sendsActionOnEndEditing = true
        proseFontSize.widthAnchor.constraint(equalToConstant: 44).isActive = true
        proseFontSize.setAccessibilityLabel(String(localized: "Prose font size in points"))
        proseFontStepper.minValue = ProseFont.sizeRange.lowerBound; proseFontStepper.maxValue = ProseFont.sizeRange.upperBound
        proseFontStepper.increment = 1
        proseFontStepper.target = self; proseFontStepper.action = #selector(stepped(_:))
        proseFontStepper.setAccessibilityLabel(String(localized: "Prose font size"))
        let proseRow = NSStackView(views: [proseFontPopup, proseFontSize, proseFontStepper, NSTextField(labelWithString: "pt")])
        proseRow.spacing = 6
        useProseFont.toolTip = String(localized: "Markdown and plain-text tabs use this font; code keeps the monospaced font in General. Zoom changes both.")
        let t = toggles
        return page([grid([
            [label(String(localized: "Prose font:")), useProseFont],
            [NSGridCell.emptyContentView, proseRow],
            [NSGridCell.emptyContentView, note(String(localized: "Markdown and plain text only; code keeps the font in General. Zoom changes both. Text › Selection › Add Caret Above and Below keep the character column, which need not line up in a proportional font."))],
            [label(String(localized: "Readable width:")), readableWidthDefault],
            [NSGridCell.emptyContentView, readableRow],
            [label(String(localized: "Spelling:")), t[.checkSpellingWhileTyping]!],
            [label(String(localized: "Grammar:")), t[.checkGrammar]!],
            [label(String(localized: "Style:")), styleCheck],
            [NSGridCell.emptyContentView, styleExtra],
            [NSGridCell.emptyContentView, styleExceptions],
        ])])
    }

    private func buildCedric() -> NSView {
        let section = AISettingsSection(settings: AIStore.load())
        section.onResize = { [weak self] in
            guard let self, let vc = self.panes[.cedric], vc.isViewLoaded else { return }
            self.fit(vc)
        }
        ai = section
        let heading = NSTextField(labelWithString: String(localized: "Cedric AI"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.setAccessibilityRole(.staticText)
        let top = grid([
            [label(String(localized: "Cedric:")), showOwl],
            [NSGridCell.emptyContentView, owlChat],
            [NSGridCell.emptyContentView, styleTips],
        ])
        // One label column for both grids, so the checkboxes line up.
        top.column(at: 0).width = section.labelColumnWidth
        return page([
            top,
            rule(),
            heading,
            section.view,
        ])
    }

    // MARK: State

    /// Shows the current settings (in the tabs built so far).
    func refresh() {
        let s = Settings.shared
        theme.selectItem(at: EditorTheme.allCases.firstIndex(of: s.theme) ?? 0)
        if fontPopup.numberOfItems > 0 { fontPopup.selectItem(at: fontNames.firstIndex(of: s.fontName) ?? 0) }
        // Same as the style fields: a refresh while the field editor is up would wipe a half-typed number.
        if fontSize.currentEditor() == nil {
            fontSize.integerValue = Int(s.fontSize)
            fontStepper.integerValue = Int(s.fontSize)
        }
        gitChanges.state = s.showGitChanges ? .on : .off
        quitOnLastClose.state = s.quitWhenLastWindowCloses ? .on : .off
        reopenLastSession.state = s.reopenFilesFromLastSession ? .on : .off
        for (k, b) in toggles { b.state = s[toggle: k] ? .on : .off }
        showOwl.state = s.showOwl ? .on : .off
        showOwl.toolTip = String(localized: "Cedric the owl in the corner of the editor, with one hint at a time. Also Cedric › Show Cedric.")
        owlChat.state = s.owlChat ? .on : .off
        styleTips.state = s.owlStyleTips ? .on : .off
        styleCheck.state = s.styleCheck ? .on : .off
        styleCheck.toolTip = String(localized: "Cedric points out filler words, redundancies (“past history”) and clichés in Markdown and plain-text prose, one at a time, never in code. Offline, no AI. Off by default.")
        if styleExtra.currentEditor() == nil { styleExtra.stringValue = s.styleCheckExtra.joined(separator: ", ") }
        if styleExceptions.currentEditor() == nil { styleExceptions.stringValue = s.styleCheckExceptions.joined(separator: ", ") }
        styleExtra.isEnabled = s.styleCheck
        styleExceptions.isEnabled = s.styleCheck
        styleTips.toolTip = String(localized: "Cedric’s style suggestions for code, on top of his checks for code that breaks or does the wrong thing (those are always on). Off by default.")
        let autoGrammar = s.checkGrammar && OwlHub.shared.ai.isActive && OwlHub.shared.ai.isAutomatic
        owlChat.toolTip = String(localized: "Ask Cedric… (⌥⌘/, or click the owl): questions, quick actions and proposed edits from a local AI engine (Apple Intelligence, the built-in model, or your LM Studio / Ollama). On by default when one is ready.")
            + " " + AskCedricEngine.privacy(autoGrammar: autoGrammar).settingsSentence
        let ind = s.defaultIndentation
        if indentKind.numberOfItems > 0 {
            indentKind.selectItem(at: ind.usesTabs ? 1 : 0)
            tabWidth.selectItem(withTag: ind.width)
        }
        if proseFontPopup.numberOfItems > 0 {
            let want: String
            switch s.proseFontName {
            case nil: want = ""
            case ProseFont.systemSerif?: want = ProseFont.systemSerif
            case let n?: want = "family:" + (NSFont(name: n, size: 13)?.familyName ?? n)
            }
            let i = proseFontPopup.indexOfItem(withRepresentedObject: want)
            proseFontPopup.selectItem(at: i >= 0 ? i : 0)
        }
        useProseFont.state = s.useProseFont ? .on : .off
        if proseFontSize.currentEditor() == nil {
            proseFontSize.integerValue = Int(s.proseFontSize)
            proseFontStepper.integerValue = Int(s.proseFontSize)
        }
        for c in [proseFontPopup, proseFontSize, proseFontStepper] as [NSControl] { c.isEnabled = s.useProseFont }
        readableWidthDefault.state = s.readableWidthDefault ? .on : .off
        if readableColumns.currentEditor() == nil {
            readableColumns.integerValue = s.readableColumns
            readableStepper.integerValue = s.readableColumns
        }
        defaultEditor?.refresh()
    }

    /// Back from Finder's Get Info, or from another window that changed
    /// Cedric AI: show the settings as they are now.
    func windowDidBecomeKey(_ notification: Notification) {
        defaultEditor?.refresh()
        ai?.reloadIfIdle()
    }

    /// "very, kind of ,, actually" → ["very", "kind of", "actually"].
    static func phrases(_ s: String) -> [String] {
        var out: [String] = []
        for p in s.split(separator: ",").map({ StyleCheck.normalize(String($0)) }) where !p.isEmpty && !out.contains(p) { out.append(p) }
        return out
    }

    @objc private func stepped(_ sender: NSStepper) {
        if sender === proseFontStepper {
            proseFontSize.integerValue = sender.integerValue
            changed(proseFontSize)
            return
        }
        if sender === readableStepper {
            readableColumns.integerValue = sender.integerValue
            changed(readableColumns)
            return
        }
        fontSize.integerValue = sender.integerValue
        changed(fontSize)
    }

    @objc func changed(_ sender: Any?) {
        let s = Settings.shared
        if let b = sender as? NSButton, let k = toggles.first(where: { $0.value === b })?.key {
            s[toggle: k] = b.state == .on
            refresh()
            return
        }
        switch sender as? NSObject {
        case theme: if let raw = theme.selectedItem?.representedObject as? String, let t = EditorTheme(rawValue: raw) { s.theme = t }
        case fontPopup: s.fontName = fontNames[max(0, fontPopup.indexOfSelectedItem)]
        case fontSize: if fontSize.integerValue >= 6, CGFloat(fontSize.integerValue) != s.fontSize { s.fontSize = CGFloat(fontSize.integerValue) }
        case readableColumns: if readableColumns.integerValue > 0, readableColumns.integerValue != s.readableColumns { s.readableColumns = readableColumns.integerValue }
        case readableWidthDefault: s.readableWidthDefault = readableWidthDefault.state == .on
        case useProseFont: s.useProseFont = useProseFont.state == .on
        case proseFontPopup:
            let rep = proseFontPopup.selectedItem?.representedObject as? String ?? ""
            if rep.hasPrefix("family:") {
                let fam = String(rep.dropFirst(7))
                // The family's regular face (else any face of it).
                let face = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 13)
                    ?? NSFontManager.shared.availableMembers(ofFontFamily: fam)?.first.flatMap { ($0.first as? String).flatMap { NSFont(name: $0, size: 13) } }
                s.proseFontName = face?.fontName
            } else {
                s.proseFontName = rep.isEmpty ? nil : rep
            }
        case proseFontSize:
            if proseFontSize.integerValue >= Int(ProseFont.sizeRange.lowerBound), CGFloat(proseFontSize.integerValue) != s.proseFontSize {
                s.proseFontSize = CGFloat(proseFontSize.integerValue)
            }
        case gitChanges: s.showGitChanges = gitChanges.state == .on
        case quitOnLastClose: s.quitWhenLastWindowCloses = quitOnLastClose.state == .on
        case reopenLastSession: s.reopenFilesFromLastSession = reopenLastSession.state == .on
        case showOwl: s.showOwl = showOwl.state == .on
        case owlChat: s.owlChat = owlChat.state == .on
        case styleTips: s.owlStyleTips = styleTips.state == .on
        case styleCheck: s.styleCheck = styleCheck.state == .on
        case styleExtra: if Self.phrases(styleExtra.stringValue) != s.styleCheckExtra { s.styleCheckExtra = Self.phrases(styleExtra.stringValue) }
        case styleExceptions: if Self.phrases(styleExceptions.stringValue) != s.styleCheckExceptions { s.styleCheckExceptions = Self.phrases(styleExceptions.stringValue) }
        case indentKind, tabWidth:
            s.defaultIndentation = Indentation(usesTabs: indentKind.indexOfSelectedItem == 1, width: tabWidth.selectedTag() > 0 ? tabWidth.selectedTag() : 4)
        default: break
        }
        refresh()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension AppDelegate {
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show() }
    /// Cedric › Cedric AI Settings…: Settings on the Cedric tab.
    @objc func showAISettings(_ sender: Any?) { SettingsWindowController.show(pane: .cedric) }
}
