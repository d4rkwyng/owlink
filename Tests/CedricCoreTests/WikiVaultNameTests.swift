import Foundation
import Testing
@testable import CedricCore

/// Wiki link and image targets are checked as the UTF-8 bytes the kernel
/// gets, not as Swift text: a slash, backslash or colon followed by a
/// combining mark is one Swift character, so a text search misses it
/// (Astra batch 6 must-fixes 2 and 3).
@Suite struct WikiVaultNameTests {
    /// Each refused name is an image that exists, so nil shows the name was
    /// refused, not that nothing was there.
    @Test func resolveImageTakesOnlyOneBareNameByItsBytes() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/notes/sub/\u{301}p.png",
                              "v/notes/a\\\u{301}p.png", "v/notes/a:\u{301}p.png", "v/notes/plain.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let folder = t.appendingPathComponent("v/notes")
        try "{}".write(to: t.appendingPathComponent("v/.obsidian/app.json"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: folder)
        let fm = FileManager.default
        for f in ["sub/\u{301}p.png", "a\\\u{301}p.png", "a:\u{301}p.png"] {
            #expect(fm.fileExists(atPath: folder.appendingPathComponent(f).path), "fixture \(f.debugDescription)")
        }
        // The nested image is found by its own bare name.
        #expect(vault.resolveImage("\u{301}p.png")?.path == folder.appendingPathComponent("sub/\u{301}p.png").path)
        #expect(vault.resolveImage("plain.png")?.path == folder.appendingPathComponent("plain.png").path)
        for name in ["sub/\u{301}p.png", "sub/p.png", "a\\\u{301}p.png", "a:\u{301}p.png", "plain.png\0", "plain\0.png"] {
            #expect(vault.resolveImage(name) == nil, "\(name.debugDescription) is not one bare image name")
        }
        // The extension allowlist still holds.
        #expect(vault.resolveImage("doc.md") == nil)
    }
}
