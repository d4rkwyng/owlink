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
        // A clean tab pushed onto a full list of unsaved ones: kept, since
        // the tab being closed is never dropped (it is what ⇧⌘T brings
        // back next). The next clean close drops it, so the list passes
        // the limit by at most this one clean tab.
        let c = ClosedTabs.push(tab("c", dirty: false), onto: r.list, limit: 2)
        #expect(c.list.map(\.untitledName) == ["x", "y", "d3", "c"])
        #expect(c.dropped.isEmpty)
        let c2 = ClosedTabs.push(tab("c2", dirty: false), onto: c.list, limit: 2)
        #expect(c2.list.map(\.untitledName) == ["x", "y", "d3", "c2"])
        #expect(c2.dropped.map(\.untitledName) == ["c"])
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
        // The owed tab doesn't count toward the unsaved cap (Astra 25e #2):
        // at a cap of two, the owed tab and two ordinary ones all stay.
        var mid = tab("mid", dirty: true)
        mid.closed = now
        let p = ClosedTabs.push(tab("new", dirty: true), onto: [owed, mid], unsavedLimit: 2, now: now, keeping: [owed.id])
        #expect(p.list.map(\.untitledName) == ["owed", "mid", "new"] && p.dropped.isEmpty)
        // Past the cap the oldest ordinary tab goes, never the owed one.
        let q = ClosedTabs.push(tab("newer", dirty: true), onto: p.list, unsavedLimit: 2, now: now, keeping: [owed.id])
        #expect(q.list.map(\.untitledName) == ["owed", "new", "newer"] && q.dropped.map(\.untitledName) == ["mid"])
    }

    /// A full set of protected entries (`unsavedLimit` of them, owed or
    /// held) and one more dirty tab closed: it is kept, never dropped as
    /// the only one that could go (its buffer would be deleted at once).
    @Test func aTabClosedOntoAFullProtectedSetIsKept() {
        let now = Date()
        let protected = (0..<ClosedTabs.unsavedLimit).map { n -> SessionTab in
            var t = tab("p\(n)", dirty: true)
            t.closed = now.addingTimeInterval(-60)
            return t
        }
        let keeping = Set(protected.map(\.id))
        let new = tab("new", dirty: true)
        let p = ClosedTabs.push(new, onto: protected, now: now, keeping: keeping)
        #expect(p.dropped.isEmpty, "dropped: \(p.dropped.map(\.untitledName))")
        #expect(p.list.count == ClosedTabs.unsavedLimit + 1 && p.list.last?.id == new.id)
        // And with room for ordinary ones as usual: the next ones are kept too.
        let q = ClosedTabs.push(tab("next", dirty: true), onto: p.list, now: now, keeping: keeping)
        #expect(q.dropped.isEmpty && q.list.count == ClosedTabs.unsavedLimit + 2)
        // At a cap of one, a new close drops the older ordinary one, never itself.
        let r = ClosedTabs.push(tab("last", dirty: true), onto: q.list, unsavedLimit: 1, now: now, keeping: keeping)
        #expect(r.dropped.map(\.untitledName) == ["new", "next"] && r.list.last?.untitledName == "last")
        // A clean tab closed onto a full list of dirty ones isn't dropped either.
        let clean = tab("clean", dirty: false)
        let c = ClosedTabs.push(clean, onto: protected, limit: 2, now: now, keeping: keeping)
        #expect(c.dropped.isEmpty && c.list.last?.id == clean.id)
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
