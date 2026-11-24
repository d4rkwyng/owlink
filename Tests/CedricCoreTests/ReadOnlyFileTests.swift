import Foundation
import Testing
@testable import CedricCore

/// A file the user can't write (chmod 444, locked in the Finder, on a
/// read-only volume) is read-only in its tab: Cedric's Apply is off and a
/// save never replaces it (0.5.2 wrote over a 0444 file with an atomic
/// rename). Real files in a temporary folder.
@Suite struct ReadOnlyFileTests {
    /// A fresh folder with `name` holding `text`; removed (flags and modes
    /// cleared first) by `cleanUp`.
    func file(_ name: String = "readonly.md", _ text: String = "# Read me\n\nTry editing it.\n") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let p = dir.appendingPathComponent(f).path
            _ = chflags(p, 0)
            _ = chmod(p, 0o644)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        _ = stat(url.path, &st)
        return st.st_mode & 0o7777
    }

    @Test func chmod444IsReadOnly() throws {
        let url = try file()
        defer { cleanUp(url) }
        #expect(FileWriteAccess.blocked(at: url) == nil, "a 0644 file the user owns is writable")
        #expect(chmod(url.path, 0o444) == 0)
        // Owned by this user, in a writable folder: still read-only (the real-use repro).
        #expect(FileWriteAccess.blocked(at: url) == .permissions)
        #expect(chmod(url.path, 0o400) == 0)
        #expect(FileWriteAccess.blocked(at: url) == .permissions)
    }

    @Test func aMissingFileIsNotBlocked() throws {
        let url = try file()
        defer { cleanUp(url) }
        #expect(FileWriteAccess.blocked(at: url.deletingLastPathComponent().appendingPathComponent("new.md")) == nil)
    }

    @Test func theFinderLockIsReadOnly() throws {
        let url = try file()
        defer { cleanUp(url) }
        try #require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0, "chflags uchg on a temp file")
        #expect(mode(url) & 0o200 != 0, "the mode still says writable")
        #expect(FileWriteAccess.blocked(at: url) == .locked)
        #expect(chflags(url.path, 0) == 0)
        #expect(FileWriteAccess.blocked(at: url) == nil, "unlocked: writable again")
    }

    @Test func aReadOnlyVolumeIsReadOnly() throws {
        // The sealed system volume is mounted read-only.
        let sys = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        try #require(FileManager.default.fileExists(atPath: sys.path))
        #expect(FileWriteAccess.blocked(at: sys) == .readOnlyVolume)
    }

    @Test func permissionChangesWhileOpenAreSeenOnTheNextCheck() throws {
        let url = try file()
        defer { cleanUp(url) }
        // Opened writable.
        let opened = try String(contentsOf: url, encoding: .utf8)
        #expect(FileWriteAccess.blocked(at: url) == nil)
        // chmod 444 while the tab is open: the next check (save, window key, Apply) sees it.
        #expect(chmod(url.path, 0o444) == 0)
        #expect(FileWriteAccess.blocked(at: url) == .permissions)
        #expect(throws: ReadOnlyFileError(url: url, reason: .permissions)) {
            try DocumentWrite.write(Data((opened + "typed\n").utf8), to: url)
        }
        // chmod 644 again: editable and savable.
        #expect(chmod(url.path, 0o644) == 0)
        #expect(FileWriteAccess.blocked(at: url) == nil)
        try DocumentWrite.write(Data((opened + "typed\n").utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == opened + "typed\n")
    }

    @Test func saveRefusesToReplaceAReadOnlyFile() throws {
        let url = try file()
        defer { cleanUp(url) }
        let before = try Data(contentsOf: url)
        #expect(chmod(url.path, 0o444) == 0)
        #expect(throws: ReadOnlyFileError(url: url, reason: .permissions)) {
            try DocumentWrite.write(Data("overwritten\n".utf8), to: url)
        }
        #expect(try Data(contentsOf: url) == before, "the bytes are unchanged")
        #expect(mode(url) == 0o444, "the mode is unchanged")

        // Locked: refused too, though the mode allows writing.
        #expect(chmod(url.path, 0o644) == 0)
        try #require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: ReadOnlyFileError(url: url, reason: .locked)) {
            try DocumentWrite.write(Data("overwritten\n".utf8), to: url)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(chflags(url.path, 0) == 0)

        // Writable: the save goes through.
        try DocumentWrite.write(Data("saved\n".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "saved\n")
    }

    @Test func aLinkToAReadOnlyFileIsRefusedAndStaysALink() throws {
        let target = try file("target.md", "target\n")
        defer { cleanUp(target) }
        let link = target.deletingLastPathComponent().appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.md")
        #expect(chmod(target.path, 0o444) == 0)
        #expect(FileWriteAccess.blocked(at: link) == .permissions, "the target decides, not the link")
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: link) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.md")
        #expect(try String(contentsOf: target, encoding: .utf8) == "target\n")
    }

    /// The save guard and the write used to resolve the link separately:
    /// retargeted in between, a writable file was checked and a read-only
    /// one replaced (the atomic rename only needs the folder). Now the
    /// target checked is the target written.
    @Test func aLinkRetargetedAfterTheCheckStillWritesTheCheckedFile() throws {
        let writable = try file("writable.md", "writable\n")
        defer { cleanUp(writable) }
        let dir = writable.deletingLastPathComponent()
        let locked = dir.appendingPathComponent("readonly.md")
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "writable.md")
        #expect(FileWriteAccess.blocked(at: link) == nil)

        try DocumentWrite.write(Data("saved\n".utf8), to: link, fileManager: .default) {
            // Between the check and the write: the link now points at the read-only file.
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "readonly.md")
        }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n", "the read-only file is untouched")
        #expect(mode(locked) == 0o444)
        #expect(try String(contentsOf: writable, encoding: .utf8) == "saved\n", "the checked file got the save")
        // And the plain save through the retargeted link is refused, as before.
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: link) }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n")
    }

    /// The same race one folder up (Codex review, 0.5.4): the file is
    /// reached through a link to a folder. Checked through it, then the
    /// folder link retargeted at a folder holding a read-only file of the
    /// same name: a write by path followed the link again and its rename
    /// replaced that file. The check and the write now share one open
    /// folder.
    @Test func aFolderLinkRetargetedAfterTheCheckStillWritesTheCheckedFolder() throws {
        let anchor = try file("anchor.md", "anchor\n")
        defer { cleanUp(anchor) }
        let base = anchor.deletingLastPathComponent()
        let fm = FileManager.default
        let good = base.appendingPathComponent("good"), bad = base.appendingPathComponent("bad")
        try fm.createDirectory(at: good, withIntermediateDirectories: false)
        try fm.createDirectory(at: bad, withIntermediateDirectories: false)
        defer { cleanUp(good.appendingPathComponent("doc.md")); cleanUp(bad.appendingPathComponent("doc.md")) }
        let writable = good.appendingPathComponent("doc.md"), locked = bad.appendingPathComponent("doc.md")
        try Data("writable\n".utf8).write(to: writable)
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        let folderLink = base.appendingPathComponent("folder")
        try fm.createSymbolicLink(atPath: folderLink.path, withDestinationPath: "good")
        let url = folderLink.appendingPathComponent("doc.md")
        #expect(FileWriteAccess.blocked(at: url) == nil)

        try DocumentWrite.write(Data("saved\n".utf8), to: url, fileManager: .default) {
            // Between the check and the write: the folder link now points at the folder with the read-only file.
            try? fm.removeItem(at: folderLink)
            try? fm.createSymbolicLink(atPath: folderLink.path, withDestinationPath: "bad")
        }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n", "the read-only file is untouched")
        #expect(mode(locked) == 0o444)
        #expect(try String(contentsOf: writable, encoding: .utf8) == "saved\n", "the checked folder's file got the save")
        #expect(try fm.destinationOfSymbolicLink(atPath: folderLink.path) == "bad")
        // The plain save through the retargeted folder link is refused.
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: url) }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n")
        // No temporary file is left in either folder.
        #expect(try fm.contentsOfDirectory(atPath: good.path) == ["doc.md"])
        #expect(try fm.contentsOfDirectory(atPath: bad.path) == ["doc.md"])
    }

    /// The write through the open folder keeps what an atomic save kept:
    /// the replaced file's mode, and a new file gets the usual one.
    @Test func aSaveKeepsTheFilesModeAndCreatesNewFiles() throws {
        let url = try file("kept.md", "before\n")
        defer { cleanUp(url) }
        #expect(chmod(url.path, 0o640) == 0)
        try DocumentWrite.write(Data("after\n".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after\n")
        #expect(mode(url) == 0o640)
        let fresh = url.deletingLastPathComponent().appendingPathComponent("new.md")
        try DocumentWrite.write(Data("new\n".utf8), to: fresh)
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "new\n")
        #expect(mode(fresh) & 0o600 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted() == ["kept.md", "new.md"])
    }

    @Test func applyIsReadOnlyForAnUnwritableFile() throws {
        let url = try file()
        defer { cleanUp(url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let snap = OwlDocumentSnapshot(text: text, generation: 2, fileName: "readonly.md", language: "markdown")
        let p = try OwlEditProposal.anchored(find: "Try editing it.", replace: "Editing this file is not permitted.", in: snap).get()
        func readOnly() -> Bool {
            // An editable buffer (Allow Editing chosen), not following, not large: only the file decides.
            OwlEditAccess.readOnly(editable: true, following: false, largeDocument: false, extrasPaused: false,
                                   unwritableFile: FileWriteAccess.blocked(at: url) != nil)
        }
        #expect(!readOnly())
        #expect(p.state(text: text as NSString, generation: 2, readOnly: readOnly()) == .ready((text as NSString).range(of: "Try editing it.")))
        #expect(chmod(url.path, 0o444) == 0)
        #expect(readOnly())
        #expect(p.state(text: text as NSString, generation: 2, readOnly: readOnly()) == .readOnly)
        let refreshed = OwlEditProposal.refresh([p], text: text as NSString, generation: 2, readOnly: readOnly())
        #expect(refreshed.states == [.readOnly] && refreshed.searches == 0)
        // Writable again: Apply comes back.
        #expect(chmod(url.path, 0o644) == 0)
        #expect(!readOnly())
    }

    @Test func theNoticeAndTitleSayWhy() {
        #expect(FileWriteAccess.notice(.permissions, name: "a.md").contains("permission"))
        #expect(FileWriteAccess.notice(.locked, name: "a.md").contains("locked"))
        #expect(FileWriteAccess.notice(.readOnlyVolume, name: "a.md").contains("read-only volume"))
        #expect(FileWriteAccess.windowTitle("a.md", readOnly: false) == "a.md")
        #expect(FileWriteAccess.windowTitle("a.md", readOnly: true) == "a.md — Read-Only")
        #expect(EditedIndicator.windowTitle(displayName: FileWriteAccess.windowTitle("a.md", readOnly: true), isDirty: true)
                == "a.md — Read-Only •", "the unsaved mark stays last")
    }
}
