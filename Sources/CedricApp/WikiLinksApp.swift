import AppKit
import CedricCore

/// Wiki links (0.6; WikiLinks.swift in CedricCore has the rules):
///
/// - **`[[` offers the open folder's notes** (`WikiCompletion`): typing
///   `[[` in a Markdown or plain-text tab, outside code spans and fences,
///   with a folder open in the sidebar and the tab not in large mode, shows
///   a list under the caret; typing filters it (prefix and fuzzy), ↑/↓
///   move, Return or Tab inserts the name and closes the `]]`, ⎋ dismisses.
///   A keystroke costs nothing until a `[[` is typed: the check is two
///   characters before the caret.
/// - **⌘-click on a `[[link]]` opens its note** in a tab (at its heading
///   for `[[Note#Heading]]`). A plain click places the caret, as in any
///   text (Owlink opens no links on a plain click in the editor); ⌘-click
///   anywhere else still adds a caret. A link to no note offers to create
///   it, as the sidebar's New File does.
/// - **Names come from the folder's file index** (`WikiNotes`), the one
///   Open Quickly uses (QuickOpenFiles: built off the main thread on first
///   use, kept fresh from the sidebar's folder watcher one folder at a
///   time). Nothing is built until a `[[`, a ⌘-click on a link or the
///   Backlinks pane asks; nothing is added to opening a document.
@MainActor
final class WikiNotes {
    static let didChange = Notification.Name("cedric.wikiNotesDidChange")
    weak var sidebar: FolderSidebar?
    let root: URL
    let realRoot: String
    private(set) var notes: NoteIndex?
    private(set) var scan: BacklinkScan
    /// Folders changed since the last scan (relative); nil: all of them.
    private var dirty: Set<String>?
    private var scanning = false, rescan = false
    private var building = false, rebuild = false
    /// Some Backlinks pane shows: the notes' links are kept read.
    var wantsBacklinks = false { didSet { if wantsBacklinks && !oldValue { scheduleScan() } } }
    /// Some Tags pane shows: the notes' tags are read too (TagsSidebar.swift).
    var wantsTags = false { didSet { if wantsTags && !oldValue { scheduleScan() } } }
    /// A pane wants the notes read.
    var wantsScan: Bool { wantsBacklinks || wantsTags }
    /// Waiting for the names (a ⌘-click before the index landed).
    private var whenReady: [() -> Void] = []
    /// For the checks.
    private(set) var notesBuilt = 0, scansDone = 0
    /// Scans that read the tags too (the Tags pane waits for one).
    private(set) var tagScansDone = 0
    /// The scan in `scan` read every note's tags (not only its links).
    private(set) var tagsRead = false
    private static let queue = DispatchQueue(label: "cedric.wiki-notes", qos: .utility)
    /// Completion ranking and backlink lookups: run against a snapshot
    /// (`notes`, `scan` are values) off the main thread.
    static let queryQueue = DispatchQueue(label: "cedric.wiki-query", qos: .userInitiated)
    /// Bumped whenever `notes` or `scan` changes: a query result made from
    /// an older snapshot is dropped.
    private(set) var generation = 0

    init(sidebar: FolderSidebar) {
        self.sidebar = sidebar
        root = sidebar.rootURL
        realRoot = sidebar.realRoot
        scan = BacklinkScan(root: sidebar.rootURL)
    }

    var truncated: Bool { sidebar?.quickOpen?.truncated ?? false }
    var isPartial: Bool { scan.isPartial || truncated }
    var isReady: Bool { notes != nil }

    /// Builds the names if there are none (or the index went stale).
    func ensure() {
        guard let s = sidebar else { return }
        let files = s.quickOpenFiles
        files.onIndexLanded = { [weak self] in self?.indexLanded() }
        files.ensure()
        if notes == nil, files.index != nil, !files.isIndexing { indexLanded() }
    }

    func whenReady(_ f: @escaping () -> Void) {
        if notes != nil { f(); return }
        whenReady.append(f)
        ensure()
    }

    private func indexLanded() {
        guard let paths = sidebar?.quickOpen?.index?.paths else { return }
        if building { rebuild = true; return }
        building = true
        let box = MainBox(value: paths), ref = WeakRef(self)
        Self.queue.async {
            let idx = NoteIndex(paths: box.value)
            let out = MainBox(value: idx)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let me = ref.value else { return }
                    me.building = false
                    me.notes = out.value
                    me.generation += 1
                    me.notesBuilt += 1
                    let waiting = me.whenReady
                    me.whenReady = []
                    waiting.forEach { $0() }
                    NotificationCenter.default.post(name: Self.didChange, object: me)
                    if me.rebuild { me.rebuild = false; me.indexLanded(); return }
                    if me.wantsScan { me.scheduleScan() }
                }
            }
        }
    }

    /// FolderWatcher events (FolderSidebar.handle), before Open Quickly's index sees them.
    func handle(_ changes: [FolderWatcher.Change]) {
        func rel(_ p: String) -> String? {
            let u = URL(fileURLWithPath: p)
            return FolderTree.relativePath(of: u, in: URL(fileURLWithPath: realRoot)) ?? FolderTree.relativePath(of: u, in: root)
        }
        for c in changes {
            switch c {
            case .folder(let p):
                if let r = rel(p) { dirty?.insert(r) }
            case .subtree, .rootChanged:
                dirty = nil
            }
        }
        // A note edited in place changes no listing: rescan from here.
        if wantsScan { scheduleScan() }
    }

    /// The watcher stopped (sidebar hidden): look at every note next time.
    func markAllDirty() { dirty = nil }

    func scheduleScan() {
        guard let notes else { ensure(); return }
        if scanning { rescan = true; return }
        scanning = true
        let d = dirty, tags = wantsTags
        dirty = []
        let box = MainBox(value: (scan, notes.paths)), ref = WeakRef(self)
        Self.queue.async {
            var s = box.value.0
            s.update(notes: box.value.1, dirty: d, tags: tags)
            let out = MainBox(value: s)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let me = ref.value else { return }
                    me.scan = out.value
                    me.generation += 1
                    me.scanning = false
                    me.scansDone += 1
                    me.tagsRead = tags
                    if tags { me.tagScansDone += 1 }
                    NotificationCenter.default.post(name: Self.didChange, object: me)
                    if me.rescan { me.rescan = false; me.scheduleScan() }
                }
            }
        }
    }

    /// The note at `url`, relative to the folder (nil: not in it).
    func relativePath(of url: URL?) -> String? {
        guard let url else { return nil }
        let rel = FolderTree.relativePath(of: url, in: root)
            ?? FolderTree.relativePath(of: URL(fileURLWithPath: FolderSidebar.realPath(url.path)), in: URL(fileURLWithPath: realRoot))
        guard let rel, !rel.isEmpty else { return nil }
        return rel
    }

    func url(of rel: String) -> URL { root.appendingPathComponent(rel) }
}

extension FolderSidebar {
    /// The open folder's notes (made on first use).
    var wikiNotesModel: WikiNotes {
        if let w = wikiNotes { return w }
        let w = WikiNotes(sidebar: self)
        wikiNotes = w
        return w
    }
}

/// A tab's wiki-link state (EditorWindowController.wiki).
@MainActor
final class WikiTabState {
    var completion: WikiCompletion?
    var backlinks: BacklinksSidebar?
    var observer: NSObjectProtocol?
    var backlinksVisible: Bool { backlinks?.superview != nil }
    var tags: TagsSidebar?
    var tagsObserver: NSObjectProtocol?
    var tagsVisible: Bool { tags?.superview != nil }
    /// Asks the user before creating a missing note (a check answers instead).
    static var confirmCreate: ((String) -> Bool)?
    /// Gets a failed create instead of an alert (the checks).
    static var createFailed: ((Error) -> Void)?
}

// MARK: - The [[ popup

/// The list under the caret (a borderless child panel that never becomes
/// key: the text view keeps the focus and hands it ↑/↓, Return, Tab, ⎋).
@MainActor
final class WikiCompletion: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let maxRows = 50
    static let rowHeight: CGFloat = 22
    let panel: NSPanel
    let table = NSTableView()
    let scroll = NSScrollView()
    let note = NSTextField(labelWithString: "")
    private(set) var rows: [NoteIndex.Suggestion] = []
    /// Where the typed name starts in the text, and the name.
    private(set) var start = 0
    private(set) var query = ""
    private weak var textView: EditorTextView?
    var onAccept: ((NoteIndex.Suggestion) -> Void)?
    var isShown: Bool { panel.isVisible }
    /// Shown, or its first list is still being ranked.
    var isActive: Bool { panel.isVisible || ranking }
    /// A ranking is out on the query queue; `request` names the latest.
    private(set) var ranking = false
    private var request = 0
    /// Return or Tab came while ranking: taken when the list lands.
    private var pendingKey: Selector?
    /// Lists shown (the checks).
    private(set) var updates = 0

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let box = NSVisualEffectView(frame: panel.contentLayoutRect)
        box.material = .menu
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.masksToBounds = true
        box.autoresizingMask = [.width, .height]
        panel.contentView = box
        let col = NSTableColumn(identifier: .init("n"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.frame = box.bounds.insetBy(dx: 0, dy: 4)
        scroll.autoresizingMask = [.width, .height]
        box.addSubview(scroll)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 10, y: 4, width: 280, height: 18)
        note.autoresizingMask = [.width]
        box.addSubview(note)
    }

    /// Shows (or refreshes) the list for `query` typed at `start` in `tv`.
    /// The names are ranked on the query queue against the index as it is
    /// now; the result is used only if the query, the tab and the index
    /// generation are still the same when it lands (a newer index ranks
    /// again).
    func show(in tv: EditorTextView, start: Int, query: String, notes: WikiNotes) {
        self.start = start
        self.query = query
        textView = tv
        tv.commandInterceptor = { [weak self] sel in self?.handle(sel) ?? false }
        request += 1
        guard let idx = notes.notes else {
            ranking = false
            apply([], ready: false, in: tv)
            return
        }
        ranking = true
        // Captured here: a main-actor static can't be read in the Sendable
        // closure (Swift 6.1 rejects it).
        let token = request, gen = notes.generation, limit = Self.maxRows
        let ref = WeakRef(self), source = WeakRef(notes), view = WeakRef(tv)
        WikiNotes.queryQueue.async {
            let found = idx.suggestions(query, limit: limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let me = ref.value, let tv = view.value, me.request == token, me.ranking,
                          me.query == query, me.start == start, me.textView === tv, tv.window != nil,
                          let notes = source.value else { return }
                    guard notes.generation == gen else {
                        me.show(in: tv, start: start, query: query, notes: notes)
                        return
                    }
                    me.ranking = false
                    me.apply(found, ready: true, in: tv)
                }
            }
        }
    }

    private func apply(_ found: [NoteIndex.Suggestion], ready: Bool, in tv: EditorTextView) {
        let old = rows.first?.path
        rows = found
        updates += 1
        if let key = pendingKey {
            pendingKey = nil
            if rows.isEmpty {
                hide()
                tv.doCommand(by: key)
            } else {
                accept(0)
            }
            return
        }
        note.stringValue = ready ? String(localized: "No matching notes") : String(localized: "Indexing notes…")
        note.isHidden = !rows.isEmpty
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            if old != rows.first?.path { table.scrollRowToVisible(0) }
        }
        let height = CGFloat(rows.isEmpty ? 1 : min(rows.count, 8)) * Self.rowHeight + 8
        let caret = tv.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        var frame = NSRect(x: caret.minX - 4, y: caret.minY - height - 2, width: 300, height: height)
        if let screen = tv.window?.screen?.visibleFrame, frame.minY < screen.minY { frame.origin.y = caret.maxY + 2 }
        panel.setFrame(frame, display: true)
        if !panel.isVisible, let w = tv.window {
            w.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func hide() {
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        textView?.commandInterceptor = nil
        request += 1
        ranking = false
        pendingKey = nil
        rows = []
        table.reloadData()
    }

    var selectedRow: Int { table.selectedRow }
    var shownNames: [String] { rows.map(\.name) }

    /// A key the text view got while the list shows: true when it was the list's.
    func handle(_ sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return false }
            let r = table.selectedRow
            let next = sel == #selector(NSResponder.moveDown(_:)) ? min(rows.count - 1, r + 1) : max(0, r - 1)
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // The list for what was just typed isn't in yet: answer when it is.
            if ranking { pendingKey = sel; return true }
            guard !rows.isEmpty else { hide(); return false }
            accept(max(0, table.selectedRow))
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func accept(_ row: Int) {
        guard row < rows.count else { return }
        let s = rows[row]
        hide()
        onAccept?(s)
    }

    @objc private func clicked(_ sender: Any?) {
        let r = table.clickedRow
        if r >= 0 { accept(r) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let s = rows[row]
        let cell = tableView.makeView(withIdentifier: .init("wc"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("wc")
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.frame = NSRect(x: 8, y: 3, width: 280, height: 16)
            t.autoresizingMask = [.width]
            c.addSubview(t)
            c.textField = t
            return c
        }()
        let text = NSMutableAttributedString(string: s.name, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        if !s.folder.isEmpty {
            text.append(NSAttributedString(string: "  " + s.folder, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        cell.textField?.attributedStringValue = text
        return cell
    }
}

extension EditorWindowController {
    /// Where `[[` may offer notes: a note-type tab, a folder open, not in
    /// large mode (even with the extras turned back on), one caret.
    var wikiEligible: Bool {
        (doc.language == .markdown || doc.language == .plain) && FolderSidebar.shared != nil
            && largeReason == nil && !largePending && textView.multiCarets == nil
    }

    /// textDidChange: a `[[` just typed opens the list; typing in it filters.
    func wikiTextChanged() {
        if wiki.completion?.isActive == true { wikiUpdateCompletion(); return }
        guard doc.language == .markdown || doc.language == .plain, FolderSidebar.shared != nil else { return }
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location >= 2 else { return }
        let ns = textView.string as NSString
        guard sel.location <= ns.length, ns.character(at: sel.location - 1) == 91, ns.character(at: sel.location - 2) == 91 else { return }
        wikiUpdateCompletion()
    }

    /// The caret moved: the list follows it or goes.
    func wikiSelectionChanged() {
        if wiki.completion?.isActive == true { wikiUpdateCompletion() }
    }

    func wikiHideCompletion() { wiki.completion?.hide() }

    /// The `[[` the caret is in on its line, if any (not in fenced code).
    func wikiTyping() -> WikiLinks.Typing? {
        let sel = textView.selectedRange()
        guard sel.length == 0, !textView.hasMarkedText() else { return nil }
        let ns = textView.string as NSString
        guard ns.length == lineIndex.length, sel.location <= ns.length else { return nil }
        let line = lineIndex.line(containing: sel.location)
        let lineStart = lineIndex.starts[line]
        let col = sel.location - lineStart
        guard col >= 2, col <= WikiLinks.maxTypingColumn else { return nil }
        if doc.language == .markdown, fences.isInFence(ns, index: lineIndex, line: line) { return nil }
        var units = [unichar](repeating: 0, count: col)
        ns.getCharacters(&units, range: NSRange(location: lineStart, length: col))
        guard var t = units.withUnsafeBufferPointer({ WikiLinks.typing(inLine: $0, caret: col) }) else { return nil }
        t.start += lineStart
        return t
    }

    func wikiUpdateCompletion() {
        guard wikiEligible, let s = FolderSidebar.shared, let t = wikiTyping() else { wiki.completion?.hide(); return }
        let notes = s.wikiNotesModel
        let c = wiki.completion ?? {
            let c = WikiCompletion()
            c.onAccept = { [weak self] s in self?.wikiInsert(s) }
            wiki.completion = c
            return c
        }()
        if !notes.isReady {
            notes.whenReady { [weak self] in
                guard let self, self.wiki.completion?.isActive == true else { return }
                self.wikiUpdateCompletion()
            }
        }
        c.show(in: textView, start: t.start, query: t.query, notes: notes)
    }

    /// Return or Tab in the list: the name replaces what was typed and the `]]` closes.
    func wikiInsert(_ s: NoteIndex.Suggestion) {
        guard let c = wiki.completion else { return }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard c.start <= caret, caret <= ns.length else { return }
        let after = ns.substring(with: NSRange(location: caret, length: min(2, ns.length - caret)))
        let range = NSRange(location: c.start, length: caret - c.start)
        if after == "]]" {
            textView.insertText(s.insert, replacementRange: range)
            textView.setSelectedRange(NSRange(location: c.start + (s.insert as NSString).length + 2, length: 0))
        } else {
            textView.insertText(s.insert + "]]", replacementRange: range)
        }
    }

    // MARK: ⌘-click

    /// ⌘-click at `index` in `tv`: true when it was on a `[[link]]` (opened
    /// or offered), false to let the click add a caret.
    func wikiCommandClick(at index: Int, in tv: EditorTextView) -> Bool {
        guard doc.language == .markdown || doc.language == .plain, largeReason == nil, !largePending,
              let s = FolderSidebar.shared else { return false }
        let ns = tv.string as NSString
        guard ns.length == lineIndex.length, index >= 0, index < ns.length else { return false }
        let line = lineIndex.line(containing: index)
        let r = lineIndex.contentRange(ofLine: line)
        guard r.length <= 20_000 else { return false }
        if doc.language == .markdown, fences.isInFence(ns, index: lineIndex, line: line) { return false }
        var units = [unichar](repeating: 0, count: r.length)
        ns.getCharacters(&units, range: r)
        guard let link = units.withUnsafeBufferPointer({ WikiLinks.link(at: index - r.location, inLine: $0) }) else { return false }
        if link.target.isEmpty {
            if let h = link.heading { jumpToHeading(h) }
            return true
        }
        let notes = s.wikiNotesModel
        notes.whenReady { [weak self, weak notes] in
            guard let self, let notes, let idx = notes.notes else { return }
            if let rel = idx.resolve(link.target) {
                self.openWikiNote(notes.url(of: rel), heading: link.heading)
            } else {
                self.offerToCreate(link.target, notes: notes)
            }
        }
        return true
    }

    func openWikiNote(_ url: URL, heading: String?, line: Int? = nil) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        app.open(url) { tab in
            if let heading { tab.jumpToHeading(heading) }
            else if let line { tab.goToLine(line + 1); tab.window?.makeFirstResponder(tab.textView) }
        }
    }

    func jumpToHeading(_ name: String) {
        let want = name.lowercased()
        let hs = MarkdownOutline.headings(in: textView.string, limit: 5_000)
        guard let h = hs.first(where: { $0.title.lowercased() == want }) else { return }
        let l = max(0, min(h.line, lineIndex.lineCount - 1))
        textView.setSelectedRange(NSRange(location: lineIndex.starts[l], length: 0))
        scrollToLine(max(0, l - 2))
        window?.makeFirstResponder(textView)
    }

    /// A link to no note: create it (as the sidebar's New File does) beside
    /// this note when it is in the folder, else at the folder's top.
    private func offerToCreate(_ target: String, notes: WikiNotes) {
        var name = target.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/") { name.removeFirst() }
        let parts = name.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { NSSound.beep(); return }
        let file = WikiLinks.isNote(name) ? parts.last! : parts.last! + ".md"
        let base = parts.count > 1 ? notes.root
            : (notes.relativePath(of: doc.fileURL) != nil ? doc.fileURL!.deletingLastPathComponent() : notes.root)
        let folder = parts.dropLast().reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        let shown = FolderTree.relativePath(of: folder.appendingPathComponent(file), in: notes.root) ?? file
        let ok: Bool
        if let confirm = WikiTabState.confirmCreate {
            ok = confirm(shown)
        } else {
            let a = NSAlert()
            a.messageText = String(localized: "“\(target)” isn’t a note in this folder.")
            a.informativeText = String(localized: "Create “\(shown)”?")
            a.addButton(withTitle: String(localized: "Create"))
            a.addButton(withTitle: String(localized: "Cancel"))
            ok = a.runModal() == .alertFirstButtonReturn
        }
        guard ok else { return }
        do {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "The folder “\(folder.lastPathComponent)” doesn’t exist.")])
            }
            // The parent is judged against the open folder's real root, and the
            // note made relative to that checked folder (a symlinked parent that
            // leads out is refused; O_EXCL keeps an existing file).
            let url = try FolderActions.createFile(named: file, in: folder, within: URL(fileURLWithPath: notes.realRoot))
            if let s = FolderSidebar.shared, let rel = FolderTree.relativePath(of: folder, in: s.rootURL) {
                let node = rel.isEmpty ? s.root : s.root.descendant(rel)
                if let node, node.isLoaded { s.load(node) }
            }
            openWikiNote(url, heading: nil)
        } catch {
            if let report = WikiTabState.createFailed { report(error); return }
            NSAlert(error: error).runModal()
        }
    }
}
