import Foundation
import Testing
@testable import CedricCore

/// The ⌘S conflict sheet's words (0.5.4 QA #7): neutral and accurate.
/// Never "another app" or "Theirs"; when Owlink knows it changed the file
/// itself (its own failed save, a save from another of its tabs) it says so.
@Suite struct DiskConflictTests {
    static let a = DiskStamp(modified: Date(timeIntervalSince1970: 1_000), size: 10, identity: .init(device: 1, inode: 2))
    static let b = DiskStamp(modified: Date(timeIntervalSince1970: 2_000), size: 12, identity: .init(device: 1, inode: 2))
    static let c = DiskStamp(modified: Date(timeIntervalSince1970: 3_000), size: 14, identity: .init(device: 1, inode: 3))

    @Test func theCauseIsWhatOwlinkKnows() {
        let (a, b, c) = (Self.a, Self.b, Self.c)
        #expect(DiskConflict.cause(known: a, lastSaved: nil, failedSave: nil, otherTabsSaved: [], current: b) == .sinceOpened)
        #expect(DiskConflict.cause(known: a, lastSaved: a, failedSave: nil, otherTabsSaved: [], current: b) == .sinceSaved)
        // Saved here earlier, but read since (a reload): since opened.
        #expect(DiskConflict.cause(known: b, lastSaved: a, failedSave: nil, otherTabsSaved: [], current: c) == .sinceOpened)
        #expect(DiskConflict.cause(known: a, lastSaved: a, failedSave: b, otherTabsSaved: [], current: b) == .ownFailedSave)
        // Its failed save, then another change: not Owlink's any more.
        #expect(DiskConflict.cause(known: a, lastSaved: a, failedSave: b, otherTabsSaved: [], current: c) == .sinceSaved)
        #expect(DiskConflict.cause(known: a, lastSaved: nil, failedSave: nil, otherTabsSaved: [c], current: c) == .savedInAnotherTab)
        #expect(DiskConflict.cause(known: a, lastSaved: nil, failedSave: nil, otherTabsSaved: [b], current: c) == .sinceOpened)
        #expect(DiskConflict.cause(known: a, lastSaved: nil, failedSave: b, otherTabsSaved: [b], current: nil) == .sinceOpened)
    }

    @Test func theWordsAreNeutralAndSayWhatOwlinkKnows() {
        #expect(DiskConflict.message(name: "notes.md") == "“notes.md” changed on disk.")
        #expect(DiskConflict.keepTitle == "Keep What’s in This Tab")
        #expect(DiskConflict.reloadTitle == "Reload from Disk")
        #expect(DiskConflict.compareTitle == "Compare")
        let causes: [DiskConflict.Cause] = [.sinceOpened, .sinceSaved, .ownFailedSave, .savedInAnotherTab]
        let details = causes.map(DiskConflict.detail)
        #expect(Set(details).count == causes.count, "each cause has its own words")
        for d in details + [DiskConflict.message(name: "x")] {
            #expect(!d.localizedCaseInsensitiveContains("another app"), "\(d)")
            #expect(!d.contains("Theirs") && !d.contains("My Version"), "\(d)")
        }
        for d in details {
            #expect(d.hasSuffix("Keep What’s in This Tab replaces the file with this tab’s text. Reload from Disk replaces this tab’s text with the file (Undo brings yours back). Compare shows the two side by side."), "\(d)")
        }
        #expect(DiskConflict.detail(.sinceOpened).hasPrefix("The file on disk changed since you opened it."))
        #expect(DiskConflict.detail(.sinceSaved).hasPrefix("The file on disk changed since Owlink last saved it."))
        #expect(DiskConflict.detail(.ownFailedSave).hasPrefix("Owlink’s last save of it from this tab didn’t finish"))
        #expect(DiskConflict.detail(.savedInAnotherTab).hasPrefix("It was saved from another Owlink tab or window"))
    }

    /// A real in-place save (0555 folder) that fails part way and is put
    /// back from its recovery copy still moves the file's stamp: before,
    /// the next ⌘S blamed "another app". The stamp it leaves is the one
    /// the tab records, and the sheet says Owlink's save didn't finish.
    @Test func aFailedInPlaceSaveIsOwlinksOwnChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { _ = chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("inplace.md")
        let original = Data(repeating: UInt8(ascii: "o"), count: 80_000)
        try original.write(to: url)
        // Opened a while ago, as a tab's file is: a write and restore
        // within DiskStamp's 1 ms tolerance of creating it would look
        // like no change at all.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        #expect(chmod(dir.path, 0o555) == 0)
        let opened = try #require(DiskStamp.of(url))
        var failed = false
        var thrown: Error?
        do {
            try DocumentWrite.write(Data(repeating: UInt8(ascii: "n"), count: 120_000), to: url, fileManager: .default,
                                    afterCheck: nil, faults: .init(failWriteAfter: 40_000))
        } catch { failed = true; thrown = error }
        #expect(failed)
        #expect(try Data(contentsOf: url) == original, "put back")
        let after = try #require(DiskStamp.of(url))
        #expect(DiskStamp.changed(known: opened, current: after), "the failed save moved the stamp, so ⌘S will ask")
        let cause = DiskConflict.cause(known: opened, lastSaved: nil, failedSave: after, otherTabsSaved: [], current: DiskStamp.of(url))
        #expect(cause == .ownFailedSave)
        // What the tab records (EditorWindowController.write(to:) calls
        // this): the writer's own word for how it left the file.
        let error = try #require(thrown)
        let recorded = try #require(DiskConflict.failedSaveStamp(error, saving: url, fileURL: url), "the writer says it wrote into the file")
        #expect(recorded == after)
        #expect(DiskConflict.cause(known: opened, lastSaved: nil, failedSave: recorded, otherTabsSaved: [], current: DiskStamp.of(url))
                == .ownFailedSave)
        #expect(SaveFailure.cause(of: error) != .changedWhileSaving, "still an I/O failure, not \"replaced\"")
        // A Save As to somewhere else that fails records nothing for this tab.
        #expect(DiskConflict.failedSaveStamp(error, saving: url, fileURL: dir.appendingPathComponent("other.md")) == nil)
    }

    /// Codex round 2: another app replacing the file while Owlink saves it
    /// (the in-place save then refuses it: EBUSY) moved the stamp across
    /// the failed save, and the next ⌘S said Owlink's own save didn't
    /// finish. Owlink never touched it: nothing recorded, neutral words.
    @Test func aFileReplacedByAnotherAppDuringTheSaveIsNotOwlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { _ = chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("swapped.md")
        try Data("mine\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        #expect(chmod(dir.path, 0o555) == 0)
        let opened = try #require(DiskStamp.of(url))
        var thrown: Error?
        do {
            try DocumentWrite.write(Data("new\n".utf8), to: url, fileManager: .default, afterCheck: {
                // Another app swaps the file between Owlink's check and its write.
                _ = chmod(dir.path, 0o755)
                let other = dir.appendingPathComponent(".other")
                try? Data("theirs, longer\n".utf8).write(to: other)
                _ = rename(other.path, url.path)
                _ = chmod(dir.path, 0o555)
            })
        } catch { thrown = error }
        let error = try #require(thrown, "the in-place save refuses the swapped file")
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving)
        #expect(try Data(contentsOf: url) == Data("theirs, longer\n".utf8), "Owlink didn't write into it")
        let now = try #require(DiskStamp.of(url))
        #expect(DiskStamp.changed(known: opened, current: now), "the stamp moved (another app), so ⌘S will ask")
        #expect(DocumentWrite.fileLeft(by: error) == nil)
        let recorded = DiskConflict.failedSaveStamp(error, saving: url, fileURL: url)
        #expect(recorded == nil, "not put down to Owlink")
        #expect(DiskConflict.cause(known: opened, lastSaved: nil, failedSave: recorded, otherTabsSaved: [], current: now) == .sinceOpened)
    }

    /// The owl's "Reload?" for the same change doesn't blame another app either.
    @Test @MainActor func theOwlsReloadHintIsNeutralToo() throws {
        let h = try #require(RulesHintProvider().check(context("hello"), facts: .init(changedOnDisk: true)).first {
            $0.id == RulesHintProvider.reloadID })
        #expect(h.title == "This file changed on disk. Reload?")
        #expect(h.detail == "The file on disk changed since this tab last read or saved it. Reloading replaces your unsaved changes (you can undo it).")
        #expect(!(h.detail ?? "").contains("Another app"))
    }

    /// 0.5.4 QA (fix round 2): ⌘S checked the file (through its link)
    /// against the tab's stamp, then the writer resolved the link again: a
    /// link pointed at another writable file in between had the save
    /// replace that file. The writer now checks the file it finds against
    /// the stamp ⌘S used, and nothing is written when it differs.
    @Test func theWriterChecksTheFileItFindsAgainstTheTabsStamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-expect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.md"), b = dir.appendingPathComponent("b.md")
        let link = dir.appendingPathComponent("link.md")
        try Data("aaa\n".utf8).write(to: a)
        try Data("bbb\n".utf8).write(to: b)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.md")
        let known = try #require(DiskStamp.of(link))
        // Pointed at b after the tab's check, before the write.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "b.md")
        var thrown: Error?
        do { try DocumentWrite.write(Data("mine\n".utf8), to: link, expecting: known) } catch { thrown = error }
        let error = try #require(thrown, "the save refused another file")
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving, "\(error)")
        #expect(try Data(contentsOf: b) == Data("bbb\n".utf8), "b untouched")
        #expect(try Data(contentsOf: a) == Data("aaa\n".utf8), "a untouched")
        // Pointed back: the file it knows, written.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.md")
        try DocumentWrite.write(Data("mine\n".utf8), to: link, expecting: known)
        #expect(try Data(contentsOf: a) == Data("mine\n".utf8))
        // No stamp to expect (Save As, a copy): as before.
        try DocumentWrite.write(Data("copy\n".utf8), to: b)
        #expect(try Data(contentsOf: b) == Data("copy\n".utf8))
    }

    /// The same narrowed to the rename: another file put in the checked
    /// file's place after the check (here, while the new text is written)
    /// is left alone; the atomic save fails rather than replace it.
    @Test func anotherFilePutInPlaceBeforeTheRenameIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("old\n".utf8).write(to: url)
        let theirs = dir.appendingPathComponent("theirs.md")
        try Data("theirs\n".utf8).write(to: theirs)
        var thrown: Error?
        do {
            try DocumentWrite.write(Data("mine\n".utf8), to: url, fileManager: .default, afterCheck: {
                _ = rename(theirs.path, url.path)
            })
        } catch { thrown = error }
        let error = try #require(thrown, "the save didn't replace the file put there")
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving, "\(error)")
        #expect(try Data(contentsOf: url) == Data("theirs\n".utf8), "the other file is still there")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["doc.md"], "no temporary file left: \(left)")
        // A new file (none there when checked) still saves.
        let fresh = dir.appendingPathComponent("fresh.md")
        try DocumentWrite.write(Data("new\n".utf8), to: fresh)
        #expect(try Data(contentsOf: fresh) == Data("new\n".utf8))
    }
}
