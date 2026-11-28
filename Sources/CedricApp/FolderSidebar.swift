import AppKit
import CedricCore

/// The folder sidebar (0.2.0): File › Open Folder… (⇧⌘O) and View › Show
/// Folder Sidebar (⌃⌘1). One app-wide sidebar, docked at the left of the
/// selected tab's split and re-docked when another tab becomes key, like
/// Find in Files (plan-0.2.0.md §6). Nothing exists until a folder is
/// opened: no view, no listing, no FSEvents stream; a folder saved in the
/// session with the sidebar hidden is only remembered (`pendingFolder`).
extension AppDelegate {
    @objc func openFolderMenu(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open Folder")
        if let dir = FolderSidebar.shared?.rootURL ?? currentTab?.doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    @objc func toggleFolderSidebarMenu(_ sender: Any?) {
        if let s = FolderSidebar.shared {
            if s.isShown { s.hide() }
            else if let viewer = currentViewerTab { s.show(in: viewer) }
            else if let tab = currentTab ?? tabs.last { s.show(in: tab) }
            scheduleSessionSave()
        } else if let p = FolderSidebar.pendingFolder {
            // Saved in the session while hidden: built now, on first use.
            openFolder(URL(fileURLWithPath: p.path, isDirectory: true), state: p)
        }
    }

    /// The file in the selected tab (a text tab or a viewer tab); nil when
    /// untitled.
    var currentFileURL: URL? { currentTab?.doc.fileURL ?? currentViewerTab?.fileURL }

    /// File › Open Enclosing Folder (⌥⇧⌘O): the folder holding the tab's
    /// file opens in the sidebar, with the file selected.
    @objc func openEnclosingFolderMenu(_ sender: Any?) {
        guard let file = currentFileURL, let dir = FolderTree.enclosingFolder(of: file) else { NSSound.beep(); return }
        openFolder(dir, reveal: file)
    }

    /// File › Reveal in Finder: the tab's file selected in a Finder window.
    @objc func revealFileInFinderMenu(_ sender: Any?) {
        guard let file = currentFileURL else { NSSound.beep(); return }
        PreviewLinkLog.reveal(file)
    }

    func validateFolderItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(openFolderMenu(_:)): return true
        // The sidebar docks in a text tab: none open, nothing to dock in.
        case #selector(openEnclosingFolderMenu(_:)):
            return FolderTree.enclosingFolder(of: currentFileURL) != nil && (currentTab ?? tabs.last) != nil
        case #selector(revealFileInFinderMenu(_:)): return currentFileURL != nil
        case #selector(openInTerminalMenu(_:)): return TerminalHere.folder(forDocument: currentFileURL) != nil
        case #selector(toggleFolderSidebarMenu(_:)):
            setShowHide(item, shown: FolderSidebar.shared?.isShown == true,
                        show: String(localized: "Show Folder Sidebar"), hide: String(localized: "Hide Folder Sidebar"))
            return (FolderSidebar.shared != nil || FolderSidebar.pendingFolder != nil) && (currentViewerTab != nil || (currentTab ?? tabs.last) != nil)
        default: return nil
        }
    }

    /// A folder (not a package): opened in the sidebar rather than as a file.
    static func isFolder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return v.isDirectory == true && v.isPackage != true
    }

    /// Opens `url` in the folder sidebar (replacing the folder open before)
    /// and shows it in the selected tab. `state`: restoring a session.
    /// `reveal`: a file to select once the folder is listed.
    /// `dock`: shows the sidebar in a given tab instead (text or viewer);
    /// false if that tab has gone, and the selected tab is used.
    func openFolder(_ url: URL, state: SessionFolder? = nil, reveal: URL? = nil, dock: ((FolderSidebar) -> Bool)? = nil) {
        // At launch (a folder dropped on the Dock icon, CEDRIC_OPEN): after
        // the first frame, once the window's tab exists.
        guard AfterFirstFrame.passed, dock != nil || (currentTab ?? tabs.last) != nil else {
            AfterFirstFrame.run { [weak self] in
                guard let self, AfterFirstFrame.passed, dock != nil || (self.currentTab ?? self.tabs.last) != nil else { return }
                self.openFolder(url, state: state, reveal: reveal, dock: dock)
            }
            return
        }
        FolderSidebar.shared?.close()
        FolderSidebar.pendingFolder = nil
        let s = FolderSidebar(root: url.standardizedFileURL, state: state)
        FolderSidebar.shared = s
        s.pendingReveal = reveal
        s.onOpen = { [weak self] node in self?.openFromFolder(node) }
        s.onCreateFile = { [weak self] node in self?.openFromFolder(node, asText: true) }
        s.onChange = { [weak self] in self?.scheduleSessionSave() }
        s.onClose = { [weak self] in self?.closeFolder() }
        s.onOpenEnclosing = { [weak self] file in
            guard let dir = FolderTree.enclosingFolder(of: file) else { return }
            self?.openFolder(dir, reveal: file)
        }
        s.onRename = { [weak self] old, new, directory in self?.folderItemRenamed(old, to: new, directory: directory) }
        s.onTrash = { [weak self] url, directory in self?.folderItemTrashed(url, directory: directory) }
        s.onPrepareFileOperation = { [weak self] in self?.finishRestore() }
        s.onFindInFolder = { [weak self] dir in
            guard let self else { return }
            self.findInFilesMenu(nil)
            self.findInFiles?.folderField.stringValue = dir.path
        }
        if state?.visible ?? true, dock?(s) != true, let tab = currentTab ?? tabs.last { s.show(in: tab) }
        // Backlinks and Tags panes follow the new folder (the notification);
        // an open `[[` list goes (wikiFolderChanged).
        NotificationCenter.default.post(name: WikiNotes.didChange, object: nil)
        tabs.forEach { $0.wikiFolderChanged() }
        scheduleSessionSave()
    }

    // MARK: Opening a file from outside the app (0.6.1)

    /// Opens files the user opened from outside the app: File › Open,
    /// Open Recent, Finder / Open With / a file dropped on the Dock icon
    /// (`application(_:open:)`, and the files a launch was given there,
    /// with CEDRIC_OPEN in check builds: the same loop), a file dropped on
    /// a window or its text (`FileDrop.open`) and the cedric script
    /// (`cedric://open?path=`). Opens from inside the app (a sidebar
    /// click, Quick Open, wiki and preview links, Find in Files, the owl,
    /// Replace in Files, session restore) call `open` and never switch.
    ///
    /// The decision (0.6.1 bug 1, `FolderTree.folderToSwitchTo`): the
    /// folder sidebar switches to the file's folder, the file selected
    /// once it is listed, only when a folder is loaded AND its sidebar is
    /// shown (hidden, only remembered from the session, or none: nothing
    /// is loaded, the 0.2.0 rule) AND the file is a regular file outside
    /// the loaded folder (links resolved on both sides: a path through a
    /// link into the folder is inside). Then the sidebar docks in the
    /// file's own tab (a text tab, a PDF, image, Office or certificate
    /// tab, or a big file's tab once its background read is done). A
    /// refused or failed open switches nothing; other tabs and unsaved
    /// text are untouched. A file already open, opened again from
    /// outside, switches too (its tab comes to the front). Of several
    /// files opened at once only the last switches the folder: it is the
    /// one whose tab ends up in front.
    func openFromOutside(_ urls: [URL]) {
        for (i, u) in urls.enumerated() { openFromOutside(u, switchesFolder: i == urls.count - 1) }
    }

    @discardableResult
    func openFromOutside(_ url: URL, switchesFolder: Bool = true, then: ((EditorWindowController) -> Void)? = nil,
                         failed: (() -> Void)? = nil) -> EditorWindowController? {
        let std = url.standardizedFileURL
        let tab = open(url, background: true, then: { [weak self] tab in
            if switchesFolder {
                self?.switchFolder(forOutsideOpenOf: tab.doc.fileURL ?? std) { [weak tab] s in
                    guard let tab, self?.tabs.contains(where: { $0 === tab }) == true else { return false }
                    s.show(in: tab)
                    return true
                }
            }
            then?(tab)
        }, failed: failed)
        // A viewer tab (made now, or brought to the front): no `then`.
        if switchesFolder, tab == nil, backgroundOpens[std] == nil, let viewer = viewerTab(for: std) {
            switchFolder(forOutsideOpenOf: viewer.fileURL) { [weak self] s in
                guard let self, let v = self.viewerTab(for: std), v === viewer, v.sidebarHost?.split != nil else { return false }
                s.show(in: v)
                return true
            }
        }
        return tab
    }

    /// `file`'s tab is there: switches the sidebar to its folder if
    /// `FolderTree.folderToSwitchTo` says so. At launch, after the first
    /// frame, once a sidebar saved in the session is rebuilt (its
    /// `restoreFolder` block is queued before the launch's files open).
    private func switchFolder(forOutsideOpenOf file: URL, dock: @escaping (FolderSidebar) -> Bool) {
        guard AfterFirstFrame.passed else {
            AfterFirstFrame.run { [weak self] in self?.switchFolder(forOutsideOpenOf: file, dock: dock) }
            return
        }
        guard let s = FolderSidebar.shared,
              let dir = FolderTree.folderToSwitchTo(opening: file, loadedRoot: s.rootURL, sidebarShown: s.isShown) else { return }
        openFolder(dir, reveal: file, dock: dock)
    }

    func closeFolder() {
        FolderSidebar.shared?.close()
        FolderSidebar.shared = nil
        FolderSidebar.pendingFolder = nil
        NotificationCenter.default.post(name: WikiNotes.didChange, object: nil)
        tabs.forEach { $0.wikiFolderChanged() }
        if let t = currentTab { t.window?.makeFirstResponder(t.textView) }
        scheduleSessionSave()
    }

    func openFromFolder(_ node: FolderNode, asText: Bool = false) {
        guard let s = FolderSidebar.shared else { return }
        // Keep the tree beside the file it opened (the tab may not become
        // key when the app isn't active). A big file is read in the
        // background: the same when its tab comes.
        let beside: (EditorWindowController) -> Void = { tab in
            guard FolderSidebar.shared === s, s.isShown else { return }
            s.show(in: tab)
            s.reveal(tab.doc.fileURL)
            tab.window?.makeFirstResponder(s.outline)
        }
        let tab = open(node.url, asText: asText, background: true, then: beside)
        if tab != nil || backgroundOpens[node.url.standardizedFileURL] != nil {
            return
        } else if s.isShown, let viewer = viewerTab(for: node.url) {
            s.show(in: viewer)
            s.reveal(viewer.fileURL)
            viewer.window?.makeFirstResponder(s.outline)
        }
    }

    /// AppDelegate.tabBecameKey: the sidebar follows the selected tab.
    func folderSidebarFollow(_ tab: EditorWindowController) {
        guard let s = FolderSidebar.shared, s.isShown else { return }
        s.show(in: tab)
        s.reveal(tab.doc.fileURL)
    }

    func folderSidebarFollow(_ viewer: any ViewerTab) {
        guard let s = FolderSidebar.shared, s.isShown else { return }
        s.show(in: viewer)
        s.reveal(viewer.fileURL)
    }

    func folderItemRenamed(_ old: URL, to new: URL, directory: Bool) {
        finishRestore()
        for tab in tabs {
            guard let url = tab.doc.fileURL,
                  let moved = FolderActions.movedURL(url, from: old, to: new, directory: directory) else { continue }
            tab.doc.fileURL = moved
            if tab.doc.missingOnDisk {
                tab.doc.missingOnDisk = false
                tab.hideDiskBar()
            }
            tab.updateTitle()
            tab.gitSaved()
        }
        for viewer in viewerTabs {
            if let moved = FolderActions.movedURL(viewer.fileURL, from: old, to: new, directory: directory) {
                viewer.followRename(moved)
            }
        }
        scheduleSessionSave()
    }

    func folderItemTrashed(_ url: URL, directory: Bool) {
        finishRestore()
        for tab in tabs {
            guard let file = tab.doc.fileURL,
                  FolderActions.movedURL(file, from: url, to: url, directory: directory) != nil else { continue }
            tab.showFileMissing()
        }
        for viewer in viewerTabs where FolderActions.movedURL(viewer.fileURL, from: url, to: url, directory: directory) != nil {
            viewer.sidebarHost?.showMissing(viewer.fileURL)
        }
        scheduleSessionSave()
    }

    /// For the session: the open folder (built or only remembered).
    var folderSessionState: SessionFolder? {
        FolderSidebar.shared?.sessionState ?? FolderSidebar.pendingFolder
    }

    /// From the session: a visible sidebar is rebuilt after the first
    /// frame (it shows a frame later rather than slowing launch); a hidden
    /// one is only remembered until View › Show Folder Sidebar.
    func restoreFolder(_ f: SessionFolder?) {
        guard let f else { return }
        FolderSidebar.pendingFolder = f
        guard f.visible else { return }
        AfterFirstFrame.run { [weak self] in
            guard let self, FolderSidebar.shared == nil, let p = FolderSidebar.pendingFolder, p == f else { return }
            guard Self.isFolder(URL(fileURLWithPath: f.path)) else { FolderSidebar.pendingFolder = nil; return }
            self.openFolder(URL(fileURLWithPath: f.path, isDirectory: true), state: f)
        }
    }
}

/// The outline view: Return opens the selected file (or toggles a folder);
/// a right click selects the row under it before the context menu.
@MainActor
final class FolderOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        if row < 0 { deselectAll(nil) }
        return super.menu(for: event)
    }
}

/// The sidebar view: a header with the folder's name and a close button,
/// and a view-based outline of the folder. Only expanded folders are
/// listed, off the main thread; FSEvents re-list the loaded folders that
/// changed and the rows are inserted/removed in place (expansion and
/// selection kept).
@MainActor
final class FolderSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    /// The one sidebar (nil until a folder is opened).
    static var shared: FolderSidebar?
    /// A folder from the session whose sidebar was hidden: nothing built.
    static var pendingFolder: SessionFolder?
    static let defaultWidth: CGFloat = 240

    let rootURL: URL
    let root: FolderNode
    /// The root's real path (symbolic links resolved): FSEvents report those.
    let realRoot: String
    /// The root, pinned by descriptor when the folder is opened: a note
    /// made from a wiki link is created beneath it (nil: it couldn't be
    /// opened, and no note is created).
    let folderRoot: FolderRoot?
    let outline = FolderOutlineView()
    let scroll = NSScrollView()
    let title = NSTextField(labelWithString: "")
    private let headerMenu = NSMenu()
    private(set) var isShown = false
    private(set) var width: CGFloat
    private(set) var showHidden: Bool
    private(set) var watcher: FolderWatcher?
    /// File › Open Quickly's index of this folder, once used (QuickOpenFiles.swift).
    var quickOpen: QuickOpenFiles?
    /// The `[[` note names and Backlinks of this folder, once used (WikiLinksApp.swift).
    var wikiNotes: WikiNotes?
    /// Dims git-ignored entries: reads a .gitignore only when a listing
    /// reaches its folder (FolderIgnore), never walks the tree.
    let ignore: FolderIgnore
    /// Folders that changed while their listing was under way: listed again after it.
    private var relistAfterLoad = Set<ObjectIdentifier>()
    /// Folders to expand once listed (restoring a session): relative paths.
    private var pendingExpand: [String]
    /// Width changes come from the user (divider drags) only once docked.
    private var tracksWidth = false
    private var enforcingWidth = false
    private var splitObserver: NSObjectProtocol?
    /// Listings applied, and the last one's folder (the check waits on them).
    private(set) var listings = 0
    var onListed: ((FolderNode) -> Void)?
    var onOpen: ((FolderNode) -> Void)?
    var onCreateFile: ((FolderNode) -> Void)?
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    var onFindInFolder: ((URL) -> Void)?
    var onOpenEnclosing: ((URL) -> Void)?
    var onRename: ((URL, URL, Bool) -> Void)?
    var onTrash: ((URL, Bool) -> Void)?
    var onPrepareFileOperation: (() -> Void)?
    private var renamingNode: FolderNode?
    /// Selected when the root is first listed (Open Enclosing Folder).
    var pendingReveal: URL?
    /// Hidden items shown after being created or renamed here.
    private var revealedHiddenURLs = Set<URL>()

    init(root url: URL, state: SessionFolder? = nil) {
        rootURL = url
        root = FolderNode(root: url)
        realRoot = Self.realPath(url.path)
        folderRoot = try? FolderRoot(url)
        ignore = FolderIgnore(root: url)
        width = state?.width.map { CGFloat($0) } ?? Self.defaultWidth
        showHidden = state?.showHidden ?? false
        pendingExpand = state?.expanded ?? []
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        clipsToBounds = true
        build()
        load(root)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // Views don't clip to their bounds since macOS 14: fill only our part.
        dirtyRect.intersection(bounds).fill()
    }

    private func build() {
        title.stringValue = rootURL.lastPathComponent
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = rootURL.path
        let close = NSButton(title: "", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Folder"))!,
                             target: self, action: #selector(closeFolder(_:)))
        close.setAccessibilityLabel(String(localized: "Close Folder"))
        close.isBordered = false
        close.identifier = .init("folder-close")
        let actions = NSPopUpButton(frame: .zero, pullsDown: true)
        let actionsLabel = String(localized: "Folder Actions")
        actions.setAccessibilityLabel(actionsLabel)
        actions.toolTip = actionsLabel
        actions.isBordered = false
        actions.controlSize = .small
        (actions.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        headerMenu.autoenablesItems = false
        headerMenu.delegate = self
        let menuTitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuTitle.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: actionsLabel)
        headerMenu.addItem(menuTitle)
        actions.menu = headerMenu
        actions.identifier = .init("folder-actions")
        let col = NSTableColumn(identifier: .init("name"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 20
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onReturn = { [weak self] in self?.activateSelection() }
        outline.setAccessibilityLabel(String(localized: "Folder"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(title)
        addSubview(actions)
        addSubview(close)
        addSubview(scroll)
    }

    override func layout() {
        super.layout()
        let close = subviews.first { $0.identifier?.rawValue == "folder-close" }
        close?.frame = NSRect(x: bounds.width - 26, y: 5, width: 20, height: 20)
        let actions = subviews.first { $0.identifier?.rawValue == "folder-actions" }
        actions?.frame = NSRect(x: bounds.width - 50, y: 5, width: 20, height: 20)
        title.frame = NSRect(x: 10, y: 7, width: max(0, bounds.width - 64), height: 16)
        scroll.frame = NSRect(x: 0, y: 28, width: bounds.width, height: max(0, bounds.height - 28))
        outline.tableColumns.first?.width = scroll.contentSize.width
    }

    /// The split it is docked in resized its panes. The user dragging a
    /// divider of that split (not a live window resize): the new width is
    /// kept and saved. Anything else (the window resized, a panel docked
    /// or closed, even by a click like the × of Find in Files: NSSplitView
    /// shares the space out by proportion, whatever the holding
    /// priorities): our width back, the editor takes the difference.
    private func splitResized() {
        guard let split = superview as? NSSplitView, let w = window, !enforcingWidth, tracksWidth else { return }
        guard abs(frame.width - width) >= 1 else { return }
        let dragging = (split as? PaneSplitView)?.isDraggingDivider == true
        if dragging && !w.inLiveResize {
            if frame.width >= 120 { width = frame.width; onChange?() }
            return
        }
        restoreWidth()
    }

    /// A pane right of the sidebar docked in or left `split`: if the
    /// sidebar is docked there, the panes are laid out again and it gets
    /// its width back (NSSplitView would share the change by proportion).
    static func keepWidth(in split: NSSplitView?) {
        guard let split, let s = shared, s.superview === split else { return }
        split.adjustSubviews()
        s.restoreWidth()
    }

    /// Back to the width the user chose (a right-side panel docked or
    /// closed, the window resized): the editor takes the difference.
    func restoreWidth() {
        guard let split = superview as? NSSplitView, !enforcingWidth, abs(frame.width - width) >= 1 else { return }
        guard split.bounds.width > width + 200 else { return }
        enforcingWidth = true
        split.setPosition(width, ofDividerAt: 0)
        enforcingWidth = false
    }

    // MARK: Showing

    /// Docks the sidebar at the left of `tab` (nothing if it is there), and
    /// starts watching the folder.
    func show(in tab: EditorWindowController) {
        show(in: tab.split)
    }

    func show(in viewer: any ViewerTab) {
        guard let split = viewer.sidebarHost?.split else { return }
        show(in: split)
    }

    private func show(in split: NSSplitView) {
        let wasShown = isShown
        isShown = true
        if superview !== split {
            tracksWidth = false
            undock()
            split.insertArrangedSubview(self, at: 0)
            split.adjustSubviews()
            split.setHoldingPriority(.init(260), forSubviewAt: 0)
            if split.bounds.width > 0 { split.setPosition(min(width, split.bounds.width * 0.5), ofDividerAt: 0) }
            split.layoutSubtreeIfNeeded()
            splitObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.splitResized() }
            }
            // Once the split has its final size, the width the user chose.
            DispatchQueue.main.async { [weak self, weak split] in
                guard let self, let split, self.superview === split else { return }
                if abs(self.frame.width - self.width) >= 1, split.bounds.width > self.width + 200 {
                    split.setPosition(self.width, ofDividerAt: 0)
                }
                self.tracksWidth = true
            }
        }
        if !wasShown {
            // Hidden meant no stream: what changed meanwhile, listed once.
            if root.isLoaded { for n in root.loadedFolders { load(n) } }
            startWatching()
        }
    }

    /// View › Show Folder Sidebar off: out of the window, no stream.
    func hide() {
        isShown = false
        watcher?.stop()
        watcher = nil
        quickOpen?.markStale()
        wikiNotes?.markAllDirty()
        let w = window
        undock()
        if let w, let tab = (NSApp.delegate as? AppDelegate)?.tabs.first(where: { $0.window === w }) { w.makeFirstResponder(tab.textView) }
    }

    /// Close Folder: hidden and forgotten.
    func close() {
        hide()
        onListed = nil
    }

    private func undock() {
        let split = superview as? NSSplitView
        if let split, let i = split.arrangedSubviews.firstIndex(of: self) {
            // Its holding priority shouldn't stay with whatever lands at its index.
            split.setHoldingPriority(.defaultLow, forSubviewAt: i)
        }
        tracksWidth = false
        if let o = splitObserver { NotificationCenter.default.removeObserver(o) }
        splitObserver = nil
        removeFromSuperview()
        // Redistribute now, and lay out remaining panes (the editor's
        // gutter and scroll view, or a viewer) so they fill at once.
        if let split {
            split.adjustSubviews()
            if split.arrangedSubviews.count == 1 {
                split.arrangedSubviews[0].frame = split.bounds
            }
            split.layoutSubtreeIfNeeded()
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let ref = WeakRef(self)
        let w = FolderWatcher(root: realRoot) { changes in
            MainActor.assumeIsolated { ref.value?.handle(changes) }
        }
        watcher = w
        w.start()
    }

    var isWatching: Bool { watcher?.isRunning == true }

    // MARK: Listing

    /// Lists `node` off the main thread (again, if it was loaded: the rows
    /// that changed are inserted and removed in place).
    func load(_ node: FolderNode) {
        guard node.isDirectory else { return }
        if node.isLoading { relistAfterLoad.insert(ObjectIdentifier(node)); return }
        if node.entry.isSymlink, FolderTree.wouldLoop(node.url, ancestors: node.ancestors.map(\.url)) {
            // A link back up the tree: shown, never expanded into.
            node.loadError = String(localized: "Links to a folder above it")
            apply([], to: node)
            return
        }
        node.isLoading = true
        let url = node.url, hidden = showHidden, ignore = ignore
        let revealed = Set(revealedHiddenURLs
            .filter { $0.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL }
            .map(\.lastPathComponent))
        let ref = WeakRef(self), box = MainBox(value: node)
        DispatchQueue.global(qos: .userInitiated).async {
            var entries: [FolderEntry] = []
            var failure: String?
            do { entries = try FolderTree.list(url, showHidden: hidden, ignore: ignore, revealed: revealed) } catch { failure = error.localizedDescription }
            let result = MainBox(value: (entries, failure))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value.isLoading = false
                    box.value.loadError = result.value.1
                    ref.value?.apply(result.value.0, to: box.value)
                }
            }
        }
    }

    private func isInTree(_ node: FolderNode) -> Bool {
        var n = node
        while let p = n.parent {
            guard p.children?.contains(where: { $0 === n }) == true else { return false }
            n = p
        }
        return n === root
    }

    private func apply(_ entries: [FolderEntry], to node: FolderNode) {
        guard isInTree(node) else { return }
        let wasLoaded = node.isLoaded
        let diff = node.apply(entries)
        let item: Any? = node === root ? nil : node
        if !wasLoaded {
            if node === root { outline.reloadData() } else { outline.reloadItem(node, reloadChildren: true) }
        } else if !diff.isEmpty {
            outline.beginUpdates()
            if !diff.removed.isEmpty { outline.removeItems(at: IndexSet(diff.removed), inParent: item, withAnimation: []) }
            if !diff.inserted.isEmpty { outline.insertItems(at: IndexSet(diff.inserted), inParent: item, withAnimation: []) }
            outline.endUpdates()
        }
        // Kept rows whose flags changed (a .gitignore edited): redrawn in place.
        if wasLoaded, let children = node.children {
            for i in diff.changed where i < children.count { outline.reloadItem(children[i], reloadChildren: false) }
        }
        listings += 1
        // Restoring: the folders that were expanded, top-down, as their parents land.
        if !pendingExpand.isEmpty, let children = node.children {
            let base = relativePath(node)
            for c in children where c.isDirectory {
                let rel = base.isEmpty ? c.name : base + "/" + c.name
                if let i = pendingExpand.firstIndex(of: rel) {
                    pendingExpand.remove(at: i)
                    outline.expandItem(c)
                }
            }
        }
        if let u = pendingReveal, u.deletingLastPathComponent().standardizedFileURL == node.url.standardizedFileURL,
           let rel = FolderTree.relativePath(of: u, in: rootURL), let found = root.descendant(rel),
           outline.row(forItem: found) >= 0 {
            pendingReveal = nil
            reveal(u)
        }
        onListed?(node)
        if relistAfterLoad.remove(ObjectIdentifier(node)) != nil { load(node) }
    }

    func relativePath(_ node: FolderNode) -> String {
        FolderTree.relativePath(of: node.url, in: rootURL) ?? ""
    }

    /// FSEvents (FolderWatcher): re-list the loaded folders that changed;
    /// events under folders never expanded cost a path walk.
    func handle(_ changes: [FolderWatcher.Change]) {
        wikiNotes?.handle(changes)
        quickOpen?.handle(changes)
        guard isShown, root.isLoaded else { return }
        // A .gitignore (or info/exclude) may have changed: read them again,
        // as each folder is listed again.
        ignore.invalidate()
        var toList: [FolderNode] = []
        // The event's folder as the tree lists it: by the bytes, else by
        // identity from the root down (a case or normalization variant of
        // a listed name, or of the root, is that folder); one gone under
        // another spelling lists its nearest listed ancestor again. A miss
        // alone never leaves a loaded folder stale.
        let root = root, rootURL = rootURL
        func node(for path: String) -> FolderNode? {
            guard let e = FolderTree.eventRelativePath(path, roots: [URL(fileURLWithPath: realRoot), rootURL]) else { return nil }
            if let n = root.listedDescendant(e.rel) { return n }
            let found = FolderTree.listedFolder(e.rel, base: e.base, root: rootURL) { key in
                root.listedDescendant(key)?.children?.filter(\.isDirectory).map(\.name)
            }
            switch found {
            case .listed(let k), .ancestor(let k): return root.listedDescendant(k)
            case .unlisted: return nil
            }
        }
        for c in changes {
            switch c {
            case .rootChanged:
                if !AppDelegate.isFolder(rootURL) { onClose?(); return }
                toList += root.loadedFolders
            case .folder(let p):
                guard let n = node(for: p), n.isLoaded else { break }
                // A folder with a .gitignore: what it ignores can change below it too.
                if FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".gitignore")) {
                    toList += n.loadedFolders
                } else {
                    toList.append(n)
                }
            case .subtree(let p):
                if let n = node(for: p) { toList += n.loadedFolders }
            }
        }
        var seen = Set<ObjectIdentifier>()
        for n in toList where seen.insert(ObjectIdentifier(n)).inserted { load(n) }
    }

    // MARK: Session

    var sessionState: SessionFolder {
        // Not a link that loops (it lists nothing).
        let expanded = root.loadedFolders.dropFirst().filter { $0.loadError == nil && outline.isItemExpanded($0) }.map(relativePath)
        return SessionFolder(path: rootURL.path, visible: isShown, width: Double(width),
                             expanded: expanded.isEmpty ? nil : Array(expanded.prefix(SessionFolder.expandedLimit)),
                             showHidden: showHidden ? true : nil)
    }

    // MARK: Selection

    /// Selects the row of `url` if its folder is listed and expanded (no
    /// folder is expanded for it).
    func reveal(_ url: URL?) {
        guard let url, let rel = FolderTree.relativePath(of: url.standardizedFileURL, in: rootURL), !rel.isEmpty,
              let n = root.descendant(rel) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, outline.selectedRow != row else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    var selectedNode: FolderNode? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FolderNode : nil
    }

    /// Single click: a file opens in a tab (or its tab is selected).
    @objc func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? FolderNode, !n.isDirectory else { return }
        onOpen?(n)
    }

    /// Double click: a folder expands or collapses; a file opens, as one click.
    @objc func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? FolderNode else { return }
        toggleOrOpen(n)
    }

    func activateSelection() {
        guard outline.selectedRow >= 0, let n = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
        toggleOrOpen(n)
    }

    private func toggleOrOpen(_ n: FolderNode) {
        if n.isDirectory {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        } else {
            onOpen?(n)
        }
    }

    @objc func closeFolder(_ sender: Any?) { onClose?() }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            updateHeaderMenu()
            return
        }
        menu.removeAllItems()
        let n = selectedNode
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = n
            menu.addItem(i)
        }
        add(String(localized: "New File…"), #selector(newFile(_:)))
        add(String(localized: "New Folder…"), #selector(newFolder(_:)))
        if n != nil {
            add(String(localized: "Rename"), #selector(renameItem(_:)))
            add(String(localized: "Move to Trash…"), #selector(trashItem(_:)))
            menu.addItem(.separator())
            add(String(localized: "Reveal in Finder"), #selector(revealInFinder(_:)))
            add(String(localized: "Open in Terminal Here"), #selector(openInTerminal(_:)))
            // A file below the root: its own folder as the sidebar's root.
            if let n, !n.isDirectory, n.url.deletingLastPathComponent().standardizedFileURL.path != rootURL.standardizedFileURL.path {
                add(String(localized: "Open Enclosing Folder"), #selector(openEnclosing(_:)))
            }
            add(String(localized: "Copy Path"), #selector(copyPath(_:)))
            add(String(localized: "Find in Folder…"), #selector(findInFolder(_:)))
            menu.addItem(.separator())
        }
        add(String(localized: "Show Hidden Files"), #selector(toggleHidden(_:)))
        menu.items.last?.state = showHidden ? .on : .off
        add(String(localized: "Close Folder"), #selector(closeFolder(_:)))
    }

    func updateHeaderMenu() {
        let menuTitle = headerMenu.items.first ?? NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerMenu.removeAllItems()
        headerMenu.addItem(menuTitle)
        let selection: FolderSidebarMenu.Selection
        if let node = selectedNode {
            if node.isDirectory {
                selection = .folder
            } else {
                selection = .file(parentIsRoot: node.url.deletingLastPathComponent().standardizedFileURL.path == rootURL.standardizedFileURL.path)
            }
        } else {
            selection = .none
        }
        let anyExpanded = (0..<outline.numberOfRows).contains { row in
            guard let node = outline.item(atRow: row) as? FolderNode else { return false }
            return outline.isItemExpanded(node)
        }
        let state = FolderSidebarMenu.State(selection: selection, anyExpanded: anyExpanded, showHidden: showHidden)
        for item in FolderSidebarMenu.items(for: state) {
            switch item {
            case .separator:
                headerMenu.addItem(.separator())
            case let .command(command, isEnabled, isChecked):
                let menuItem = NSMenuItem(title: Self.title(for: command), action: Self.action(for: command), keyEquivalent: "")
                menuItem.isEnabled = isEnabled
                menuItem.state = isChecked.map { $0 ? .on : .off } ?? .off
                if command == .openFolder {
                    menuItem.target = NSApp.delegate
                } else {
                    menuItem.target = self
                    menuItem.representedObject = selectedNode ?? root
                }
                headerMenu.addItem(menuItem)
            }
        }
    }

    private static func title(for command: FolderSidebarMenu.Command) -> String {
        switch command {
        case .newFile: String(localized: "New File…")
        case .newFolder: String(localized: "New Folder…")
        case .rename: String(localized: "Rename")
        case .moveToTrash: String(localized: "Move to Trash…")
        case .revealInFinder: String(localized: "Reveal in Finder")
        case .openInTerminal: String(localized: "Open in Terminal Here")
        case .openEnclosingFolder: String(localized: "Open Enclosing Folder")
        case .copyPath: String(localized: "Copy Path")
        case .findInFolder: String(localized: "Find in Folder…")
        case .refresh: String(localized: "Refresh")
        case .collapseAll: String(localized: "Collapse All")
        case .showHiddenFiles: String(localized: "Show Hidden Files")
        case .openFolder: String(localized: "Open Folder…")
        case .closeFolder: String(localized: "Close Folder")
        }
    }

    private static func action(for command: FolderSidebarMenu.Command) -> Selector {
        switch command {
        case .newFile: #selector(newFile(_:))
        case .newFolder: #selector(newFolder(_:))
        case .rename: #selector(renameItem(_:))
        case .moveToTrash: #selector(trashItem(_:))
        case .revealInFinder: #selector(revealInFinder(_:))
        case .openInTerminal: #selector(openInTerminal(_:))
        case .openEnclosingFolder: #selector(openEnclosing(_:))
        case .copyPath: #selector(copyPath(_:))
        case .findInFolder: #selector(findInFolder(_:))
        case .refresh: #selector(refresh(_:))
        case .collapseAll: #selector(collapseAll(_:))
        case .showHiddenFiles: #selector(toggleHidden(_:))
        case .openFolder: #selector(AppDelegate.openFolderMenu(_:))
        case .closeFolder: #selector(closeFolder(_:))
        }
    }

    private func target(_ sender: Any?) -> FolderNode {
        ((sender as? NSMenuItem)?.representedObject as? FolderNode) ?? selectedNode ?? root
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func checkVisibleName(_ name: String) throws {
        if FolderTree.alwaysHidden.contains(name) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "“\(name)” is always hidden in the folder sidebar.")])
        }
    }

    private func createItem(_ sender: Any?, directory: Bool) {
        let target = target(sender)
        let parent = target.isDirectory ? target : target.parent ?? root
        let alert = NSAlert()
        alert.messageText = directory ? String(localized: "New Folder") : String(localized: "New File")
        alert.informativeText = String(localized: "Enter a name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.setAccessibilityLabel(String(localized: "Name"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try createItem(named: field.stringValue, in: parent, directory: directory)
        } catch { showError(error) }
    }

    func createItem(named name: String, in parent: FolderNode, directory: Bool) throws {
        try checkVisibleName(name)
        let url = try FolderActions.create(in: parent.url, name: name, directory: directory)
        revealAfterChange(url, in: parent)
        if !directory {
            let node = FolderNode(url: url, entry: FolderEntry(name: url.lastPathComponent, isDirectory: false), parent: parent)
            onCreateFile?(node)
        }
    }

    @objc func newFile(_ sender: Any?) { createItem(sender, directory: false) }
    @objc func newFolder(_ sender: Any?) { createItem(sender, directory: true) }

    private func revealAfterChange(_ url: URL, in parent: FolderNode) {
        if url.lastPathComponent.hasPrefix("."), !showHidden,
           !FolderTree.alwaysHidden.contains(url.lastPathComponent) {
            revealedHiddenURLs.insert(url.standardizedFileURL)
        }
        pendingReveal = url
        if parent !== root { outline.expandItem(parent) }
        load(parent)
        quickOpen?.markStale()
    }

    @objc func renameItem(_ sender: Any?) {
        let node = target(sender)
        guard node !== root, let row = (0..<outline.numberOfRows).first(where: { outline.item(atRow: $0) as? FolderNode === node }),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { NSSound.beep(); return }
        renamingNode = node
        field.isEditable = true
        field.isSelectable = true
        field.selectText(nil)
        if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
        field.currentEditor()?.selectedRange = FolderActions.renameSelection(name: node.name, isDirectory: node.isDirectory)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renamingNode else { return }
        renamingNode = nil
        field.isEditable = false
        field.isSelectable = false
        defer { field.stringValue = node.name }
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSCancelTextMovement { return }
        guard let parent = node.parent else { return }
        do {
            try checkVisibleName(field.stringValue)
            onPrepareFileOperation?()
            let new = try FolderActions.rename(node.url, name: field.stringValue)
            guard new.path != node.url.path else { return }
            revealedHiddenURLs.remove(node.url.standardizedFileURL)
            onRename?(node.url, new, node.isDirectory)
            revealAfterChange(new, in: parent)
        } catch { showError(error) }
    }

    @objc func trashItem(_ sender: Any?) {
        let node = target(sender)
        guard node !== root else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Move “\(node.name)” to Trash?")
        alert.informativeText = String(localized: "You can put it back from the Trash.")
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onPrepareFileOperation?()
        let url = node.url, directory = node.isDirectory
        let parentURL = url.deletingLastPathComponent()
        NSWorkspace.shared.recycle([url]) { [self] moved, error in
            MainActor.assumeIsolated {
                guard moved[url] != nil else {
                    self.showError(error ?? NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                    userInfo: [NSLocalizedDescriptionKey: String(localized: "The item could not be moved to Trash.")]))
                    return
                }
                self.onTrash?(url, directory)
                self.quickOpen?.markStale()
                if let rel = FolderTree.relativePath(of: parentURL, in: self.rootURL),
                   let parent = self.root.descendant(rel) { self.load(parent) }
                if let error { self.showError(error) }
            }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([target(sender).url])
    }

    /// Open in Terminal Here: a folder row's folder, a file row's own folder.
    @objc func openInTerminal(_ sender: Any?) {
        let n = target(sender)
        guard let folder = TerminalHere.folder(forItem: n.url, isDirectory: n.isDirectory) else { NSSound.beep(); return }
        TerminalOpener.open(folder)
    }

    @objc func openEnclosing(_ sender: Any?) {
        let n = target(sender)
        onOpenEnclosing?(n.url)
    }

    @objc func copyPath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target(sender).url.path, forType: .string)
    }

    @objc func findInFolder(_ sender: Any?) {
        let n = target(sender)
        onFindInFolder?(n.isDirectory ? n.url : n.url.deletingLastPathComponent())
    }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        if showHidden { revealedHiddenURLs.removeAll() }
        for n in root.loadedFolders { load(n) }
        onChange?()
    }

    @objc func refresh(_ sender: Any?) {
        ignore.invalidate()
        quickOpen?.markStale()
        for n in root.loadedFolders { load(n) }
    }

    @objc func collapseAll(_ sender: Any?) {
        for node in root.children ?? [] where outline.isItemExpanded(node) {
            outline.collapseItem(node, collapseChildren: true)
        }
        onChange?()
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FolderNode) ?? root).children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FolderNode) ?? root).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // A loop link or an unreadable folder: listed once, nothing to open.
        guard let n = item as? FolderNode else { return false }
        return n.isDirectory && n.loadError == nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let n = notification.userInfo?["NSObject"] as? FolderNode, !n.isLoaded else { return }
        load(n)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { onChange?() }
    func outlineViewItemDidCollapse(_ notification: Notification) { onChange?() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FolderNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("folder-cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.delegate = self
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            for v in [image, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let symbol = n.entry.isSymlink ? "link" : n.isDirectory ? "folder" : "doc"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = n.isDirectory ? .controlAccentColor : .secondaryLabelColor
        cell.textField?.stringValue = n.name
        // Git-ignored: dimmed further than a hidden file.
        cell.textField?.textColor = n.entry.isIgnored ? .tertiaryLabelColor
            : n.entry.isHidden || n.loadError != nil ? .secondaryLabelColor : .labelColor
        cell.imageView?.alphaValue = n.entry.isIgnored ? 0.45 : 1
        cell.toolTip = n.loadError.map { "\(n.url.path)\n\($0)" } ?? n.url.path
        return cell
    }
}
