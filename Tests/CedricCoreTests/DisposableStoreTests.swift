import Foundation
import Testing
@testable import CedricCore

/// crash-check's in-app guard: the session folder must be the very folder
/// the script made (by identity), never the real session or around it,
/// however its path is spelled.
@Suite struct DisposableStoreTests {
    let fm = FileManager.default

    @Test func onlyThePinnedFolderOutsideTheRealSessionIsAccepted() throws {
        let root = tempDir()
        defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("RealCedric"), session = real.appendingPathComponent("Session")
        let scratch = root.appendingPathComponent("scratch"), store = scratch.appendingPathComponent("s1")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let protected = [real, session]
        let id = try #require(DisposableStore.identity(store.path))
        #expect(DisposableStore.refusal(store, expected: id, protected: protected) == nil)
        // Another folder, even one made later at the same path, isn't it.
        let other = scratch.appendingPathComponent("s2")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(DisposableStore.refusal(other, expected: id, protected: protected) != nil)
        // The real session, by its own identity, or spelled another way.
        let sid = try #require(DisposableStore.identity(session.path))
        #expect(DisposableStore.refusal(session, expected: sid, protected: protected) != nil)
        let upper = URL(fileURLWithPath: root.path + "/REALCEDRIC/session")
        if let uid = DisposableStore.identity(upper.path) {   // a case-insensitive volume
            #expect(uid == sid)
            #expect(DisposableStore.refusal(upper, expected: uid, protected: protected) != nil, "a case variant is still the real session")
        }
        // Inside the real session, or holding it.
        let inner = session.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(DisposableStore.refusal(inner, expected: DisposableStore.identity(inner.path)!, protected: protected) != nil)
        #expect(DisposableStore.refusal(root, expected: DisposableStore.identity(root.path)!, protected: protected) != nil)
        // A link to the real session, even with the session's identity expected.
        let link = scratch.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: session)
        #expect(DisposableStore.refusal(link, expected: sid, protected: protected) != nil)
        #expect(DisposableStore.refusal(link, expected: DisposableStore.identity(link.path)!, protected: protected) != nil)
    }
}
