import Foundation
import Testing
@testable import CedricCore

/// The new files an atomic save leaves when it is killed before its
/// rename (`.owlink-save-<UUID>`): the next save into that folder removes
/// them, and nothing else.
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
        DocumentWrite.sweptFolders.forget()
        try DocumentWrite.write(Data("saved\n".utf8), to: dir.appendingPathComponent("doc.txt"))
    }

    @Test func aSaveRemovesItsFoldersStaleTemps() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        try Data("old\n".utf8).write(to: dir.appendingPathComponent("doc.txt"))
        let stale = try temp(dir), other = try temp(dir)
        try save(dir)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(!fm.fileExists(atPath: other.path))
        #expect(try String(contentsOf: dir.appendingPathComponent("doc.txt"), encoding: .utf8) == "saved\n")
        // Nothing else of the save's own is left either.
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["doc.txt"])
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

    @Test func onlyTheExactNameOfARegularFileWithOneLinkGoes() throws {
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

    @Test func aFolderIsSweptOncePerRun() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        try save(dir)
        let later = try temp(dir)
        // Not forgotten: the second save doesn't list the folder again.
        try DocumentWrite.write(Data("again\n".utf8), to: dir.appendingPathComponent("doc.txt"))
        #expect(fm.fileExists(atPath: later.path))
    }

    @Test func tempNames() {
        let id = UUID().uuidString
        #expect(DocumentWrite.isTempName(".owlink-save-" + id))
        #expect(!DocumentWrite.isTempName(".owlink-save-" + id.lowercased()))
        #expect(!DocumentWrite.isTempName(".owlink-save-" + id + "x"))
        #expect(!DocumentWrite.isTempName("owlink-save-" + id))
    }
}
