import Foundation
import Testing
@testable import CedricCore

/// A failed save says why in plain words, that the text is still in the
/// tab, and points at Save As (0.5.4 QA #6: EBUSY and ENXIO showed only
/// "The file “x” couldn’t be saved in the folder “y”." with an empty
/// body). Real failures from DocumentWrite in a 0555 folder, and the
/// errors it and Foundation throw.
@Suite struct SaveFailureTests {
    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-savefail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanUp(_ dir: URL) {
        _ = chmod(dir.path, 0o755)
        try? FileManager.default.removeItem(at: dir)
    }

    /// What Foundation's NSAlert(error:) showed: no reason, no next step.
    static let generic = "couldn’t be saved in the folder"

    func expectPlain(_ t: SaveFailure.Text, name: String, reason: String, _ comment: Comment? = nil) {
        #expect(t.message == "Couldn’t save “\(name)”.", comment)
        #expect(t.detail.contains(reason), "says why: \(t.detail)")
        #expect(t.detail.contains("Your text is still in this tab"), "reassures: \(t.detail)")
        #expect(t.detail.contains("use Save As"), "points at Save As: \(t.detail)")
        #expect(!t.message.contains(Self.generic) && !t.detail.contains(Self.generic))
    }

    /// The file swapped for another between the check and the in-place
    /// write in a 0555 folder: EBUSY, "replaced or changed while saving".
    @Test func aFileReplacedWhileSavingSaysSo() throws {
        let dir = try folder()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("swapped.md")
        try Data("mine\n".utf8).write(to: url)
        #expect(chmod(dir.path, 0o555) == 0)
        var thrown: Error?
        do {
            try DocumentWrite.write(Data("mine, edited\n".utf8), to: url, fileManager: .default, afterCheck: {
                _ = chmod(dir.path, 0o755)
                let other = dir.appendingPathComponent("other.md")
                try? Data("theirs\n".utf8).write(to: other)
                _ = rename(other.path, url.path)
                _ = chmod(dir.path, 0o555)
            })
        } catch { thrown = error }
        let error = try #require(thrown)
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving, "\(error)")
        expectPlain(SaveFailure.text(for: error, saving: url, offer: .saveAs), name: "swapped.md",
                    reason: "was replaced or changed while Owlink was saving it")
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n", "the other file is untouched")
    }

    /// A pipe in the file's place in a 0555 folder (QA A1f: after Keep My
    /// Version): not a file Owlink can save into. Before, DocumentWrite
    /// called the pipe it had checked "busy" (EBUSY), as if it had been
    /// swapped during the save; now ENXIO.
    @Test func aPipeInItsPlaceSaysItIsNotAFile() throws {
        let dir = try folder()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("fifo.md")
        #expect(mkfifo(url.path, 0o644) == 0)
        #expect(chmod(dir.path, 0o555) == 0)
        var thrown: Error?
        do { try DocumentWrite.write(Data("mine\n".utf8), to: url) } catch { thrown = error }
        let error = try #require(thrown)
        #expect(SaveFailure.cause(of: error) == .notAFile, "\(error)")
        expectPlain(SaveFailure.text(for: error, saving: url, offer: .saveAs), name: "fifo.md",
                    reason: "is not a regular file any more (it is a pipe or a device)")
    }

    @Test func eachCauseHasPlainWords() {
        let url = URL(fileURLWithPath: "/tmp/folder0555/notes.md")
        func posix(_ code: Int32, _ kind: CocoaError.Code = .fileWriteUnknown) -> Error {
            CocoaError(kind, userInfo: [NSURLErrorKey: url, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code)!) as NSError])
        }
        let cases: [(Error, SaveFailure.Cause, String)] = [
            (posix(EBUSY), .changedWhileSaving, "replaced or changed while Owlink was saving it"),
            (posix(ENXIO), .notAFile, "it is a pipe or a device"),
            (posix(ENOSPC, .fileWriteOutOfSpace), .outOfSpace, "isn’t enough space on the disk"),
            (CocoaError(.fileWriteOutOfSpace), .outOfSpace, "isn’t enough space on the disk"),
            (posix(EDQUOT, .fileWriteOutOfSpace), .outOfSpace, "isn’t enough space on the disk"),
            (posix(EFBIG), .tooBig, "file-size limit"),
            (posix(EROFS, .fileWriteVolumeReadOnly), .readOnlyVolume, "read-only volume"),
            (posix(EACCES, .fileWriteNoPermission), .noPermission, "permission to save in the folder “folder0555”"),
            (posix(ENOENT, .fileNoSuchFile), .folderMissing, "The folder “folder0555” isn’t there any more"),
            (posix(EIO), .other("The system said: “Input/output error”."), "Input/output error"),
            (NSError(domain: "Cedric", code: 1, userInfo: [NSLocalizedDescriptionKey: "Some characters can’t be saved as Latin 1."]),
             .other("Some characters can’t be saved as Latin 1."), "Some characters can’t be saved as Latin 1."),
        ]
        for (error, cause, words) in cases {
            #expect(SaveFailure.cause(of: error) == cause, "\(error)")
            expectPlain(SaveFailure.text(for: error, saving: url, offer: .saveAs), name: "notes.md", reason: words)
        }
    }

    /// A save that failed during the write and couldn't put the file back:
    /// where the copy of it is.
    @Test func aKeptRecoveryCopySaysWhere() {
        let url = URL(fileURLWithPath: "/tmp/f/notes.md")
        let error = CocoaError(.fileWriteUnknown, userInfo: ["OwlinkRecoveryCopy": "/tmp/owlink-recovery-x/notes.md"])
        #expect(SaveFailure.cause(of: error) == .keptRecoveryCopy(path: "/tmp/owlink-recovery-x/notes.md"))
        expectPlain(SaveFailure.text(for: error, saving: url, offer: .saveAs), name: "notes.md",
                    reason: "A copy of it as it was is at /tmp/owlink-recovery-x/notes.md.")
    }

    /// Read-only (and locked) as found mid-save: the same words as ⌘S on a
    /// file already read-only, which offer Save As.
    @Test func readOnlyUsesTheReadOnlyWords() {
        let url = URL(fileURLWithPath: "/tmp/f/locked.md")
        for reason in [FileWriteAccess.Blocked.permissions, .locked, .readOnlyVolume] {
            let t = SaveFailure.text(for: ReadOnlyFileError(url: url, reason: reason), saving: url, offer: .saveAs)
            #expect(t.message == "“locked.md” is read-only.")
            #expect(t.detail == FileWriteAccess.notice(reason, name: "locked.md"))
            #expect(t.detail.contains("Save As"))
        }
    }

    /// Save a Copy and exports say the text is still in the tab, without
    /// pointing at the tab's own Save As.
    @Test func copiesAndExportsSayWhatIsLeft() {
        let url = URL(fileURLWithPath: "/tmp/f/notes copy.md")
        let error = CocoaError(.fileWriteOutOfSpace)
        let copy = SaveFailure.text(for: error, saving: url, offer: .saveCopy)
        #expect(copy.detail.hasPrefix("There isn’t enough space on the disk to save “notes copy.md”."))
        #expect(copy.detail.hasSuffix("Nothing was copied. Your text is still in this tab; choose another place for the copy."))
        let export = SaveFailure.text(for: error, saving: url, offer: .none)
        #expect(export.detail.hasSuffix(" Your text is still in this tab."))
    }
}
