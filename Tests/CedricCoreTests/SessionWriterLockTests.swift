import Foundation
import Testing
@testable import CedricCore

/// Two Owlinks on one session folder (Astra 27e #6): each would commit and
/// prune against its own snapshot, so the second could delete a buffer
/// the first just wrote. The first to claim the folder's lock is its only
/// writer; another store that can't claim it reads nothing for launch and
/// writes, removes and prunes nothing there: it writes a store of its own
/// (`instances/<uuid>/`), or, if none can be made, nothing at all.
@Suite(.serialized) struct SessionWriterLockTests {
    private let fm = FileManager.default

    private func isInstance(_ c: SessionStore.WriterClaim) -> Bool {
        if case .instance = c { return true }
        return false
    }

    /// The first store backs up a new tab (journaled, not committed yet);
    /// then a second store on the same folder, as a second Owlink would,
    /// saves its own session and prunes. The first's buffer survives, and
    /// its commit and relaunch bring the text back.
    @Test func aSecondStoreCantSaveOrPruneOverTheFirstsBuffers() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = SessionStore(directory: dir)
        #expect(first.claimWriter() == .claimed)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try first.writeBuffer(a.id, text: "committed")
        try first.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = SessionTab(untitledName: "Untitled 2", hasBuffer: true)
        try first.writeBuffer(b.id, text: "the first's new tab")
        let committed = try Data(contentsOf: dir.appendingPathComponent("session.json"))

        let second = SessionStore(directory: dir)
        // Round 6 had `.inUse` here and every write refused: the second's
        // text was then only in memory, lost with a crash (27e #6, round 7).
        let claim = second.claimWriter()
        #expect(isInstance(claim), "the lock is taken (a real flock, another open file): a store of its own")
        #expect(second.notWriter == nil)
        let own = try #require(second.instanceDirectory)
        #expect(claim == .instance(own) && own.deletingLastPathComponent().lastPathComponent == "instances"
                && own.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(second.loadForLaunch() == .none, "the other Owlink's session is not restored here")
        let mine = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try second.writeBuffer(mine.id, text: "second's")
        try second.save(Session(windows: [SessionWindow(tabs: [mine])]))
        try second.noteReopened(a.id)
        second.pruneBuffers(keeping: [mine.id])
        second.removeBuffer(a.id)
        second.removeBuffer(b.id)
        #expect(first.readBuffer(b.id) == "the first's new tab", "the first's newest buffer survives")
        #expect(first.readBuffer(a.id) == "committed")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("\(mine.id.uuidString).txt").path), "nothing of the second's written in the folder")
        #expect(second.readBuffer(mine.id) == "second's", "but in its own store")
        #expect(try Data(contentsOf: dir.appendingPathComponent("session.json")) == committed, "session.json untouched")

        // The first goes on: commits, prunes, and a relaunch has both.
        try first.save(Session(windows: [SessionWindow(tabs: [a, b])]))
        first.pruneBuffers(keeping: [a.id, b.id])
        let relaunch = SessionStore(directory: dir)
        #expect(isInstance(relaunch.claimWriter()), "still the first's while it runs")
        let after = SessionStore(directory: dir)
        guard case .session(let s, _) = after.loadForLaunch() else { Issue.record("readable"); return }
        #expect(s.allTabs.map(\.id) == [a.id, b.id])
        #expect(after.readBuffer(b.id) == "the first's new tab")
    }

    /// The lock goes with its store (the process ending, in the app):
    /// the next one claims it.
    @Test func theLockIsFreedWhenItsHolderGoes() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        var first: SessionStore? = SessionStore(directory: dir)
        #expect(first?.claimWriter() == .claimed)
        #expect(first?.claimWriter() == .claimed, "asking again: still the writer")
        #expect(isInstance(SessionStore(directory: dir).claimWriter()))
        first = nil
        let next = SessionStore(directory: dir)
        #expect(next.claimWriter() == .claimed)
        try next.writeBuffer(UUID(), text: "writes")
    }

    /// Another process holding the lock (flock(2) from python3, as a
    /// second Owlink process would): not claimed.
    @Test func aLockHeldByAnotherProcessIsRespected() throws {
        let dir = tempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            open(sys.argv[2], "w").close()
            time.sleep(30)
            """, dir.appendingPathComponent("session.lock").path, ready.path]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        for _ in 0..<200 where !fm.fileExists(atPath: ready.path) { usleep(25_000) }
        #expect(fm.fileExists(atPath: ready.path), "the other process holds the lock")
        let store = SessionStore(directory: dir)
        #expect(isInstance(store.claimWriter()))
        try store.save(Session(windows: []))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("session.json").path), "its session goes to its own store")
        p.terminate(); p.waitUntilExit()
        #expect(SessionStore(directory: dir).claimWriter() == .claimed, "free once that process has gone")
    }

    /// A store never asked to claim (tests, tools) writes as before.
    @Test func aStoreThatNeverClaimsStillWrites() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s = SessionStore(directory: dir)
        try s.writeBuffer(UUID(), text: "x")
        try s.save(Session(windows: []))
        #expect(s.notWriter == nil)
    }

    /// Asked again after the lock file was replaced, `claimWriter` checks
    /// the file, not just that it has a descriptor: the lock is lost, and
    /// the store moves to a store of its own, carrying the buffers it had
    /// committed or journaled, and says so (`moves`, `onMovedToInstance`).
    @Test func claimingAgainChecksTheLockFile() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let said = MovedTo()
        store.onMovedToInstance = { said.append($0) }
        #expect(store.claimWriter() == .claimed)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try store.writeBuffer(a.id, text: "committed")
        try store.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = UUID()
        try store.writeBuffer(b, text: "journaled")
        #expect(store.claimWriter() == .claimed, "unchanged: still the writer")
        #expect(store.moves == 0)
        // Removed, not replaced: lost as well.
        try fm.removeItem(at: dir.appendingPathComponent("session.lock"))
        let claim = store.claimWriter()
        let own = try #require(store.instanceDirectory)
        #expect(claim == .instance(own))
        #expect(store.moves == 1)
        #expect(said.value == [own])
        #expect(store.directory == own)
        #expect(store.readBuffer(a.id) == "committed", "carried over")
        #expect(store.readBuffer(b) == "journaled", "carried over")
        let journal = try Data(contentsOf: own.appendingPathComponent("pending-buffers.json"))
        let ids = try JSONDecoder().decode(SessionStore.Journal.self, from: journal).ids
        #expect(Set(ids) == [a.id.uuidString, b.uuidString], "and journaled there: a crash keeps them")
        #expect(store.claimWriter() == .instance(own), "its own lock checks out")
        // A new lock in the folder: free, but this store never goes back.
        #expect(SessionStore(directory: dir).claimWriter() == .claimed)
    }

    /// Neither the folder's lock nor a store of its own (the instances
    /// folder can't be made): as in round 6, the store writes nothing.
    @Test func withNoStoreOfItsOwnNothingIsWritten() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = SessionStore(directory: dir)
        #expect(first.claimWriter() == .claimed)
        try Data("not a folder".utf8).write(to: dir.appendingPathComponent("instances"))
        let second = SessionStore(directory: dir)
        #expect(second.claimWriter() == .inUse)
        #expect(second.notWriter == SessionStore.inUseReason)
        let mine = UUID()
        #expect(throws: SessionStoreError.held(SessionStore.inUseReason)) { try second.writeBuffer(mine, text: "second's") }
        #expect(throws: SessionStoreError.held(SessionStore.inUseReason)) { try second.save(Session(windows: [])) }
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("\(mine.uuidString).txt").path))
    }

    /// A dead store with a text that can't be read: what can be read is
    /// adopted, and the store is kept whole after the commit, unreadable
    /// text included. A writer that saves no session doesn't adopt.
    @Test func aDeadStoreThatCantBeReadWholeIsKept() throws {
        let dir = tempDir()
        defer {
            for (_, d) in instanceStores(dir) { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: d.path) }
            try? fm.removeItem(at: dir)
        }
        var first: SessionStore? = SessionStore(directory: dir)
        #expect(first?.claimWriter() == .claimed)
        var dead: SessionStore? = SessionStore(directory: dir)
        #expect(isInstance(dead!.claimWriter()))
        let ok = SessionTab(untitledName: "Untitled", hasBuffer: true)
        let locked = SessionTab(untitledName: "Untitled 2", hasBuffer: true)
        try dead?.writeBuffer(ok.id, text: "readable")
        try dead?.writeBuffer(locked.id, text: "can't be read for now")
        try dead?.save(Session(windows: [SessionWindow(tabs: [ok, locked])]))
        let deadDir = try #require(dead?.instanceDirectory)
        dead = nil
        first = nil
        let lockedFile = deadDir.appendingPathComponent("\(locked.id.uuidString).txt")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedFile.path)

        var readOnly: SessionStore? = SessionStore(directory: dir)
        readOnly?.adoptsInstances = false
        #expect(readOnly?.claimWriter() == .claimed)
        #expect(readOnly?.loadForLaunch() == SessionStore.LaunchLoad.none, "not adopted by a run that saves no session")
        #expect(readOnly?.adoptedFromInstances == 0)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("\(ok.id.uuidString).txt").path))
        readOnly = nil

        let next = SessionStore(directory: dir)
        #expect(next.claimWriter() == .claimed)
        guard case .session(let s, _) = next.loadForLaunch() else { Issue.record("a session"); return }
        #expect(s.allTabs.map(\.id) == [ok.id], "the readable text is adopted")
        #expect(next.adoptedFromInstances == 1)
        try next.save(s)
        next.pruneBuffers(keeping: s.bufferIDs)
        #expect(fm.fileExists(atPath: lockedFile.path), "the dead store is kept, its unreadable text with it")
        #expect(fm.fileExists(atPath: deadDir.appendingPathComponent("\(ok.id.uuidString).txt").path))
        #expect(next.readBuffer(ok.id) == "readable")
    }

    private func instanceStores(_ dir: URL) -> [(String, URL)] {
        let root = dir.appendingPathComponent("instances")
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).flatMap { name in
            ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)) ?? []).map { (name, root.appendingPathComponent(name).appendingPathComponent($0)) }
        }
    }
}

/// The folders `onMovedToInstance` reported.
final class MovedTo: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var value: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    func append(_ u: URL) { lock.lock(); defer { lock.unlock() }; urls.append(u) }
}
