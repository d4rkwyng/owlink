import Foundation
import Testing
@testable import CedricCore

/// The iOS app's data safety: the recovery store (crash-safe copies of
/// unsaved text), the revert store (the bytes as opened) and the
/// "Save automatically" decisions.
@Suite struct SaveSafetyTests {
    let fm = FileManager.default

    func temp() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory() + "owlink-save-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func record(_ path: String = "/docs/a.txt", text: String = "hello", at date: Date = Date()) -> RecoveryRecord {
        RecoveryRecord(documentPath: path, displayName: (path as NSString).lastPathComponent, bookmark: Data([1, 2, 3]),
                       savedAt: date, text: text, encoding: .utf16LE, lineEnding: .crlf)
    }

    func mode(_ u: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: Recovery store

    @Test func recoveryWriteAndReadBack() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t.appendingPathComponent("Recovery"))
        let r = record(text: "unsaved ✓\nsecond line")
        try store.write(r)
        #expect(store.read(documentPath: r.documentPath) == r)
        #expect(mode(store.directory) == 0o700)
        #expect(mode(store.fileURL(forDocumentPath: r.documentPath)) == 0o600)
        let excluded = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
    }

    @Test func recoveryWriteReplacesAtomicallyWithNoTempLeft() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "one"))
        try store.write(record(text: "two"))
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "two")
        #expect(try fm.contentsOfDirectory(atPath: t.path).count == 1)
    }

    @Test func recoveryIsPerDocument() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record("/docs/a.txt", text: "A"))
        try store.write(record("/docs/b.txt", text: "B", at: Date().addingTimeInterval(5)))
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "A")
        #expect(store.read(documentPath: "/docs/b.txt")?.text == "B")
        #expect(store.read(documentPath: "/docs/c.txt") == nil)
        #expect(store.all().map(\.text) == ["B", "A"])
    }

    @Test func newerThanTheDocument() {
        let now = Date()
        let r = record(at: now)
        #expect(r.isNewer(thanDocumentModified: now.addingTimeInterval(-10)))
        #expect(!r.isNewer(thanDocumentModified: now.addingTimeInterval(10)))
        #expect(!r.isNewer(thanDocumentModified: now))
        // The document is gone or has no date: still offered.
        #expect(r.isNewer(thanDocumentModified: nil))
    }

    @Test func pendingOnlyWhenNewer() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        let now = Date()
        try store.write(record(at: now))
        #expect(store.pending(documentPath: "/docs/a.txt", documentModified: now.addingTimeInterval(-60)) != nil)
        #expect(store.pending(documentPath: "/docs/a.txt", documentModified: now.addingTimeInterval(60)) == nil)
    }

    @Test func recoveryClear() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record("/docs/a.txt"))
        try store.write(record("/docs/b.txt"))
        store.clear(documentPath: "/docs/a.txt")
        #expect(store.read(documentPath: "/docs/a.txt") == nil)
        #expect(store.read(documentPath: "/docs/b.txt") != nil)
        // Clearing what isn't there is fine.
        store.clear(documentPath: "/docs/a.txt")
        #expect(store.all().count == 1)
    }

    func setAside(in dir: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable-") }
    }

    @Test func recoveryIgnoresMissingFolder() {
        let t = URL(fileURLWithPath: NSTemporaryDirectory() + "owlink-save-safety-none-\(UUID().uuidString)")
        #expect(RecoveryStore(directory: t).all().isEmpty)
        #expect(RecoveryStore(directory: t).read(documentPath: "/docs/a.txt") == nil)
    }

    @Test func readSetsJunkAside() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        let junk = store.fileURL(forDocumentPath: "/docs/a.txt")
        try Data("not a plist".utf8).write(to: junk)
        #expect(store.read(documentPath: "/docs/a.txt") == nil)
        // Damaged bytes are set aside by read itself, not deleted and not left under the live name.
        #expect(!fm.fileExists(atPath: junk.path))
        let aside = try setAside(in: t)
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: aside[0]) == Data("not a plist".utf8))
    }

    @Test func allSetsJunkAside() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        let junk = store.fileURL(forDocumentPath: "/docs/b.txt")
        try Data("also not a plist".utf8).write(to: junk)
        #expect(store.all().isEmpty)
        #expect(!fm.fileExists(atPath: junk.path))
        let aside = try setAside(in: t)
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: aside[0]) == Data("also not a plist".utf8))
    }

    /// A write that arrives while a read is about to set junk aside waits
    /// for it (another store value on the same folder too): the junk goes
    /// aside, and the new copy stays live and readable.
    @Test func aWriteDuringSetAsideStaysLive() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let arrived = DispatchSemaphore(value: 0)
        var w = RecoveryStore(directory: t)
        // Fires only when the writer finds the folder locked and is about to wait.
        w.checkLockContended = { arrived.signal() }
        let writer = w
        var reader = RecoveryStore(directory: t)
        let junk = reader.fileURL(forDocumentPath: "/docs/a.txt")
        try Data("not a plist".utf8).write(to: junk)
        let fresh = record(text: "new")
        let done = DispatchSemaphore(value: 0)
        let blocked = Flag()
        reader.checkBeforeSetAside = { _ in
            DispatchQueue.global().async {
                try? writer.write(fresh)
                done.signal()
            }
            // The writer has reached the lock this read holds and waits there.
            blocked.set(arrived.wait(timeout: .now() + 10) == .success && done.wait(timeout: .now()) == .timedOut)
        }
        #expect(reader.read(documentPath: "/docs/a.txt") == nil)
        #expect(blocked.value, "the writer arrived and was held at the folder lock")
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(writer.read(documentPath: "/docs/a.txt") == fresh)
        let aside = try setAside(in: t)
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: aside[0]) == Data("not a plist".utf8))
    }

    /// A live file that opens but fails on read (EIO): a write keeps its
    /// bytes (set aside, as a read does) or fails and leaves them live.
    @Test func writeOverALiveFileThatFailsOnReadKeepsItsBytes() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "old"))
        let live = store.fileURL(forDocumentPath: "/docs/a.txt")
        let bytes = try Data(contentsOf: live)
        var failing = store
        failing.checkFailRead = true
        do {
            try failing.write(record(text: "new"))
            let aside = try setAside(in: t)
            #expect(aside.count == 1)
            #expect(try aside.first.map { try Data(contentsOf: $0) } == bytes, "the old bytes were set aside")
            #expect(store.read(documentPath: "/docs/a.txt")?.text == "new")
        } catch {
            #expect(try Data(contentsOf: live) == bytes, "a failed write leaves the live bytes")
        }
    }

    /// The unreadable live file can't be set aside: the write fails and
    /// the live bytes stay.
    @Test func writeFailsWhenAnUnreadableLiveFileCantBeSetAside() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "old"))
        let live = store.fileURL(forDocumentPath: "/docs/a.txt")
        let bytes = try Data(contentsOf: live)
        var stuck = store
        stuck.checkFailRead = true
        stuck.checkFailSetAside = true
        #expect(throws: (any Error).self) { try stuck.write(record(text: "new")) }
        #expect(try Data(contentsOf: live) == bytes)
        #expect(try setAside(in: t).isEmpty)
    }

    /// An lstat error other than ENOENT is not "no file": the bytes there
    /// are kept (set aside, or the write fails), never replaced unseen.
    @Test func anLstatErrorIsNotAbsence() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "old"))
        let live = store.fileURL(forDocumentPath: "/docs/a.txt")
        let bytes = try Data(contentsOf: live)
        var statFails = store
        statFails.checkStatErrno = EIO
        do {
            try statFails.write(record(text: "new"))
            let aside = try setAside(in: t)
            #expect(aside.count == 1)
            #expect(try aside.first.map { try Data(contentsOf: $0) } == bytes)
        } catch {
            #expect(try Data(contentsOf: live) == bytes)
        }
        // Confirmed missing (ENOENT) is absence: nothing to keep.
        var missing = RecoveryStore(directory: t)
        missing.checkStatErrno = ENOENT
        try missing.write(record("/docs/b.txt", text: "b"))
        #expect(store.read(documentPath: "/docs/b.txt")?.text == "b")
    }

    /// A write that failed because the unreadable live copy couldn't be
    /// kept, then a clear from another store value (the fault still
    /// there): the only copy isn't deleted.
    @Test func aClearAfterAFailedWriteKeepsTheOnlyCopy() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "old"))
        let live = store.fileURL(forDocumentPath: "/docs/a.txt")
        let bytes = try Data(contentsOf: live)
        var stuck = store
        stuck.checkFailRead = true
        stuck.checkFailSetAside = true
        #expect(throws: (any Error).self) { try stuck.write(record(text: "new")) }
        var other = RecoveryStore(directory: t)
        other.checkFailRead = true
        other.checkFailSetAside = true
        other.clear(documentPath: "/docs/a.txt")
        #expect(try Data(contentsOf: live) == bytes, "not deleted")
        // Once it can be set aside, clear keeps the bytes there rather than delete them.
        var unreadable = RecoveryStore(directory: t)
        unreadable.checkFailRead = true
        unreadable.clear(documentPath: "/docs/a.txt")
        #expect(!fm.fileExists(atPath: live.path))
        let aside = try setAside(in: t)
        #expect(aside.count == 1)
        #expect(try aside.first.map { try Data(contentsOf: $0) } == bytes)
    }

    /// A live file that is there but can't be read is set aside (bytes
    /// kept), not left for a later write to replace.
    @Test func anUnreadableFileIsSetAsideOnRead() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "kept"))
        let live = store.fileURL(forDocumentPath: "/docs/a.txt")
        let bytes = try Data(contentsOf: live)
        var failing = store
        failing.checkFailRead = true
        #expect(failing.read(documentPath: "/docs/a.txt") == nil)
        #expect(!fm.fileExists(atPath: live.path))
        let aside = try setAside(in: t)
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: aside[0]) == bytes)
    }

    @Test func recoveryWriteIsDurableAndAFailedFlushLeavesThePreviousCopy() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "one"))
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "one")
        // failSync is the dying-disk check: the temp file's flush fails
        // before the rename, so the previous copy stays.
        #expect(throws: (any Error).self) { try store.write(record(text: "two"), failSync: true) }
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "one")
        #expect(try fm.contentsOfDirectory(atPath: t.path).filter { $0.hasSuffix(".recovery") }.count == 1)
    }

    @Test func recoveryWriteFolderFlushFailureIsUnconfirmedAndReadersSeeTheNewCopy() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RecoveryStore(directory: t)
        try store.write(record(text: "one"))
        // make() flushes parent entries to revalidate the folder; throw only
        // on the post-rename flush of the store directory itself.
        let dir = t.standardizedFileURL.path
        #expect(throws: PrivateDirectory.Unconfirmed.self) {
            try store.write(record(text: "two"), syncFolder: { path in
                if (path as NSString).standardizingPath == dir { throw CocoaError(.fileWriteUnknown) }
            })
        }
        // The rename happened; only the folder flush failed.
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "two")
    }

    /// First use with the folder and its parents missing: each new folder
    /// is made and its entry flushed through its parent; a failed flush
    /// fails the write (nothing acknowledged), and the retry flushes the
    /// unconfirmed folder again before going on.
    @Test func firstRecoveryWriteMakesMissingFoldersDurably() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let a = t.appendingPathComponent("a"), b = a.appendingPathComponent("b"), dir = b.appendingPathComponent("Recovery")
        let store = RecoveryStore(directory: dir)
        #expect(throws: (any Error).self) {
            try store.write(record(text: "one"), syncFolder: { _ in throw CocoaError(.fileWriteUnknown) })
        }
        #expect(!fm.fileExists(atPath: store.fileURL(forDocumentPath: "/docs/a.txt").path))
        let synced = Synced()
        // Another value on the same folder shares what is unconfirmed.
        try RecoveryStore(directory: dir).write(record(text: "one"), syncFolder: { synced.add($0) })
        let p = { (u: URL) in u.standardizedFileURL.path }
        #expect(synced.paths == [p(t), p(a), p(b), p(dir)])
        #expect(store.read(documentPath: "/docs/a.txt")?.text == "one")
        #expect(mode(dir) == 0o700)
    }

    /// The throttle's own rule; RecoveryWriter's first write before
    /// textChanged() returns is covered by the iOS tests
    /// (SaveSafetyEditorTests.testRecoveryWriterCopiesTheFirstEditAtOnceAndDefersTheNext).
    @Test func firstRecoveryWriteIsImmediateThenAtMostEveryThreeSeconds() {
        #expect(RecoveryThrottle.delay(sinceLastWrite: nil) == 0, "the first edit writes at once")
        #expect(RecoveryThrottle.delay(sinceLastWrite: 0) == RecoveryThrottle.interval)
        #expect(RecoveryThrottle.delay(sinceLastWrite: RecoveryThrottle.interval) == 0)
    }

    @Test func throttleWritesAtMostEveryThreeSeconds() {
        #expect(RecoveryThrottle.interval == 3)
        #expect(RecoveryThrottle.delay(sinceLastWrite: nil) == 0)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 0) == 3)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 1) == 2)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 3) == 0)
        #expect(RecoveryThrottle.delay(sinceLastWrite: 30) == 0)
        // A clock that went backwards doesn't hold writes back.
        #expect(RecoveryThrottle.delay(sinceLastWrite: -5) == 0)
    }

    // MARK: Revert store

    @Test func revertKeepLoadAndClear() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RevertStore(directory: t.appendingPathComponent("Opened"))
        let bytes = Data([0xff, 0xfe, 0x68, 0x00, 0x0d, 0x00, 0x0a, 0x00])
        #expect(store.keep(bytes, id: "doc1") == .kept)
        #expect(store.load(id: "doc1") == bytes)
        #expect(mode(store.fileURL(id: "doc1")) == 0o600)
        let excluded = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        store.clear(id: "doc1")
        #expect(store.load(id: "doc1") == nil)
    }

    @Test func revertCapIsTwentyMegabytes() throws {
        #expect(RevertStore.maxBytes == 20 * 1024 * 1024)
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RevertStore(directory: t, maxBytes: 8)
        #expect(store.keep(Data(count: 8), id: "atCap") == .kept)
        #expect(store.keep(Data(count: 9), id: "over") == .tooLarge(bytes: 9))
        #expect(store.load(id: "over") == nil)
        #expect(!fm.fileExists(atPath: store.fileURL(id: "over").path))
    }

    @Test func revertClearAllAtLaunch() throws {
        let t = try temp(); defer { try? fm.removeItem(at: t) }
        let store = RevertStore(directory: t)
        store.keep(Data("a".utf8), id: "a")
        store.keep(Data("b".utf8), id: "b")
        try Data("other".utf8).write(to: t.appendingPathComponent("keep.me"))
        store.clearAll()
        #expect(store.load(id: "a") == nil)
        #expect(store.load(id: "b") == nil)
        #expect(fm.fileExists(atPath: t.appendingPathComponent("keep.me").path))
    }

    // MARK: Save automatically

    @Test func autosaveOnlyWhenOnAndEdited() {
        #expect(SavePolicy.shouldAutosave(saveAutomatically: true, hasUnsavedChanges: true))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: true, hasUnsavedChanges: false))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: false, hasUnsavedChanges: true))
        #expect(!SavePolicy.shouldAutosave(saveAutomatically: false, hasUnsavedChanges: false))
    }

    @Test func closeAsksOnlyWhenOffAndEdited() {
        #expect(SavePolicy.onClose(saveAutomatically: false, hasUnsavedChanges: true) == .ask)
        #expect(SavePolicy.onClose(saveAutomatically: false, hasUnsavedChanges: false) == .close)
        #expect(SavePolicy.onClose(saveAutomatically: true, hasUnsavedChanges: true) == .close)
        #expect(SavePolicy.onClose(saveAutomatically: true, hasUnsavedChanges: false) == .close)
    }

    @Test func saveButtonOnlyWithAutosaveOff() {
        #expect(SavePolicy.showsSaveButton(saveAutomatically: false))
        #expect(!SavePolicy.showsSaveButton(saveAutomatically: true))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set(_ b: Bool) { lock.lock(); v = b; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

private final class Synced: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ p: String) { lock.lock(); list.append(p); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
