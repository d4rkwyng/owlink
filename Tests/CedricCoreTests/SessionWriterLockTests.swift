import Foundation
import Testing
@testable import CedricCore

/// Two Owlinks on one session folder (Astra 27e #6): each would commit and
/// prune against its own snapshot, so the second could delete a buffer
/// the first just wrote. The first to claim the folder's lock is its only
/// writer; another store that can't claim it reads nothing for launch and
/// writes, removes and prunes nothing.
@Suite(.serialized) struct SessionWriterLockTests {
    private let fm = FileManager.default

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
        #expect(second.claimWriter() == .inUse, "the lock is taken (a real flock, another open file)")
        #expect(second.notWriter == SessionStore.inUseReason)
        #expect(second.loadForLaunch() == .none, "the other Owlink's session is not restored here")
        let mine = SessionTab(untitledName: "Untitled", hasBuffer: true)
        #expect(throws: SessionStoreError.held(SessionStore.inUseReason)) { try second.writeBuffer(mine.id, text: "second's") }
        #expect(throws: SessionStoreError.held(SessionStore.inUseReason)) {
            try second.save(Session(windows: [SessionWindow(tabs: [mine])]))
        }
        #expect(throws: SessionStoreError.held(SessionStore.inUseReason)) { try second.noteReopened(a.id) }
        second.pruneBuffers(keeping: [mine.id])
        second.removeBuffer(a.id)
        second.removeBuffer(b.id)
        #expect(second.readBuffer(b.id) == "the first's new tab", "the first's newest buffer survives")
        #expect(second.readBuffer(a.id) == "committed")
        #expect(second.readBuffer(mine.id) == nil, "nothing of the second's written")
        #expect(try Data(contentsOf: dir.appendingPathComponent("session.json")) == committed, "session.json untouched")

        // The first goes on: commits, prunes, and a relaunch has both.
        try first.save(Session(windows: [SessionWindow(tabs: [a, b])]))
        first.pruneBuffers(keeping: [a.id, b.id])
        let relaunch = SessionStore(directory: dir)
        #expect(relaunch.claimWriter() == .inUse, "still the first's while it runs")
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
        #expect(SessionStore(directory: dir).claimWriter() == .inUse)
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
        #expect(store.claimWriter() == .inUse)
        #expect(throws: SessionStoreError.self) { try store.save(Session(windows: [])) }
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
}
