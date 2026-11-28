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
/// shared `NoteIndex`, `BacklinkScan` and `TagTree`; cancelled when the
/// sheet goes or the root changes (the listing and each note check it).
/// One read takes at most `maxTotalBytes` of notes and keeps at most
/// `maxBacklinks` backlinks and `maxTagRefs` tag places; past those the
/// sheet says some notes weren't read. Nothing is written and there is no
/// live watcher.
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

    @Published private(set) var state: State = .idle
    @Published private(set) var backlinks: [BacklinkScan.Backlink] = []
    @Published private(set) var tags: TagTree?
    @Published private(set) var partial = false
    @Published private(set) var truncated = false
    let headings: [MarkdownOutline.Heading]
    let document: URL
    private(set) var root: URL?
    /// Finds `root` off the main thread on the first load, when it isn't
    /// given (the folder probe lists the document's folder).
    private var findRoot: (@Sendable () -> URL?)?
    /// The current read (tests await it).
    private(set) var task: Task<Void, Never>?
    private var work: Task<Outcome, Never>?

    init(document: URL, root: URL?, headings: [MarkdownOutline.Heading], findRoot: (@Sendable () -> URL?)? = nil) {
        self.document = document.standardizedFileURL
        self.root = root?.standardizedFileURL
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
        let doc = document, known = root, find = findRoot
        let work = Task.detached(priority: .userInitiated) { () -> Outcome in
            guard let root = known ?? find?() else { return .noFolder }
            guard let rel = Self.relativePath(of: doc, under: root) else { return .notInFolder(root) }
            guard let result = Self.read(root: root, note: rel, cancelled: { Task.isCancelled }) else { return .cancelled }
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

    func setRoot(_ url: URL?) {
        root = url?.standardizedFileURL
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
    nonisolated static func openableNote(_ url: URL, under root: URL) -> URL? {
        guard let rel = relativePath(of: url, under: root) else { return nil }
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fd = Beneath.open(parts, beneath: dir, flags: O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return root.appendingPathComponent(rel)
    }

    struct ReadResult: Sendable {
        var backlinks: [BacklinkScan.Backlink]
        var tags: TagTree
        var partial: Bool
        var truncated: Bool
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

    /// Backlinks to `note` and the tags under `root`, within the caps (see
    /// the type's comment); nil when `cancelled` said stop. `listed`: the
    /// notes as listed earlier (tests: a note swapped after the listing).
    nonisolated static func read(root: URL, note: String, listed given: [String]? = nil,
                                 cancelled: () -> Bool = { false }) -> ReadResult? {
        let listed = given.map { (paths: $0, truncated: false) } ?? notes(under: root, cancelled: cancelled)
        if cancelled() { return nil }
        let index = NoteIndex(paths: listed.paths)
        var scan = BacklinkScan(root: root)
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dir >= 0 {
            defer { close(dir) }
            var budget = maxTotalBytes
            scan.update(notes: index.paths, dirty: nil, tags: true, cancelled: cancelled, read: { rel in
                let r = BacklinkScan.readBeneath(rel, root: dir, maxBytes: min(BacklinkScan.maxFileBytes, budget))
                if case .read(let size, _, _) = r { budget -= size }
                return r
            })
        }
        if cancelled() { return nil }
        var truncated = listed.truncated
        var backlinks = scan.backlinks(to: note, in: index)
        if backlinks.count > maxBacklinks {
            backlinks = Array(backlinks.prefix(maxBacklinks))
            truncated = true
        }
        var kept: [String: [Tags.Ref]] = [:]
        var room = maxTagRefs
        for (rel, refs) in scan.tagsByNote.sorted(by: { $0.key < $1.key }) {
            guard room > 0 else { truncated = true; break }
            if refs.count > room { truncated = true }
            kept[rel] = Array(refs.prefix(room))
            room -= min(room, refs.count)
        }
        return ReadResult(backlinks: backlinks, tags: TagTree(files: kept),
                          partial: scan.isPartial || dir < 0, truncated: truncated)
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
        let granted = PreviewFolderGrants.shared.root(for: folder)
        let headings = document.language.language == .markdown ? MarkdownOutline.headings(in: textView.text) : []
        // The folder probe and the vault walk run off the main thread, on the first read.
        return NoteLinksModel(document: doc, root: nil, headings: headings, findRoot: {
            NoteLinksModel.root(for: doc, granted: granted,
                                readable: granted == nil && PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: doc)))
        })
    }

    /// The notes' root for this document, as the sheet finds it (one
    /// policy for both): see `NoteLinksModel`.
    func noteLinksRoot() -> URL? {
        let doc = document.fileURL
        let folder = doc.deletingLastPathComponent()
        let granted = PreviewFolderGrants.shared.root(for: folder)
        return NoteLinksModel.root(for: doc, granted: granted,
                                   readable: granted == nil && PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: doc)))
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
                guard let self, let root = model?.root, let note = NoteLinksModel.openableNote(url, under: root) else {
                    self?.toast(String(localized: "That note isn’t in the folder Owlink can read."))
                    return
                }
                self.openLinked(note)
            }
        }, onChooseFolder: { [weak self, weak model] in
            guard let self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.directoryURL = self.document.fileURL.deletingLastPathComponent()
            picker.delegate = self.imagePickerDelegate
            self.imagePickerDelegate.picked = { urls in
                guard let folder = urls.first, let model else { return }
                PreviewFolderGrants.shared.add(folder)
                let granted = PreviewFolderGrants.shared.root(for: model.document.deletingLastPathComponent())
                model.setRoot(NoteLinksModel.root(for: model.document, granted: granted, readable: false))
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
    func wikiTarget(_ link: WikiLinks.Link) -> URL? {
        guard let root = noteLinksRoot() else { return nil }
        let vault = WikiVault(documentFolder: document.fileURL.deletingLastPathComponent(), openedRoot: root)
        guard let url = vault.resolve(link.target) else { return nil }
        return NoteLinksModel.openableNote(url, under: root)
    }

    /// The edit menu's "Open “Note”" when the caret is in a `[[link]]`
    /// (the Mac's click to open; a tap on iOS places the caret).
    func wikiLinkMenuAction(for range: NSRange) -> UIAction? {
        guard range.location != NSNotFound, let link = wikiLink(at: range.location), !link.embed else { return nil }
        let name = link.alias ?? link.target
        let a = UIAction(title: String(localized: "Open “\(name)”"), image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in
            guard let self else { return }
            guard let url = self.wikiTarget(link) else {
                self.toast(String(localized: "No note named “\(link.target)” in the folder Owlink can read."))
                return
            }
            self.openLinked(url)
        }
        a.accessibilityIdentifier = "editor.openWikiLink"
        return a
    }
}

/// A weak reference a closure can hold.
final class WeakBox<T: AnyObject> {
    weak var value: T?
}
