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
    var lineEnding: LineEnding = .lf
    var mixedLineEndings = false
    /// The line endings as read, while the file mixes them.
    private var lineEndingLayout: LineEndingLayout?
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
    private var writing: (state: DiskState, layout: LineEndingLayout?)?
    /// The file's bytes as read, until they are backed up before the first
    /// write (not kept for files over the copy store's cap).
    private var bytesAsRead: Data?
    private var backedUpSinceRead = false
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
    /// This document's copy of the file as opened (Revert to Opened Version).
    let openedCopyID = UUID().uuidString
    /// What happened to that copy (nil: not opened yet).
    private(set) var openedCopy: RevertStore.Kept?

    var currentState: DiskState {
        DiskState(text: currentText?() ?? text,
                  format: .init(encoding: encoding, lineEnding: lineEnding, mixedLineEndings: mixedLineEndings),
                  hasBOM: DiskState.includeBOM(encoding: encoding, onDisk: onDisk))
    }

    override func contents(forType typeName: String) throws -> Any {
        if let t = currentText?() { text = t }
        let state = currentState
        // Mixed line endings: unchanged lines keep their own.
        var endings: [LineEnding]?
        if mixedLineEndings, let layout = lineEndingLayout {
            endings = TextCodec.lineEndings(for: text, keeping: layout, fallback: lineEnding)
        }
        guard let data = TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding, includeBOM: state.hasBOM,
                                          endings: endings) else {
            throw OpenError.unencodable(encoding)
        }
        writing = (state, endings.map { LineEndingLayout(text: text, endings: $0) })
        return data
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        let data: Data
        if let d = contents as? Data { data = d } else if let w = contents as? FileWrapper, let d = w.regularFileContents { data = d } else { data = Data() }
        guard let decoded = TextCodec.decode(data) else { throw OpenError.undecodable }
        if decoded.looksBinary && !openBinaryAnyway { throw OpenError.binary }
        // The bytes as first opened (not on a reload after a change elsewhere).
        if openedCopy == nil { openedCopy = SaveSafetyStores.revert.keep(data, id: openedCopyID) }
        bytesAsRead = data.count <= SafetyCopyStore.maxBytes ? data : nil
        backedUpSinceRead = false
        text = decoded.text
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        mixedLineEndings = decoded.mixedLineEndings
        lineEndingLayout = decoded.lineEndingLayout
        onDisk = DiskState(text: decoded.text, format: .init(encoding: decoded.encoding, lineEnding: decoded.lineEnding,
                                                             mixedLineEndings: decoded.mixedLineEndings),
                           hasBOM: decoded.hasBOM)
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
        super.autosave(completionHandler: completionHandler)
    }

    /// The private copy of the file as opened, if one was kept.
    func openedBytes() -> Data? { SaveSafetyStores.revert.load(id: openedCopyID) }

    func discardOpenedCopy() { SaveSafetyStores.revert.clear(id: openedCopyID) }

    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: ((Bool) -> Void)? = nil) {
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
        backUpBeforeFirstWrite()
        savesInFlight += 1
        super.save(to: url, for: saveOperation) { ok in
            self.savesInFlight = max(0, self.savesInFlight - 1)
            if ok {
                if !self.hasUnsavedChanges { self.firstUnsavedEdit = nil }
                if let w = self.writing, url == self.fileURL {
                    self.onDisk = w.state
                    self.diskStateStale = false
                    if let layout = w.layout { self.lineEndingLayout = layout }
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

    /// Before the first write after a read: the file as read goes to the
    /// safety copies (7 days; Restore Previous Version).
    private func backUpBeforeFirstWrite() {
        guard BackupPolicy.shouldBackUp(needsWrite: true, backedUpSinceRead: backedUpSinceRead, haveBytes: bytesAsRead != nil),
              let data = bytesAsRead else { return }
        let copy = SafetyCopy(documentPath: recoveryPath, displayName: displayName, kind: .original, sourceDate: fileModificationDate)
        if (try? SaveSafetyStores.copies.keep(data, as: copy)) != nil {
            backedUpSinceRead = true
            bytesAsRead = nil
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
