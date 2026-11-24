import AppKit
import CedricCore

/// One open buffer: where it lives (or its untitled name), how to write it
/// back, and whether it has unsaved changes. The text itself lives in the
/// tab's text storage.
///
/// Not NSDocument: Notepad++'s model (quit without prompts, unsaved and
/// untitled tabs restored next launch) fights NSDocument's save-on-quit
/// review and its own untitled autosave locations, so Cedric keeps a small
/// model of its own and its own session store.
@MainActor
final class EditorDocument {
    let id: UUID
    var fileURL: URL?
    var untitledName: String
    var encoding: TextEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var mixedLineEndings = false
    /// The language and who decided it (auto-detected, picked, the file's).
    var languageChoice = LanguageChoice()
    var language: Language { languageChoice.language }
    /// Picked from the menu: never re-detected (typing, paste, save).
    var languageIsManual: Bool { languageChoice.isManual }
    /// The file's date at the last read or save. Setting it drops the
    /// size (unknown until `noteDisk`), so a stale size never fakes a change.
    var fileModified: Date? { didSet { fileSize = nil } }
    /// The file's size at the last read or save, when known.
    private(set) var fileSize: Int?
    /// What the file looked like when last read or written (DiskStamp).
    var diskStamp: DiskStamp { DiskStamp(modified: fileModified, size: fileSize) }
    func noteDisk(_ s: DiskStamp?) { fileModified = s?.modified; fileSize = s?.size }

    /// Edits since open (a generation: grammar results, owl proposals
    /// and session buffer writes compare it). Unsaved is `edited`'s call.
    private(set) var changeCount = 0
    /// Unsaved edits: the text against the text at the last save or open,
    /// plus format changes and session/missing buffers (EditedState).
    private var edited = EditedState()
    /// The tab's text (its storage, not a copy), set by its window
    /// controller: what a save, open or clean reload remembers.
    var currentText: (() -> NSString?)?
    /// The change count the session store last saved a buffer for: set
    /// only once that write has succeeded (hot close trusts it to skip
    /// its own write).
    var sessionChangeCount = -1
    /// The change count of a buffer write queued and not yet done, so the
    /// next timed save doesn't queue the same text again; -1 if none.
    var sessionWritingCount = -1

    var isDirty: Bool { edited.isDirty }
    /// When the document last went from saved to unsaved (the owl's "Save a copy?").
    private(set) var unsavedSince: Date?
    /// The file changed on disk while the tab had unsaved edits (clean tabs just reload).
    var changedOnDisk = false
    /// The file was deleted or moved away while open (the "deleted" bar
    /// was shown; the tab was made unsaved so its text survives).
    var missingOnDisk = false
    /// Text › Indentation, picked for this tab (nil: the file's own, else Settings').
    var indentation: Indentation?
    /// What the text's first lines use (Indentation.detect), read the first
    /// time it is needed after the text was set, never at launch.
    var detectedIndentation: Indentation??

    init(id: UUID = UUID(), fileURL: URL? = nil, untitledName: String) {
        self.id = id
        self.fileURL = fileURL
        self.untitledName = untitledName
    }

    var displayName: String { fileURL?.lastPathComponent ?? untitledName }

    /// The text changed (typing, paste, a tool, undo, redo): unsaved
    /// unless it is the saved text again.
    func noteChange() {
        changeCount += 1
        updateEdited { $0.textChanged(to: currentText?()) }
    }

    /// Encoding or line endings changed: unsaved until written, whatever the text.
    func noteFormatChange() {
        changeCount += 1
        updateEdited { $0.noteFormatChange() }
    }

    /// The whole buffer was replaced (`setText`: disk reload, encoding
    /// reopen, Follow File reset). The edit generation moves so a `.lines`
    /// proposal cannot match the new text by its stored offset. A clean
    /// document stays clean: this is not a user edit.
    func noteBufferReplacement() {
        changeCount = OwlBufferReplacement.generation(after: changeCount)
        rebaseIfClean()
    }

    /// The text was set without an edit (open, reload): when clean, it is
    /// what undo has to come back to.
    func rebaseIfClean() {
        if !isDirty { edited.saved(currentText?()) }
    }

    func markSaved() { edited.saved(currentText?()); unsavedSince = nil; changedOnDisk = false; missingOnDisk = false }
    /// Restored from a session buffer: unsaved by definition.
    func markDirtyFromSession() {
        changeCount += 1
        updateEdited { $0.forceDirty() }
    }

    /// Applies `change` and keeps `unsavedSince` in step with the flag.
    private func updateEdited(_ change: (inout EditedState) -> Void) {
        let was = isDirty
        change(&edited)
        if !was, isDirty { unsavedSince = unsavedSince ?? Date() }
        if was, !isDirty { unsavedSince = nil }
    }

    enum LoadError: Error, LocalizedError {
        case unreadable(URL, Error)
        case notText(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let u, let e): return String(localized: "Couldn’t open “\(u.lastPathComponent)”: \(e.localizedDescription)")
            case .notText(let u): return String(localized: "“\(u.lastPathComponent)” isn’t text in a supported encoding.")
            }
        }
    }

    /// Reads and decodes a file; returns the LF-normalised text.
    static func read(_ url: URL, encoding: TextEncoding? = nil) throws -> (DecodedText, Date?) {
        let data: Data
        if let kind = SpecialFile.kind(atPath: url.path) {
            throw LoadError.unreadable(url, NSError(domain: "Cedric", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "It is \(kind), not a regular file.")]))
        }
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(url, error)
        }
        guard let decoded = TextCodec.decode(data, as: encoding) else { throw LoadError.notText(url) }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (decoded, mod)
    }

    func apply(_ d: DecodedText) {
        encoding = d.encoding
        lineEnding = d.lineEnding
        mixedLineEndings = d.mixedLineEndings
    }

    /// Writes `text` to `url` in this document's encoding and line ending.
    func write(_ text: String, to url: URL) throws {
        guard let data = TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding) else {
            throw NSError(domain: "Cedric", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Some characters can’t be saved as \(encoding.displayName). Choose UTF-8 from the encoding menu in the status bar and save again.")])
        }
        // Through a symbolic link: replace its target (keeping the link and
        // the target's permissions), not the link itself; never a read-only
        // file (FileWriteAccess: permissions, locked, read-only volume).
        try DocumentWrite.write(data, to: url)
        fileURL = url
        noteDisk(DiskStamp.of(url))
        mixedLineEndings = false
        markSaved()
    }
}
