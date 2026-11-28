import SwiftUI
import UIKit
import CedricCore

/// Wiki links and tags on iOS (Mac 0.6.0's Backlinks beside Outline, and
/// the Tags pane), as one sheet instead of sidebars: Outline (the note's
/// headings), Backlinks (the notes whose `[[links]]` lead here) and Tags
/// (every #tag in the folder and the notes holding it). The notes are those
/// under the vault: the Obsidian vault inside the folder the preview was
/// granted, else that folder (`WikiVault.vaultRoot`), else the document's
/// own folder when Owlink can read it. Read once when the sheet opens, off
/// the main thread, by the shared `NoteIndex`, `BacklinkScan` and `TagTree`;
/// nothing is written and there is no live watcher.
@MainActor
final class NoteLinksModel: ObservableObject {
    enum State: Equatable { case idle, reading, ready, noFolder, notInFolder }

    @Published private(set) var state: State = .idle
    @Published private(set) var backlinks: [BacklinkScan.Backlink] = []
    @Published private(set) var tags: TagTree?
    @Published private(set) var partial = false
    @Published private(set) var truncated = false
    let headings: [MarkdownOutline.Heading]
    let document: URL
    private(set) var root: URL?
    /// The current read (tests await it).
    private(set) var task: Task<Void, Never>?

    init(document: URL, root: URL?, headings: [MarkdownOutline.Heading]) {
        self.document = document.standardizedFileURL
        self.root = root?.standardizedFileURL
        self.headings = headings
    }

    /// The notes' folder for `document`: see the type's comment.
    static func root(for document: URL, granted: URL?, readable: Bool) -> URL? {
        let folder = document.deletingLastPathComponent()
        if let granted { return WikiVault.vaultRoot(for: folder, granted: granted) ?? granted }
        return readable ? folder : nil
    }

    func url(of rel: String) -> URL? { root?.appendingPathComponent(rel) }

    func load() {
        guard let root else { state = .noFolder; return }
        guard let rel = Self.relativePath(of: document, under: root) else { state = .notInFolder; return }
        state = .reading
        task?.cancel()
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.read(root: root, note: rel) }.value
            guard let self, !Task.isCancelled else { return }
            self.backlinks = result.backlinks
            self.tags = result.tags
            self.partial = result.partial
            self.truncated = result.truncated
            self.state = .ready
        }
    }

    func setRoot(_ url: URL?) {
        root = url?.standardizedFileURL
        load()
    }

    nonisolated static func relativePath(of file: URL, under root: URL) -> String? {
        for (f, r) in [(file.standardizedFileURL.path, root.standardizedFileURL.path),
                       (file.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)] {
            let prefix = r.hasSuffix("/") ? r : r + "/"
            if f.hasPrefix(prefix) { return String(f.dropFirst(prefix.count)) }
        }
        return nil
    }

    struct ReadResult: Sendable {
        var backlinks: [BacklinkScan.Backlink]
        var tags: TagTree
        var partial: Bool
        var truncated: Bool
    }

    /// The notes under `root` (relative paths), as the vault lists them:
    /// no hidden files or folders, at most `WikiVault.maxDepth` deep and
    /// `WikiVault.maxEntries` entries.
    nonisolated static func notes(under root: URL) -> (paths: [String], truncated: Bool) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        var out: [String] = []
        var seen = 0
        var truncated = false
        while let url = e.nextObject() as? URL {
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

    nonisolated static func read(root: URL, note: String) -> ReadResult {
        let listed = notes(under: root)
        let index = NoteIndex(paths: listed.paths)
        var scan = BacklinkScan(root: root)
        scan.update(notes: index.paths, dirty: nil, tags: true)
        return ReadResult(backlinks: scan.backlinks(to: note, in: index), tags: TagTree(files: scan.tagsByNote),
                          partial: scan.isPartial, truncated: listed.truncated)
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
        .task { if model.state == .idle { model.load() } }
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
        let folder = document.fileURL.deletingLastPathComponent()
        let granted = PreviewFolderGrants.shared.root(for: folder)
        let readable = PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: document.fileURL))
        let headings = document.language.language == .markdown ? MarkdownOutline.headings(in: textView.text) : []
        return NoteLinksModel(document: document.fileURL,
                              root: NoteLinksModel.root(for: document.fileURL, granted: granted, readable: readable),
                              headings: headings)
    }

    func presentNoteLinks(_ pane: NoteLinksView.Pane) {
        let model = makeNoteLinksModel()
        var host: UIHostingController<NoteLinksView>!
        let view = NoteLinksView(model: model, pane: pane, onHeading: { [weak self] h in
            host.dismiss(animated: true) { self?.revealLine(h.line + 1) }
        }, onNote: { [weak self] url in
            host.dismiss(animated: true) {
                // Only a note under the folder that was read.
                guard let self, let root = model.root, NoteLinksModel.relativePath(of: url, under: root) != nil else { return }
                self.openLinked(url)
            }
        }, onChooseFolder: { [weak self] in
            guard let self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.directoryURL = self.document.fileURL.deletingLastPathComponent()
            picker.delegate = self.imagePickerDelegate
            self.imagePickerDelegate.picked = { urls in
                guard let folder = urls.first else { return }
                PreviewFolderGrants.shared.add(folder)
                let granted = PreviewFolderGrants.shared.root(for: model.document.deletingLastPathComponent())
                model.setRoot(NoteLinksModel.root(for: model.document, granted: granted, readable: false))
            }
            host.present(picker, animated: true)
        })
        host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
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
    func wikiTarget(_ link: WikiLinks.Link) -> URL? {
        let folder = document.fileURL.deletingLastPathComponent()
        let vault = WikiVault(documentFolder: folder,
                              openedRoot: WikiVault.vaultRoot(for: folder, granted: PreviewFolderGrants.shared.root(for: folder)))
        return vault.resolve(link.target)
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
