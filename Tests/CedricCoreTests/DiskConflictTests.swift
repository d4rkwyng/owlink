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

    /// The same file (same inode) written in place by another app after
    /// the check, while the new text was written: the pre-rename check
    /// compared device and inode only and replaced it, losing that edit
    /// (Sol round 2). Its size and times are rechecked too: same length or
    /// longer, the save fails and their bytes stay. `MINE\n` is the same
    /// five bytes as the file was (Sol round 3): only the times tell.
    @Test(arguments: ["MINE\n", "THEIRS\n", "theirs, longer\n"])
    func theCheckedFileEditedInPlaceBeforeTheRenameIsLeftAlone(edit: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-inplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("mine\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        let known = try #require(DiskStamp.of(url))
        final class Edited: @unchecked Sendable { var ok = false }
        let edited = Edited()
        var thrown: Error?
        do {
            try DocumentWrite.write(Data("new text\n".utf8), to: url, fileManager: .default, afterCheck: {
                let fd = open(url.path, O_WRONLY | O_CLOEXEC)
                guard fd >= 0 else { return }
                let bytes = Array(edit.utf8)
                edited.ok = pwrite(fd, bytes, bytes.count, 0) == bytes.count
                close(fd)
            }, expecting: known)
        } catch { thrown = error }
        #expect(edited.ok, "the file was edited in place after the check")
        let error = try #require(thrown, "the save didn't replace the edited file")
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving, "\(error)")
        #expect(try Data(contentsOf: url) == Data(edit.utf8), "their edit is still there")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["doc.md"], "no temporary file left: \(left)")
        // Untouched since the check: saved.
        let again = try #require(DiskStamp.of(url))
        try DocumentWrite.write(Data("new text\n".utf8), to: url, expecting: again)
        #expect(try Data(contentsOf: url) == Data("new text\n".utf8))
    }

    /// The POSIX code under a save error.
    private func posixCode(_ error: Error) -> Int32? {
        ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) }
    }

    /// The last look before the rename couldn't look (here the folder
    /// stopped letting this user search it): that is not "nothing there".
    /// 0.5.4 before review 3 took every `fstatat` failure for a file that
    /// had gone and let the rename replace whatever was there unchecked.
    @Test func thePreRenameLookFailingIsNotAnAbsentFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-prerename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { _ = chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("old\n".utf8).write(to: url)
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        var checked = stat()
        #expect(fstatat(fd, "doc.md", &checked, AT_SYMLINK_NOFOLLOW) == 0)
        #expect(try DocumentWrite.nothingElseAt("doc.md", in: fd, checked: checked, url: url), "unchanged: may be replaced")
        #expect(try DocumentWrite.nothingElseAt("gone.md", in: fd, checked: checked, url: url), "ENOENT: gone, may be written")
        // Injected, so it holds for any runner (root searches a 000 folder).
        for code in [EACCES, EIO] {
            var injected: Error?
            do { _ = try DocumentWrite.nothingElseAt("doc.md", in: fd, checked: checked, url: url, failing: [code]) } catch { injected = error }
            let error = try #require(injected, "an injected \(code) doesn't authorize the rename")
            #expect(posixCode(error) == code, "\(error)")
        }
        // The real refusal too, where the folder's mode binds this user.
        guard geteuid() != 0 else { return }
        #expect(chmod(dir.path, 0o000) == 0)
        var probe = stat()
        let refused = fstatat(fd, "doc.md", &probe, AT_SYMLINK_NOFOLLOW) != 0 ? errno : 0
        #expect(refused == EACCES, "the folder refuses the look: \(refused)")
        var thrown: Error?
        do { _ = try DocumentWrite.nothingElseAt("doc.md", in: fd, checked: checked, url: url) } catch { thrown = error }
        let error = try #require(thrown, "a failed look doesn't authorize the rename")
        #expect(posixCode(error) == EACCES, "\(error)")
    }

    /// The same through a whole save: the look fails with EIO, the save
    /// fails with EIO and the file put in place meanwhile is left alone;
    /// EINTR is looked again (and sees that file: changed while saving).
    @Test func aSaveWhosePreRenameLookFailsRenamesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-prerename-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        func save(_ errors: [Int32], theirs: String?) throws -> Error? {
            try Data("old\n".utf8).write(to: url)
            let known = try #require(DiskStamp.of(url))
            let other = dir.appendingPathComponent("theirs.md")
            if let theirs { try Data(theirs.utf8).write(to: other) }
            do {
                try DocumentWrite.write(Data("mine\n".utf8), to: url, fileManager: .default, afterCheck: {
                    if theirs != nil { _ = rename(other.path, url.path) }
                }, faults: DocumentWrite.Faults(preRenameStatErrors: errors), expecting: known)
            } catch { return error }
            return nil
        }
        let eio = try #require(try save([EIO], theirs: "theirs\n"), "EIO: no rename")
        #expect(posixCode(eio) == EIO, "\(eio)")
        #expect(SaveFailure.cause(of: eio) != .changedWhileSaving)
        #expect(try Data(contentsOf: url) == Data("theirs\n".utf8), "the file put there is still there")
        let eintr = try #require(try save([EINTR, EINTR], theirs: "theirs\n"), "EINTR: looked again")
        #expect(SaveFailure.cause(of: eintr) == .changedWhileSaving, "\(eintr)")
        #expect(try Data(contentsOf: url) == Data("theirs\n".utf8))
        #expect(try save([EINTR], theirs: nil) == nil, "EINTR, then the checked file: saved")
        #expect(try Data(contentsOf: url) == Data("mine\n".utf8))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["doc.md"], "no temporary file left: \(left)")
    }

    /// Between ⌘S's check and the writer's own: another app's same-size
    /// edit whose date lands within the session stamp's millisecond
    /// tolerance. The writer compared with that tolerance, so the edit
    /// passed, became the baseline for the pre-rename recheck, and was
    /// overwritten (0.5.4 QA review 3). The tab's exact `stat` (`seen`)
    /// now goes to the writer, and any difference fails the save.
    @Test func aSameSizeSubMillisecondEditAfterTheTabsCheckIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-exact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("mine\n".utf8).write(to: url)
        func setModified(_ sec: Int, _ nsec: Int) -> Bool {
            var times = [timespec(tv_sec: sec, tv_nsec: nsec), timespec(tv_sec: sec, tv_nsec: nsec)]
            return utimensat(AT_FDCWD, url.path, &times, 0) == 0
        }
        let base = Int(Date().timeIntervalSince1970) - 60
        #expect(setModified(base, 100_000_000))
        // The tab's ⌘S check: its stamp and the exact file, from one stat.
        let known = try #require(DiskStamp.of(url))
        let (seen, stamp) = try #require(DiskStamp.Exact.of(url))
        #expect(stamp == known)
        // Another app: same five bytes, same inode, 0.4 ms later.
        let fd = open(url.path, O_WRONLY | O_CLOEXEC)
        #expect(fd >= 0)
        let bytes = Array("MINE\n".utf8)
        #expect(pwrite(fd, bytes, bytes.count, 0) == bytes.count)
        close(fd)
        #expect(setModified(base, 100_400_000))
        #expect(!DiskStamp.changed(known: known, current: DiskStamp.of(url)), "within the tolerant stamp's millisecond")
        var thrown: Error?
        do { try DocumentWrite.write(Data("new text\n".utf8), to: url, expecting: known, seen: seen) } catch { thrown = error }
        let error = try #require(thrown, "the save didn't write over the edit")
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving, "\(error)")
        #expect(DocumentWrite.fileLeft(by: error) == nil, "Owlink didn't write into it")
        #expect(try Data(contentsOf: url) == Data("MINE\n".utf8), "their edit is still there")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["doc.md"], "no temporary file left: \(left)")
        // Checked again (the file as it is now): saved.
        let again = try #require(DiskStamp.Exact.of(url))
        try DocumentWrite.write(Data("new text\n".utf8), to: url, expecting: again.stamp, seen: again.exact)
        #expect(try Data(contentsOf: url) == Data("new text\n".utf8))
    }

    /// The same on the in-place save (a 0555 folder, Sol round 3): the
    /// checked file edited in place by another app after the writer's
    /// check, before it opens the file. The identity matched, so the
    /// recovery copy took their edit as the file and the save overwrote
    /// it. Now its size and times are rechecked against the check first.
    @Test(arguments: ["MINE\n", "theirs, longer\n"])
    func theCheckedFileEditedInPlaceBeforeAnInPlaceSaveIsLeftAlone(edit: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-inplace0555-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { _ = chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try Data("mine\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        #expect(chmod(dir.path, 0o555) == 0)
        let known = try #require(DiskStamp.of(url))
        final class Edited: @unchecked Sendable { var ok = false }
        let edited = Edited()
        var thrown: Error?
        do {
            try DocumentWrite.write(Data("new text\n".utf8), to: url, fileManager: .default, afterCheck: {
                let fd = open(url.path, O_WRONLY | O_CLOEXEC)
                guard fd >= 0 else { return }
                let bytes = Array(edit.utf8)
                edited.ok = pwrite(fd, bytes, bytes.count, 0) == bytes.count
                close(fd)
            }, expecting: known)
        } catch { thrown = error }
        #expect(edited.ok, "the file was edited in place after the check")
        let error = try #require(thrown, "the in-place save didn't overwrite the edited file")
        #expect(SaveFailure.cause(of: error) == .changedWhileSaving, "\(error)")
        #expect(DocumentWrite.fileLeft(by: error) == nil, "Owlink didn't write into it")
        #expect(try Data(contentsOf: url) == Data(edit.utf8), "their edit is still there")
        // Untouched since the check: saved in place.
        let again = try #require(DiskStamp.of(url))
        try DocumentWrite.write(Data("new text\n".utf8), to: url, expecting: again)
        #expect(try Data(contentsOf: url) == Data("new text\n".utf8))
    }
}
