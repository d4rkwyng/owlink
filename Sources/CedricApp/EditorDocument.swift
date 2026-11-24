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
    /// The file mixes line endings (`lineEnding` is the most common).
    /// While `lineBreaks` is kept, a save writes each break as it was.
    var mixedLineEndings = false
    /// A mixed file's own line breaks (LineBreaks): a save writes each
    /// line's break back as it was, until a line ending is picked
    /// (`convertLineEndings`), which drops them.
    var lineBreaks: LineBreaks?
    /// The encoding is Owlink's guess (not valid UTF-8: an 8-bit one),
    /// until the user keeps it or picks one (the encoding bar).
    var encodingGuessed = false
    /// The language and who decided it (auto-detected, picked, the file's).
    var languageChoice = LanguageChoice()
    var language: Language { languageChoice.language }
    /// Picked from the menu: never re-detected (typing, paste, save).
    var languageIsManual: Bool { languageChoice.isManual }
    /// What the file looked like when last read or written (DiskStamp:
    /// date, size and identity), set only as a whole by `noteDisk` so a
    /// date never pairs with another file's size or identity.
    private(set) var diskStamp = DiskStamp(modified: nil)
    /// The file's date at the last read or save.
    var fileModified: Date? { diskStamp.modified }
    func noteDisk(_ s: DiskStamp?) { diskStamp = s ?? DiskStamp(modified: nil) }
    /// The stamp this tab's last save left (DiskConflict: "since Owlink
    /// last saved it", and "saved from another Owlink tab" for the others).
    private(set) var lastSavedStamp: DiskStamp?
    /// The file as a failed save from this tab left it, if that save
    /// changed it (an in-place write that stopped part way, put back or
    /// not): the conflict sheet then says Owlink did it, not another app.
    var failedSaveStamp: DiskStamp?

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
    /// what undo has to come back to. `fingerprint`: the text's, made off
    /// the main thread while a large file opened (used when its length is
    /// the text's).
    func rebaseIfClean(fingerprint: TextFingerprint? = nil) {
        guard !isDirty else { return }
        let text = currentText?()
        if let fingerprint, let text, fingerprint.length == text.length, fingerprint.length > edited.snapshotLimit {
            edited.saved(fingerprint: fingerprint)
        } else {
            edited.saved(text)
        }
    }

    /// The tab's text storage changed (every change, edits and not):
    /// where the text can now differ from the saved text (EditedState
    /// keeps a long saved text as chunk hashes, not a copy).
    func noteStorageEdit(_ range: NSRange, delta: Int) { edited.noteEdit(range, delta: delta) }

    /// The saved text is kept as chunk hashes, not a copy (checks).
    var keepsSavedFingerprint: Bool { edited.keepsFingerprint }

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

    /// Reads and decodes a file; returns the LF-normalised text and the
    /// file's stamp. The stamp is taken before the bytes are read: if the
    /// file changes (or a link is pointed elsewhere) in between, the next
    /// check sees a change rather than missing one.
    /// `shareBytes`: the bytes are read into memory of their own (not
    /// mapped: TextCodec.snapshot), and a large ASCII file's text reads
    /// them in place (TextCodec.decode), for opening into a tab: the file
    /// changing meanwhile changes nothing already read.
    nonisolated static func read(_ url: URL, encoding: TextEncoding? = nil, shareBytes: Bool = false) throws -> (DecodedText, DiskStamp?) {
        let data: Data
        if let kind = SpecialFile.kind(atPath: url.path) {
            throw LoadError.unreadable(url, NSError(domain: "Cedric", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "It is \(kind), not a regular file.")]))
        }
        let stamp = DiskStamp.of(url)
        do {
            data = shareBytes ? try TextCodec.snapshot(of: url) : try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(url, error)
        }
        guard let decoded = TextCodec.decode(data, as: encoding, shareBytes: shareBytes) else { throw LoadError.notText(url) }
        return (decoded, stamp)
    }

    func apply(_ d: DecodedText) {
        lineEnding = d.lineEnding
        mixedLineEndings = d.mixedLineEndings
        lineBreaks = d.mixedLineEndings ? d.lineBreaks : nil
        // Read again in the encoding it guessed (a reload): still a guess.
        encodingGuessed = d.encodingGuessed || (encodingGuessed && d.encoding == encoding)
        encoding = d.encoding
    }

    /// A tab restored from the session (or ⇧⌘T): still a guess if it was
    /// one, and, restored from an unsaved buffer, a mixed file's own breaks
    /// read from the file again (as it is now: the next save matches the
    /// buffer's lines to it).
    func restoreFormat(_ st: SessionTab, fromBuffer: Bool) {
        if st.encodingGuessed == true, st.encoding == encoding { encodingGuessed = true }
        if fromBuffer, st.mixedLineEndings == true, let url = fileURL,
           let (d, _) = try? Self.read(url, encoding: st.encoding), d.mixedLineEndings, let breaks = d.lineBreaks {
            mixedLineEndings = true
            lineBreaks = breaks
            lineEnding = d.lineEnding
        }
    }

    /// The session's record of this document's format guesses (SessionTab).
    func noteFormat(in st: inout SessionTab) {
        st.encodingGuessed = encodingGuessed ? true : nil
        st.mixedLineEndings = mixedLineEndings && lineBreaks != nil ? true : nil
    }

    /// `text` as this document saves it: its encoding, and its line
    /// ending, or each line's own when they are mixed (`lineBreaks`).
    /// Nil if a character can't be represented in the encoding.
    func encoded(_ text: String) -> (data: Data, saved: LineBreaks.Saved?)? {
        if mixedLineEndings, let lineBreaks {
            let saved = lineBreaks.write(text)
            return TextCodec.encode(saved.output, encoding: encoding, lineEnding: .lf).map { ($0, saved) }
        }
        return TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding).map { ($0, nil) }
    }

    /// Writes `text` to `url` in this document's encoding and line ending.
    func write(_ text: String, to url: URL) throws {
        guard let (data, saved) = encoded(text) else {
            throw NSError(domain: "Cedric", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Some characters can’t be saved as \(encoding.displayName). Choose UTF-8 from the encoding menu in the status bar and save again.")])
        }
        // Through a symbolic link: replace its target (keeping the link and
        // the target's permissions), not the link itself; never a read-only
        // file (FileWriteAccess: permissions, locked, read-only volume).
        let stamp = try DocumentWrite.write(data, to: url)
        fileURL = url
        noteDisk(stamp)
        lastSavedStamp = stamp
        failedSaveStamp = nil
        // Kept mixed: what was written is the next save's starting point.
        if let saved {
            mixedLineEndings = saved.mixed
            lineBreaks = saved.mixed ? saved.breaks : nil
            lineEnding = saved.dominant
        } else {
            mixedLineEndings = false
            lineBreaks = nil
        }
        markSaved()
    }
}
