import Foundation
import Testing
@testable import CedricCore

@Suite struct DiskStampTests {
    let t = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    @Test func sameStampIsNoChange() {
        let s = DiskStamp(modified: t, size: 10)
        #expect(!DiskStamp.changed(known: s, current: s))
        // A date that went through the session file as a Double.
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t.addingTimeInterval(0.0002)), current: s))
    }

    @Test func newerOrOlderDateIsAChange() {
        let known = DiskStamp(modified: t, size: 10)
        #expect(DiskStamp.changed(known: known, current: DiskStamp(modified: t.addingTimeInterval(1), size: 10)))
        // Another app restoring an older copy (its own date) counts too.
        #expect(DiskStamp.changed(known: known, current: DiskStamp(modified: t.addingTimeInterval(-60), size: 10)))
    }

    @Test func sizeCountsOnlyWhenBothKnowIt() {
        #expect(DiskStamp.changed(known: DiskStamp(modified: t, size: 10), current: DiskStamp(modified: t, size: 11)))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t), current: DiskStamp(modified: t, size: 11)))
    }

    @Test func unknownOrGoneIsNoChange() {
        #expect(!DiskStamp.changed(known: nil, current: DiskStamp(modified: t)))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t), current: nil))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: nil), current: DiskStamp(modified: t)))
    }

    @Test func readsAFile() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("diskstamp-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: u) }
        try "four".write(to: u, atomically: true, encoding: .utf8)
        let a = try #require(DiskStamp.of(u))
        #expect(a.size == 4 && a.modified != nil)
        try "longer text".write(to: u, atomically: true, encoding: .utf8)
        #expect(DiskStamp.changed(known: a, current: DiskStamp.of(u)))
        #expect(DiskStamp.of(u.appendingPathExtension("gone")) == nil)
    }

    @Test func goneFileIsMissing() {
        let known = DiskStamp(modified: t, size: 10)
        #expect(DiskStamp.status(known: known, current: nil, exists: false) == .missing)
        // Never read from disk (no date): saving just creates it.
        #expect(DiskStamp.status(known: DiskStamp(modified: nil), current: nil, exists: false) == .same)
        #expect(DiskStamp.status(known: nil, current: nil, exists: false) == .same)
        // There but unreadable (no access): not deleted.
        #expect(DiskStamp.status(known: known, current: nil, exists: true) == .same)
        #expect(DiskStamp.status(known: known, current: known, exists: true) == .same)
        #expect(DiskStamp.status(known: known, current: DiskStamp(modified: t.addingTimeInterval(5), size: 10), exists: true) == .changed)
    }

    @Test func deletedOrMovedFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskstamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("open.md")
        try "text".write(to: u, atomically: true, encoding: .utf8)
        let known = try #require(DiskStamp.of(u))
        #expect(DiskStamp.status(known: known, at: u) == .same)
        let moved = dir.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: u, to: moved)
        #expect(DiskStamp.status(known: known, at: u) == .missing)
        // Moved back untouched: the same file again.
        try FileManager.default.moveItem(at: moved, to: u)
        #expect(DiskStamp.status(known: known, at: u) == .same)
        try FileManager.default.removeItem(at: u)
        #expect(DiskStamp.status(known: known, at: u) == .missing)
    }

    /// A file opened through a symbolic link (a chain of two here, as for
    /// dotfiles linked into a repo) is stamped by its target, the file a
    /// save writes: before 0.5.4's QA the stamp was the link's own, so
    /// another app rewriting the target was never seen and ⌘S wrote over it.
    @Test func aStampThroughALinkSeesTheTargetChange() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cedric-stamp-link-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.md")
        try Data("target v1".utf8).write(to: target)
        try fm.setAttributes([.modificationDate: t], ofItemAtPath: target.path)
        let hop = dir.appendingPathComponent("hop.md"), link = dir.appendingPathComponent("link.md")
        try fm.createSymbolicLink(atPath: hop.path, withDestinationPath: "target.md")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "hop.md")

        let known = try #require(DiskStamp.of(link))
        #expect(known == DiskStamp.of(target), "the link's stamp is the target's")
        #expect(known.size == 9)
        #expect(DiskStamp.status(known: known, at: link) == .same)

        // Another app rewrites the target (the links aren't touched).
        try Data("target v3 written by another app".utf8).write(to: target)
        try fm.setAttributes([.modificationDate: t.addingTimeInterval(5)], ofItemAtPath: target.path)
        #expect(DiskStamp.changed(known: known, current: DiskStamp.of(link)))
        #expect(DiskStamp.status(known: known, at: link) == .changed)
    }

    /// The link pointed at another file while the tab is open: ⌘S would
    /// write that file, so it is a change (before, the retarget went
    /// unseen and the tab's text replaced the other file). A link left
    /// pointing nowhere is a missing file, not a change.
    @Test func aRetargetedLinkIsAChangeAndADanglingOneIsMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cedric-stamp-retarget-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.md"), other = dir.appendingPathComponent("other.md")
        try Data("real file".utf8).write(to: real)
        try fm.setAttributes([.modificationDate: t], ofItemAtPath: real.path)
        try Data("other file, older".utf8).write(to: other)
        try fm.setAttributes([.modificationDate: t.addingTimeInterval(-3600)], ofItemAtPath: other.path)
        let link = dir.appendingPathComponent("a.md")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")
        let known = try #require(DiskStamp.of(link))

        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "other.md")
        #expect(DiskStamp.status(known: known, at: link) == .changed)

        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "gone.md")
        #expect(DiskStamp.of(link) == nil)
        #expect(DiskStamp.status(known: known, at: link) == .missing)
    }

    /// Codex 0.5.4 review: a link pointed at another file with the same
    /// date and size (a timestamp-preserving copy) went unseen, and ⌘S
    /// wrote over that file. The stamp carries the target's identity.
    @Test func aLinkRetargetedToAFileWithTheSameDateAndSizeIsAChange() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cedric-stamp-twin-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.md"), twin = dir.appendingPathComponent("twin.md")
        try Data("same size".utf8).write(to: real)
        try Data("SAME SIZE".utf8).write(to: twin)
        for u in [real, twin] { try fm.setAttributes([.modificationDate: t], ofItemAtPath: u.path) }
        let link = dir.appendingPathComponent("a.md")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")
        let known = try #require(DiskStamp.of(link))
        #expect(known.identity != nil)

        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "twin.md")
        let now = try #require(DiskStamp.of(link))
        #expect(now.modified == known.modified && now.size == known.size, "the same date and size")
        #expect(DiskStamp.status(known: known, at: link) == .changed)
        // A link to a folder is a change too (a save there fails), not a crash.
        try fm.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "folder")
        #expect(DiskStamp.status(known: known, at: link) == .changed)
        #expect(throws: (any Error).self) { try DocumentWrite.write(Data("mine".utf8), to: link) }
        #expect(try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("folder").path).isEmpty, "the folder is untouched")
    }

    /// QA S10 "replace-same-stamp": another app atomically replaces the
    /// file with one of the same size and date. Another inode: a change.
    @Test func anAtomicReplaceWithTheSameDateAndSizeIsAChange() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cedric-stamp-replace-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let u = dir.appendingPathComponent("open.md"), next = dir.appendingPathComponent(".next")
        try Data("version 1".utf8).write(to: u)
        try fm.setAttributes([.modificationDate: t], ofItemAtPath: u.path)
        let known = try #require(DiskStamp.of(u))
        try Data("version 2".utf8).write(to: next)
        try fm.setAttributes([.modificationDate: t], ofItemAtPath: next.path)
        #expect(rename(next.path, u.path) == 0)
        #expect(DiskStamp.of(u)?.modified == known.modified && DiskStamp.of(u)?.size == known.size)
        #expect(DiskStamp.status(known: known, at: u) == .changed)
    }

    /// A stamp without identity (a session saved before 0.5.4) compares
    /// the date and size only, so an upgrade alone shows no change.
    @Test func identityCountsOnlyWhenBothKnowIt() {
        let a = DiskStamp.FileID(device: 1, inode: 2), b = DiskStamp.FileID(device: 1, inode: 3)
        #expect(DiskStamp.changed(known: DiskStamp(modified: t, size: 4, identity: a), current: DiskStamp(modified: t, size: 4, identity: b)))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t), current: DiskStamp(modified: t, size: 4, identity: b)))
        #expect(!DiskStamp.changed(known: DiskStamp(modified: t, size: 4, identity: a), current: DiskStamp(modified: t, size: 4, identity: a)))
        // And the session keeps it: an older session file decodes without it.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","hasBuffer":true,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0,"fileModified":800000000}"#
        let tab = try? JSONDecoder().decode(SessionTab.self, from: Data(old.utf8))
        #expect(tab != nil && tab?.diskStamp.identity == nil && tab?.diskStamp.size == nil)
        var withID = SessionTab(fileModified: t, fileSize: 4, fileID: a)
        withID.hasBuffer = true
        let round = try? JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(withID))
        #expect(round?.diskStamp == DiskStamp(modified: t, size: 4, identity: a))
    }

    /// Owlink's own saves stamp the file they wrote: the atomic replace
    /// (a new inode, through a link too) and the in-place save return the
    /// stamp the path shows afterwards, so the tab sees no change.
    @Test func aSaveReturnsTheStampOfTheFileItWrote() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cedric-stamp-save-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { _ = chmod(dir.path, 0o755); try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.md"), link = dir.appendingPathComponent("link.md")
        try Data("before".utf8).write(to: target)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "target.md")
        let before = try #require(DiskStamp.of(link))
        let saved = try DocumentWrite.write(Data("after, atomically".utf8), to: link)
        #expect(saved.identity != before.identity, "the atomic replace is a new file")
        #expect(DiskStamp.status(known: saved, at: link) == .same, "and its own stamp is no change")
        #expect(saved == DiskStamp.of(target))
        // In place, in a folder that refuses new files: the same file.
        #expect(chmod(dir.path, 0o555) == 0)
        let inPlace = try DocumentWrite.write(Data("in place".utf8), to: link)
        #expect(inPlace.identity == saved.identity && inPlace.size == 8)
        #expect(DiskStamp.status(known: inPlace, at: link) == .same)
    }
}
