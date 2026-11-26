import AppKit
import CedricCore

/// View › Show Tags (0.6): every `#tag` in the open folder's notes, with
/// counts, as a tree (`#a/b` under `a`), most used first; a click on a
/// tag lists the notes that have it, with the line, and a click on a note
/// opens it at that line. A per-tab pane beside the Outline and Backlinks.
///
/// The tags come from the files, read with the links in the same pass
/// (`WikiNotes`/`BacklinkScan`: off the main thread, the folder's file
/// index for the walk, kept per file by date and size, refreshed from the
/// folder watcher). The tree is made on the query queue and shown only if
/// the folder and the scan are still the ones it was made from. Nothing is
/// written; nothing is read while no Tags pane shows. Notes over 5 MB, or
/// past the index's cap, are left out, and the pane says "partial".
@MainActor
final class TagsSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 220

    /// A row of the tag tree (NSOutlineView wants objects).
    final class Item: NSObject {
        let node: TagTree.Node
        let children: [Item]
        init(_ n: TagTree.Node) {
            node = n
            children = n.children.map(Item.init)
        }
    }

    let title = NSTextField(labelWithString: String(localized: "Tags"))
    let outline = NSOutlineView()
    let tagScroll = NSScrollView()
    let header = NSTextField(labelWithString: "")
    let table = NSTableView()
    let notesScroll = NSScrollView()
    let note = NSTextField(wrappingLabelWithString: "")
    private(set) var tree: TagTree?
    /// The folder's notes `tree` was made from: its hits are paths in that
    /// folder, opened only while it is still the sidebar's.
    private(set) weak var model: WikiNotes?
    private(set) var items: [Item] = []
    /// The tag whose notes are listed (its path as shown), if any.
    private(set) var selectedTag: String?
    private(set) var hits: [TagTree.Hit] = []
    /// Expanded tags (lowercased paths), kept across refreshes.
    private var expanded = Set<String>()
    private var restoring = false
    /// A note row clicked: the hit and the notes it came from.
    var onOpen: ((TagTree.Hit, WikiNotes?) -> Void)?
    private var textColor = NSColor.textColor
    private var dimColor = NSColor.secondaryLabelColor
    /// Trees applied (the checks wait for one).
    private(set) var builds = 0
    private(set) var partial = false
    /// The latest tree asked for (a result for an older one is dropped).
    var request = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        let col = NSTableColumn(identifier: .init("t"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // Expanding a tag mustn't widen the column past the pane (the counts are at its right).
        outline.autoresizesOutlineColumn = false
        outline.intercellSpacing = NSSize(width: 0, height: outline.intercellSpacing.height)
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 20
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(tagClicked(_:))
        tagScroll.documentView = outline
        let ncol = NSTableColumn(identifier: .init("n"))
        ncol.resizingMask = .autoresizingMask
        table.addTableColumn(ncol)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 38
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(noteClicked(_:))
        notesScroll.documentView = table
        for s in [tagScroll, notesScroll] {
            s.hasVerticalScroller = true
            s.autohidesScrollers = true
            s.drawsBackground = false
            s.borderType = .noBorder
        }
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        header.isHidden = true
        notesScroll.isHidden = true
        [title, note, tagScroll, header, notesScroll].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 10, y: 9, width: w - 20, height: 16)
        let noteH: CGFloat = note.isHidden ? 0 : 34
        note.frame = NSRect(x: 10, y: 30, width: w - 20, height: noteH)
        let top: CGFloat = 32 + noteH
        let rest = max(0, bounds.height - top)
        if selectedTag == nil {
            tagScroll.frame = NSRect(x: 0, y: top, width: w - 1, height: rest)
        } else {
            let tagsH = (rest * 0.5).rounded()
            tagScroll.frame = NSRect(x: 0, y: top, width: w - 1, height: tagsH)
            header.frame = NSRect(x: 10, y: top + tagsH + 6, width: w - 20, height: 16)
            let listTop = top + tagsH + 26
            notesScroll.frame = NSRect(x: 0, y: listTop, width: w - 1, height: max(0, bounds.height - listTop))
        }
        outline.tableColumns.first?.width = tagScroll.contentSize.width
        outline.sizeLastColumnToFit()
        table.tableColumns.first?.width = notesScroll.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).intersection(dirtyRect).intersection(bounds)
        dimColor.withAlphaComponent(0.25).setFill()
        r.fill()
    }

    func applyPalette(_ p: EditorPalette) {
        layer?.backgroundColor = NSColor(hex: p.gutterBackground).cgColor
        textColor = NSColor(hex: p.foreground)
        dimColor = NSColor(hex: p.gutterForeground)
        title.textColor = dimColor
        header.textColor = dimColor
        note.textColor = dimColor
        outline.reloadData()
        restoreExpansion()
        table.reloadData()
        needsDisplay = true
    }

    /// The tree (nil: none yet) made from `model`'s notes, or a message
    /// instead of it, and whether it is partial. Another model (the folder
    /// was closed or replaced) drops the listed tag and the expanded ones.
    func set(_ t: TagTree?, model m: WikiNotes?, message: String?, partial: Bool) {
        if message != nil { request += 1 }
        if m !== model {
            model = m
            expanded = []
            selectedTag = nil
        }
        tree = t
        self.partial = partial
        builds += 1
        items = (t?.roots ?? []).map(Item.init)
        var text = message ?? ((t?.roots.isEmpty ?? true) ? String(localized: "No tags in this folder’s notes.") : "")
        if partial { text += (text.isEmpty ? "" : " ") + String(localized: "Partial: some notes were too big or past the limit.") }
        note.stringValue = text
        note.isHidden = text.isEmpty
        outline.reloadData()
        restoreExpansion()
        // The listed tag follows the new tree (or goes, when no note has it now).
        if let sel = selectedTag, let t, t.node(sel) != nil { showNotes(sel) } else { showNotes(nil) }
        needsLayout = true
    }

    var message: String { note.isHidden ? "" : note.stringValue }

    private func restoreExpansion() {
        restoring = true
        defer { restoring = false }
        func walk(_ list: [Item]) {
            for i in list where expanded.contains(i.node.path.lowercased()) {
                outline.expandItem(i)
                walk(i.children)
            }
        }
        walk(items)
        if let sel = selectedTag?.lowercased(), let i = item(sel) {
            let r = outline.row(forItem: i)
            if r >= 0 { outline.selectRowIndexes([r], byExtendingSelection: false) }
        }
    }

    private func item(_ lowerPath: String) -> Item? {
        func find(_ list: [Item]) -> Item? {
            for i in list {
                let p = i.node.path.lowercased()
                if p == lowerPath { return i }
                if lowerPath.hasPrefix(p + "/"), let f = find(i.children) { return f }
            }
            return nil
        }
        return find(items)
    }

    /// Lists the notes with `tag` (nil: none listed).
    func showNotes(_ tag: String?) {
        guard let tag, let t = tree, let node = t.node(tag) else {
            selectedTag = nil
            hits = []
            header.isHidden = true
            notesScroll.isHidden = true
            table.reloadData()
            needsLayout = true
            return
        }
        selectedTag = node.path
        hits = t.notes(for: node.path)
        header.stringValue = node.count == 1 ? String(localized: "#\(node.path): 1 note") : String(localized: "#\(node.path): \(node.count) notes")
        header.isHidden = false
        notesScroll.isHidden = false
        table.reloadData()
        needsLayout = true
    }

    /// Shown rows of the tag tree, top to bottom, as "path count" (the checks).
    var shownRows: [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Item).map { "\($0.node.path) \($0.node.count)" } }
    }

    /// Selects tag `path` as a click does, expanding the tags above it (the checks).
    func selectTag(_ path: String) {
        let parts = path.split(separator: "/")
        var p = ""
        for part in parts.dropLast() {
            p += (p.isEmpty ? "" : "/") + part.lowercased()
            if let i = item(p) { outline.expandItem(i) }
        }
        guard let i = item(path.lowercased()) else { return }
        let r = outline.row(forItem: i)
        if r >= 0 { outline.selectRowIndexes([r], byExtendingSelection: false) }
        showNotes(i.node.path)
    }

    /// Opens note row `r` as a click does (the checks).
    func activate(_ r: Int) {
        guard r >= 0, r < hits.count else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        onOpen?(hits[r], model)
    }

    @objc private func tagClicked(_ sender: Any?) {
        let r = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard r >= 0, let i = outline.item(atRow: r) as? Item else { return }
        showNotes(i.node.path)
    }

    @objc private func noteClicked(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < hits.count else { return }
        onOpen?(hits[r], model)
    }

    // MARK: Outline (the tags)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !restoring, let i = notification.userInfo?["NSObject"] as? Item { expanded.insert(i.node.path.lowercased()) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !restoring, let i = notification.userInfo?["NSObject"] as? Item { expanded.remove(i.node.path.lowercased()) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let i = item as? Item else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("tc"), owner: nil) as? TagCell ?? TagCell()
        cell.name.stringValue = "#" + i.node.name
        cell.name.textColor = textColor
        cell.count.stringValue = "\(i.node.count)"
        cell.count.textColor = dimColor
        cell.toolTip = i.node.count == 1 ? String(localized: "#\(i.node.path): 1 note") : String(localized: "#\(i.node.path): \(i.node.count) notes")
        return cell
    }

    // MARK: Table (the notes with the listed tag)

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < hits.count else { return nil }
        let h = hits[row]
        let cell = tableView.makeView(withIdentifier: .init("bc"), owner: nil) as? BacklinkCell ?? BacklinkCell()
        let name = ((h.source as NSString).deletingPathExtension as NSString).lastPathComponent
        let folder = (h.source as NSString).deletingLastPathComponent
        cell.name.stringValue = folder.isEmpty ? name : name + "  ·  " + folder
        cell.name.textColor = textColor
        cell.snippet.stringValue = h.snippet
        cell.snippet.textColor = dimColor
        cell.toolTip = String(localized: "\(h.source), line \(h.line + 1)\n\(h.snippet)")
        return cell
    }
}

final class TagCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        identifier = .init("tc")
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        addSubview(name)
        addSubview(count)
    }

    override func layout() {
        super.layout()
        // From the cell's own width (the outline indents nested rows).
        let w = bounds.width
        count.frame = NSRect(x: max(0, w - 46), y: 2, width: 40, height: 16)
        name.frame = NSRect(x: 2, y: 2, width: max(0, w - 52), height: 16)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension EditorWindowController {
    var tagsVisible: Bool { wiki.tagsVisible }

    /// View › Show Tags (any text tab: the tags are the folder's, not this note's).
    func toggleTags() {
        if wiki.tagsVisible { hideTags(); return }
        let s = wiki.tags ?? {
            let s = TagsSidebar(frame: .zero)
            s.onOpen = { [weak self] h, model in self?.openTagHit(h, from: model) }
            wiki.tags = s
            return s
        }()
        s.applyPalette(palette)
        editorContainer.tags = s
        if wiki.tagsObserver == nil {
            wiki.tagsObserver = NotificationCenter.default.addObserver(forName: WikiNotes.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTags() }
            }
        }
        refreshTags()
    }

    func hideTags() {
        editorContainer.tags = nil
        if let o = wiki.tagsObserver { NotificationCenter.default.removeObserver(o) }
        wiki.tagsObserver = nil
        if let app = NSApp.delegate as? AppDelegate, !app.tabs.contains(where: { $0 !== self && $0.tagsVisible }) {
            FolderSidebar.shared?.wikiNotes?.wantsTags = false
        }
    }

    /// The tree from what the folder's notes hold now (made on the query queue).
    func refreshTags() {
        guard wiki.tagsVisible, let side = wiki.tags else { return }
        guard let folder = FolderSidebar.shared else {
            side.set(nil, model: nil, message: String(localized: "Open a folder to see the tags in its notes."), partial: false)
            return
        }
        let notes = folder.wikiNotesModel
        notes.wantsTags = true
        guard notes.notes != nil, notes.tagsRead else {
            // The tree shown stays only while it is this folder's (a
            // replaced folder's tree and notes go at once).
            side.set(side.model === notes ? side.tree : nil, model: notes, message: String(localized: "Reading the folder’s notes…"), partial: false)
            notes.ensure()
            return
        }
        // Shown only if it is still the latest asked for this pane, the
        // folder is the same and its notes haven't changed since (a change
        // posts didChange, which asks again).
        let scan = notes.scan, gen = notes.generation, partial = notes.isPartial
        side.request += 1
        let token = side.request
        let me = WeakRef(self), pane = WeakRef(side), model = WeakRef(notes)
        WikiNotes.queryQueue.async {
            let tree = TagTree(files: scan.tagsByNote)
            let out = MainBox(value: tree)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let tab = me.value, let side = pane.value, let notes = model.value,
                          side.request == token, notes.generation == gen, FolderSidebar.shared?.wikiNotes === notes,
                          tab.wiki.tags === side, tab.wiki.tagsVisible else { return }
                    side.set(out.value, model: notes, message: nil, partial: partial)
                }
            }
        }
    }

    /// Opens a hit only in the folder it was found in (a path from a
    /// replaced folder may name another note in the new one).
    private func openTagHit(_ h: TagTree.Hit, from model: WikiNotes?) {
        guard let notes = FolderSidebar.shared?.wikiNotes, let model, model === notes else { return }
        openWikiNote(notes.url(of: h.source), heading: nil, line: h.line)
    }
}
