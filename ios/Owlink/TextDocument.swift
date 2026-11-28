import UIKit
import UniformTypeIdentifiers
import CedricCore

/// One text file, opened through the Files app (local, iCloud Drive or
/// any file provider). Reading and writing go through the core's
/// `TextCodec`, as on the Mac: the encoding and line ending are detected on
/// open, the text is held with LF line endings, and saving writes the
/// file's own encoding and line ending back.
///
/// Byte for byte: a save whose text and format are what is on disk writes
/// nothing (`DiskState`); a file that mixes line endings keeps each
/// unchanged line's own; UTF-16 without a byte-order mark gets none.
final class TextDocument: UIDocument {
    /// Accessed only by the safety queue; each read starts a new sequence.
    private final class ReadHistory: @unchecked Sendable {
        var hasCopy = false
    }

    enum OpenError: LocalizedError {
        case binary, undecodable, unencodable(TextEncoding)
        var errorDescription: String? {
            switch self {
            case .binary: return String(localized: "This file looks like a binary file, not text.")
            case .undecodable: return String(localized: "Owlink couldn’t read this file as text.")
            case .unencodable(let e): return String(localized: "Some characters can’t be saved as \(e.displayName). Choose UTF-8 in the document menu.")
            }
        }
    }

    /// LF-normalised text.
    var text = ""
    var encoding: TextEncoding = .utf8
    /// Not valid UTF-8: read as the 8-bit encoding TextCodec guessed. The
    /// editor says so (Reopen with Encoding… / Keep), as the Mac's bar.
    var encodingGuessed = false
    var lineEnding: LineEnding = .lf
    var mixedLineEndings = false
    /// The line endings as read, while the file mixes them (0.6.0 LineBreaks).
    private var lineBreaks: LineBreaks?
    /// What is on disk: as read, then as last written.
    private(set) var onDisk: DiskState? {
        didSet { onDiskUTF16Length = onDisk?.text.utf16.count }
    }
    private(set) var onDiskUTF16Length: Int?
    private(set) var savesInFlight = 0
    private(set) var diskStateStale = false
    /// A disk comparison is safe only while the snapshot is current.
    var cleanCheckAllowed: Bool {
        savesInFlight == 0 && !diskStateStale && !externalChangePending && !documentState.contains(.inConflict)
    }
    /// What the save in progress writes (becomes `onDisk` if it succeeds).
    private var writing: (state: DiskState, breaks: LineBreaks?, bytes: Data?)?
    /// The bytes as read or last written, unless over the copy store's cap.
    private var bytesOnDisk: Data?
    private var readHistory = ReadHistory()
    private var autosaveInProgress = false
    var language = LanguageChoice()
    /// Allows opening a file that looks binary (asked once).
    var openBinaryAnyway = false
    /// Called on the main queue after the file was (re)read from disk.
    var onReload: (() -> Void)?
    /// Called on the main queue when the file changed on disk while there
    /// were unsaved edits: nothing was reloaded; the editor asks Keep Mine
    /// / Use Theirs.
    var onExternalChange: (() -> Void)?
    /// The app asked for the next revert itself (Use Theirs, Keep Other).
    private var revertChosen = false
    /// Keep Mine / Use Theirs is being asked.
    private(set) var externalChangePending = false
    /// Set by the editor: returns its current text before a save.
    var currentText: (() -> String)?
    private(set) var firstUnsavedEdit: Date?
    /// Called on the main queue when `hasUnsavedChanges` may have changed
    /// (an edit, a save, a revert): the editor's "Edited" mark.
    var onEditedChange: (() -> Void)?
    /// Called on the main queue after a save that succeeded.
    var onSaved: (() -> Void)?
    /// Called on the main queue when a save failed (the error as UIDocument
    /// handed it over; the text stays, unsaved).
    var onSaveError: ((Error) -> Void)?
    /// Called on the main queue when UIDocument disables or enables editing.
    var onEditingAllowed: ((Bool) -> Void)?
    /// The last save failed for a reason only an edit can change (a
    /// character the encoding can't hold): autosave waits for an edit.
    private(set) var saveBlockedUntilEdited = false
    /// "Save automatically" (Settings): read at each autosave.
    var saveAutomatically: () -> Bool = { AppSettings.saveAutomatically }
    /// The document for a note opened from a link (`expecting`: the file it
    /// was checked to be, nil for any).
    static func linkedNote(at url: URL, expecting: Beneath.FileID?) -> TextDocument {
        let doc = TextDocument(fileURL: url)
        doc.expectedFile = expecting
        return doc
    }

    /// Set before the first open: the file (device and inode) a link was
    /// checked to lead to. That read opens one descriptor, not following a
    /// final symbolic link, and reads only if it is still that file; later
    /// reads (a change made elsewhere) go the usual way.
    private var expectedFile: Beneath.FileID?

    enum LinkedNoteError: LocalizedError {
        case changed
        var errorDescription: String? { String(localized: "The note changed after it was checked, so it wasn’t opened.") }
    }

    /// Why the last read failed (nil: it didn't): set on UIDocument's read
    /// queue, looked at once the open has finished. The browser decides
    /// from it, not by reading the file again (`DocumentOpening`).
    private(set) var readFailure: Error?

    override func read(from url: URL) throws {
        do {
            try readOnce(from: url)
            readFailure = nil
        } catch {
            readFailure = error
            throw error
        }
    }

    private func readOnce(from url: URL) throws {
        guard let expected = expectedFile else { return try super.read(from: url) }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LinkedNoteError.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Beneath.FileID(fd: fd) == expected else {
            throw LinkedNoteError.changed
        }
        let data = try handle.readToEnd() ?? Data()
        expectedFile = nil
        try load(fromContents: data, ofType: fileType)
    }

    /// This document's copy of the file as opened (Revert to Opened Version).
    let openedCopyID = UUID().uuidString
    /// What happened to that copy (nil: not opened yet).
    private(set) var openedCopy: RevertStore.Kept?

    var currentState: DiskState {
        DiskState(text: currentText?() ?? text,
                  format: .init(encoding: encoding, lineEnding: lineEnding, mixedLineEndings: mixedLineEndings),
                  hasBOM: DiskState.includeBOM(encoding: encoding, onDisk: onDisk))
    }

    /// The bytes a save writes for `text`: in the document's encoding,
    /// with its BOM, and with mixed line endings each unchanged line's own.
    /// Pure: no save bookkeeping (Share… sends exactly this).
    func serialized(_ text: String) throws -> Data {
        // Mixed line endings: LineBreaks writes each remaining break as it was.
        guard let data = TextCodec.encodeDocument(text, encoding: encoding, lineEnding: lineEnding,
                                                  lineBreaks: mixedLineEndings ? lineBreaks : nil) else {
            throw OpenError.unencodable(encoding)
        }
        return data
    }

    /// Keep mixed endings lined up with an edit (`LineBreaks.replace`).
    /// Returns the breaks the edit took out of `old` (empty with no mixed
    /// endings), for Undo and Redo to put back (`restoreLineBreaks`).
    @discardableResult
    func noteTextReplacement(_ old: NSRange, newLength: Int) -> [Int] {
        lineBreaks?.replace(old, newLength: newLength) ?? []
    }

    /// Undo or Redo put text back at `location` (now `within`, in `text`):
    /// the breaks an edit took from it come back (`LineBreaks.restore`).
    func restoreLineBreaks(_ removed: [Int], at location: Int, within: NSRange, in text: NSString) {
        guard !removed.isEmpty else { return }
        _ = lineBreaks?.restore(removed, at: location, within: within, in: text)
    }

    override func contents(forType typeName: String) throws -> Any {
        if let t = currentText?() { text = t }
        let state = currentState
        let data = try serialized(text)
        writing = (state, mixedLineEndings ? lineBreaks : nil,
                   data.count <= SafetyCopyStore.maxBytes ? data : nil)
        return data
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        let data: Data
        if let d = contents as? Data { data = d } else if let w = contents as? FileWrapper, let d = w.regularFileContents { data = d } else { data = Data() }
        guard let decoded = TextCodec.decode(data) else { throw OpenError.undecodable }
        if decoded.looksBinary && !openBinaryAnyway { throw OpenError.binary }
        // The bytes as first opened (not on a reload after a change elsewhere).
        if openedCopy == nil { openedCopy = SaveSafetyStores.revert.keep(data, id: openedCopyID) }
        bytesOnDisk = data.count <= SafetyCopyStore.maxBytes ? data : nil
        readHistory = ReadHistory()
        text = decoded.text
        encoding = decoded.encoding
        encodingGuessed = decoded.encodingGuessed
        lineEnding = decoded.lineEnding
        mixedLineEndings = decoded.mixedLineEndings
        lineBreaks = decoded.lineBreaks
        onDisk = DiskState(text: decoded.text, format: .init(encoding: decoded.encoding, lineEnding: decoded.lineEnding,
                                                             mixedLineEndings: decoded.mixedLineEndings),
                           hasBOM: !decoded.encoding.bom.isEmpty)
        diskStateStale = false
        if !language.isManual { language = .forFile(named: fileURL.lastPathComponent, content: decoded.text) }
        firstUnsavedEdit = nil
        if let onReload { DispatchQueue.main.async(execute: onReload) }
    }

    override func updateChangeCount(_ change: UIDocument.ChangeKind) {
        super.updateChangeCount(change)
        if change == .done, firstUnsavedEdit == nil { firstUnsavedEdit = Date() }
        if change == .done { saveBlockedUntilEdited = false }
        if change == .cleared { firstUnsavedEdit = nil }
        notifyEdited()
    }

    private func notifyEdited() {
        guard let onEditedChange else { return }
        if Thread.isMainThread { onEditedChange() } else { DispatchQueue.main.async(execute: onEditedChange) }
    }

    /// UIKit autosaves on a timer, when the app goes to the background and
    /// when the document closes; with "Save automatically" off it doesn't.
    /// Nothing is lost: the editor keeps a recovery copy while there are
    /// unsaved changes, and closing asks Save / Don't Save / Cancel.
    override func autosave(completionHandler: ((Bool) -> Void)? = nil) {
        guard SavePolicy.shouldAutosave(saveAutomatically: saveAutomatically(), hasUnsavedChanges: hasUnsavedChanges,
                                        blockedUntilEdited: saveBlockedUntilEdited) else {
            completionHandler?(true)
            return
        }
        autosaveInProgress = true
        super.autosave { ok in
            DispatchQueue.main.async {
                self.autosaveInProgress = false
                completionHandler?(ok)
            }
        }
    }

    /// The private copy of the file as opened, if one was kept.
    func openedBytes() -> Data? { SaveSafetyStores.revert.load(id: openedCopyID) }

    /// The file's bytes as they are on disk now, for Reopen with Encoding…:
    /// a coordinated read of the document's URL (other writers finish
    /// first) with the access the document already has, not a cached copy.
    /// Nil when it can't be read.
    func bytesForReopen() -> Data? {
        let url = fileURL
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { u in
            data = try? Data(contentsOf: u)
        }
        return error == nil ? data : nil
    }

    func discardOpenedCopy() { SaveSafetyStores.revert.clear(id: openedCopyID) }

    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: ((Bool) -> Void)? = nil) {
        let isAutosave = autosaveInProgress
        // Nothing changed from what is on disk (an edit undone, a format
        // change undone): the file isn't written at all.
        if saveOperation == .forOverwriting, url == fileURL, cleanCheckAllowed,
           !DiskState.needsWrite(currentState, onDisk: onDisk) {
            if hasUnsavedChanges { updateChangeCount(.cleared) }
            firstUnsavedEdit = nil
            completionHandler?(true)
            onSaved?()
            notifyEdited()
            return
        }
        writing = nil
        if saveOperation == .forOverwriting, url == fileURL { backUpBeforeWrite(isAutosave: isAutosave) }
        savesInFlight += 1
        super.save(to: url, for: saveOperation) { ok in
            self.savesInFlight = max(0, self.savesInFlight - 1)
            if ok {
                if !self.hasUnsavedChanges { self.firstUnsavedEdit = nil }
                if let w = self.writing, url == self.fileURL {
                    self.onDisk = w.state
                    self.bytesOnDisk = w.bytes
                    self.diskStateStale = false
                    if let breaks = w.breaks { self.lineBreaks = breaks }
                }
            }
            self.writing = nil
            // A failed save leaves the text unsaved (the Edited mark, the
            // recovery copy), whatever UIDocument's count says.
            if !ok, !self.hasUnsavedChanges { super.updateChangeCount(.done) }
            completionHandler?(ok)
            if ok { self.onSaved?() }
            self.notifyEdited()
        }
    }

    /// Keep the last disk bytes for Restore Previous Version before writing.
    private func backUpBeforeWrite(isAutosave: Bool) {
        guard let data = bytesOnDisk else { return }
        let path = recoveryPath, name = displayName, modified = fileModificationDate
        let history = readHistory
        SaveSafetyStores.queue.async {
            let store = SaveSafetyStores.copies
            let snapshot = store.all()
            let newest = store.copies(forDocumentPath: path, in: snapshot).first { $0.kind == .original }
            let newestBytes = newest.flatMap { $0.byteCount == data.count ? store.data(for: $0) : nil }
            let firstSinceRead = !history.hasCopy
            if firstSinceRead, let newest, newestBytes == data {
                do {
                    if newest.pinned != true { try store.pin(newest) }
                    history.hasCopy = true
                } catch {
                    NSLog("Owlink couldn't pin a pre-save copy: %@", error.localizedDescription)
                }
                return
            }
            let now = Date()
            guard SaveHistory.shouldKeep(bytesOnDisk: data, newestKept: newestBytes, isAutosave: isAutosave,
                                         newestSavedAt: newest?.savedAt, now: now, firstSinceRead: firstSinceRead) else { return }
            let copy = SafetyCopy(documentPath: path, displayName: name, kind: .original, savedAt: now,
                                  sourceDate: modified, pinned: firstSinceRead ? true : nil)
            do {
                let kept = try store.keep(data, as: copy)
                history.hasCopy = true
                let updated = (snapshot + [kept]).sorted {
                    if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
                    return $0.id < $1.id
                }
                let remaining = store.pruneSaveHistory(forDocumentPath: path, in: updated)
                store.pruneSaveHistoryBudget(in: remaining)
            } catch {
                NSLog("Owlink couldn't keep a pre-save copy: %@", error.localizedDescription)
            }
        }
    }

    /// Save (and revert) errors: UIDocument's default only logs them. The
    /// editor shows them; nothing is presented modally.
    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        if case OpenError.unencodable = error { saveBlockedUntilEdited = true }
        let report = onSaveError
        DispatchQueue.main.async { report?(error) }
        finishedHandlingError(error, recovered: false)
    }

    /// The default "does nothing": the editor makes the text read-only.
    override func disableEditing() {
        super.disableEditing()
        let f = onEditingAllowed
        DispatchQueue.main.async { f?(false) }
    }

    override func enableEditing() {
        super.enableEditing()
        let f = onEditingAllowed
        DispatchQueue.main.async { f?(true) }
    }

    /// UIDocument reverts when the file changed elsewhere, which discards
    /// unsaved edits. With unsaved edits it doesn't, yet: the editor copies
    /// both sides and asks (`onExternalChange`).
    override func revert(toContentsOf url: URL, completionHandler: ((Bool) -> Void)? = nil) {
        switch ExternalChange.onRevert(hasUnsavedChanges: hasUnsavedChanges, chosen: revertChosen, asking: externalChangePending) {
        case .reload:
            revertChosen = false
            externalChangePending = false
            super.revert(toContentsOf: url, completionHandler: completionHandler)
        case .askFirst:
            bytesOnDisk = nil
            externalChangePending = true
            completionHandler?(false)
            if let onExternalChange { DispatchQueue.main.async(execute: onExternalChange) }
        case .ignore:
            completionHandler?(false)
        }
    }

    /// Reads the file again after the person chose its version on disk
    /// (Use Theirs, Keep Other Version in a conflict).
    func revertAfterChoice(_ done: @escaping (Bool) -> Void) {
        revertChosen = true
        revert(toContentsOf: fileURL, completionHandler: done)
    }

    /// The snapshot may not match the file; the next save writes and clears it.
    func markDiskStateStale() {
        diskStateStale = true
        bytesOnDisk = nil
    }

    /// Keep Mine: the edits stay unsaved, and the next save replaces theirs.
    func keepMineAfterExternalChange() {
        externalChangePending = false
        markDiskStateStale()
        updateChangeCount(.done)
    }

    var displayName: String { fileURL.lastPathComponent }

    /// The file types the document browser shows: text of any kind, and any
    /// other file (opened as text when it is text).
    static let browsableTypes: [UTType] = [.text, .sourceCode, .script, .json, .xml, .yaml, .commaSeparatedText,
                                            .propertyList, .data]
}
