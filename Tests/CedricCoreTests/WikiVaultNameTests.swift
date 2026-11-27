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

    /// A note or image directly in the vault root whose name starts with a
    /// combining mark is inside the vault; a sibling folder whose name only
    /// starts like the root's is not.
    @Test func aRootNameStartingWithACombiningMarkIsInTheVault() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/\u{301}x.md", "v/\u{301}p.png", "v\u{301}/z.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("v"), folder = root.appendingPathComponent("notes")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("z.md"),
                                                   withDestinationURL: t.appendingPathComponent("v\u{301}/z.md"))
        let vault = WikiVault(documentFolder: folder)
        #expect(vault.resolve("\u{301}x")?.path == root.appendingPathComponent("\u{301}x.md").path)
        #expect(vault.resolveImage("\u{301}p.png")?.path == root.appendingPathComponent("\u{301}p.png").path)
        #expect(vault.resolve("z") == nil, "a link to the sibling folder v\u{301} stays out")
    }

    /// A ".." after a slash before a combining mark is still a parent
    /// component; the vault-root note it would reach is found by its name.
    @Test func resolveRefusesAParentComponentByItsBytes() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/\u{301}x.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("v")
        let vault = WikiVault(documentFolder: root.appendingPathComponent("notes"))
        #expect(vault.resolve("\u{301}x")?.path == root.appendingPathComponent("\u{301}x.md").path, "the note is there")
        for target in ["../\u{301}x", "../\u{301}x.md", "./../\u{301}x", "notes/../\u{301}x", "/../\u{301}x", "..//\u{301}x",
                       "\0\u{301}x", "\u{301}x\0"] {
            #expect(vault.resolve(target) == nil, "\(target.debugDescription)")
        }
    }

    /// A leading slash before a combining mark is still a path from the
    /// vault root: it finds the root's note, not the one beside the document.
    @Test func resolveTakesALeadingSlashByItsByte() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/\u{301}x.md", "v/notes/\u{301}x.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("v"), folder = root.appendingPathComponent("notes")
        let vault = WikiVault(documentFolder: folder)
        #expect(vault.resolve("\u{301}x")?.path == folder.appendingPathComponent("\u{301}x.md").path, "a bare name: beside the document first")
        #expect(vault.resolve("/\u{301}x")?.path == root.appendingPathComponent("\u{301}x.md").path)
        #expect(vault.resolve("//\u{301}x")?.path == root.appendingPathComponent("\u{301}x.md").path, "repeated slashes as before")
    }

    /// "sub/\u{301}x" names a note in a folder "sub": with none there, a
    /// same-named note elsewhere is not taken for it.
    @Test func resolveQualifiedMissDoesNotTakeASameNamedNoteElsewhere() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/other/\u{301}x.md", "v/deep/sub/\u{301}y.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("v")
        let vault = WikiVault(documentFolder: root.appendingPathComponent("notes"))
        #expect(vault.resolve("\u{301}x")?.path == root.appendingPathComponent("other/\u{301}x.md").path, "the note is there")
        #expect(vault.resolve("sub/\u{301}x") == nil)
        #expect(vault.resolve("/sub/\u{301}x") == nil)
        #expect(vault.resolve("sub/\u{301}y")?.path == root.appendingPathComponent("deep/sub/\u{301}y.md").path, "a qualified hit still resolves")
        #expect(vault.resolve("other/\u{301}x")?.path == root.appendingPathComponent("other/\u{301}x.md").path)
    }

    /// "." components and repeated separators behave as before.
    @Test func resolveKeepsDotAndRepeatedSeparators() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/notes/Here.md", "v/x/Target.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("v"), folder = root.appendingPathComponent("notes")
        let vault = WikiVault(documentFolder: folder)
        let target = root.appendingPathComponent("x/Target.md").path
        #expect(vault.resolve("./Here")?.path == folder.appendingPathComponent("Here.md").path)
        #expect(vault.resolve("x//Target")?.path == target)
        #expect(vault.resolve("x/./Target")?.path == target)
        #expect(vault.resolve("/x/Target")?.path == target)
    }
}
