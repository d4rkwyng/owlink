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
        #expect(chmod(dir.path, 0o555) == 0)
        let opened = try #require(DiskStamp.of(url))
        var failed = false
        do {
            try DocumentWrite.write(Data(repeating: UInt8(ascii: "n"), count: 120_000), to: url, fileManager: .default,
                                    afterCheck: nil, faults: .init(failWriteAfter: 40_000))
        } catch { failed = true }
        #expect(failed)
        #expect(try Data(contentsOf: url) == original, "put back")
        let after = try #require(DiskStamp.of(url))
        #expect(DiskStamp.changed(known: opened, current: after), "the failed save moved the stamp, so ⌘S will ask")
        let cause = DiskConflict.cause(known: opened, lastSaved: nil, failedSave: after, otherTabsSaved: [], current: DiskStamp.of(url))
        #expect(cause == .ownFailedSave)
    }

    /// The owl's "Reload?" for the same change doesn't blame another app either.
    @Test @MainActor func theOwlsReloadHintIsNeutralToo() throws {
        let h = try #require(RulesHintProvider().check(context("hello"), facts: .init(changedOnDisk: true)).first {
            $0.id == RulesHintProvider.reloadID })
        #expect(h.title == "This file changed on disk. Reload?")
        #expect(h.detail == "The file on disk changed since this tab last read or saved it. Reloading replaces your unsaved changes (you can undo it).")
        #expect(!(h.detail ?? "").contains("Another app"))
    }
}
