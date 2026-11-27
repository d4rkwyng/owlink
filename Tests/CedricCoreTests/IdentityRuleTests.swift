import Foundation
import Testing
@testable import CedricCore

/// Names and containment by bytes; "the same file or folder" by
/// file-system identity only (Astra batch 17v, 0.6 validators round 5).
@Suite struct IdentityRuleTests {
    @Test func pathKeysKeepCanonicalTwinsApart() {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        #expect(nfc == nfd)                       // Swift text: one string
        #expect(!FolderTree.sameBytes(nfc, nfd))  // the bytes: two names
        var m: FolderTree.PathMap<Int> = [:]
        m[nfc] = 1; m[nfd] = 2
        #expect(m.count == 2 && m[nfc] == 1 && m[nfd] == 2)
        #expect(Set([FolderTree.PathKey(nfc), FolderTree.PathKey(nfd)]).count == 2)
    }

    @Test func fileIDsAreHashableIdentities() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let a = try #require(Beneath.FileID(path: d.path, followLast: true))
        let b = try #require(Beneath.FileID(path: d.path + "/.", followLast: true))
        #expect(Set([a, b]).count == 1)
    }
}
