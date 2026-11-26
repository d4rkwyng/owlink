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

    // MARK: Dot names

    /// A listed name starting with a dot byte is hidden when Finder's flag
    /// is unknown, a dot followed by a combining mark too; the flag wins
    /// when it is known.
    @Test func aDotThenAMarkIsAHiddenName() {
        #expect(FolderTree.isHidden(".\u{301}x", resourceValue: nil))
        #expect(FolderTree.isHidden(".env", resourceValue: nil))
        #expect(!FolderTree.isHidden("\u{301}x", resourceValue: nil))
        #expect(!FolderTree.isHidden(".\u{301}x", resourceValue: false) && FolderTree.isHidden("x", resourceValue: true))
    }

    /// Replace in Files' leftover temp files (`.<name>.owlink-XXXXXX`):
    /// one for a name starting with a combining mark, or a dot name, is
    /// swept; one for another spelling of a canonically equivalent name
    /// is another file's and is left.
    @Test func leftoverTempFilesAreMatchedByBytes() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        func put(_ name: String) throws -> URL {
            let u = t.appendingPathComponent(name)
            try Data("x".utf8).write(to: u)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: u.path)
            return u
        }
        let mark = try put("\u{301}x.txt"), dot = try put(".\u{301}y.txt"), omega = try put("\u{3A9}.txt")
        let markTemp = try put(".\u{301}x.txt.owlink-Ab12Cd"), dotTemp = try put("..\u{301}y.txt.owlink-Zz9Y8x")
        let ohmTemp = try put(".\u{2126}.txt.owlink-Qq1Ww2"), notOurs = try put(".\u{301}x.txt.owlink-Ab12C")
        FileReplace.sweepTempFiles(for: [mark, dot, omega])
        let left = Set(try fm.contentsOfDirectory(atPath: t.path).map { Array($0.utf8) })
        func has(_ u: URL) -> Bool { left.contains(Array(u.lastPathComponent.utf8)) }
        #expect(!has(markTemp), "a mark-leading name's temp file is swept")
        #expect(!has(dotTemp), "a dot name's temp file is swept")
        #expect(has(ohmTemp), "another spelling's temp file is left")
        #expect(has(notOurs), "not six letters or digits after the marker")
        #expect(has(mark) && has(dot) && has(omega), "the files themselves are left")
    }

    // MARK: Identity

    /// Loop detection, the loaded child by name, a file's word goal and an
    /// exported page's relative link tell the Ohm sign and Omega apart.
    @Test func pathsAndNamesAreTheSameOnlyByTheirBytes() {
        #expect(!FolderTree.wouldLoop(omega, ancestors: [ohm]))
        #expect(FolderTree.wouldLoop(ohm, ancestors: [base, ohm]))
        let root = FolderNode(root: base)
        root.apply([FolderEntry(name: "\u{2126}", isDirectory: true)])
        #expect(root.child(named: "\u{3A9}") == nil, "another spelling isn't the loaded child")
        #expect(root.child(named: "\u{2126}") != nil)
        let goals = [FileWordGoal(path: ohm.path, words: 300)]
        #expect(FileWordGoals.goal(for: omega.path, in: goals) == nil)
        #expect(FileWordGoals.goal(for: ohm.path, in: goals) == 300)
        let set = FileWordGoals.setting(400, for: omega.path, in: goals)
        #expect(set.count == 2, "setting the other spelling's goal leaves this one's")
        #expect(WikiVault.relativeHref(omega.appendingPathComponent("a.png"), from: ohm) == "../%CE%A9/a.png")
        #expect(WikiVault.relativeHref(ohm.appendingPathComponent("a.png"), from: ohm) == "a.png")
    }

    /// Renaming a file between canonically equivalent spellings renames
    /// it (the volume here folds them into one file, and the name's bytes
    /// change); before, Swift text called the names equal and the rename
    /// did nothing.
    @Test func aRenameBetweenEquivalentSpellingsRenames() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let src = t.appendingPathComponent("\u{2126}.txt")
        try Data("x".utf8).write(to: src)
        let moved = try FolderActions.rename(src, name: "\u{3A9}.txt")
        #expect(Array(moved.lastPathComponent.utf8) == Array("\u{3A9}.txt".utf8))
        let names = try fm.contentsOfDirectory(atPath: t.path).map { Array($0.utf8) }
        #expect(names.contains(Array("\u{3A9}.txt".utf8)), "listed by the new bytes: \(names)")
        #expect(try Data(contentsOf: moved) == Data("x".utf8))
        #expect(try FolderActions.rename(moved, name: "\u{3A9}.txt") == moved, "the same bytes: nothing to do")
    }

    // MARK: Path-keyed collections

    /// The sidebar keys a folder's entries by their names' bytes: two
    /// canonically equivalent names are two nodes with their own URLs, and
    /// a name re-listed in the other spelling is a remove and an insert.
    @Test func sidebarEntriesAreKeyedByBytes() {
        let a = FolderEntry(name: "\u{2126}.md", isDirectory: false), b = FolderEntry(name: "\u{3A9}.md", isDirectory: false)
        let root = FolderNode(root: base)
        root.apply([a, b])
        root.apply([a, b])
        let kids = root.children ?? []
        #expect(kids.count == 2 && kids[0] !== kids[1], "two nodes")
        #expect(kids.map { Array($0.url.lastPathComponent.utf8) } == [Array(a.name.utf8), Array(b.name.utf8)], "each its own URL")
        let d = FolderTree.diff(old: [a], new: [b])
        #expect(d.removed == [0] && d.inserted == [0], "the other spelling replaces the entry")
    }

    /// Open Quickly's index keeps a listing per folder by the relative
    /// path's bytes, and finds a file's name after the last "/" byte.
    @Test func openQuicklyIsKeyedByBytes() {
        var idx = FileIndex(root: base, showHidden: false, limit: 100)
        idx.dirs["\u{2126}"] = FileIndex.Dir(files: ["a.txt"], subdirs: [])
        idx.dirs["\u{3A9}"] = FileIndex.Dir(files: ["b.txt"], subdirs: [])
        let paths = Set(idx.paths.map { Array($0.utf8) })
        #expect(paths == [Array("\u{2126}/a.txt".utf8), Array("\u{3A9}/b.txt".utf8)], "each folder's own files")
        let p = "\u{301}d/x/\u{301}n.txt"
        let m = FileMatchIndex(paths: [p])
        #expect(m.nameStart == [p.count - "\u{301}n.txt".count], "the name starts after the last slash byte")
    }
}
