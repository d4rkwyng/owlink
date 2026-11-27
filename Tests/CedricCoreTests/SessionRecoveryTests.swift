import Foundation
import Testing
@testable import CedricCore

/// The session store across a kill between writing buffers and committing
/// `session.json` (the journal), and when launch can't read or keep
/// what it finds (holds).
@Suite struct SessionRecoveryTests {
    private func store(_ dir: URL) -> SessionStore { SessionStore(directory: dir) }
    private let fm = FileManager.default

    // MARK: The journal

    @Test func aBufferWrittenAfterAValidSessionComesBackAfterAKill() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try first.writeBuffer(a.id, text: "committed text")
        try first.save(Session(windows: [SessionWindow(tabs: [a])]))
        // A new tab's first text: written, then the app dies before the
        // session naming it is committed. The older session still reads.
        let b = UUID()
        try first.writeBuffer(b, text: "only copy")
        #expect(first.load()?.allTabs.map(\.id) == [a.id])

        let relaunch = store(dir)
        guard case .session(let s, let recovered) = relaunch.loadForLaunch() else { Issue.record("a readable session"); return }
        #expect(s.allTabs.map(\.id) == [a.id])
        #expect(recovered == [b])
        #expect(relaunch.readBuffer(b) == "only copy")
        // The tab is opened and saved: an ordinary buffer from then on.
        try relaunch.save(Session(windows: [SessionWindow(tabs: [a, SessionTab(id: b, untitledName: "Recovered", hasBuffer: true)])]))
        relaunch.pruneBuffers(keeping: [a.id, b])
        guard case .session(_, let again) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(again.isEmpty)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("pending-buffers.json").path))
    }

    @Test func aBufferLetGoIsNotBroughtBack() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        let b = UUID()
        try s1.writeBuffer(a.id, text: "a")
        try s1.writeBuffer(b, text: "b, discarded before the next save")
        // The tab was discarded; the next session doesn't name it, and the
        // app dies after committing it but before the prune.
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        #expect(s1.readBuffer(b) != nil)
        guard case .session(_, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(recovered.isEmpty)
    }

    @Test func steadyTypingInATabTheSessionNamesWritesNoJournal() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "1")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        try s1.writeBuffer(a.id, text: "12")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("pending-buffers.json").path))
        // Also after a relaunch: what the launched session names counts.
        let s2 = store(dir)
        _ = s2.loadForLaunch()
        try s2.writeBuffer(a.id, text: "123")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("pending-buffers.json").path))
    }

    @Test func journaledIdsTheSessionNamesWithoutTextGetTheirBuffer() {
        let open = SessionTab(path: "/tmp/edited.txt", hasBuffer: false)
        var closedClean = SessionTab(path: "/tmp/reopened.txt", hasBuffer: false)
        closedClean.closed = Date()
        var closedUnsaved = SessionTab(path: "/tmp/closed-unsaved.txt", hasBuffer: true)
        closedUnsaved.closed = Date()
        let gone = UUID(), stray = UUID()
        let session = Session(windows: [SessionWindow(tabs: [open])], closedTabs: [closedClean, closedUnsaved])
        let r = SessionStore.applyJournal(session, journal: [open.id, closedClean.id, closedUnsaved.id, gone, stray, stray]) { $0 != gone }
        // The file's first edit: the tab comes back with it.
        #expect(r.session.windows[0].tabs[0].hasBuffer)
        // Reopened from the closed list and edited: open again, with it.
        #expect(r.session.windows.count == 2)
        #expect(r.session.windows[1].tabs.map(\.id) == [closedClean.id])
        #expect(r.session.windows[1].tabs[0].hasBuffer && r.session.windows[1].tabs[0].closed == nil)
        #expect(r.session.closedTabs?.map(\.id) == [closedUnsaved.id])
        // Named nowhere: recovered, once; a buffer that isn't there: nothing.
        #expect(r.recovered == [stray])
    }

    @Test func aDamagedJournalBringsBackEveryUnnamedBuffer() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = UUID()
        try s1.writeBuffer(b, text: "b")
        try Data("{".utf8).write(to: dir.appendingPathComponent("pending-buffers.json"))
        guard case .session(_, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(recovered == [b])
    }

    /// The app dies after committing a session that let a buffer go,
    /// before the journal that listed it is removed (or removing it
    /// failed): the journal is spent, and the buffer doesn't come back.
    @Test func aJournalLeftAfterItsCommitBringsNothingBack() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        let dropped = UUID()
        try s1.writeBuffer(dropped, text: "discarded before the commit")
        let journal = dir.appendingPathComponent("pending-buffers.json")
        let left = try Data(contentsOf: journal)
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        // As if the removal never happened.
        try left.write(to: journal)
        guard case .session(let s, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(recovered.isEmpty)
        #expect(s.allTabs.map(\.id) == [a.id])
    }

    /// The same journal before its commit is pending, and a journal from
    /// before commits were numbered (a bare array) always is.
    @Test func aPendingOrUnnumberedJournalIsApplied() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = UUID()
        try s1.writeBuffer(b, text: "b")
        let journal = dir.appendingPathComponent("pending-buffers.json")
        let j = try JSONDecoder().decode(SessionStore.Journal.self, from: Data(contentsOf: journal))
        #expect(j.ids == [b.uuidString] && j.generation == 2)
        guard case .session(_, let pending) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(pending == [b])
        try JSONEncoder().encode([b.uuidString]).write(to: journal)
        guard case .session(_, let legacy) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(legacy == [b])
    }

    /// A journal that decodes but names something that isn't an id is
    /// damaged: launch scans for every buffer the session doesn't name.
    @Test func aJournalWithAnInvalidIdIsDamaged() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = UUID()
        try s1.writeBuffer(b, text: "b")
        let journal = dir.appendingPathComponent("pending-buffers.json")
        for bad in [#"["not-an-id"]"#, #"{"generation": 2, "ids": ["not-an-id"]}"#] {
            try Data(bad.utf8).write(to: journal)
            guard case .session(_, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
            #expect(recovered == [b], "\(bad)")
        }
    }

    /// A damaged journal (an invalid id): launch scans, recovers an
    /// unnamed buffer and reopens a closed tab near the end of its
    /// retention. A new tab written before the first commit replaces the
    /// damaged journal; a second crash must still bring back the scanned
    /// buffer and keep the closed tab open, not just the new tab.
    @Test func aRepairedJournalCarriesWhatTheScanFound() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let s0 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        var closed = SessionTab(path: "/tmp/closed-with-text.txt", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 3600)
        try s0.writeBuffer(a.id, text: "a")
        try s0.writeBuffer(closed.id, text: "closed text")
        try s0.save(Session(windows: [SessionWindow(tabs: [a])], closedTabs: [closed]))
        let orphan = UUID()
        try s0.writeBuffer(orphan, text: "only copy, journal damaged")
        try Data(#"{"generation": 2, "ids": ["not-an-id"]}"#.utf8).write(to: dir.appendingPathComponent("pending-buffers.json"))

        let s1 = store(dir)
        guard case .session(let first, let found) = s1.loadForLaunch(now: t1) else { Issue.record("readable"); return }
        #expect(found == [orphan])
        #expect(first.closedTabs == nil && first.allTabs.contains { $0.id == closed.id }, "the scan reopens the closed tab")
        let new = UUID()
        try s1.writeBuffer(new, text: "a new tab before the first commit")
        // Killed before any commit; the next launch is a day later.
        guard case .session(let second, let recovered) = store(dir).loadForLaunch(now: t1.addingTimeInterval(86_400)) else { Issue.record("readable"); return }
        #expect(Set(recovered) == [orphan, new], "\(recovered)")
        #expect(ClosedTabs.expire(second.closedTabs ?? [], now: t1.addingTimeInterval(86_400)).dropped.isEmpty, "nothing expires")
        #expect(second.allTabs.contains { $0.id == closed.id && $0.hasBuffer }, "the closed tab stays open")
    }

    /// Commit numbers no commit can have: a journal numbered Int.min (or
    /// 0) is damaged (launch scans), and a session numbered Int.max
    /// spends no journal and is committed past without overflowing.
    @Test func impossibleCommitNumbersAreDamagedNotTrusted() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        let b = UUID()
        try s1.writeBuffer(b, text: "b")
        let journal = dir.appendingPathComponent("pending-buffers.json")
        for g in [Int.min, 0, -1] {
            try JSONEncoder().encode(SessionStore.Journal(generation: g, ids: [])).write(to: journal)
            guard case .session(_, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
            #expect(recovered == [b], "journal numbered \(g): damaged, scanned")
        }
        try JSONEncoder().encode(SessionStore.Journal(generation: 2, ids: [b.uuidString])).write(to: journal)
        let file = dir.appendingPathComponent("session.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        manifest["generation"] = Int.max
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
        let s2 = store(dir)
        guard case .session(_, let recovered) = s2.loadForLaunch() else { Issue.record("readable"); return }
        #expect(recovered == [b], "a session numbered Int.max spends no journal")
        try s2.save(Session(windows: [SessionWindow(tabs: [a, SessionTab(id: b, untitledName: "Recovered", hasBuffer: true)])]))
        let c = UUID()
        try s2.writeBuffer(c, text: "c")
        guard case .session(let s, let again) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(s.allTabs.map(\.id) == [a.id, b], "committed past it")
        #expect(again == [c])
    }

    // MARK: Reopened closed tabs

    /// A closed tab whose entry kept a buffer, closed just inside
    /// `ClosedTabs.keepDays` when one launch reads it. ⇧⌘T reopens it,
    /// it is edited, and the app dies before the next commit. The next
    /// launch, a day later, is past its closing date's retention: the
    /// tab must come back open with the new text, not be expired with it.
    @Test func aReopenedClosedTabWithABufferSurvivesACrashAcrossItsRetention() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let t2 = t1.addingTimeInterval(86_400)
        let s0 = store(dir)
        var closed = SessionTab(path: "/tmp/closed-with-text.txt", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 3600)
        try s0.writeBuffer(closed.id, text: "text when it closed")
        try s0.save(Session(windows: [], closedTabs: [closed]))

        let s1 = store(dir)
        guard case .session(let first, _) = s1.loadForLaunch(now: t1) else { Issue.record("readable"); return }
        #expect(ClosedTabs.expire(first.closedTabs ?? [], now: t1).dropped.isEmpty, "inside retention at the first launch")
        try s1.noteReopened(closed.id)
        try s1.writeBuffer(closed.id, text: "edited after reopening")
        #expect(s1.load()?.closedTabs?.map(\.id) == [closed.id], "the commit still lists it as closed")

        guard case .session(let second, let recovered) = store(dir).loadForLaunch(now: t2) else { Issue.record("readable"); return }
        let expiry = ClosedTabs.expire(second.closedTabs ?? [], now: t2)
        #expect(!expiry.dropped.contains { $0.id == closed.id }, "not expired with its old closing date")
        let back = second.allTabs.first { $0.id == closed.id }
        #expect(back?.hasBuffer == true && back?.closed == nil, "open again, with its buffer")
        #expect(recovered.isEmpty)
        #expect(store(dir).readBuffer(closed.id) == "edited after reopening")
    }

    /// A closed tab whose buffer an earlier launch couldn't read (held in
    /// the commit), readable now: ⇧⌘T reads it, releases the hold and
    /// journals the reopen; the app dies before the next commit. The
    /// next launch, past the old closing date's retention, must open it,
    /// not skip the reopen because the old commit still holds it (then
    /// release it, leave it closed and expire its text).
    @Test func aReopenedTabWhoseBufferWasHeldSurvivesACrash() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let s0 = store(dir)
        var closed = SessionTab(untitledName: "Untitled", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 3600)
        try s0.writeBuffer(closed.id, text: "held, readable again", open: false)
        s0.holdBuffer(closed.id)
        try s0.save(Session(windows: [], closedTabs: [closed]))
        #expect(s0.load()?.heldBuffers == [closed.id])

        let s1 = store(dir)
        guard case .session(let first, _) = s1.loadForLaunch(now: t1) else { Issue.record("readable"); return }
        #expect(first.closedTabs?.map(\.id) == [closed.id], "still closed at the first launch")
        // ⇧⌘T: read, released, journaled.
        #expect(s1.readBuffer(closed.id) == "held, readable again")
        s1.releaseBuffer(closed.id)
        try s1.noteReopened(closed.id)

        let t2 = t1.addingTimeInterval(86_400)
        let s2 = store(dir)
        guard case .session(let second, let recovered) = s2.loadForLaunch(now: t2) else { Issue.record("readable"); return }
        #expect(ClosedTabs.expire(second.closedTabs ?? [], now: t2).dropped.isEmpty, "not expired under its old closing date")
        #expect(second.allTabs.contains { $0.id == closed.id && $0.hasBuffer && $0.closed == nil }, "open again, with its text")
        #expect(second.heldBuffers == nil && !s2.heldBuffers.contains(closed.id), "no longer held")
        #expect(recovered.isEmpty)
        // Unreadable again at that launch: left held and closed.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: s2.bufferURL(closed.id).path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: s2.bufferURL(closed.id).path) }
        guard case .session(let third, _) = store(dir).loadForLaunch(now: t2) else { Issue.record("readable"); return }
        #expect(third.closedTabs?.map(\.id) == [closed.id] && third.heldBuffers == [closed.id], "unreadable: still held, still closed")
    }

    /// The other a177bf9 route (sol-e): reopened near its retention, edited,
    /// and the synchronous save that would list it open fails (a full
    /// disk), then the app is killed. The next launch, past the old date,
    /// opens it with the edit rather than expiring it.
    @Test func aReopenedClosedTabSurvivesAFailedSaveAndACrashAcrossItsRetention() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let s0 = store(dir)
        var closed = SessionTab(path: "/tmp/closed-with-text.txt", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 3600)
        try s0.writeBuffer(closed.id, text: "text when it closed")
        try s0.save(Session(windows: [], closedTabs: [closed]))
        let s1 = store(dir)
        _ = s1.loadForLaunch(now: t1)
        try s1.noteReopened(closed.id)
        try s1.writeBuffer(closed.id, text: "edited after reopening")
        var open = closed
        open.closed = nil
        s1.checkFailWrites = true
        #expect(throws: (any Error).self) { try s1.save(Session(windows: [SessionWindow(tabs: [open])])) }
        let t2 = t1.addingTimeInterval(86_400)
        guard case .session(let s, _) = store(dir).loadForLaunch(now: t2) else { Issue.record("readable"); return }
        #expect(ClosedTabs.expire(s.closedTabs ?? [], now: t2).dropped.isEmpty)
        #expect(s.allTabs.contains { $0.id == closed.id && $0.hasBuffer && $0.closed == nil })
        #expect(store(dir).readBuffer(closed.id) == "edited after reopening")
    }

    /// A held closed tab reopened (journaled), then unreadable at the next
    /// launch, which saves successfully (clearing the journal), then
    /// readable again at a launch past its old closing date's retention
    /// (Astra 20e #4): the reopen must survive the save, the tab must come
    /// back open with its text, and nothing may expire it meanwhile.
    @Test func aHeldReopenSurvivesASaveWhileUnreadable() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let s0 = store(dir)
        var closed = SessionTab(untitledName: "Untitled", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 3600)
        try s0.writeBuffer(closed.id, text: "the only copy", open: false)
        s0.holdBuffer(closed.id)
        try s0.save(Session(windows: [], closedTabs: [closed]))

        // Readable again: ⇧⌘T reads it, releases the hold and journals
        // the reopen; killed before the next commit.
        let s1 = store(dir)
        _ = s1.loadForLaunch(now: t1)
        #expect(s1.readBuffer(closed.id) == "the only copy")
        s1.releaseBuffer(closed.id)
        try s1.noteReopened(closed.id)

        // Unreadable at the next launch, inside retention: held, closed.
        let path = s1.bufferURL(closed.id).path
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        let t2 = t1.addingTimeInterval(60)
        let s2 = store(dir)
        guard case .session(let second, _) = s2.loadForLaunch(now: t2) else { Issue.record("readable"); return }
        #expect(second.closedTabs?.map(\.id) == [closed.id] && second.heldBuffers == [closed.id], "unreadable: held, closed")
        // That run saves what it has (as the app does: its closed list).
        try s2.save(Session(windows: [], closedTabs: second.closedTabs))
        s2.pruneBuffers(keeping: [closed.id])
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("pending-buffers.json").path), "the save cleared the journal")

        // Readable at a launch past the old closing date's retention.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let t3 = t1.addingTimeInterval(2 * 86_400)
        let s3 = store(dir)
        guard case .session(let third, let recovered) = s3.loadForLaunch(now: t3) else { Issue.record("readable"); return }
        #expect(third.allTabs.contains { $0.id == closed.id && $0.hasBuffer && $0.closed == nil }, "open again: \(third.closedTabs?.map(\.id) ?? [])")
        #expect((third.closedTabs ?? []).isEmpty && recovered.isEmpty)
        #expect(third.heldBuffers == nil && !s3.heldBuffers.contains(closed.id), "no longer held")
        #expect(s3.readBuffer(closed.id) == "the only copy")
    }

    /// The repeat reopen after an uncertain commit (Astra 20e #1): a
    /// committed closed tab is reopened (journaled), the commit listing
    /// it open fails before its rename, it is closed again and that
    /// commit's rename lands but its folder flush fails, then it is
    /// reopened again and edited. A kill there must bring it back open
    /// with the edit, whichever commit is on disk: the reopen marker from
    /// before the uncertain commit is spent by it, so the second reopen
    /// (and the edit) must journal again, numbered above it.
    @Test func aRepeatReopenAfterAnUnconfirmedCommitIsJournaledAgain() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let s0 = store(dir)
        var closed = SessionTab(untitledName: "Untitled", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 3600)
        try s0.writeBuffer(closed.id, text: "text when it first closed")
        try s0.save(Session(windows: [], closedTabs: [closed]))
        let firstCommit = try Data(contentsOf: dir.appendingPathComponent("session.json"))

        let s1 = store(dir)
        _ = s1.loadForLaunch(now: t1)
        // ⇧⌘T: journaled; the commit listing it open fails before its rename.
        try s1.noteReopened(closed.id)
        var open = closed
        open.closed = nil
        s1.checkFailWrites = true
        #expect(throws: (any Error).self) { try s1.save(Session(windows: [SessionWindow(tabs: [open])])) }
        s1.checkFailWrites = false
        // Closed again: its text written, then the commit listing it closed
        // is renamed into place but its folder flush fails.
        try s1.writeBuffer(closed.id, text: "text when it closed again")
        var closedAgain = closed
        closedAgain.closed = t1
        s1.checkFailFolderSync = true
        #expect(throws: (any Error).self) { try s1.save(Session(windows: [], closedTabs: [closedAgain])) }
        s1.checkFailFolderSync = false
        #expect(s1.load()?.closedTabs?.map(\.id) == [closed.id], "the unconfirmed commit lists it closed")
        // ⇧⌘T again, and an edit; killed before any commit.
        try s1.noteReopened(closed.id)
        try s1.writeBuffer(closed.id, text: "edited after the second reopen")

        let t2 = t1.addingTimeInterval(86_400)
        guard case .session(let s, let recovered) = store(dir).loadForLaunch(now: t2) else { Issue.record("readable"); return }
        #expect(s.closedTabs == nil, "not on the closed list: \(s.closedTabs?.map(\.id) ?? [])")
        #expect(s.allTabs.contains { $0.id == closed.id && $0.hasBuffer && $0.closed == nil }, "open again, with its buffer")
        #expect(recovered.isEmpty)
        // Or with the commit before it on disk (the flush lost the rename).
        try firstCommit.write(to: dir.appendingPathComponent("session.json"))
        guard case .session(let older, _) = store(dir).loadForLaunch(now: t2) else { Issue.record("readable"); return }
        #expect(older.closedTabs == nil && older.allTabs.contains { $0.id == closed.id && $0.hasBuffer }, "open over the older commit too")
        #expect(store(dir).readBuffer(closed.id) == "edited after the second reopen")
    }

    /// Reopened and not edited: journaled anyway, so it isn't expired
    /// either; once a commit lists it open, the journal is spent.
    @Test func aReopenedClosedTabIsJournaledBeforeAnyEdit() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let t1 = Date()
        let s0 = store(dir)
        var closed = SessionTab(untitledName: "Untitled", hasBuffer: true)
        closed.closed = t1.addingTimeInterval(-Double(ClosedTabs.keepDays) * 86_400 + 60)
        try s0.writeBuffer(closed.id, text: "kept")
        try s0.save(Session(windows: [], closedTabs: [closed]))
        let s1 = store(dir)
        _ = s1.loadForLaunch(now: t1)
        try s1.noteReopened(closed.id)
        guard case .session(let s, _) = store(dir).loadForLaunch(now: t1.addingTimeInterval(86_400)) else { Issue.record("readable"); return }
        #expect(s.closedTabs == nil)
        #expect(s.windows.first?.tabs.map(\.id) == [closed.id])
        var open = closed
        open.closed = nil
        try s1.save(Session(windows: [SessionWindow(tabs: [open])]))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("pending-buffers.json").path))
    }

    /// A closed tab's text kept in memory and written later (its close
    /// couldn't write it) is not a reopen: it stays on the closed list.
    @Test func aClosedTabsLateWriteDoesntReopenIt() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s0 = store(dir)
        var closed = SessionTab(untitledName: "Untitled", hasBuffer: true)
        closed.closed = Date()
        try s0.save(Session(windows: [], closedTabs: [closed]))
        let s1 = store(dir)
        _ = s1.loadForLaunch()
        try s1.writeBuffer(closed.id, text: "written after the close", open: false)
        guard case .session(let s, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(s.closedTabs?.map(\.id) == [closed.id] && s.windows.isEmpty && recovered.isEmpty)
    }

    // MARK: Commits that depend on buffer writes

    /// A commit names a buffer whose write failed (its own snapshot's, or
    /// an earlier one's it relied on as still in flight): refused, the
    /// older session and the journal stay. Once a write with that number
    /// or a later one has worked, it goes through.
    @Test func aCommitWaitsForTheWritesItNeeds() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s.writeBuffer(a.id, text: "a", sequence: 1)
        try s.save(Session(windows: [SessionWindow(tabs: [a])]), requiring: [a.id: .written(1)])
        let b = SessionTab(untitledName: "Untitled 2", hasBuffer: true)
        s.checkFailWrites = true
        #expect(throws: (any Error).self) { try s.writeBuffer(b.id, text: "b", sequence: 2) }
        s.checkFailWrites = false
        // A later snapshot that skipped b's write as in flight.
        #expect(throws: SessionStoreError.buffersMissing([b.id])) {
            try s.save(Session(windows: [SessionWindow(tabs: [a, b])]), requiring: [a.id: .onDisk, b.id: .written(2)])
        }
        #expect(s.load()?.allTabs.map(\.id) == [a.id], "the older session stays")
        // b's text written, but by an older write than the one needed.
        try s.writeBuffer(b.id, text: "b, older", sequence: 1)
        #expect(throws: SessionStoreError.self) {
            try s.save(Session(windows: [SessionWindow(tabs: [a, b])]), requiring: [b.id: .written(2)])
        }
        try s.writeBuffer(b.id, text: "b", sequence: 3)
        try s.save(Session(windows: [SessionWindow(tabs: [a, b])]), requiring: [a.id: .onDisk, b.id: .written(2)])
        #expect(s.load()?.allTabs.map(\.id) == [a.id, b.id])
    }

    /// A buffer the commit needs on disk that isn't there: refused (a held
    /// one counts as there).
    @Test func aCommitNeedsItsBuffersOnDisk() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s.save(Session(windows: []))
        #expect(throws: SessionStoreError.buffersMissing([a.id])) {
            try s.save(Session(windows: [SessionWindow(tabs: [a])]), requiring: [a.id: .onDisk])
        }
        s.holdBuffer(a.id)
        try s.save(Session(windows: [SessionWindow(tabs: [a])]), requiring: [a.id: .onDisk])
    }

    // MARK: Durable writes

    /// A flush to disk that fails (check builds: checkFailSync) fails the
    /// write: the old buffer and session.json stay as they were, and no
    /// temp file is left.
    @Test func aFailedFlushFailsTheWriteAndKeepsTheOldFile() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s.writeBuffer(a.id, text: "on disk")
        try s.save(Session(windows: [SessionWindow(tabs: [a])]))
        s.checkFailSync = true
        #expect(throws: (any Error).self) { try s.writeBuffer(a.id, text: "not confirmed") }
        #expect(throws: (any Error).self) { try s.writeBuffer(UUID(), text: "new, not confirmed") }
        #expect(throws: (any Error).self) { try s.save(Session(windows: [])) }
        #expect(s.readBuffer(a.id) == "on disk")
        #expect(s.load()?.allTabs.map(\.id) == [a.id])
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasPrefix(".") }, "\(names)")
        s.checkFailSync = false
        try s.writeBuffer(a.id, text: "confirmed")
        try s.save(Session(windows: [SessionWindow(tabs: [a])]))
        #expect(s.readBuffer(a.id) == "confirmed")
    }

    /// A commit renamed into place whose folder flush then fails: the
    /// writer can't know which commit is on disk. A new tab written next
    /// must come back after a kill whether session.json is that commit
    /// (it was in place) or the one before (it was lost with the flush):
    /// its journal mustn't be numbered as spent by the commit on disk.
    @Test func aCommitWhoseFlushFailsAfterItsRenameDoesntSpendTheNextJournal() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s.writeBuffer(a.id, text: "a")
        try s.save(Session(windows: [SessionWindow(tabs: [a])]))
        let before = try Data(contentsOf: dir.appendingPathComponent("session.json"))
        s.checkFailFolderSync = true
        #expect(throws: (any Error).self) { try s.save(Session(windows: [SessionWindow(tabs: [a])], untitledCounter: 1)) }
        s.checkFailFolderSync = false
        #expect(s.load()?.untitledCounter == 1, "the unconfirmed commit is in place")
        let b = UUID()
        try s.writeBuffer(b, text: "a new tab after the unconfirmed commit")
        // Killed here. session.json as the rename left it:
        guard case .session(_, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(recovered == [b], "the new tab comes back over the unconfirmed commit")
        // Or as a power loss could leave it, the commit before:
        try before.write(to: dir.appendingPathComponent("session.json"))
        guard case .session(_, let again) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(again == [b], "and over the commit before it")
        #expect(store(dir).readBuffer(b) == "a new tab after the unconfirmed commit")
    }

    /// First use makes the store's folders (Cedric, Session): each new
    /// folder's entry is flushed through its parent, and a flush that
    /// fails fails the write (nothing counts as kept in a folder whose
    /// path may not be on the disk). Later runs flush the store's own
    /// entry once too.
    @Test func firstUseFlushesEveryNewFolderThroughItsParent() throws {
        let base = tempDir()
        defer { try? fm.removeItem(at: base) }
        let cedric = base.appendingPathComponent("Cedric"), dir = cedric.appendingPathComponent("Session")
        let s = store(dir)
        s.checkFailFolderSync = true
        let first = UUID()
        #expect(throws: (any Error).self) { try s.writeBuffer(first, text: "not confirmed") }
        #expect(s.readBufferResult(first) == .missing, "nothing written into an unconfirmed folder")
        s.checkFailFolderSync = false
        try s.writeBuffer(first, text: "kept")
        let synced = s.checkSyncedFolders
        #expect(synced.contains(base.path), "Cedric's entry flushed in its parent: \(synced)")
        #expect(synced.contains(cedric.path), "Session's entry flushed in Cedric: \(synced)")
        #expect(s.readBuffer(first) == "kept")
        // An existing store: its own entry and its parent's (Cedric's: made
        // by another part of Owlink, maybe never flushed) once, and a
        // failure there fails too.
        let again = store(dir)
        again.checkFailFolderSync = true
        #expect(throws: (any Error).self) { try again.writeBuffer(UUID(), text: "x") }
        again.checkFailFolderSync = false
        try again.writeBuffer(UUID(), text: "y")
        #expect(Array(again.checkSyncedFolders.prefix(2)) == [base.path, cedric.path], "\(again.checkSyncedFolders)")
    }

    /// Astra 20e #6: first use makes Cedric, and the flush of its entry in
    /// the folder above fails. The retry finds Cedric there; it must not
    /// stop at it, make Session, flush Cedric and acknowledge the write
    /// with Cedric's own entry never confirmed. Only flushes that worked
    /// count (`checkSyncedFolders` doesn't list failed ones), and only
    /// those of the retry.
    @Test func aRetryAfterAFailedFirstUseFlushConfirmsTheFolderItMade() throws {
        let base = tempDir()
        defer { try? fm.removeItem(at: base) }
        // `base` stands for Application Support: there already.
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let cedric = base.appendingPathComponent("Cedric"), dir = cedric.appendingPathComponent("Session")
        let s = store(dir)
        s.checkFailFolderSync = true
        #expect(throws: (any Error).self) { try s.writeBuffer(UUID(), text: "not confirmed") }
        s.checkFailFolderSync = false
        #expect(fm.fileExists(atPath: cedric.path), "Cedric was made; its flush failed")
        let before = s.checkSyncedFolders.count
        let id = UUID()
        try s.writeBuffer(id, text: "kept")
        let retry = Array(s.checkSyncedFolders.dropFirst(before))
        #expect(retry.contains(base.path), "Cedric's entry flushed in its parent on the retry: \(retry)")
        #expect(retry.firstIndex(of: base.path) ?? .max < retry.firstIndex(of: cedric.path) ?? -1, "outermost first: \(retry)")
        #expect(s.readBuffer(id) == "kept")
    }

    /// Another part of Owlink (the CLI token) made Cedric first, with no
    /// flush. The store's first write must flush Cedric's entry in its
    /// parent too, not only Session's in Cedric.
    @Test func firstUseFlushesASupportFolderSomethingElseMade() throws {
        let base = tempDir()
        defer { try? fm.removeItem(at: base) }
        let cedric = base.appendingPathComponent("Cedric"), dir = cedric.appendingPathComponent("Session")
        try PrivateDirectory.make(cedric, root: cedric)
        let s = store(dir)
        try s.writeBuffer(UUID(), text: "kept")
        let synced = s.checkSyncedFolders
        #expect(synced.contains(base.path), "Cedric's entry flushed in its parent: \(synced)")
        #expect(synced.contains(cedric.path), "Session's entry flushed in Cedric: \(synced)")
    }

    @Test func durableWritesReplaceAtomically() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("f.json")
        try PrivateDirectory.writePrivateFile(Data("one".utf8), to: f, durable: true)
        #expect(throws: (any Error).self) { try PrivateDirectory.writePrivateFile(Data("two".utf8), to: f, durable: true, failSync: true) }
        #expect(try Data(contentsOf: f) == Data("one".utf8))
        #expect(try fm.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["f.json"])
        try PrivateDirectory.syncFolder(dir.path)
        #expect(throws: (any Error).self) { try PrivateDirectory.syncFolder(dir.appendingPathComponent("none").path) }
    }

    // MARK: Holds

    @Test func anUnreadableSessionThatCantBeMovedIsCopiedAside() throws {
        let dir = tempDir()
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: dir.appendingPathComponent("session.json").path); try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.json")
        try Data("{truncated".utf8).write(to: file)
        try fm.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let s = store(dir)
        guard case .recover(let aside?, _) = s.loadForLaunch() else { Issue.record("kept aside (copied)"); return }
        #expect(try Data(contentsOf: aside) == Data("{truncated".utf8))
        #expect(s.hold == nil)
    }

    @Test func anUnreadableSessionThatCantBeKeptHoldsTheStore() throws {
        let dir = tempDir()
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "unsaved")
        let orphan = UUID()
        try s1.writeBuffer(orphan, text: "named nowhere")
        let file = dir.appendingPathComponent("session.json")
        try Data("{truncated".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let s = store(dir)
        guard case .recover(nil, let buffers) = s.loadForLaunch() else { Issue.record("recover, nothing set aside"); return }
        #expect(Set(buffers) == [a.id, orphan])
        #expect(s.hold != nil)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Writable again: still held for this run. Never overwritten, never pruned.
        #expect(throws: SessionStoreError.self) { try s.save(Session(windows: [])) }
        s.pruneBuffers(keeping: [])
        #expect(try Data(contentsOf: file) == Data("{truncated".utf8))
        #expect(s.readBuffer(a.id) == "unsaved")
        #expect(s.readBuffer(orphan) == "named nowhere")
    }

    @Test func aFolderThatCantBeListedIsLeftAsItIs() throws {
        let dir = tempDir()
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = UUID()
        try s1.writeBuffer(a, text: "unsaved")
        let file = dir.appendingPathComponent("session.json")
        try Data("{truncated".utf8).write(to: file)
        // Search and write, no read: the session file opens, the folder doesn't list.
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
        let s = store(dir)
        #expect(s.loadForLaunch() == .recover(setAside: nil, buffers: []))
        #expect(s.hold != nil)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(fm.fileExists(atPath: file.path))
        #expect(throws: SessionStoreError.self) { try s.save(Session(windows: [])) }
        s.pruneBuffers(keeping: [])
        #expect(s.readBuffer(a) == "unsaved")
        // The next launch, folder readable: the usual recovery.
        guard case .recover(_?, let buffers) = store(dir).loadForLaunch() else { Issue.record("recovered next launch"); return }
        #expect(buffers == [a])
    }

    /// A held store deletes nothing, not even a buffer the app lets go
    /// directly (a closed tab past its retention, a tab saved).
    @Test func aHeldStoreRemovesNoBuffer() throws {
        let dir = tempDir()
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = UUID()
        try s1.writeBuffer(a, text: "unsaved")
        try Data("{truncated".utf8).write(to: dir.appendingPathComponent("session.json"))
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
        let s = store(dir)
        _ = s.loadForLaunch()
        #expect(s.hold != nil)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        s.removeBuffer(a)
        #expect(s.readBuffer(a) == "unsaved")
    }

    /// Launch can't read the journal nor list the folder: held. New text
    /// written this run is journaled beside the damaged journal, never
    /// over it, so the next launch still knows to scan, and finds both
    /// the older unnamed buffer and the new one. Its commit then removes
    /// the held run's journal.
    @Test func aHeldStoreNeverReplacesTheJournal() throws {
        let dir = tempDir()
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        let older = UUID()
        try s1.writeBuffer(older, text: "only copy, journal lost")
        let journal = dir.appendingPathComponent("pending-buffers.json")
        try Data("{".utf8).write(to: journal)
        // Search and write, no read: the session opens, the folder doesn't list.
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
        let s2 = store(dir)
        guard case .session = s2.loadForLaunch() else { Issue.record("readable"); return }
        #expect(s2.hold != nil)
        let new = UUID()
        try s2.writeBuffer(new, text: "typed while held")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(try Data(contentsOf: journal) == Data("{".utf8), "the damaged journal is left as it was")
        let s3 = store(dir)
        guard case .session(_, let recovered) = s3.loadForLaunch() else { Issue.record("readable"); return }
        #expect(s3.hold == nil)
        #expect(Set(recovered) == [older, new])
        try s3.save(Session(windows: [SessionWindow(tabs: [a] + recovered.map { SessionTab(id: $0, untitledName: "Recovered", hasBuffer: true) })]))
        let left = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("pending-buffers") }
        #expect(left.isEmpty, "\(left)")
    }

    /// The held run's journal alone (the main one readable): applied too.
    @Test func aHeldRunsJournalIsApplied() throws {
        let dir = tempDir()
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
        let s1 = store(dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        try s1.writeBuffer(a.id, text: "a")
        try s1.save(Session(windows: [SessionWindow(tabs: [a])]))
        try Data("{".utf8).write(to: dir.appendingPathComponent("pending-buffers.json"))
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
        let s2 = store(dir)
        _ = s2.loadForLaunch()
        let new = UUID()
        try s2.writeBuffer(new, text: "typed while held")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try fm.removeItem(at: dir.appendingPathComponent("pending-buffers.json"))
        guard case .session(_, let recovered) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(recovered == [new])
    }

    /// A held launch that couldn't read the session (commit 20) nor list
    /// the folder knows no commit number. Text written once the disk
    /// works again must come back at the next launch, which reads commit
    /// 20 again: a held run's journal is applied whatever its number.
    /// With no journal at launch it is the main journal (unnumbered), with
    /// one it is a journal of its own beside it; either is applied until
    /// a commit adopts it by name, and a copy left after that commit (its
    /// removal failed) is spent.
    @Test func aHeldRunsJournalIsAppliedWhateverTheCommitNumber() throws {
        for withJournal in [false, true] {
            let dir = tempDir()
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? fm.removeItem(at: dir) }
            let s1 = store(dir)
            let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
            try s1.writeBuffer(a.id, text: "a")
            for _ in 0..<20 { try s1.save(Session(windows: [SessionWindow(tabs: [a])])) }
            let older = UUID()
            if withJournal { try s1.writeBuffer(older, text: "pending before the held run") }
            let file = dir.appendingPathComponent("session.json")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
            let held = store(dir)
            _ = held.loadForLaunch()
            #expect(held.hold != nil, "held")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let new = UUID()
            try held.writeBuffer(new, text: "typed once the disk worked again")
            let next = store(dir)
            guard case .session(_, let recovered) = next.loadForLaunch() else { Issue.record("readable"); return }
            #expect(Set(recovered) == Set(withJournal ? [older, new] : [new]), "journal at launch: \(withJournal)")
            let journals = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("pending-buffers") }
            #expect(journals.count == (withJournal ? 2 : 1), "\(journals)")
            // A held journal whose removal fails (locked): still there after
            // the commit that adopted it, and after the next one.
            let side = journals.filter { $0.hasPrefix("pending-buffers.held-") }.map { dir.appendingPathComponent($0).path }
            defer { for p in side { try? fm.setAttributes([.immutable: false], ofItemAtPath: p) } }
            for p in side { try fm.setAttributes([.immutable: true], ofItemAtPath: p) }
            try next.save(Session(windows: [SessionWindow(tabs: [a] + recovered.map { SessionTab(id: $0, untitledName: "Recovered", hasBuffer: true) })]))
            guard case .session(_, let after) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
            #expect(after.isEmpty, "adopted: spent, even though it is still there")
            try next.save(Session(windows: [SessionWindow(tabs: [a])]))
            guard case .session(_, let later) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
            #expect(later.isEmpty, "and after the next commit, which names it again")
            #expect(side.allSatisfy { fm.fileExists(atPath: $0) }, "the locked journal is still there")
        }
    }

    @Test func aMissingFolderIsAFirstLaunchNotAHold() {
        let s = store(tempDir())
        #expect(s.loadForLaunch() == .none)
        #expect(s.hold == nil)
    }

    @Test func anUnreadableBufferIsHeldNeverPruned() throws {
        let dir = tempDir()
        let s1 = store(dir)
        let a = UUID()
        try s1.writeBuffer(a, text: "unsaved")
        let path = s1.bufferURL(a).path
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path); try? fm.removeItem(at: dir) }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        guard case .unreadable = s1.readBufferResult(a) else { Issue.record("unreadable"); return }
        #expect(s1.readBufferResult(UUID()) == .missing)
        s1.holdBuffer(a)
        try s1.save(Session(windows: []))
        s1.pruneBuffers(keeping: [])
        s1.removeBuffer(a)
        #expect(fm.fileExists(atPath: path))
        // Named in the session, so the next launch tries it again.
        guard case .session(let s, _) = store(dir).loadForLaunch() else { Issue.record("readable"); return }
        #expect(s.heldBuffers == [a])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(s1.readBufferResult(a) == .text("unsaved"))
    }

    @Test func injectedWriteFailuresFailEveryWrite() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let s = store(dir)
        s.checkFailWrites = true
        #expect(DevEnvironment.checksEnabled)
        #expect(throws: (any Error).self) { try s.writeBuffer(UUID(), text: "x") }
        #expect(throws: (any Error).self) { try s.save(Session(windows: [])) }
        s.checkFailWrites = false
        try s.save(Session(windows: []))
    }
}
