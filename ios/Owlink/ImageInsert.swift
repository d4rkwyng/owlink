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

    /// Where the images go: the document's folder, when Owlink can write
    /// there. Nil when it has no folder access yet (ask for it).
    var imageFolder: URL? {
        let dir = document.fileURL.deletingLastPathComponent()
        if PreviewFolderGrants.shared.root(for: dir) != nil { return dir }
        return FileManager.default.isWritableFile(atPath: dir.path) ? dir : nil
    }

    func pickImageFiles() {
        guard markdownEditable else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.imageContentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = imagePickerDelegate
        imagePickerDelegate.picked = { [weak self] urls in self?.insertImageFiles(urls) }
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
    /// copied to a temporary folder first, then in like a picked file.
    private func loadPhotos(_ results: [PHPickerResult]) {
        guard !results.isEmpty else { return }
        let range = textView.selectedRange
        let generation = self.generation
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-photos-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
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
                let dest = tmp.appendingPathComponent(base).appendingPathExtension(ext)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    lock.withLock { copied.append((i, dest)) }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let self else { return }
            let files = copied.sorted { $0.0 < $1.0 }.map(\.1)
            guard !files.isEmpty else { self.toast(String(localized: "The photos couldn’t be read.")); return }
            // The caret stays where it was when the picker opened, unless the text changed since.
            let at = self.generation == generation ? range : self.textView.selectedRange
            self.insertImageFiles(files, at: at)
        }
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

    /// Copies `files` into "images" next to the document and inserts their
    /// links at `range` (the selection by default) as one undo step.
    /// Returns the paths inserted (tests), or nil when nothing went in.
    @discardableResult
    func insertImageFiles(_ files: [URL], at range: NSRange? = nil) -> [String]? {
        guard markdownEditable else { return nil }
        let images = files.filter { MarkdownPaste.isImageFile($0) }
        guard !images.isEmpty else {
            toast(String(localized: "Only image files can be inserted."))
            return nil
        }
        guard let dir = imageFolder else {
            askForImageFolder(then: { [weak self] in self?.insertImageFiles(images, at: range) })
            return nil
        }
        let store: ImageStore
        do {
            store = try ImageStore.open(in: dir)
        } catch let failure as ImageStore.Failure {
            showImageError(Self.imageStoreMessage(failure))
            return nil
        } catch {
            showImageError(error.localizedDescription)
            return nil
        }
        var names: [String] = []
        var failed = false
        for f in images {
            let scoped = f.startAccessingSecurityScopedResource()
            defer { if scoped { f.stopAccessingSecurityScopedResource() } }
            do {
                names.append(try store.copy(from: f, name: f.lastPathComponent))
            } catch let failure as ImageStore.Failure where failure == .notRegularFile || failure == .badName {
                failed = true
            } catch let failure as ImageStore.Failure {
                showImageError(Self.imageStoreMessage(failure))
                if names.isEmpty { return nil }
                break
            } catch {
                showImageError(error.localizedDescription)
                if names.isEmpty { return nil }
                break
            }
        }
        guard !names.isEmpty else {
            showImageError(Self.imageStoreMessage(.notRegularFile))
            return nil
        }
        // Just before inserting: each link must still lead to the file written.
        let paths: [String]
        do {
            paths = try names.map { try store.link(for: $0) }
        } catch {
            showImageError(Self.imageStoreMessage(.destinationChanged))
            return nil
        }
        let len = textView.textStorage.length
        let want = range ?? textView.selectedRange
        let loc = min(want.location == NSNotFound ? len : want.location, len)
        let r = NSRange(location: loc, length: min(want.length, len - loc))
        let s = MarkdownPaste.imageLinks(paths)
        applyTextEdit(TextEdit(range: r, replacement: s, selection: NSRange(location: r.location + (s as NSString).length, length: 0)),
                      actionName: String(localized: "Insert Image"))
        if failed { toast(String(localized: "Some files couldn’t be copied.")) }
        return paths
    }

    /// No access to the document's folder yet: the same folder grant the
    /// preview uses (it covers every document inside it).
    private func askForImageFolder(then: @escaping () -> Void) {
        let a = UIAlertController(title: String(localized: "Allow Owlink to use this folder?"),
                                  message: String(localized: "Images are copied into an “images” folder next to the document. Choose the document’s folder (or one above it) so Owlink can write there."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: String(localized: "Choose Folder…"), style: .default) { [weak self] _ in
            guard let self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.directoryURL = self.document.fileURL.deletingLastPathComponent()
            picker.delegate = self.imagePickerDelegate
            self.imagePickerDelegate.picked = { [weak self] urls in
                guard let self, let folder = urls.first else { return }
                PreviewFolderGrants.shared.add(folder)
                if self.imageFolder != nil { then() } else {
                    self.showImageError(String(localized: "That folder doesn’t hold this document, so images can’t be saved next to it."))
                }
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

/// The pickers' delegate (one per editor): hands back what was picked.
@MainActor
final class ImagePickerDelegate: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    var picked: (([URL]) -> Void)?
    var photos: (([PHPickerResult]) -> Void)?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = picked
        picked = nil
        done?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked = nil }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let done = photos
        photos = nil
        picker.dismiss(animated: true) { done?(results) }
    }
}
