import Foundation
import Testing
@testable import CedricCore

/// 0.5.4 leftover 1: after Revert to Saved (or Reload), ⌘Z brought the old
/// text back but kept the reloaded version's encoding and BOM, so a save
/// wrote the old text with a BOM it never had, or without the one it had.
/// The reload's undo record now carries the whole `DocumentFormat`.
///
/// `Tab` is the app's sequence in miniature, over the same CedricCore
/// pieces: a reload reads the file in the tab's base encoding
/// (EditorWindowController.reloadFromDisk, `TextEncoding.base`), keeps the
/// format before and after for its undo and redo, and every change compares
/// text, breaks and encoding with the saved ones (EditorDocument
/// `noteChange` / `noteBreaksChange`, EditedState). The app's own check is
/// FileNoticesCheck (CEDRIC_CHECK=filenotices), which needs a GUI session.
@Suite struct ReloadUndoFormatTests {
    struct Tab {
        var text: String
        var format: DocumentFormat
        var edited = EditedState()
        /// The reload's undo and redo sides: (text, format).
        var undoSide: (String, DocumentFormat)?
        var redoSide: (String, DocumentFormat)?

        static func format(_ d: DecodedText) -> DocumentFormat {
            DocumentFormat(encoding: d.encoding, encodingGuessed: d.encodingGuessed, lineEnding: d.lineEnding,
                           lineBreaks: d.mixedLineEndings ? d.lineBreaks : nil)
        }

        init(opening bytes: [UInt8]) throws {
            let d = try #require(TextCodec.decode(Data(bytes)))
            text = d.text
            format = Self.format(d)
            markSaved()
        }

        var isDirty: Bool { edited.isDirty }

        mutating func markSaved() {
            edited.saved(text as NSString, breaks: format.lineBreaks, ending: format.lineEnding, encoding: format.encoding)
        }

        /// What EditorDocument does after every change.
        mutating func noteChange() {
            edited.textChanged(to: text as NSString)
            edited.breaksChanged(to: format.lineBreaks, ending: format.lineEnding)
            edited.encodingChanged(to: format.encoding)
        }

        mutating func type(_ new: String) { text = new; noteChange() }

        /// Revert to Saved / Reload: the file now, in the tab's base encoding.
        mutating func reload(_ bytes: [UInt8]) throws {
            let d = try #require(TextCodec.decode(Data(bytes), as: format.encoding.base))
            undoSide = (text, format)
            text = d.text
            // EditorDocument.apply: read again in the encoding it guessed, still a guess.
            let guessed = d.encodingGuessed || (format.encodingGuessed && d.encoding == format.encoding)
            format = Self.format(d)
            format.encodingGuessed = guessed
            redoSide = (text, format)
            markSaved()
        }

        /// ⌘Z of the reload: the old text, then its format (undoOrRedoEnded).
        mutating func undo() throws {
            let (t, f) = try #require(undoSide)
            text = t; noteChange()
            format = f; noteChange()
        }

        mutating func redo() throws {
            let (t, f) = try #require(redoSide)
            text = t; noteChange()
            format = f; noteChange()
        }

        /// ⌘S: the bytes a save writes.
        func saved() throws -> [UInt8] { [UInt8](try #require(format.encoded(text))) }
    }

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    static func u8(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// The 0.5.4 report: a file without a BOM, edited, rewritten on disk
    /// with one, reverted, ⌘Z: the save had the BOM the edited version
    /// never had. And the reverse dropped one.
    @Test(arguments: [(false, true), (true, false)])
    func undoAfterRevertWritesTheOldVersionsBOM(oldHasBOM: Bool, newHasBOM: Bool) throws {
        let old = (oldHasBOM ? Self.bom : []) + Self.u8("café\n")
        var tab = try Tab(opening: old)
        #expect(tab.format.encoding == (oldHasBOM ? .utf8BOM : .utf8))
        tab.type("café crème\n")
        let disk = (newHasBOM ? Self.bom : []) + Self.u8("thé\n")
        try tab.reload(disk)
        #expect(tab.text == "thé\n" && !tab.isDirty)
        #expect(tab.format.encoding == (newHasBOM ? .utf8BOM : .utf8), "the reloaded version's own BOM")
        #expect(try tab.saved() == disk, "saved now: the file's bytes")

        try tab.undo()
        #expect(tab.text == "café crème\n" && tab.isDirty)
        let expected = (oldHasBOM ? Self.bom : []) + Self.u8("café crème\n")
        #expect(try tab.saved() == expected, "⌘Z, then ⌘S: the edited text with its own BOM, or none")
        // What 0.6.0 wrote: the old text in the reloaded version's encoding.
        let before = try #require(DocumentFormat(encoding: newHasBOM ? .utf8BOM : .utf8, lineEnding: .lf).encoded(tab.text))
        #expect([UInt8](before) != expected, "the case is real")

        try tab.redo()
        #expect(tab.text == "thé\n" && !tab.isDirty, "redo: the file again, clean")
        #expect(try tab.saved() == disk)
        try tab.undo()
        #expect(try tab.saved() == expected, "Revert, ⌘Z, ⌘⇧Z, ⌘Z: still the old version's")
    }

    /// Only the BOM differs: the same text with and without one. ⌘Z gives
    /// the saved text back, so only the encoding says a save would change
    /// the file; the tab must be unsaved (autosave and close skip a clean
    /// tab), and the save writes the old version's bytes.
    @Test func aBOMOnlyDifferenceIsUnsavedAfterUndo() throws {
        var tab = try Tab(opening: Self.u8("draft\n"))
        tab.type("same\n")
        // Another app saved the same words, with a BOM.
        try tab.reload(Self.bom + Self.u8("same\n"))
        #expect(tab.text == "same\n" && !tab.isDirty && tab.format.encoding == .utf8BOM)
        try tab.undo()
        #expect(tab.text == "same\n" && tab.format.encoding == .utf8)
        #expect(tab.isDirty && tab.edited.encodingDiffers && !tab.edited.textDiffers, "unsaved by the encoding alone")
        #expect(try tab.saved() == Self.u8("same\n"), "⌘S writes the edited version as it was: no BOM")
        try tab.redo()
        #expect(!tab.isDirty, "redo: the file's encoding again, clean")
    }

    /// The breaks and the encoding come back together (a mixed file
    /// without a BOM, rewritten all LF with one).
    @Test func mixedBreaksAndTheBOMComeBackTogether() throws {
        var tab = try Tab(opening: Self.u8("one\r\ntwo\nthree\r\n"))
        #expect(tab.format.lineBreaks != nil)
        // After the last break: `Tab` doesn't move breaks with an edit
        // (the app's trackLineBreaks does; FileNoticesCheck covers that).
        tab.type("one\ntwo\nthree\nfour")
        try tab.reload(Self.bom + Self.u8("plain\nlf\n"))
        #expect(tab.format.lineBreaks == nil && tab.format.encoding == .utf8BOM)
        try tab.undo()
        #expect(try tab.saved() == Self.u8("one\r\ntwo\nthree\r\nfour"), "its own breaks, and no BOM")
    }

    /// UTF-16 keeps its BOM through a reload either way (the base encoding
    /// is read again), and a U+FEFF that is text, not the BOM, stays text.
    @Test(arguments: [TextEncoding.utf16LE, .utf16BE])
    func utf16KeepsItsBOMAndATextFEFF(enc: TextEncoding) throws {
        func bytes(_ s: String) throws -> [UInt8] {
            [UInt8](try #require(DocumentFormat(encoding: enc, lineEnding: .lf).encoded(s)))
        }
        let old = try bytes("\u{FEFF}zero width\n")
        var tab = try Tab(opening: old)
        #expect(tab.format.encoding == enc && tab.text == "\u{FEFF}zero width\n", "one BOM read, the second is text")
        tab.type("\u{FEFF}zero width!\n")
        try tab.reload(try bytes("other\n"))
        try tab.undo()
        #expect(tab.format.encoding == enc)
        #expect(try tab.saved() == bytes("\u{FEFF}zero width!\n"))
    }

    /// A guessed 8-bit encoding comes back as a guess.
    @Test func aGuessComesBackAsAGuess() throws {
        var tab = try Tab(opening: [0x63, 0x61, 0x66, 0xE9, 0x0A])   // "café" in Latin-1: not UTF-8
        #expect(tab.format.encodingGuessed)
        let guessed = tab.format
        tab.type("café!\n")
        // Valid UTF-8 now, but read again as the tab's Latin-1.
        try tab.reload(Self.u8("thé\n"))
        #expect(tab.format.encoding == .latin1 && tab.format.encodingGuessed && tab.text == "thÃ©\n")
        try tab.undo()
        #expect(tab.format == guessed)
        #expect(try tab.saved() == [0x63, 0x61, 0x66, 0xE9, 0x21, 0x0A])
    }

    /// The save after ⌘Z goes through DocumentWrite: a write that fails
    /// part way leaves the reloaded file's bytes, never the old text in the
    /// reloaded encoding, and the retry writes the old version's bytes.
    @Test func aFailedSaveAfterUndoLeavesTheFileAndTheRetryWritesTheOldFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-reload-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        let disk = Self.bom + Self.u8("theirs\n")
        try Data(disk).write(to: url)
        var tab = try Tab(opening: Self.u8("mine\n"))
        tab.type("mine, edited\n")
        try tab.reload(disk)
        try tab.undo()
        let data = Data(try tab.saved())
        #expect(throws: (any Error).self) {
            try DocumentWrite.write(data, to: url, faults: DocumentWrite.Faults(failFileFlush: true))
        }
        #expect(try [UInt8](Data(contentsOf: url)) == disk, "the failed save left the file as it was")
        #expect(tab.isDirty, "still unsaved")
        try DocumentWrite.write(data, to: url)
        tab.markSaved()
        let written = try [UInt8](Data(contentsOf: url))
        #expect(written == Self.u8("mine, edited\n"), "no BOM: the edited version never had one")
        let back = try #require(TextCodec.decode(Data(written)))
        #expect(back.text == tab.text && back.encoding == .utf8)
        #expect(!tab.isDirty)
    }

    // MARK: EditedState's encoding baseline

    @Test func encodingIsComparedOnlyWhenTheBaselineGaveOne() {
        var s = EditedState(savedText: "a")
        s.encodingChanged(to: .utf16LE)
        #expect(!s.isDirty, "no encoding at the baseline: not compared (as before 0.6.1)")
        s.saved("a", encoding: .utf8)
        s.encodingChanged(to: .utf8BOM)
        #expect(s.isDirty && s.encodingDiffers)
        s.encodingChanged(to: .utf8)
        #expect(!s.isDirty, "back to the saved encoding: clean")
        s.encodingChanged(to: .latin1)
        s.saved("a", encoding: .latin1)
        #expect(!s.isDirty && !s.encodingDiffers, "a save takes the encoding as the new baseline")
        s.saved(fingerprint: TextFingerprint("a", chunk: 4), encoding: .utf16BE)
        s.encodingChanged(to: .utf16LE)
        #expect(s.isDirty, "a fingerprint baseline compares it too")
    }

    /// A sticky format change (the encoding menu) stays unsaved whatever
    /// the encoding comparison says, as before.
    @Test func aConvertedEncodingStaysUnsavedUntilSaved() {
        var s = EditedState(savedText: "a")
        s.saved("a", encoding: .utf8)
        s.noteFormatChange()
        s.encodingChanged(to: .utf8)
        #expect(s.isDirty && !s.encodingDiffers)
    }
}
