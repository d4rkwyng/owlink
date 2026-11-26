import Foundation
import Testing
@testable import CedricCore

/// The new files an atomic save leaves when it is killed before its
/// rename (`.owlink-save-<UUID>`): nothing removes them on its own. A file
/// with that exact name in a user's folder may be the user's own or
/// another process's save under way, so a save never deletes one.
@Suite(.serialized) struct SaveTempSweepTests {
    private let fm = FileManager.default

    private func folder() throws -> URL {
        let d = tempDir()
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func temp(_ dir: URL, _ name: String = DocumentWrite.tempPrefix + UUID().uuidString, age: TimeInterval = 3600) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data("half a save".utf8).write(to: u)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
        return u
    }

    private func save(_ dir: URL) throws {
        try DocumentWrite.write(Data("saved\n".utf8), to: dir.appendingPathComponent("doc.txt"))
    }

    /// Reversed on purpose (0.6 review): an old, unlocked, single-link
    /// regular file of this user's with the exact name used to be swept.
    @Test func aMatchingUserFileIsNeverDeleted() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        try Data("old\n".utf8).write(to: dir.appendingPathComponent("doc.txt"))
        let mine = try temp(dir), other = try temp(dir, age: 86_400 * 365)
        try save(dir)
        try save(dir)
        #expect(fm.fileExists(atPath: mine.path))
        #expect(fm.fileExists(atPath: other.path))
        #expect(try Data(contentsOf: mine) == Data("half a save".utf8))
        #expect(try Data(contentsOf: other) == Data("half a save".utf8))
        #expect(try String(contentsOf: dir.appendingPathComponent("doc.txt"), encoding: .utf8) == "saved\n")
        // Nothing of the save's own is left beside them.
        #expect(try Set(fm.contentsOfDirectory(atPath: dir.path)) == ["doc.txt", mine.lastPathComponent, other.lastPathComponent])
    }

    @Test func aRecentTempIsKept() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let recent = try temp(dir, age: 0)
        try save(dir)
        #expect(fm.fileExists(atPath: recent.path))
    }

    @Test func aTempASaveStillHoldsIsKept() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let busy = try temp(dir)
        let fd = open(busy.path, O_RDONLY)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        try save(dir)
        #expect(fm.fileExists(atPath: busy.path))
    }

    @Test func linksFoldersAndLookAlikesAreLeftAlone() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let id = UUID().uuidString
        let names = [".owlink-save-", ".owlink-save-abc", ".owlink-save-" + id.lowercased(), "x.owlink-save-" + id,
                     ".owlink-save-" + id + ".txt", ".owlink-save-" + id + " "]
        let kept = try names.map { try temp(dir, $0) }
        // A link with the name, to a file elsewhere.
        let target = try temp(dir, "linked-target.txt")
        let link = dir.appendingPathComponent(DocumentWrite.tempPrefix + UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        // A second name for a file (a hard link).
        let hard = try temp(dir)
        let hard2 = dir.appendingPathComponent("hard-link.txt")
        try fm.linkItem(at: hard, to: hard2)
        // A folder with the name.
        let sub = dir.appendingPathComponent(DocumentWrite.tempPrefix + UUID().uuidString)
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try save(dir)
        for k in kept { #expect(fm.fileExists(atPath: k.path), "\(k.lastPathComponent)") }
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(fm.fileExists(atPath: target.path))
        #expect(fm.fileExists(atPath: hard.path) && fm.fileExists(atPath: hard2.path))
        #expect(fm.fileExists(atPath: sub.path))
    }

    @Test func aTempLeftBeforeAnEarlierSaveIsKeptByLaterOnes() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        try save(dir)
        let later = try temp(dir)
        try DocumentWrite.write(Data("again\n".utf8), to: dir.appendingPathComponent("doc.txt"))
        #expect(fm.fileExists(atPath: later.path))
    }

    @Test func tempPrefix() {
        #expect(DocumentWrite.tempPrefix == ".owlink-save-")
    }
}
