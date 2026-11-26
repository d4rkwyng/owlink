import Foundation
import Testing
@testable import CedricCore

/// Validators round 4, the whole-app sweep: every file-system containment,
/// identity or name decision compares the UTF-8 bytes the kernel gets
/// (`FolderTree.relativePath`, `FolderTree.components`, `Beneath.isName`,
/// `FolderTree.isDotName`, `FolderTree.sameBytes`, `FolderTree.PathKey`),
/// not Swift text. As text a slash followed by a combining mark is one
/// character (so a prefix test or a split at "/" misses it), a dot
/// followed by one isn't a "." prefix, and canonically equivalent but
/// byte-distinct names (the Ohm sign U+2126 and Omega U+03A9) are equal.
@Suite struct PathBytesTests {
    let fm = FileManager.default
    /// A folder that doesn't exist: paths below it are only compared.
    let base = URL(fileURLWithPath: "/cedric-no-such-folder-\(UUID().uuidString)")
    var ohm: URL { base.appendingPathComponent("\u{2126}") }
    var omega: URL { base.appendingPathComponent("\u{3A9}") }

    func folder() throws -> URL {
        let d = fm.temporaryDirectory.appendingPathComponent("cedric-bytes-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func theHelpers() {
        #expect(FolderTree.isDotName(".\u{301}x") && FolderTree.isDotName(".env") && FolderTree.isDotName("."))
        #expect(!FolderTree.isDotName("\u{301}.x") && !FolderTree.isDotName("x.") && !FolderTree.isDotName(""))
        #expect("\u{2126}" == "\u{3A9}", "Swift text calls them equal")
        #expect(!FolderTree.sameBytes("\u{2126}", "\u{3A9}") && FolderTree.sameBytes("a\u{301}", "a\u{301}"))
        #expect(Set([FolderTree.PathKey("\u{2126}"), FolderTree.PathKey("\u{3A9}")]).count == 2)
        #expect(FolderTree.PathKey(URL(fileURLWithPath: "/a/./b")) == FolderTree.PathKey("/a/b"), "a URL's standardized path")
        #expect(FolderTree.PathKey("\u{301}d/x").string == "\u{301}d/x")
    }

    // MARK: Containment

    /// `PrivateDirectory.make` tightens the root above the folder it makes
    /// when that folder is inside it, also a first folder whose name
    /// starts with a combining mark.
    @Test func aPrivateFolderTightensItsRootAboveAMarkLeadingFolder() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let root = t.appendingPathComponent("support")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PrivateDirectory.make(root.appendingPathComponent("\u{301}d"), root: root)
        let mode = try #require(try fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o700, "the root was tightened")
        // The root's name plus a mark is a sibling: that root is left alone.
        let other = t.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PrivateDirectory.make(t.appendingPathComponent("other\u{301}/d"), root: other)
        let left = try #require(try fm.attributesOfItem(atPath: other.path)[.posixPermissions] as? Int)
        #expect(left & 0o777 == 0o755, "a sibling's root is not touched")
    }

    /// A pasted file's relative link, Replace in Files' inside-the-folder
    /// test and its folder names below the root: a mark-leading folder is
    /// inside, the folder's name plus a mark and the other spelling of a
    /// canonically equivalent folder are not.
    @Test func pasteAndReplaceContainmentIsByBytes() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        let inMark = doc.appendingPathComponent("\u{301}d/a.png")
        try fm.createDirectory(at: inMark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: inMark)
        #expect(MarkdownPaste.relativePath(of: inMark, from: doc) == MarkdownPaste.encode("\u{301}d/a.png"))
        #expect(MarkdownPaste.relativePath(of: t.appendingPathComponent("doc\u{301}/a.png"), from: doc) == nil)
        #expect(MarkdownPaste.relativePath(of: omega.appendingPathComponent("a.png"), from: ohm) == nil, "another spelling is another folder")
        #expect(MarkdownPaste.relativePath(of: ohm.appendingPathComponent("a.png"), from: ohm) == "a.png")

        #expect(SafePaths.isInside(inMark, doc))
        #expect(SafePaths.isInside(doc.appendingPathComponent("\u{301}x.txt"), doc), "first level")
        #expect(SafePaths.isInside(doc, doc))
        #expect(!SafePaths.isInside(t.appendingPathComponent("doc\u{301}/x.txt"), doc))
        #expect(!SafePaths.isInside(omega.appendingPathComponent("x.txt"), ohm))

        #expect(TreeWrite.relativeDirectories(of: doc.appendingPathComponent("\u{301}d/e/f.txt"), under: doc) == ["\u{301}d", "e"])
        #expect(TreeWrite.relativeDirectories(of: doc.appendingPathComponent("\u{301}f.txt"), under: doc) == [])
        #expect(TreeWrite.relativeDirectories(of: t.appendingPathComponent("doc\u{301}/f.txt"), under: doc) == nil)
        #expect(TreeWrite.relativeDirectories(of: omega.appendingPathComponent("d/f.txt"), under: ohm) == nil,
                "Replace in Files writes only below the root by its bytes")
        #expect(TreeWrite.relativeDirectories(of: ohm.appendingPathComponent("d/f.txt"), under: ohm) == ["d"])
    }

    /// A save through a symbolic link whose destination starts with "/"
    /// and a combining mark writes the absolute target the kernel follows,
    /// not a file of that name beside the link.
    @Test func aLinkDestinationIsAbsoluteByItsFirstByte() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let link = t.appendingPathComponent("note.md")
        let dest = "/\u{301}cedric-no-such-\(UUID().uuidString).md"
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: dest)
        #expect(Array(SafePaths.writeTarget(for: link).path.utf8) == Array(dest.utf8))
        let rel = t.appendingPathComponent("rel.md")
        try fm.createSymbolicLink(atPath: rel.path, withDestinationPath: "\u{301}x.md")
        #expect(SafePaths.writeTarget(for: rel) == t.appendingPathComponent("\u{301}x.md").standardizedFileURL)
    }

    /// A vault root is never the home folder or above it, judged by the
    /// paths' bytes: a folder spelled with the Ohm sign is not above a home
    /// spelled with Omega.
    @Test func aVaultRootAboveHomeIsJudgedByBytes() {
        let home = omega.appendingPathComponent("user")
        #expect(!WikiVault.mayBeVaultRoot(omega, home: home), "above the home folder")
        #expect(!WikiVault.mayBeVaultRoot(home, home: home), "the home folder itself")
        #expect(WikiVault.mayBeVaultRoot(ohm, home: home), "another spelling is another folder")
        #expect(!WikiVault.mayBeVaultRoot(base.appendingPathComponent("x"), home: base.appendingPathComponent("x/\u{301}h")))
        #expect(WikiVault.mayBeVaultRoot(base.appendingPathComponent("x/\u{301}h/n"), home: base.appendingPathComponent("x/\u{301}h")))
    }
}
