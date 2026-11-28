import SwiftUI
import UIKit
import CedricCore

/// Wiki links and tags on iOS (Mac 0.6.0's Backlinks beside Outline, and
/// the Tags pane), as one sheet instead of sidebars: Outline (the note's
/// headings), Backlinks (the notes whose `[[links]]` lead here) and Tags
/// (every #tag in the folder and the notes holding it).
///
/// One root for the sheet and the editor's "Open “Note”" (`root(for:)`):
/// the Obsidian vault inside the folder the preview was granted, else that
/// folder, else the document's own folder when Owlink can read it; never a
/// vault above what Owlink may read. A note is listed, read and opened only
/// when the file its path leads to is inside that root (`relativePath`),
/// read through the root's descriptor as a regular file (a note replaced by
/// a symbolic link is skipped, `BacklinkScan.readBeneath`), and checked
/// again the same way just before it opens (`openableNote`).
///
/// Read when Backlinks or Tags is first shown, off the main thread, by the
/// shared `NoteIndex`, `BacklinkScan.collect` and `TagTree`; cancelled when
/// the sheet goes or the root changes (the listing, each note and each line
/// of one, and the tag tree check it). One read takes at most
/// `maxTotalBytes` of notes and holds at most `maxBacklinks` backlinks and
/// `maxTagRefs` tag places while it collects; past those the sheet says
/// some notes weren't read. The root is opened first, never through a
/// symbolic link, and a later read refuses it if it is another folder.
/// Nothing is written and there is no live watcher.
@MainActor
final class NoteLinksModel: ObservableObject {
    enum State: Equatable { case idle, reading, ready, noFolder, notInFolder }

    /// Bytes of notes one read takes in all (each note at most
    /// `BacklinkScan.maxFileBytes`): 32 MiB, a few times a large vault's
    /// text, well under what an iPhone lets the app hold.
    nonisolated static let maxTotalBytes = 32 * 1024 * 1024
    /// Backlinks kept (a list longer than this isn't read by anyone).
    nonisolated static let maxBacklinks = 1_000
    /// Tag places kept, over all notes (each is a line's snippet).
    nonisolated static let maxTagRefs = 20_000
    /// Tag tree entries (a tag, or a tag above a nested one, in one note).
    nonisolated static let maxTagEntries = 50_000

    /// The folder grant a root is read beneath, as it was granted
    /// (`PreviewFolderGrants.Grant`): the root is opened by opening the
    /// grant where it was then, without following a link, checking it is
    /// still that folder, and opening the root's folders below it from
    /// there (never by the root's path).
    typealias Anchor = PreviewFolderGrants.Grant
    /// The grant `root` is read beneath (nil: a root that isn't granted,
    /// the document's own folder).
    private(set) var anchor: Anchor?

    @Published private(set) var state: State = .idle
    @Published private(set) var backlinks: [BacklinkScan.Backlink] = []
    @Published private(set) var tags: TagTree?
    @Published private(set) var partial = false
    @Published private(set) var truncated = false
    let headings: [MarkdownOutline.Heading]
    let document: URL
    private(set) var root: URL?
    /// `root` as it was first read: a later read (and a note opened from
    /// the sheet) refuses a root that is now another folder.
    private(set) var rootID: Beneath.FileID?
    /// Finds `root` off the main thread on the first load, when it isn't
    /// given (the folder probe lists the document's folder).
    private var findRoot: (@Sendable () -> URL?)?
    /// The current read (tests await it).
    private(set) var task: Task<Void, Never>?
    private var work: Task<Outcome, Never>?

    init(document: URL, root: URL?, headings: [MarkdownOutline.Heading], anchor: Anchor? = nil,
         findRoot: (@Sendable () -> URL?)? = nil) {
        self.document = document.standardizedFileURL
        self.root = root?.standardizedFileURL
        self.anchor = anchor
        self.headings = headings
        self.findRoot = root == nil ? findRoot : nil
    }

    /// The notes' folder for `document`: see the type's comment.
    nonisolated static func root(for document: URL, granted: URL?, readable: Bool) -> URL? {
        let folder = document.deletingLastPathComponent()
        if let granted { return WikiVault.vaultRoot(for: folder, granted: granted) ?? granted }
        return readable ? folder : nil
    }

    func url(of rel: String) -> URL? { root?.appendingPathComponent(rel) }

    enum Outcome: Sendable {
        case noFolder, notInFolder(URL), cancelled, ready(URL, ReadResult)
    }

    func load() {
        cancel()
        if root == nil, findRoot == nil { state = .noFolder; return }
        if let root, Self.relativePath(of: document, under: root) == nil { state = .notInFolder; return }
        state = .reading
        let doc = document, known = root, find = findRoot, knownID = rootID, anchor = anchor
        let work = Task.detached(priority: .userInitiated) { () -> Outcome in
            guard let root = known ?? find?() else { return .noFolder }
            guard let rel = Self.relativePath(of: doc, under: root) else { return .notInFolder(root) }
            guard let result = Self.read(root: root, note: rel, rootID: knownID, anchor: anchor,
                                         cancelled: { Task.isCancelled }) else { return .cancelled }
            return .ready(root, result)
        }
        self.work = work
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .cancelled: return
            case .noFolder:
                self.findRoot = nil
                self.state = .noFolder
            case .notInFolder(let root):
                self.adopt(root)
                self.state = .notInFolder
            case .ready(let root, let result):
                self.adopt(root)
                if self.rootID == nil { self.rootID = result.rootID }
                self.backlinks = result.backlinks
                self.tags = result.tags
                self.partial = result.partial
                self.truncated = result.truncated
                self.state = .ready
            }
        }
    }

    private func adopt(_ found: URL) {
        if root == nil { root = found.standardizedFileURL }
        findRoot = nil
    }

    /// Stops the read (the sheet went away, or another starts).
    func cancel() {
        task?.cancel()
        work?.cancel()
        task = nil
        work = nil
        if state == .reading { state = .idle }
    }

    func setRoot(_ url: URL?, anchor: Anchor? = nil) {
        root = url?.standardizedFileURL
        self.anchor = anchor
        rootID = nil
        findRoot = nil
        load()
    }

    /// `file`'s path below `root`, when the file it leads to (symbolic
    /// links resolved) is inside `root` resolved; compared by the UTF-8
    /// bytes. As written when that is below `root` too, else resolved.
    nonisolated static func relativePath(of file: URL, under root: URL) -> String? {
        func below(_ f: String, _ r: String) -> String? {
            var base = Array(r.utf8)
            if base.last != 0x2f { base.append(0x2f) }
            let path = Array(f.utf8)
            guard path.count > base.count, path.starts(with: base) else { return nil }
            return String(decoding: path[base.count...], as: UTF8.self)
        }
        // Where the path leads must be inside the root: a link out isn't.
        guard let resolved = below(file.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path) else { return nil }
        return below(file.standardizedFileURL.path, root.standardizedFileURL.path) ?? resolved
    }

    /// `url`, when it is a note Owlink may open from `root`: inside it
    /// (`relativePath`) and, looked up from `root`'s descriptor right now,
    /// a regular file reached without leaving `root` (the last component
    /// not followed). Checked just before a note opens.
    nonisolated static func openableNote(_ url: URL, under root: URL, rootID: Beneath.FileID? = nil, anchor: Anchor? = nil) -> URL? {
        checkedNote(url, under: root, rootID: rootID, anchor: anchor)?.url
    }

    /// A note `openableNote` allows, and the file it is (device and
    /// inode): what is opened later must still be that file
    /// (`TextDocument.linkedNote`). The root is opened as `openRoot` opens
    /// it (beneath `anchor`, the grant, when given), and must still be
    /// `rootID` when given.
    struct CheckedNote: Sendable {
        var url: URL
        var id: Beneath.FileID
    }

    nonisolated static func checkedNote(_ url: URL, under root: URL, rootID: Beneath.FileID? = nil, anchor: Anchor? = nil) -> CheckedNote? {
        guard let rel = relativePath(of: url, under: root) else { return nil }
        let dir = openRoot(root, expected: rootID, anchor: anchor)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fd = Beneath.open(parts, beneath: dir, flags: O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, let id = Beneath.FileID(fd: fd) else { return nil }
        return CheckedNote(url: root.appendingPathComponent(rel), id: id)
    }

    struct ReadResult: Sendable {
        var backlinks: [BacklinkScan.Backlink]
        var tags: TagTree
        var partial: Bool
        var truncated: Bool
        /// The root as read (its device and inode).
        var rootID: Beneath.FileID?
    }

    /// The notes under `root` (relative paths), as the vault lists them:
    /// no hidden files or folders, at most `WikiVault.maxDepth` deep and
    /// `WikiVault.maxEntries` entries, each leading inside `root`.
    nonisolated static func notes(under root: URL, cancelled: () -> Bool = { false }) -> (paths: [String], truncated: Bool) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        var out: [String] = []
        var seen = 0
        var truncated = false
        while let url = e.nextObject() as? URL {
            if cancelled() { break }
            seen += 1
            if seen > WikiVault.maxEntries { truncated = true; break }
            if e.level > WikiVault.maxDepth { e.skipDescendants(); continue }
            guard WikiLinks.isNote(url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let rel = relativePath(of: url, under: root) else { continue }
            out.append(rel)
        }
        return (out, truncated)
    }

    /// What one read did (tests): the most links and tags it held at once,
    /// and how many it parsed in all.
    final class ScanStats: @unchecked Sendable {
        var retained = 0
        var parsed = 0
    }

    /// The root opened for reading, -1 when it can't be. With `anchor`
    /// (the grant the root is in): the grant opened where it was when
    /// granted, not through a symbolic link, and still the folder granted
    /// (its identity is required), then the root's folders below it
    /// opened from that descriptor (`Beneath.open`, no link followed);
    /// the root's own path is never looked up. Without: the root's path,
    /// not a symbolic link. Either way still `expected` when given (the
    /// folder as first read).
    nonisolated static func openRoot(_ root: URL, expected: Beneath.FileID?, anchor: Anchor? = nil) -> Int32 {
        let dir: Int32
        if let anchor {
            guard let id = anchor.id else { return -1 }
            let base = anchor.url.standardizedFileURL.pathComponents, path = root.standardizedFileURL.pathComponents
            guard path.count >= base.count, Array(path.prefix(base.count)) == base else { return -1 }
            let grant = open(anchor.resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard grant >= 0 else { return -1 }
            guard Beneath.FileID(fd: grant) == id else { close(grant); return -1 }
            let below = Array(path.dropFirst(base.count))
            if below.isEmpty {
                dir = grant
            } else {
                dir = Beneath.open(below, beneath: grant, flags: O_RDONLY | O_DIRECTORY)
                close(grant)
                guard dir >= 0 else { return -1 }
            }
        } else {
            dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { return -1 }
        }
        if let expected, Beneath.FileID(fd: dir) != expected { close(dir); return -1 }
        return dir
    }

    /// Backlinks to `note` and the tags under `root`, within the caps (see
    /// the type's comment), kept to them as they are collected; nil when
    /// `cancelled` said stop. `listed`: the notes as listed earlier (tests:
    /// a note swapped after the listing). `rootID`: the root as it was
    /// first read; a root that is now a symbolic link or another folder is
    /// not read (an empty, partial result). `stats`, `readNote`: tests.
    nonisolated static func read(root: URL, note: String, listed given: [String]? = nil, rootID: Beneath.FileID? = nil,
                                 anchor: Anchor? = nil, cancelled: () -> Bool = { false }, stats: ScanStats? = nil,
                                 readNote: (String, Int32, Int) -> BacklinkScan.NoteRead = { BacklinkScan.readBeneath($0, root: $1, maxBytes: $2) }) -> ReadResult? {
        // The root first: what is listed by path is read only through it.
        let dir = openRoot(root, expected: rootID, anchor: anchor)
        guard dir >= 0 else {
            return cancelled() ? nil : ReadResult(backlinks: [], tags: TagTree(files: [:]), partial: true, truncated: false, rootID: rootID)
        }
        defer { close(dir) }
        let id = Beneath.FileID(fd: dir)
        let listed = given.map { (paths: $0, truncated: false) } ?? notes(under: root, cancelled: cancelled)
        if cancelled() { return nil }
        let index = NoteIndex(paths: listed.paths)
        var budget = maxTotalBytes
        let found = BacklinkScan.collect(notes: index.paths, to: note, in: index, maxBacklinks: maxBacklinks, maxTagRefs: maxTagRefs,
                                         cancelled: cancelled) { rel in
            let r = readNote(rel, dir, min(BacklinkScan.maxFileBytes, budget))
            if case .read(let size, _, _) = r { budget -= size }
            return r
        }
        stats?.parsed = found.parsed
        stats?.retained = found.backlinks.count + found.tagsByNote.values.reduce(0) { $0 + $1.count }
        if found.cancelled || cancelled() { return nil }
        let tags = TagTree(files: found.tagsByNote, cancelled: cancelled, maxEntries: maxTagEntries)
        if cancelled() { return nil }
        return ReadResult(backlinks: found.backlinks, tags: tags, partial: found.skipped > 0,
                          truncated: listed.truncated || found.truncated || tags.truncated, rootID: id)
    }
}

struct NoteLinksView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case outline, backlinks, tags
        var id: String { rawValue }
        var title: String {
            switch self {
            case .outline: return String(localized: "Outline")
            case .backlinks: return String(localized: "Backlinks")
            case .tags: return String(localized: "Tags")
            }
        }
    }

    @ObservedObject var model: NoteLinksModel
    @State var pane: Pane
    var onHeading: (MarkdownOutline.Heading) -> Void
    var onNote: (URL) -> Void
    var onChooseFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var openTag: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(String(localized: "Show"), selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                .accessibilityIdentifier("notelinks.pane")
                List {
                    switch pane {
                    case .outline: outline
                    case .backlinks: folderGate { backlinkRows }
                    case .tags: folderGate { tagRows }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("notelinks.list")
            }
            .navigationTitle(pane.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
        }
        // Read when Backlinks or Tags is first shown; stopped when the sheet goes.
        .task(id: pane) { if pane != .outline, model.state == .idle { model.load() } }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var outline: some View {
        if model.headings.isEmpty {
            Text(String(localized: "No headings in this document.")).foregroundStyle(.secondary)
        }
        ForEach(Array(model.headings.enumerated()), id: \.offset) { _, h in
            Button { onHeading(h) } label: {
                Text(h.title).padding(.leading, CGFloat(max(0, h.level - 1)) * 14)
            }
            .accessibilityIdentifier("notelinks.heading")
        }
    }

    @ViewBuilder private func folderGate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch model.state {
        case .noFolder:
            Text(String(localized: "Owlink can read only this file. Choose its folder to see the notes that link here and their tags."))
                .foregroundStyle(.secondary)
            Button(String(localized: "Choose Folder…"), action: onChooseFolder)
                .accessibilityIdentifier("notelinks.chooseFolder")
        case .notInFolder:
            Text(String(localized: "This note isn’t in the folder Owlink can read.")).foregroundStyle(.secondary)
        case .idle, .reading:
            HStack { ProgressView(); Text(String(localized: "Reading the folder’s notes…")).foregroundStyle(.secondary) }
        case .ready:
            content()
            if model.partial || model.truncated {
                Text(String(localized: "Some notes weren’t read (too many, or too large)."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var backlinkRows: some View {
        if model.backlinks.isEmpty {
            Text(String(localized: "No notes link here.")).foregroundStyle(.secondary)
        }
        ForEach(Array(model.backlinks.enumerated()), id: \.offset) { _, b in
            Button {
                if let url = model.url(of: b.source) { onNote(url) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.noteName(b.source)).font(.body)
                    Text(b.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .accessibilityIdentifier("notelinks.backlink")
        }
    }

    @ViewBuilder private var tagRows: some View {
        let roots = model.tags?.roots ?? []
        if roots.isEmpty {
            Text(String(localized: "No tags in these notes.")).foregroundStyle(.secondary)
        }
        ForEach(Self.flatten(roots), id: \.path) { node in
            DisclosureGroup(isExpanded: Binding(get: { openTag == node.path }, set: { openTag = $0 ? node.path : nil })) {
                ForEach(Array((model.tags?.notes(for: node.path) ?? []).enumerated()), id: \.offset) { _, hit in
                    Button {
                        if let url = model.url(of: hit.source) { onNote(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.noteName(hit.source))
                            Text(hit.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("notelinks.tagNote")
                }
            } label: {
                HStack {
                    Text("#" + node.path)
                    Spacer()
                    Text(node.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityIdentifier("notelinks.tag")
        }
    }

    /// Nested tags (#a/b) as one list, parents first.
    static func flatten(_ nodes: [TagTree.Node]) -> [TagTree.Node] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    static func noteName(_ rel: String) -> String {
        ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

extension EditorViewController {
    /// More › Backlinks and Tags… (Markdown and plain text notes).
    @objc func showNoteLinks() { presentNoteLinks(.backlinks) }

    var noteLinksApply: Bool {
        let l = document.language.language
        return l == .markdown || l == .plain
    }

    func makeNoteLinksModel() -> NoteLinksModel {
        let doc = document.fileURL
        let folder = doc.deletingLastPathComponent()
        // The grant as it was granted: the first read is beneath it too.
        let grant = folderGrants.grant(for: folder)
        let granted = grant?.url
        let headings = document.language.language == .markdown ? MarkdownOutline.headings(in: textView.text) : []
        // The folder probe and the vault walk run off the main thread, on the first read.
        return NoteLinksModel(document: doc, root: nil, headings: headings, anchor: grant, findRoot: {
            NoteLinksModel.root(for: doc, granted: granted,
                                readable: granted == nil && PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: doc)))
        })
    }

    /// The notes' root for this document, as the sheet finds it (one
    /// policy for both): see `NoteLinksModel`.
    func noteLinksRoot() -> URL? { noteLinksPlace()?.root }

    /// The root, and the grant it is read beneath (nil: not granted).
    func noteLinksPlace() -> (root: URL, anchor: NoteLinksModel.Anchor?)? {
        let doc = document.fileURL
        let folder = doc.deletingLastPathComponent()
        let grant = folderGrants.grant(for: folder)
        let root = NoteLinksModel.root(for: doc, granted: grant?.url,
                                       readable: grant == nil && PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: doc)))
        return root.map { ($0, grant) }
    }

    func presentNoteLinks(_ pane: NoteLinksView.Pane) {
        present(makeNoteLinksController(pane), animated: true)
    }

    /// The sheet's controller. Its callbacks hold it weakly, so once it is
    /// dismissed it and its model (and the model's read) go.
    func makeNoteLinksController(_ pane: NoteLinksView.Pane) -> UIHostingController<NoteLinksView> {
        let model = makeNoteLinksModel()
        // Weak: the hosting controller holds the view, whose callbacks would hold it back.
        let host = WeakBox<UIHostingController<NoteLinksView>>()
        let view = NoteLinksView(model: model, pane: pane, onHeading: { [weak self] h in
            host.value?.dismiss(animated: true) { self?.revealLine(h.line + 1) }
        }, onNote: { [weak self, weak model] url in
            host.value?.dismiss(animated: true) {
                // Only a note inside the folder that was read, checked again now.
                guard let self, let root = model?.root,
                      let note = NoteLinksModel.checkedNote(url, under: root, rootID: model?.rootID, anchor: model?.anchor) else {
                    self?.toast(String(localized: "That note isn’t in the folder Owlink can read."))
                    return
                }
                self.openLinked(note.url, expecting: note.id)
            }
        }, onChooseFolder: { [weak self, weak model] in
            guard let self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.directoryURL = self.document.fileURL.deletingLastPathComponent()
            picker.delegate = self.imagePickerDelegate
            self.imagePickerDelegate.picked = { [weak self] urls in
                guard let self, let folder = urls.first, let model else { return }
                self.folderGrants.add(folder)
                let grant = self.folderGrants.grant(for: model.document.deletingLastPathComponent())
                model.setRoot(NoteLinksModel.root(for: model.document, granted: grant?.url, readable: false), anchor: grant)
            }
            host.value?.present(picker, animated: true)
        })
        let controller = UIHostingController(rootView: view)
        host.value = controller
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return controller
    }

    /// The `[[wiki link]]` at `offset`, if the caret or selection is in one.
    func wikiLink(at offset: Int) -> WikiLinks.Link? {
        guard noteLinksApply, lineIndex.length == textView.textStorage.length, offset <= lineIndex.length else { return nil }
        let line = lineIndex.contentRange(ofLine: lineIndex.line(containing: offset))
        guard line.length <= WikiLinks.maxTypingColumn else { return nil }
        let text = (textView.textStorage.string as NSString).substring(with: line)
        let units = Array(text.utf16)
        let column = offset - line.location
        return units.withUnsafeBufferPointer { WikiLinks.link(at: column, inLine: $0) }
    }

    /// Where a wiki link leads (the vault's notes, as the preview resolves them).
    /// Within the sheet's root only (never a vault above what Owlink may
    /// read), and checked from the root's descriptor (`openableNote`).
    func wikiTarget(_ link: WikiLinks.Link) -> URL? { wikiNote(link)?.url }

    /// `wikiTarget`, with the file it was checked to be. A root inside a
    /// grant (the grant itself, or a vault below it) is opened beneath the
    /// grant as it was granted (`NoteLinksModel.openRoot`).
    func wikiNote(_ link: WikiLinks.Link) -> NoteLinksModel.CheckedNote? {
        guard let place = noteLinksPlace() else { return nil }
        let vault = WikiVault(documentFolder: document.fileURL.deletingLastPathComponent(), openedRoot: place.root)
        guard let url = vault.resolve(link.target) else { return nil }
        return NoteLinksModel.checkedNote(url, under: place.root, anchor: place.anchor)
    }

    /// The edit menu's "Open “Note”" when the caret is in a `[[link]]`
    /// (the Mac's click to open; a tap on iOS places the caret).
    func wikiLinkMenuAction(for range: NSRange) -> UIAction? {
        guard range.location != NSNotFound, let link = wikiLink(at: range.location), !link.embed else { return nil }
        let name = link.alias ?? link.target
        let a = UIAction(title: String(localized: "Open “\(name)”"), image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in
            guard let self else { return }
            guard let note = self.wikiNote(link) else {
                self.toast(String(localized: "No note named “\(link.target)” in the folder Owlink can read."))
                return
            }
            self.openLinked(note.url, expecting: note.id)
        }
        a.accessibilityIdentifier = "editor.openWikiLink"
        return a
    }
}

/// A weak reference a closure can hold.
final class WeakBox<T: AnyObject> {
    weak var value: T?
}
