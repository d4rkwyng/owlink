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
