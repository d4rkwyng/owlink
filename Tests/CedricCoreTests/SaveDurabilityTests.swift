import Foundation
import Testing
@testable import CedricCore

/// A save (⌘S, Save As, quit's Save As) counts as done only once the new
/// file and its name are on the disk (Astra 27e #5): the tab then becomes
/// clean and its session buffer removable, so a power loss after the
/// session cleanup reached the disk but before the save did would lose
/// the text. The atomic save flushes its new file before the rename and
/// the folder after it; either flush failing fails the save.
@Suite(.serialized) struct SaveDurabilityTests {
    private let fm = FileManager.default

    private func folder() throws -> URL {
        let d = tempDir()
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func names(_ dir: URL) throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: dir.path)) }

    @Test func aFailedFileFlushFailsTheSaveAndKeepsTheOldFile() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("doc.txt")
        try Data("old\n".utf8).write(to: doc)
        #expect(throws: (any Error).self) {
            try DocumentWrite.write(Data("new\n".utf8), to: doc, faults: DocumentWrite.Faults(failFileFlush: true))
        }
        #expect(try String(contentsOf: doc, encoding: .utf8) == "old\n", "not renamed over the old file")
        #expect(try names(dir) == ["doc.txt"], "no new file left beside it")
    }

    @Test func aFailedFileFlushFailsSaveAsToANewFile() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("new.txt")
        #expect(throws: (any Error).self) {
            try DocumentWrite.write(Data("new\n".utf8), to: doc, faults: DocumentWrite.Faults(failFileFlush: true))
        }
        #expect(try names(dir).isEmpty, "nothing written")
    }

    @Test func aFailedFolderFlushAfterTheRenameFailsTheSave() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("new.txt")
        var failure: Error?
        do {
            try DocumentWrite.write(Data("new\n".utf8), to: doc, faults: DocumentWrite.Faults(failFolderFlush: true))
        } catch { failure = error }
        #expect(failure != nil, "the save fails")
        // In place (readers may see it), but not confirmed on the disk:
        // the caller doesn't count it as saved, and the error says the
        // save left this file there (the next ⌘S's sheet: Owlink's own).
        #expect(try names(dir) == ["new.txt"])
        #expect(failure.flatMap(DocumentWrite.fileLeft(by:)) == DiskStamp.of(doc))
    }

    @Test func aSaveWithoutFaultsStillWorks() throws {
        let dir = try folder()
        defer { try? fm.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("doc.txt")
        try Data("old\n".utf8).write(to: doc)
        try DocumentWrite.write(Data("new\n".utf8), to: doc)
        #expect(try String(contentsOf: doc, encoding: .utf8) == "new\n")
        #expect(try names(dir) == ["doc.txt"])
    }
}
