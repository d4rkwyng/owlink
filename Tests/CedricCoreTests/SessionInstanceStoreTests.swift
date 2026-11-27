import Foundation
import Testing
@testable import CedricCore

/// Two Owlinks on one session folder, the cases the lock alone left open
/// (Astra 27e #6, round 7): the lock file replaced under its holder, a
/// second Owlink's own crash, and what the next writer does with a dead
/// one's text. Written against `claimWriter`'s results and the files on
/// disk only, so they run on the store before instance stores too.
@Suite(.serialized) struct SessionInstanceStoreTests {
    private let fm = FileManager.default

    /// Every `instances/<uuid>/<id>.txt` under `dir`: id → text.
    private func instanceTexts(_ dir: URL) -> [UUID: String] {
        let root = dir.appendingPathComponent("instances")
        var out: [UUID: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let d = root.appendingPathComponent(name)
            for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".txt") {
                if let id = UUID(uuidString: String(f.dropLast(4))), let t = try? String(contentsOf: d.appendingPathComponent(f), encoding: .utf8) {
                    out[id] = t
                }
            }
        }
        return out
    }

    /// The instance store holding buffer `id`.
    private func instanceHolding(_ dir: URL, _ id: UUID) -> URL? {
        let root = dir.appendingPathComponent("instances")
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let d = root.appendingPathComponent(name)
            if fm.fileExists(atPath: d.appendingPathComponent("\(id.uuidString).txt").path) { return d }
        }
        return nil
    }

    /// Every file under `dir` with its bytes (a store's whole state).
    private func snapshot(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            out[f] = (try? Data(contentsOf: dir.appendingPathComponent(f))) ?? Data()
        }
        return out
    }

    /// 1. The session folder restored from a backup while the first Owlink
    /// runs: `session.lock` is a new file, so a second Owlink's lock on it
    /// succeeds. The first must stop writing there (its lock is no longer
    /// the folder's), so the two never both write or prune the folder:
    /// the second's new buffer survives the first's commit and prune, the
    /// first's later text goes to a store of its own, and the first's
    /// journaled draft survives the second's save and prune.
    @Test func aReplacedLockFileNeverLetsTwoStoresWriteTheFolder() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = SessionStore(directory: dir)
        #expect(first.claimWriter() == .claimed)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try first.writeBuffer(a.id, text: "committed")
        try first.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = SessionTab(untitledName: "Untitled 2", hasBuffer: true)
        try first.writeBuffer(b.id, text: "the first's journaled draft")

        // A restore: a new session.lock renamed over the one the first holds.
        let lockFile = dir.appendingPathComponent("session.lock")
        let restored = dir.appendingPathComponent("session.lock.restored")
        try Data().write(to: restored)
        #expect(rename(restored.path, lockFile.path) == 0)

        let second = SessionStore(directory: dir)
        #expect(second.claimWriter() == .claimed, "the new lock file is free: the second is the folder's writer")
        guard case .session(let s2, let recovered) = second.loadForLaunch() else { Issue.record("the second reads the session"); return }
        #expect(recovered == [b.id], "the first's journaled draft comes back in the second")
        let d = SessionTab(untitledName: "Untitled 3", hasBuffer: true)
        try second.writeBuffer(d.id, text: "the second's new tab")
        let manifest = try Data(contentsOf: dir.appendingPathComponent("session.json"))

        // The first goes on: a new tab, a commit, a prune, a removal.
        let c = SessionTab(untitledName: "Untitled 4", hasBuffer: true)
        try? first.writeBuffer(c.id, text: "the first's text after the replacement")
        try? first.save(Session(windows: [SessionWindow(tabs: [a, b, c])]))
        first.pruneBuffers(keeping: [a.id, b.id, c.id])
        first.removeBuffer(a.id)
        #expect(second.readBuffer(d.id) == "the second's new tab", "the first's prune didn't delete the second's buffer")
        #expect(second.readBuffer(a.id) == "committed", "nor its removal the folder's buffer")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("\(c.id.uuidString).txt").path), "the first wrote nothing more in the folder")
        #expect(try Data(contentsOf: dir.appendingPathComponent("session.json")) == manifest, "nor its session")
        #expect(instanceTexts(dir)[c.id] == "the first's text after the replacement", "the first's text is in a store of its own")

        // The second commits what it restored and its own tab, and prunes.
        var bt = SessionTab(untitledName: "Recovered", hasBuffer: true)
        bt.id = b.id
        try second.save(Session(windows: s2.windows + [SessionWindow(tabs: [bt, d])]))
        second.pruneBuffers(keeping: [a.id, b.id, d.id])
        #expect(second.readBuffer(b.id) == "the first's journaled draft", "the first's journaled draft survives the second's save and prune")
        #expect(second.readBuffer(d.id) == "the second's new tab")
    }

    /// 2. A second Owlink (the folder's lock is held) types a draft, its
    /// timed backup runs, and it dies: the draft is on disk, in its own
    /// store in the session folder, and the folder itself is untouched.
    @Test func aSecondStoresDraftIsOnDiskAfterItDies() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = SessionStore(directory: dir)
        #expect(first.claimWriter() == .claimed)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try first.writeBuffer(a.id, text: "the first's")
        try first.save(Session(windows: [SessionWindow(tabs: [a])]))
        let before = snapshot(dir)

        var second: SessionStore? = SessionStore(directory: dir)
        _ = second?.claimWriter()
        let t = SessionTab(untitledName: "Untitled", hasBuffer: true)
        // The timed backup: the buffer, the commit that needs it, the prune.
        try? second?.writeBuffer(t.id, text: "the second Owlink's draft", sequence: 1)
        try? second?.save(Session(windows: [SessionWindow(tabs: [t])]), requiring: [t.id: .written(1)])
        second?.pruneBuffers(keeping: [t.id])
        second = nil // dead: its descriptors closed, as a kill -9 does

        #expect(instanceTexts(dir)[t.id] == "the second Owlink's draft", "the draft's bytes are on disk")
        let own = try #require(instanceHolding(dir, t.id))
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: own.appendingPathComponent("session.json")))
        #expect(session.allTabs.map(\.id) == [t.id], "its own session names it")
        var st = stat()
        #expect(lstat(own.path, &st) == 0 && st.st_mode & 0o777 == 0o700, "owner-only")
        var after = snapshot(dir)
        after["instances"] = nil
        #expect(after == before, "nothing of the session folder's own changed")
        #expect(first.readBuffer(a.id) == "the first's")
    }

    /// 3. The next writer's launch adopts a dead Owlink's store before any
    /// expiry or prune: its open tab, its closed tab and a text it had
    /// only journaled come back, written and journaled here; the dead
    /// store is removed only by the commit after that, and a live one
    /// (its lock held) is never touched.
    @Test func theNextWriterAdoptsADeadInstanceStoreFirst() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        var first: SessionStore? = SessionStore(directory: dir)
        #expect(first?.claimWriter() == .claimed)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try first?.writeBuffer(a.id, text: "the first's")
        try first?.save(Session(windows: [SessionWindow(tabs: [a])]))

        var dead: SessionStore? = SessionStore(directory: dir)
        _ = dead?.claimWriter()
        let t = SessionTab(untitledName: "Untitled", hasBuffer: true)
        var closedTab = SessionTab(untitledName: "Untitled 2", hasBuffer: true)
        closedTab.closed = Date()
        try? dead?.writeBuffer(t.id, text: "the dead one's open draft")
        try? dead?.writeBuffer(closedTab.id, text: "the dead one's closed draft", open: false)
        try? dead?.save(Session(windows: [SessionWindow(tabs: [t])], closedTabs: [closedTab]))
        let j = UUID()
        try? dead?.writeBuffer(j, text: "journaled only, then the crash")
        dead = nil

        let live = SessionStore(directory: dir)
        _ = live.claimWriter()
        let lt = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try? live.writeBuffer(lt.id, text: "the live one's draft")
        try? live.save(Session(windows: [SessionWindow(tabs: [lt])]))
        let liveDir = try #require(instanceHolding(dir, lt.id), "the live one has a store of its own")
        let liveBefore = snapshot(liveDir)
        let deadDir = try #require(instanceHolding(dir, t.id))
        first = nil

        let next = SessionStore(directory: dir)
        #expect(next.claimWriter() == .claimed)
        guard case .session(let s, let recovered) = next.loadForLaunch() else { Issue.record("a session"); return }
        #expect(s.allTabs.contains { $0.id == t.id && $0.hasBuffer }, "the dead one's open tab is in the session")
        #expect(next.readBuffer(t.id) == "the dead one's open draft")
        #expect(s.closedTabs?.contains { $0.id == closedTab.id && $0.hasBuffer } == true, "its closed tab is on the closed list")
        #expect(next.readBuffer(closedTab.id) == "the dead one's closed draft")
        #expect(recovered.contains(j), "its journaled text comes back too")
        #expect(next.readBuffer(j) == "journaled only, then the crash")
        #expect(s.allTabs.contains { $0.id == a.id }, "the folder's own session as before")
        #expect(fm.fileExists(atPath: deadDir.path), "the dead store stays until a commit here names its text")

        var jt = SessionTab(untitledName: "Recovered", hasBuffer: true)
        jt.id = j
        let committed = Session(windows: s.windows + [SessionWindow(tabs: [jt])], closedTabs: s.closedTabs)
        try next.save(committed)
        next.pruneBuffers(keeping: committed.bufferIDs)
        #expect(!fm.fileExists(atPath: deadDir.path), "removed once the commit has it")
        #expect(next.readBuffer(t.id) == "the dead one's open draft", "and the text survives the prune")
        #expect(next.readBuffer(closedTab.id) == "the dead one's closed draft")
        #expect(next.readBuffer(j) == "journaled only, then the crash")
        #expect(snapshot(liveDir) == liveBefore, "the live store is untouched")
        #expect(live.readBuffer(lt.id) == "the live one's draft")
    }
}
