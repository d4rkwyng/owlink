import Foundation
import Testing
@testable import CedricCore

@Suite struct ClosedTabsTests {
    func tab(_ name: String, dirty: Bool) -> SessionTab { SessionTab(untitledName: name, hasBuffer: dirty) }

    @Test func newestLastAndOneEntryPerTab() {
        let a = tab("a", dirty: true), b = tab("b", dirty: false)
        var list = ClosedTabs.push(a, onto: []).list
        list = ClosedTabs.push(b, onto: list).list
        #expect(list.map(\.untitledName) == ["a", "b"])
        // The same tab closed again moves to the top, once.
        list = ClosedTabs.push(a, onto: list).list
        #expect(list.map(\.untitledName) == ["b", "a"])
    }

    @Test func overTheLimitCleanTabsGoFirst() {
        var list: [SessionTab] = []
        var dropped: [SessionTab] = []
        for (n, dirty) in [("d1", true), ("c1", false), ("d2", true), ("c2", false)] {
            let r = ClosedTabs.push(tab(n, dirty: dirty), onto: list, limit: 3)
            list = r.list
            dropped += r.dropped
        }
        // c1 (the oldest without unsaved text) went, not d1.
        #expect(list.map(\.untitledName) == ["d1", "d2", "c2"])
        #expect(dropped.map(\.untitledName) == ["c1"])
    }

    @Test func unsavedTabsAreNeverDropped() {
        // All unsaved: none goes (its buffer would be deleted); the list grows past the limit.
        let r = ClosedTabs.push(tab("d3", dirty: true), onto: [tab("x", dirty: true), tab("y", dirty: true)], limit: 2)
        #expect(r.list.map(\.untitledName) == ["x", "y", "d3"])
        #expect(r.dropped.isEmpty)
        // A clean tab pushed onto a full list of unsaved ones: the clean one is what goes.
        let c = ClosedTabs.push(tab("c", dirty: false), onto: r.list, limit: 2)
        #expect(c.list.map(\.untitledName) == ["x", "y", "d3"])
        #expect(c.dropped.map(\.untitledName) == ["c"])
        // 60 unsaved closes at the default limit of 50: all 60 kept.
        var list: [SessionTab] = []
        for n in 0..<60 {
            let p = ClosedTabs.push(tab("u\(n)", dirty: true), onto: list)
            #expect(p.dropped.isEmpty)
            list = p.list
        }
        #expect(list.count == 60)
    }

    /// A held tab whose reopen is owed (`Session.heldReopened`) never
    /// expires and is never dropped by the unsaved cap.
    @Test func anOwedReopenNeverExpiresOrIsDropped() {
        let now = Date()
        var owed = tab("owed", dirty: true)
        owed.closed = now.addingTimeInterval(-Double(ClosedTabs.keepDays + 5) * 86_400)
        var old = tab("old", dirty: true)
        old.closed = owed.closed
        let e = ClosedTabs.expire([owed, old], now: now, keeping: [owed.id])
        #expect(e.list.map(\.untitledName) == ["owed"] && e.dropped.map(\.untitledName) == ["old"])
        // Past the unsaved cap the oldest tab not owed goes, not the owed one.
        var mid = tab("mid", dirty: true)
        mid.closed = now
        let p = ClosedTabs.push(tab("new", dirty: true), onto: [owed, mid], unsavedLimit: 2, now: now, keeping: [owed.id])
        #expect(p.list.map(\.untitledName) == ["owed", "new"] && p.dropped.map(\.untitledName) == ["mid"])
    }

    @Test func savedWithTheSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-closed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let closed = tab("Untitled 2", dirty: true)
        try store.writeBuffer(closed.id, text: "closed but kept")
        try store.save(Session(windows: [], closedTabs: [closed]))
        // Pruning keeps what the caller keeps: the closed tab's buffer.
        store.pruneBuffers(keeping: [closed.id])
        let loaded = try #require(store.load())
        #expect(loaded.closedTabs == [closed])
        #expect(store.readBuffer(closed.id) == "closed but kept")
    }
}
