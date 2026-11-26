import AppKit
import CedricCore

/// View › Show Backlinks (0.6): the notes in the open folder that link to
/// this one, each with the line that links, beside the Outline (the same
/// per-tab sidebar pattern). A click opens that note at the line. Built
/// the first time it is shown; the links come from the files
/// (`WikiNotes`/`BacklinkScan`: read off the main thread, kept per file
/// by date and size, refreshed from the folder watcher), never from a
/// database, and nothing is written. Notes over 5 MB, or past the index's
/// cap, are left out, and the pane says "partial".
@MainActor
final class BacklinksSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 220
    let title = NSTextField(labelWithString: String(localized: "Backlinks"))
    let table = NSTableView()
    let scroll = NSScrollView()
    let note = NSTextField(wrappingLabelWithString: "")
    private(set) var links: [BacklinkScan.Backlink] = []
    var onJump: ((BacklinkScan.Backlink) -> Void)?
    private var textColor = NSColor.textColor
    private var dimColor = NSColor.secondaryLabelColor
    /// Lists applied (the checks wait for one).
    private(set) var builds = 0
    private(set) var partial = false
    /// The latest list asked for (a result for an older one is dropped,
    /// and one still queued behind a newer one isn't computed).
    let latest = LatestRequest()
    var request: Int {
        get { latest.value }
        set { latest.value = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        let col = NSTableColumn(identifier: .init("b"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 38
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        addSubview(title)
        addSubview(scroll)
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 9, width: bounds.width - 20, height: 16)
        let noteH: CGFloat = note.isHidden ? 0 : 34
        note.frame = NSRect(x: 10, y: 30, width: bounds.width - 20, height: noteH)
        let top: CGFloat = 32 + noteH
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width - 1, height: max(0, bounds.height - top))
        table.tableColumns.first?.width = scroll.contentSize.width
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
        note.textColor = dimColor
        table.reloadData()
        needsDisplay = true
    }

    /// The list, or a message instead of it (`message`), and whether it is partial.
    func set(_ l: [BacklinkScan.Backlink], message: String?, partial: Bool) {
        if message != nil { request += 1 }
        links = l
        self.partial = partial
        builds += 1
        var text = message ?? (l.isEmpty ? String(localized: "No notes link here.") : "")
        if partial { text += (text.isEmpty ? "" : " ") + String(localized: "Partial: some notes were too big or past the limit.") }
        note.stringValue = text
        note.isHidden = text.isEmpty
        needsLayout = true
        table.reloadData()
    }

    var message: String { note.isHidden ? "" : note.stringValue }

    func numberOfRows(in tableView: NSTableView) -> Int { links.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < links.count else { return nil }
        let b = links[row]
        let cell = tableView.makeView(withIdentifier: .init("bc"), owner: nil) as? BacklinkCell ?? BacklinkCell()
        let name = ((b.source as NSString).deletingPathExtension as NSString).lastPathComponent
        let folder = (b.source as NSString).deletingLastPathComponent
        cell.name.stringValue = folder.isEmpty ? name : name + "  ·  " + folder
        cell.name.textColor = textColor
        cell.snippet.stringValue = b.snippet
        cell.snippet.textColor = dimColor
        cell.toolTip = String(localized: "\(b.source), line \(b.line + 1)\n\(b.snippet)")
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < links.count else { return }
        onJump?(links[r])
    }

    /// Selects and opens row `r` (the checks; a click does the same).
    func activate(_ r: Int) {
        guard r >= 0, r < links.count else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        onJump?(links[r])
    }
}

final class BacklinkCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let snippet = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 38))
        identifier = .init("bc")
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        snippet.font = .systemFont(ofSize: 11)
        for t in [name, snippet] {
            t.lineBreakMode = .byTruncatingTail
            t.autoresizingMask = [.width]
            addSubview(t)
        }
        name.frame = NSRect(x: 8, y: 20, width: 188, height: 16)
        snippet.frame = NSRect(x: 8, y: 3, width: 188, height: 15)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

extension EditorWindowController {
    var backlinksVisible: Bool { wiki.backlinksVisible }

    /// Backlinks apply to note types (Markdown, plain text).
    var backlinksApply: Bool { doc.language == .markdown || doc.language == .plain }

    /// View › Show Backlinks.
    func toggleBacklinks() {
        if wiki.backlinksVisible { hideBacklinks(); return }
        guard backlinksApply else { NSSound.beep(); return }
        let s = wiki.backlinks ?? {
            let s = BacklinksSidebar(frame: .zero)
            s.onJump = { [weak self] b in self?.openBacklink(b) }
            wiki.backlinks = s
            return s
        }()
        s.applyPalette(palette)
        editorContainer.backlinks = s
        if wiki.observer == nil {
            wiki.observer = NotificationCenter.default.addObserver(forName: WikiNotes.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBacklinks() }
            }
        }
        FolderSidebar.shared?.wikiNotesModel.wantsBacklinks = true
        refreshBacklinks()
    }

    func hideBacklinks() {
        editorContainer.backlinks = nil
        if let o = wiki.observer { NotificationCenter.default.removeObserver(o) }
        wiki.observer = nil
        if let app = NSApp.delegate as? AppDelegate, !app.tabs.contains(where: { $0 !== self && $0.backlinksVisible }) {
            FolderSidebar.shared?.wikiNotesModel.wantsBacklinks = false
        }
    }

    /// The list for this note, from what the folder's notes hold now.
    func refreshBacklinks() {
        guard wiki.backlinksVisible, let side = wiki.backlinks else { return }
        if !backlinksApply { hideBacklinks(); return }
        guard let folder = FolderSidebar.shared else {
            side.set([], message: String(localized: "Open a folder to see the notes that link here."), partial: false)
            return
        }
        let notes = folder.wikiNotesModel
        notes.wantsBacklinks = true
        guard let rel = notes.relativePath(of: doc.fileURL) else {
            side.set([], message: String(localized: "This note isn’t in the open folder."), partial: false)
            return
        }
        guard let idx = notes.notes, notes.scansDone > 0 else {
            side.set([], message: String(localized: "Reading the folder’s notes…"), partial: false)
            notes.ensure()
            return
        }
        // The traversal runs on the query queue against this snapshot; its
        // list is shown only if it is still the latest asked for this pane,
        // the tab still shows this note and the notes haven't changed since
        // (a change posts didChange, which asks again).
        let scan = notes.scan, gen = notes.generation, partial = notes.isPartial
        side.request += 1
        let token = side.request, gate = side.latest, delay = WikiNotes.queryDelay
        let me = WeakRef(self), pane = WeakRef(side), model = WeakRef(notes)
        WikiNotes.queryQueue.async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            // A newer refresh (or a message) came while this waited: skip the walk.
            guard gate.isLatest(token) else { return }
            let found = scan.backlinks(to: rel, in: idx)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Applied only from the sidebar's current notes (a folder closed or
                    // replaced since asks again: wikiFolderChanged).
                    guard let tab = me.value, let side = pane.value, let notes = model.value,
                          FolderSidebar.shared?.wikiNotes === notes,
                          side.request == token, notes.generation == gen, tab.wiki.backlinks === side, tab.wiki.backlinksVisible,
                          notes.relativePath(of: tab.doc.fileURL) == rel else { return }
                    side.set(found, message: nil, partial: partial)
                }
            }
        }
    }

    /// The sidebar's folder was closed or replaced: an open `[[` list goes
    /// (its names, and any keys held for it, were the old folder's) and a
    /// visible Backlinks pane asks the new folder (or says there is none).
    func wikiFolderChanged() {
        wiki.completion?.hide()
        if wiki.backlinksVisible { refreshBacklinks() }
    }

    private func openBacklink(_ b: BacklinkScan.Backlink) {
        guard let notes = FolderSidebar.shared?.wikiNotesModel else { return }
        openWikiNote(notes.url(of: b.source), heading: nil, line: b.line)
    }
}
