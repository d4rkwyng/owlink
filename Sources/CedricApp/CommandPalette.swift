import AppKit
import CedricCore

/// View › Command Palette (⇧⌘P): a search field over every command in the
/// menu bar, with its menu path and shortcut, fuzzy-matched as you type
/// (CommandMatcher in CedricCore), recently run commands first.
///
/// - **Built from the live main menu** each time it opens, so a new menu
///   item (or Text Tool) shows up with no list to keep in sync. Left out:
///   the palette itself, separators, hidden items, the Services menu,
///   the Window menu's window list, and items that are views (the Help
///   menu's search field).
/// - **Disabled items are shown dimmed**, validated as the menu bar would
///   validate them for the window the palette was opened over. Return on
///   one does nothing.
/// - **Running a command** closes the palette, gives the window back its
///   key status and sends the item's action along that window's responder
///   chain, as choosing it from the menu bar would.
/// - **Free when closed**: nothing is built until the first ⇧⌘P; there are
///   no observers or timers. Closing drops the rows (and the menu items
///   they hold); the panel itself is kept for the next open.
/// - **VoiceOver**: the result count is announced as the list changes,
///   and the selected command (title, shortcut, menu, "dimmed") as the
///   arrow keys move.
/// - **Open Quickly** (File › Open Quickly…, ⌥⌘O, 0.4.0) opens it in file
///   mode: the folder sidebar's files by fuzzy name (QuickOpen.swift in
///   CedricCore, the index in QuickOpenFiles.swift), then the current
///   Markdown document's headings. In either mode `#` searches the
///   headings only and `>` the commands (as in VS Code). Return opens the
///   file (or jumps to the heading).
@MainActor
final class CommandPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static private(set) var shared: CommandPalette?
    /// The recent commands (by menu path), newest first, for this run of the app.
    static var recents = CommandRecents()

    struct Row {
        enum Target {
            case command(NSMenuItem)
            case file(URL)
            case heading(MarkdownOutline.Heading)
        }
        let target: Target
        let candidate: CommandMatcher.Candidate
        let shortcut: String
        var item: NSMenuItem? { if case .command(let i) = target { return i } else { return nil } }
    }

    enum Mode { case commands, files }
    /// What the palette was opened for (⇧⌘P commands, ⌥⌘O files).
    private(set) var mode: Mode = .commands
    /// What the rows are now (the query's prefix can change it).
    private(set) var showing: QuickOpen.Query = .commands("")

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 36
    static let visibleRows = 12
    static let fieldHeight: CGFloat = 44

    let panel: PalettePanel
    let field = NSTextField()
    let table = NSTableView()
    let scroll = NSScrollView()
    let empty = NSTextField(labelWithString: String(localized: "No matching commands"))
    weak var parent: NSWindow?

    private(set) var rows: [Row] = []
    private(set) var shown: [Int] = []
    private var index: CommandIndex?
    /// The menu's commands, collected at a ⇧⌘P open or the first `>` query.
    private var commandRows: [Row]?
    /// The parent tab's Markdown headings, read at the first query that wants them.
    private var headings: [MarkdownOutline.Heading]?

    /// Milliseconds the last open took, from the command to the panel
    /// drawn with its list (dev checks report it).
    private(set) static var lastOpenMilliseconds: Double = 0
    /// The last VoiceOver announcement (dev checks read it).
    private(set) var lastAnnouncement = ""
    var isOpen: Bool { panel.isVisible }

    // MARK: Opening

    static func toggle(over window: NSWindow?, mode: Mode = .commands) {
        if let p = shared, p.isOpen {
            // The other mode's key while open: switch, keeping the window.
            if p.mode == mode { p.close() } else { let w = p.parent; p.close(); p.open(over: w, mode: mode) }
            return
        }
        let p = shared ?? CommandPalette()
        shared = p
        p.open(over: window, mode: mode)
    }

    override init() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.palette = self
        panel.setAccessibilityLabel(String(localized: "Command Palette"))

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = String(localized: "Type a command")
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(String(localized: "Search commands"))

        table.addTableColumn(NSTableColumn(identifier: .init("cmd")))
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(String(localized: "Commands"))

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true

        let line = NSBox()
        line.boxType = .separator
        for v in [field, line, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: Self.fieldHeight / 2),
            line.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            line.topAnchor.constraint(equalTo: bg.topAnchor, constant: Self.fieldHeight),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    /// Phase times of the last open, in ms (dev checks print them).
    private(set) static var lastOpenPhases: [(String, Double)] = []

    func open(over window: NSWindow?, mode: Mode = .commands) {
        let start = CACurrentMediaTime()
        var phases: [(String, Double)] = []
        var t = start
        func mark(_ name: String) { let n = CACurrentMediaTime(); phases.append((name, (n - t) * 1000)); t = n }
        parent = window
        self.mode = mode
        panel.appearance = window?.effectiveAppearance
        headings = nil
        commandRows = mode == .commands ? Self.collect(for: window) : nil
        if mode == .files, let files = FolderSidebar.shared?.quickOpenFiles {
            files.onUpdate = { [weak self] in
                guard let self, self.isOpen, case .files = self.showing else { return }
                self.filter(keepSelection: true)
            }
            files.ensure()
        }
        mark("collect")
        index = nil // prepared on the first keystroke: an empty query needs no scoring
        field.stringValue = ""
        field.placeholderString = mode == .commands ? String(localized: "Type a command")
            : String(localized: "Open quickly: a file name, # a heading, > a command")
        field.setAccessibilityLabel(mode == .commands ? String(localized: "Search commands") : String(localized: "Open Quickly"))
        fill()
        table.reloadData()
        mark("reload")
        resize()
        place()
        mark("frame")
        // Float on Top uses `.floating` (level 3). This panel is a child
        // ordered above, so AppKit keeps it — and a sheet — above that
        // parent. Raising the panel further would put it over a sheet
        // (modalPanel is 8; a sheet stays with its parent). Do not.
        if let window, panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        mark("place")
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        mark("order")
        selectFirstEnabled()
        panel.displayIfNeeded()
        mark("display")
        Self.lastOpenMilliseconds = (CACurrentMediaTime() - start) * 1000
        Self.lastOpenPhases = phases
        announceCount()
    }

    func close() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
        shown = []
        index = nil
        commandRows = nil
        headings = nil
        table.reloadData()
        parent?.makeKeyAndOrderFront(nil)
    }

    /// The top centre of the window, a little below its title bar.
    private func place() {
        let frame = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let top = parent.map { $0.contentLayoutRect.maxY + $0.frame.minY } ?? frame.maxY
        let size = panel.frame.size
        panel.setFrameTopLeftPoint(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (top - 8).rounded()))
    }

    private func resize() {
        let n = min(max(shown.count, 1), Self.visibleRows)
        let h = Self.fieldHeight + 1 + CGFloat(n) * Self.rowHeight
        var f = panel.frame
        f.origin.y += f.height - h
        f.size = NSSize(width: Self.width, height: h)
        panel.setFrame(f, display: false)
        empty.isHidden = !shown.isEmpty
        if shown.isEmpty { empty.stringValue = emptyText }
    }

    /// What the empty list says.
    var emptyText: String {
        switch showing {
        case .commands: return String(localized: "No matching commands")
        case .headings: return String(localized: "No matching headings")
        case .files:
            guard let side = FolderSidebar.shared else { return String(localized: "Open a folder (⇧⌘O) to find its files") }
            if side.quickOpenFiles.matcher == nil { return String(localized: "Indexing files…") }
            return String(localized: "No matching files")
        }
    }

    // MARK: The menu

    /// Every command in the main menu, validated for `window`.
    static func collect(for window: NSWindow?) -> [Row] {
        guard let main = NSApp.mainMenu else { return [] }
        var out: [Row] = []
        out.reserveCapacity(512)
        let skipMenus: [NSMenu?] = [NSApp.servicesMenu]
        let systemAdded = [#selector(NSApplication.orderFrontCharacterPalette(_:)), Selector(("startDictation:"))]
        func walk(_ menu: NSMenu, _ path: String) {
            if skipMenus.contains(where: { $0 === menu }) { return }
            let isWindowsMenu = menu === NSApp.windowsMenu
            for i in menu.items {
                if i.isSeparatorItem || i.isHidden || i.view != nil || i.title.isEmpty { continue }
                if let sub = i.submenu {
                    walk(sub, path.isEmpty ? i.title : "\(path) › \(i.title)")
                    continue
                }
                guard let action = i.action, action != #selector(AppDelegate.showCommandPalette(_:)) else { continue }
                if systemAdded.contains(action) { continue }
                // The Window menu's list of windows (wherever AppKit put it: anything that brings a window forward).
                if action == #selector(NSWindow.makeKeyAndOrderFront(_:)) || i.target is NSWindow
                    || (isWindowsMenu && i.representedObject is NSWindow) { continue }
                let enabled = validate(i, in: window, autoenables: menu.autoenablesItems)
                let shortcut = i.keyEquivalent.isEmpty ? "" : MenuShortcuts.name(i)
                // The title after validation (Detach/Attach Preview changes it there).
                let id = path.isEmpty ? i.title : "\(path) › \(i.title)"
                out.append(Row(target: .command(i), candidate: .init(id: id, title: i.title, path: path, enabled: enabled), shortcut: shortcut))
            }
        }
        let walkAll = {
            for top in main.items {
                guard let sub = top.submenu else { continue }
                walk(sub, top.title)
            }
        }
        if let app = NSApp.delegate as? AppDelegate { app.withValidationPass(walkAll) } else { walkAll() }
        return out
    }

    /// What `item`'s action is sent to from `window`: its own target, or
    /// the first responder of `window`'s chain (then the window, its
    /// delegate and controller, the app and its delegate) that implements
    /// it, as AppKit picks it for the key window. The palette's own panel
    /// is never asked, so the search field doesn't take Copy or Select All.
    static func target(for item: NSMenuItem, in window: NSWindow?) -> AnyObject? {
        guard let action = item.action else { return nil }
        if let t = item.target { return t }
        var chain: [AnyObject] = []
        var r: NSResponder? = window?.firstResponder
        while let cur = r { chain.append(cur); r = cur.nextResponder }
        if let window {
            chain.append(window)
            if let d = window.delegate { chain.append(d) }
            if let c = window.windowController { chain.append(c) }
        }
        chain.append(NSApp)
        if let d = NSApp.delegate { chain.append(d) }
        return chain.first { $0.responds(to: action) }
    }

    static func validate(_ item: NSMenuItem, in window: NSWindow?, autoenables: Bool = true) -> Bool {
        guard autoenables else { return item.isEnabled }
        guard let target = target(for: item, in: window) else { return false }
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        return true
    }

    // MARK: Running

    func runSelected() {
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { NSSound.beep(); return }
        let row = rows[shown[r]]
        guard row.candidate.enabled else { NSSound.beep(); return }
        let window = parent
        let item: NSMenuItem
        switch row.target {
        case .command(let i): item = i
        case .file(let url):
            close()
            Self.openFile(url)
            return
        case .heading(let h):
            let tab = window?.windowController as? EditorWindowController
            close()
            tab?.jump(to: h)
            return
        }
        close()
        guard let action = item.action, Self.validate(item, in: window) else { NSSound.beep(); return }
        Self.recents.note(row.candidate.id)
        let target = Self.target(for: item, in: window)
        NSApp.sendAction(action, to: target, from: item)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        runSelected()
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) { filter() }

    /// `keepSelection`: the file index changed under the list (not a
    /// keystroke): the selected row stays selected if it is still there.
    func filter(keepSelection: Bool = false) {
        let selectedID = keepSelection && table.selectedRow >= 0 && table.selectedRow < shown.count
            ? rows[shown[table.selectedRow]].candidate.id : nil
        fill()
        table.reloadData()
        resize()
        if let id = selectedID, let r = shown.firstIndex(where: { rows[$0].candidate.id == id }) {
            select(r, announce: false)
        } else {
            selectFirstEnabled()
        }
        announceCount()
    }

    /// `rows` and `shown` for the query in the field.
    private func fill() {
        showing = QuickOpen.parse(field.stringValue, filesMode: mode == .files)
        switch showing {
        case .commands(let q):
            if commandRows == nil { commandRows = Self.collect(for: parent) }
            rows = commandRows ?? []
            if q.trimmingCharacters(in: .whitespaces).isEmpty {
                shown = CommandIndex.emptyQueryOrder(rows.map(\.candidate), recent: Self.recents.ids)
            } else {
                if index == nil { index = CommandIndex(rows.map(\.candidate)) }
                shown = index!.rank(query: q, recent: Self.recents.ids)
            }
        case .headings(let q):
            rows = headingRows(q)
            shown = Array(rows.indices)
        case .files(let q):
            // The headings follow the files once something is typed (or
            // when there is no folder to list).
            let blank = q.trimmingCharacters(in: .whitespaces).isEmpty
            rows = fileRows(q) + (blank && FolderSidebar.shared != nil ? [] : headingRows(q))
            shown = Array(rows.indices)
        }
    }

    private func fileRows(_ q: String) -> [Row] {
        guard let side = FolderSidebar.shared else { return [] }
        let files = side.quickOpenFiles
        guard let m = files.matcher else { return [] }
        let top = files.root.lastPathComponent
        return m.rank(q).map { i in
            let rel = m.paths[i]
            let dir = (rel as NSString).deletingLastPathComponent
            return Row(target: .file(files.root.appendingPathComponent(rel)),
                       candidate: .init(id: "file:" + rel, title: m.name(i), path: dir.isEmpty ? top : top + "/" + dir),
                       shortcut: "")
        }
    }

    private func headingRows(_ q: String) -> [Row] {
        if headings == nil {
            let tab = parent?.windowController as? EditorWindowController
            headings = tab.map { $0.doc.language == .markdown ? MarkdownOutline.headings(in: $0.textView.string, limit: 5_000) : [] } ?? []
        }
        let hs = headings ?? []
        return QuickOpen.rankHeadings(hs, query: q).prefix(QuickOpen.shownLimit).map { i in
            let h = hs[i]
            return Row(target: .heading(h),
                       candidate: .init(id: "heading:\(h.line)", title: h.title,
                                        path: String(localized: "Heading \(h.level), line \(h.line + 1)")),
                       shortcut: "")
        }
    }

    /// Return on a file row: its tab (opened, or selected if open), shown
    /// in the sidebar, the text focused.
    static func openFile(_ url: URL) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        // A big file opens in the background: the same, when its tab is ready.
        app.open(url, background: true) { tab in
            tab.window?.makeKeyAndOrderFront(nil)
            tab.window?.makeFirstResponder(tab.textView)
            if let s = FolderSidebar.shared, s.isShown { s.reveal(tab.doc.fileURL) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(-Self.visibleRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(Self.visibleRows)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): close()
        default: return false
        }
        return true
    }

    func move(_ by: Int) {
        guard !shown.isEmpty else { NSSound.beep(); return }
        let cur = table.selectedRow
        let next = cur < 0 ? (by > 0 ? 0 : shown.count - 1) : min(max(cur + by, 0), shown.count - 1)
        select(next)
    }

    private func selectFirstEnabled() {
        if shown.isEmpty { table.deselectAll(nil); return }
        select(shown.firstIndex { rows[$0].candidate.enabled } ?? 0, announce: false)
    }

    private func select(_ r: Int, announce: Bool = true) {
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
        if announce { announceSelection() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes it, as a menu would.
        if panel.isVisible { close() }
    }

    // MARK: VoiceOver

    private func announce(_ s: String) {
        lastAnnouncement = s
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: s, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func announceCount() {
        let n: Int = shown.count
        if case .commands = showing {
            announce(n == 0 ? String(localized: "No matching commands")
                            : n == 1 ? String(localized: "1 command") : String(localized: "\(n) commands"))
        } else {
            announce(n == 0 ? emptyText : n == 1 ? String(localized: "1 result") : String(localized: "\(n) results"))
        }
    }

    func spoken(_ row: Row) -> String {
        var parts = [row.candidate.title]
        if !row.shortcut.isEmpty { parts.append(row.shortcut) }
        if !row.candidate.path.isEmpty { parts.append(row.candidate.path) }
        if !row.candidate.enabled { parts.append(String(localized: "dimmed")) }
        return parts.joined(separator: ", ")
    }

    private func announceSelection() {
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { return }
        announce(spoken(rows[shown[r]]))
    }

    /// The rows shown now, as "title" (dev checks).
    var shownTitles: [String] { shown.map { rows[$0].candidate.title } }
    var shownRows: [Row] { shown.map { rows[$0] } }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PaletteCell.id, owner: nil) as? PaletteCell) ?? PaletteCell()
        let r = rows[shown[row]]
        cell.show(r)
        cell.setAccessibilityLabel(spoken(r))
        return cell
    }
}

/// One row: the title, its menu path under it, the shortcut on the right.
@MainActor
final class PaletteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("paletteRow")
    let title = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let key = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.font = .systemFont(ofSize: 13)
        path.font = .systemFont(ofSize: 10.5)
        key.font = .systemFont(ofSize: 12)
        key.alignment = .right
        for f in [title, path] { f.lineBreakMode = .byTruncatingTail; f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [title, path, key] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -10),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            path.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -10),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ r: CommandPalette.Row) {
        title.stringValue = r.candidate.title
        path.stringValue = r.candidate.path
        key.stringValue = r.shortcut
        let on = r.candidate.enabled
        title.textColor = on ? .labelColor : .disabledControlTextColor
        path.textColor = on ? .secondaryLabelColor : .disabledControlTextColor
        key.textColor = on ? .secondaryLabelColor : .disabledControlTextColor
    }
}

/// A borderless panel that can take the keyboard (for its search field)
/// but never becomes the main window, so the editor stays the window the
/// menus act on.
final class PalettePanel: NSPanel {
    weak var palette: CommandPalette?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { palette?.close() }
}

extension AppDelegate {
    @objc func showCommandPalette(_ sender: Any?) {
        let key = NSApp.keyWindow
        let over = (key is PalettePanel ? nil : key) ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && !($0 is PalettePanel) && $0.windowController != nil }
        CommandPalette.toggle(over: over)
    }
}
