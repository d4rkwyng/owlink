import UIKit
import CedricCore

/// Where the app keeps its safety copies, both private to the app and
/// kept out of iCloud and computer backups:
/// - recovery copies of unsaved text: Application Support/Owlink/Recovery
///   (not Caches: the system may empty Caches, and these must survive a
///   crash until they are offered);
/// - the bytes of each open document as opened (Revert to Opened Version):
///   Caches/Owlink/Opened, deleted when the document closes and at launch;
/// - safety copies made before anything replaces a file's bytes (conflict
///   versions, unsaved text before a reload, save history):
///   Application Support/Owlink/Copies, kept up to 7 days.
enum SaveSafetyStores {
    static let recovery: RecoveryStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RecoveryStore(directory: base.appendingPathComponent("Owlink/Recovery", isDirectory: true))
    }()

    static let revert: RevertStore = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return RevertStore(directory: base.appendingPathComponent("Owlink/Opened", isDirectory: true))
    }()

    static let copies: SafetyCopyStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SafetyCopyStore(directory: base.appendingPathComponent("Owlink/Copies", isDirectory: true))
    }()

    /// Serializes recovery writes and pre-save history work.
    static let queue = DispatchQueue(label: "app.owlink.recovery", qos: .utility)

    #if DEBUG
    static func flush() { queue.sync {} }
    #endif
}

/// Safety copies of one document, made before anything replaces its text.
enum DocumentCopies {
    /// The unsaved text, in the document's encoding (UTF-8 if it can't hold
    /// it). Synchronous: done before the question that could replace it.
    @MainActor @discardableResult
    static func keepUnsaved(_ text: String, of doc: TextDocument) -> Bool {
        let enc = TextCodec.encode(text, encoding: doc.encoding, lineEnding: doc.lineEnding)
        let copy = SafetyCopy(documentPath: doc.recoveryPath, displayName: doc.displayName, kind: .unsavedText,
                              encoding: enc == nil ? .utf8 : doc.encoding)
        return (try? SaveSafetyStores.copies.keep(enc ?? Data(text.utf8), as: copy)) != nil
    }

    /// The file as it is on disk now, read coordinated off the main thread.
    @MainActor static func keepDisk(of doc: TextDocument, kind: SafetyCopy.Kind, done: @escaping (Bool) -> Void) {
        let url = doc.fileURL, path = doc.recoveryPath, name = doc.displayName
        let store = SaveSafetyStores.copies
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSError?
            var data: Data?
            NSFileCoordinator(filePresenter: doc).coordinate(readingItemAt: url, options: [], error: &err) { u in
                data = try? Data(contentsOf: u)
            }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let ok = data.map { (try? store.keep($0, as: SafetyCopy(documentPath: path, displayName: name, kind: kind,
                                                                     sourceDate: modified))) != nil } ?? false
            DispatchQueue.main.async { done(ok) }
        }
    }
}

/// The documents open in an editor in this process, and which window
/// (scene session) has each: their recovery copies are live, not left
/// over from a crash, and a second open goes to that window.
@MainActor enum OpenDocuments {
    static var registry = OpenDocumentRegistry()

    static func isOpen(_ path: String) -> Bool { registry.contains(path: path) }

    /// The live window that has `url` open, if another one does. A window
    /// that is gone is forgotten.
    static func otherWindow(having url: URL, than window: String) -> UISceneSession? {
        guard let owner = registry.owner(ofPath: url.path), owner != window else { return nil }
        if let s = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == owner }) { return s }
        registry.removeAll(window: owner)
        return nil
    }
}

extension TextDocument {
    /// The key for its recovery copy.
    var recoveryPath: String { fileURL.standardizedFileURL.path }
}

/// Keeps a recovery copy of one editor's unsaved text: written at most
/// every 3 seconds while the document has unsaved changes (either save
/// mode), off the main thread and atomically; cleared on save and on a
/// clean close.
@MainActor final class RecoveryWriter {
    private weak var document: TextDocument?
    private let path: String
    private let snapshot: () -> String
    private var timer: Timer?
    private var lastWrite: Date?
    private var bookmark: Data?
    private var stopped = false

    init(document: TextDocument, snapshot: @escaping () -> String) {
        self.document = document
        self.path = document.recoveryPath
        self.snapshot = snapshot
    }

    /// The text changed: write soon (now, or when 3 s have passed since the last write).
    func textChanged() {
        guard !stopped, timer == nil, document?.hasUnsavedChanges == true else { return }
        let delay = RecoveryThrottle.delay(sinceLastWrite: lastWrite.map { Date().timeIntervalSince($0) })
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeNow() }
        }
    }

    /// Writes at once (going to the background).
    func writeNow() {
        timer?.invalidate()
        timer = nil
        guard !stopped, let doc = document, doc.hasUnsavedChanges else { return }
        if bookmark == nil { bookmark = try? doc.fileURL.bookmarkData(options: .minimalBookmark) }
        lastWrite = Date()
        let record = RecoveryRecord(documentPath: path, displayName: doc.displayName, bookmark: bookmark, savedAt: Date(),
                                    text: snapshot(), encoding: doc.encoding, lineEnding: doc.lineEnding)
        let store = SaveSafetyStores.recovery
        SaveSafetyStores.queue.async { try? store.write(record) }
    }

    /// Saved (or closed cleanly): the copy goes. Later edits write again.
    func clear() {
        timer?.invalidate()
        timer = nil
        lastWrite = nil
        let store = SaveSafetyStores.recovery, path = path
        SaveSafetyStores.queue.async { store.clear(documentPath: path) }
    }

    /// The editor closed: clear (or keep, if the save failed) and write no more.
    func stop(keepingCopy: Bool) {
        if !keepingCopy { clear() }
        timer?.invalidate()
        timer = nil
        stopped = true
    }
}

/// At launch: recovery copies left by a crash or a forced quit, offered
/// one at a time.
@MainActor enum RecoveryOffer {
    private static var offeredAtLaunch = false

    /// Launched to open a file, or by a test: no offer this launch (the
    /// file opened still gets its own).
    static func skipLaunchOffer() { offeredAtLaunch = true }

    static func offerLeftovers(from browser: DocumentBrowserViewController) {
        guard !offeredAtLaunch else { return }
        offeredAtLaunch = true
        let records = SaveSafetyStores.recovery.all().filter { !OpenDocuments.isOpen($0.documentPath) }
        offer(records[...], from: browser)
    }

    private static func offer(_ records: ArraySlice<RecoveryRecord>, from browser: DocumentBrowserViewController) {
        guard let r = records.first else { return }
        let rest = records.dropFirst()
        let url = resolve(r)
        let modified = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        // Saved since (here or on another device): nothing to offer.
        if url != nil, !r.isNewer(thanDocumentModified: modified) {
            SaveSafetyStores.recovery.clear(documentPath: r.documentPath)
            offer(rest, from: browser)
            return
        }
        let a = alert(for: r) { restore in
            if restore {
                if let url {
                    browser.presentDocument(at: url, recovered: r)
                } else {
                    notFound(r, from: browser) { offer(rest, from: browser) }
                    return
                }
            } else {
                SaveSafetyStores.recovery.clear(documentPath: r.documentPath)
            }
            // The next one once this is dealt with (after the editor, if one opened).
            if url == nil || !restore { offer(rest, from: browser) }
        }
        browser.present(a, animated: true)
    }

    /// "Owlink closed with unsaved changes in X. Restore?"
    static func alert(for r: RecoveryRecord, done: @escaping (Bool) -> Void) -> UIAlertController {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        let a = UIAlertController(title: String(localized: "Owlink closed with unsaved changes in \(r.displayName). Restore?"),
                                  message: String(localized: "Last copied \(f.string(from: r.savedAt))."), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Discard"), style: .destructive) { _ in done(false) })
        a.addAction(UIAlertAction(title: String(localized: "Restore"), style: .default) { _ in done(true) })
        a.preferredAction = a.actions.last
        return a
    }

    private static func resolve(_ r: RecoveryRecord) -> URL? {
        if let b = r.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = u.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        let u = URL(fileURLWithPath: r.documentPath)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// The document can't be found: the text can still be copied.
    private static func notFound(_ r: RecoveryRecord, from browser: UIViewController, then: @escaping () -> Void) {
        let a = UIAlertController(title: String(localized: "Couldn’t find \(r.displayName)"),
                                  message: String(localized: "Copy the unsaved text to the clipboard, to paste it into another document?"),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Discard"), style: .destructive) { _ in
            SaveSafetyStores.recovery.clear(documentPath: r.documentPath)
            then()
        })
        a.addAction(UIAlertAction(title: String(localized: "Copy Text"), style: .default) { _ in
            UIPasteboard.general.string = r.text
            SaveSafetyStores.recovery.clear(documentPath: r.documentPath)
            then()
        })
        browser.present(a, animated: true)
    }
}
