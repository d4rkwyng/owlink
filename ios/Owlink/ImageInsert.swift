import UIKit
import PhotosUI
import UniformTypeIdentifiers
import CedricCore

/// The Context Bar's Image button and Format › Markdown › Insert Image…,
/// as on the Mac (0.6.0): picked images are copied into the "images"
/// folder next to the document by the shared `ImageStore` (descriptors,
/// kept beneath the document's folder, never overwriting, no partial file
/// under a final name), and relative links go in as one undo step.
///
/// On iOS the images come from Files (a copy of each picked file) or the
/// photo library (the system picker runs out of process, so no photo
/// library permission is asked). Owlink may only write next to the
/// document inside a folder it was given (the preview's "Open the folder"
/// grant, or its own container); otherwise it asks for the folder first.
extension EditorViewController {
    /// Format › Markdown › Insert Image…: the Files picker.
    @objc func markdownInsertImageFileMenu(_ sender: Any?) { pickImageFiles() }

    /// The Image button's menu: Photos, Files, or the old empty image link.
    func imageInsertMenu() -> UIMenu {
        let photos = UIAction(title: String(localized: "Photo Library…"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
            self?.pickImagePhotos()
        }
        photos.accessibilityIdentifier = "contextbar.image.photos"
        let files = UIAction(title: String(localized: "Choose File…"), image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.pickImageFiles()
        }
        files.accessibilityIdentifier = "contextbar.image.files"
        let link = UIAction(title: String(localized: "Image Link"), image: UIImage(systemName: "link")) { [weak self] _ in
            self?.markdownImageMenu(nil)
        }
        link.accessibilityIdentifier = "contextbar.image.link"
        return UIMenu(children: [photos, files, UIMenu(options: .displayInline, children: [link])])
    }

    /// Tests: the app container Owlink may write in without a grant
    /// (nil: the app's home folder).
    nonisolated(unsafe) static var imageContainerForTests: URL?

    /// Where images go: the document's folder, the root it is opened
    /// beneath, and for a granted folder the identity it was granted with.
    struct ImageDestination: Sendable {
        var folder: URL
        var root: URL
        /// The granted root as it was granted (device and inode).
        var rootID: Beneath.FileID?
        /// `root` is a folder grant: `rootID` is required.
        var granted: Bool
    }

    /// Where the images go. Under a folder grant: the root is the grant as
    /// the registry recorded it (where it was then, and its identity),
    /// never resolved again, and the document's folder (symbolic links
    /// resolved) must be inside it; a grant that matched decides alone
    /// (nil when the folder now leads out of it, never the container).
    /// With no grant, Owlink's own container, both resolved.
    /// `ImageStore.open(in:beneath:rootID:)` then opens the root without
    /// following a link, checks it is still the folder granted, and
    /// refuses a link out of it on the way. Nil when Owlink has no such
    /// access yet (ask).
    var imageDestination: ImageDestination? {
        let dir = document.fileURL.deletingLastPathComponent()
        let container = Self.imageContainerForTests ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return Self.imageDestination(for: dir, grant: folderGrants.grant(for: dir), container: container)
    }

    nonisolated static func imageDestination(for dir: URL, grant: PreviewFolderGrants.Grant?, container: URL) -> ImageDestination? {
        let folder = dir.resolvingSymlinksInPath().standardizedFileURL
        func inside(_ root: URL) -> Bool {
            let base = root.pathComponents, path = folder.pathComponents
            return path.count >= base.count && Array(path.prefix(base.count)) == base
        }
        if let grant {
            let root = grant.resolved.standardizedFileURL
            return inside(root) ? ImageDestination(folder: folder, root: root, rootID: grant.id, granted: true) : nil
        }
        let root = container.resolvingSymlinksInPath().standardizedFileURL
        return inside(root) ? ImageDestination(folder: folder, root: root, rootID: nil, granted: false) : nil
    }

    /// Tests: `granted` taken as a grant made just now.
    nonisolated static func imageDestination(for dir: URL, granted: URL?, container: URL) -> ImageDestination? {
        let grant = granted.map { g -> PreviewFolderGrants.Grant in
            let resolved = g.resolvingSymlinksInPath().standardizedFileURL
            return PreviewFolderGrants.Grant(url: g.standardizedFileURL, resolved: resolved,
                                             id: Beneath.FileID(path: resolved.path, followLast: false))
        }
        return imageDestination(for: dir, grant: grant, container: container)
    }

    func pickImageFiles() {
        guard markdownEditable else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.imageContentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = imagePickerDelegate
        imagePickerDelegate.picked = { [weak self] urls in
            Task { await self?.insertImageFiles(urls) }
        }
        present(picker, animated: true)
    }

    func pickImagePhotos() {
        guard markdownEditable else { return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = imagePickerDelegate
        imagePickerDelegate.photos = { [weak self] results in self?.loadPhotos(results) }
        present(picker, animated: true)
    }

    static var imageContentTypes: [UTType] {
        MarkdownPaste.imageExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// Photos come as files the picker hands over for the call only:
    /// copied to a temporary folder first (one folder per photo, so two
    /// with the same suggested name both stay), then in like a picked
    /// file. The insertion owns that folder (`StagedImages`) until it is
    /// done, cancelled or failed, a folder grant asked for on the way too.
    private func loadPhotos(_ results: [PHPickerResult]) {
        guard !results.isEmpty else { return }
        let range = textView.selectedRange
        let generation = self.generation
        let staging = StagedImages()
        let tmp = staging.dir
        let group = DispatchGroup()
        let lock = NSLock()
        var copied: [(Int, URL)] = []
        for (i, result) in results.enumerated() {
            let provider = result.itemProvider
            let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .image) } ?? .image
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "jpg") : url.pathExtension
                let base = Self.photoName(suggested: provider.suggestedName, index: i)
                guard let dest = Self.stagedPhotoURL(in: tmp, index: i, name: base, ext: ext) else { return }
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    lock.withLock { copied.append((i, dest)) }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let files = lock.withLock { copied.sorted { $0.0 < $1.0 }.map(\.1) }
            guard !files.isEmpty else { self.toast(String(localized: "The photos couldn’t be read.")); return }
            // The caret stays where it was when the picker opened, unless the text changed since.
            let at = self.generation == generation ? range : self.textView.selectedRange
            Task { await self.insertImageFiles(files, at: at, staging: staging) }
        }
    }

    /// Where photo `index` is staged: its own folder in `tmp` (made), so
    /// equal names never meet.
    nonisolated static func stagedPhotoURL(in tmp: URL, index: Int, name: String, ext: String) -> URL? {
        let dir = tmp.appendingPathComponent(String(index), isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// A photo's file name: the picker's suggestion (one name, no path),
    /// else "photo-<date>-<n>".
    nonisolated static func photoName(suggested: String?, index: Int, now: Date = Date()) -> String {
        if let s = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
           !s.contains("/"), !s.contains("\0"), s != ".", s != ".." {
            return s
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "photo-\(f.string(from: now))" + (index > 0 ? "-\(index + 1)" : "")
    }

    /// Copies `files` into "images" next to the document (off the main
    /// thread) and inserts their links as one undo step: at `range` (the
    /// selection by default) if the text is unchanged since, else at the
    /// selection then; nothing when the document changed. Each source is
    /// opened without following a symbolic link and must be a regular
    /// file. `staging` (photos) is kept until this is over, a folder grant
    /// asked for first included. Returns the paths inserted (tests), or
    /// nil when nothing went in.
    @discardableResult
    func insertImageFiles(_ files: [URL], at range: NSRange? = nil, staging: StagedImages? = nil) async -> [String]? {
        guard markdownEditable else { return nil }
        let images = files.filter { MarkdownPaste.isImageFile($0) }
        guard !images.isEmpty else {
            toast(String(localized: "Only image files can be inserted."))
            return nil
        }
        guard let dest = imageDestination else {
            imagePickerDelegate.pendingInsert = PendingImageInsert(files: images, range: range, generation: generation, staging: staging)
            askForImageFolder()
            return nil
        }
        let doc = document
        let generation = self.generation
        let want = range ?? textView.selectedRange
        // The destination carries the granted folder's identity (none for Owlink's own container).
        let copied = await Task.detached(priority: .userInitiated) { Self.copyImages(images, to: dest) }.value
        withExtendedLifetime(staging) {}
        // Back on the main thread: still this document, not closing, still editable.
        guard document === doc, !closing, markdownEditable else { return nil }
        if let error = copied.error { showImageError(error) }
        guard let store = copied.store, !copied.names.isEmpty else {
            if copied.error == nil { showImageError(Self.imageStoreMessage(.notRegularFile)) }
            return nil
        }
        // Just before inserting: each link must still lead to the file written.
        let paths: [String]
        do {
            paths = try copied.names.map { try store.link(for: $0) }
        } catch {
            showImageError(Self.imageStoreMessage(.destinationChanged))
            return nil
        }
        let len = textView.textStorage.length
        let at = self.generation == generation ? want : textView.selectedRange
        let loc = min(at.location == NSNotFound ? len : at.location, len)
        let r = NSRange(location: loc, length: min(at.length, len - loc))
        let s = MarkdownPaste.imageLinks(paths)
        guard applyTextEdit(TextEdit(range: r, replacement: s, selection: NSRange(location: r.location + (s as NSString).length, length: 0)),
                            actionName: String(localized: "Insert Image")) else { return nil }
        if copied.failed { toast(String(localized: "Some files couldn’t be copied.")) }
        return paths
    }

    /// What `copyImages` hands back to the main thread. The store is used
    /// there only for `link(for:)`, after the copies are over.
    struct ImageCopies: @unchecked Sendable {
        var store: ImageStore?
        var names: [String] = []
        var failed = false
        var error: String?
    }

    /// Tests: a destination given as two folders (`rootID` when known).
    nonisolated static func copyImages(_ images: [URL], to dest: (folder: URL, root: URL), rootID: Beneath.FileID? = nil) -> ImageCopies {
        copyImages(images, to: ImageDestination(folder: dest.folder, root: dest.root, rootID: rootID, granted: rootID != nil))
    }

    /// The copies, off the main thread: "images" opened beneath `dest.root`
    /// (itself not a symbolic link, and for a grant still the folder
    /// granted: refused without its identity), each source opened without
    /// following a link.
    nonisolated static func copyImages(_ images: [URL], to dest: ImageDestination) -> ImageCopies {
        var out = ImageCopies()
        guard !dest.granted || dest.rootID != nil else {
            out.error = imageStoreMessage(.outside)
            return out
        }
        let store: ImageStore
        do {
            store = try ImageStore.open(in: dest.folder, beneath: dest.root, rootID: dest.rootID)
        } catch let failure as ImageStore.Failure {
            out.error = imageStoreMessage(failure)
            return out
        } catch {
            out.error = error.localizedDescription
            return out
        }
        out.store = store
        for f in images {
            let scoped = f.startAccessingSecurityScopedResource()
            defer { if scoped { f.stopAccessingSecurityScopedResource() } }
            do {
                out.names.append(try store.copy(from: f, name: f.lastPathComponent, followLink: false))
            } catch let failure as ImageStore.Failure where failure == .notRegularFile || failure == .badName {
                out.failed = true
            } catch let failure as ImageStore.Failure {
                out.error = imageStoreMessage(failure)
                break
            } catch {
                out.error = error.localizedDescription
                break
            }
        }
        return out
    }

    /// The insertion waiting for a folder grant goes ahead (its staged
    /// photos still there), or, without access still, is dropped.
    @discardableResult
    func resumePendingImageInsert() async -> [String]? {
        guard let pending = imagePickerDelegate.pendingInsert else { return nil }
        imagePickerDelegate.pendingInsert = nil
        guard imageDestination != nil else {
            showImageError(String(localized: "That folder doesn’t hold this document, so images can’t be saved next to it."))
            return nil
        }
        let at = pending.generation == generation ? pending.range : nil
        return await insertImageFiles(pending.files, at: at, staging: pending.staging)
    }

    /// No access to the document's folder yet: the same folder grant the
    /// preview uses (it covers every document inside it). The pending
    /// insertion waits; Cancel (here or in the picker) drops it.
    private func askForImageFolder() {
        let a = UIAlertController(title: String(localized: "Allow Owlink to use this folder?"),
                                  message: String(localized: "Images are copied into an “images” folder next to the document. Choose the document’s folder (or one above it) so Owlink can write there."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.imagePickerDelegate.pendingInsert = nil
        })
        a.addAction(UIAlertAction(title: String(localized: "Choose Folder…"), style: .default) { [weak self] _ in
            guard let self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.directoryURL = self.document.fileURL.deletingLastPathComponent()
            picker.delegate = self.imagePickerDelegate
            self.imagePickerDelegate.cancelled = { [weak self] in self?.imagePickerDelegate.pendingInsert = nil }
            self.imagePickerDelegate.picked = { [weak self] urls in
                guard let self else { return }
                guard let folder = urls.first else { self.imagePickerDelegate.pendingInsert = nil; return }
                self.folderGrants.add(folder)
                Task { await self.resumePendingImageInsert() }
            }
            self.present(picker, animated: true)
        })
        present(a, animated: true)
    }

    private func showImageError(_ text: String) {
        let a = UIAlertController(title: String(localized: "Couldn’t insert the image"), message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }

    /// What the user is told when ImageStore refuses (the Mac's wording, iOS terms).
    nonisolated static func imageStoreMessage(_ failure: ImageStore.Failure) -> String {
        switch failure {
        case .outside:
            return String(localized: "The “images” folder next to this document points outside its folder, so images aren’t saved there.")
        case .destinationChanged:
            return String(localized: "The “images” folder next to this document changed while the images were copied, so no links were inserted.")
        case .imagesIsLink:
            return String(localized: "The “images” folder next to this document is a symbolic link; images are only saved in a real folder.")
        case .otherVolume:
            return String(localized: "The “images” folder next to this document is on a different volume from the document, so images can’t be saved there.")
        case .notRegularFile, .badName:
            return String(localized: "The image couldn’t be copied.")
        }
    }
}

/// Photos staged for an insertion: a temporary folder, removed when the
/// last holder (the insertion, or one waiting for a folder grant) lets go.
final class StagedImages: @unchecked Sendable {
    let dir: URL
    init(in parent: URL = FileManager.default.temporaryDirectory) {
        dir = parent.appendingPathComponent("owlink-photos-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
}

/// An insertion waiting for the folder grant.
struct PendingImageInsert {
    var files: [URL]
    var range: NSRange?
    var generation: Int
    var staging: StagedImages?
}

/// The pickers' delegate (one per editor): hands back what was picked.
@MainActor
final class ImagePickerDelegate: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    var picked: (([URL]) -> Void)?
    /// The document picker was cancelled (once, then cleared).
    var cancelled: (() -> Void)?
    var photos: (([PHPickerResult]) -> Void)?
    /// The image insertion waiting for a folder grant (it owns its staged photos).
    var pendingInsert: PendingImageInsert?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = picked
        picked = nil
        cancelled = nil
        done?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let done = cancelled
        picked = nil
        cancelled = nil
        done?()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let done = photos
        photos = nil
        picker.dismiss(animated: true) { done?(results) }
    }
}
