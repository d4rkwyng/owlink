import Foundation
import Testing
@testable import CedricCore

/// 0.6.1: opening a file from outside the app (File › Open, Open Recent,
/// Finder, the Dock icon, a drop, the cedric script) switches a shown
/// folder sidebar to the file's folder when the file is outside the
/// loaded one (`FolderTree.folderToSwitchTo`).
@Suite struct FolderSwitchPolicyTests {
    /// A temp folder holding `files` (relative paths), symbolic links
    /// resolved (so /var vs /private/var is the tests' own choice).
    private func tree(_ files: [String]) throws -> URL {
        let made = tempDir()
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let root = made.resolvingSymlinksInPath()
        for f in files {
            let u = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.utf8).write(to: u)
        }
        return root
    }

    private func switched(_ file: URL, root: URL?, shown: Bool = true) -> String? {
        FolderTree.folderToSwitchTo(opening: file, loadedRoot: root, sidebarShown: shown)?.path
    }

    @Test func fileOutsideTheRootSwitchesToItsFolder() throws {
        let t = try tree(["a/one.md", "b/Welcome.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let a = t.appendingPathComponent("a", isDirectory: true)
        #expect(switched(t.appendingPathComponent("b/Welcome.md"), root: a) == t.appendingPathComponent("b").path)
        // The folder above the root holds the file: outside the root too.
        try Data("x".utf8).write(to: t.appendingPathComponent("top.md"))
        #expect(switched(t.appendingPathComponent("top.md"), root: a) == t.path)
    }

    @Test func fileInsideTheRootDoesNotSwitch() throws {
        let t = try tree(["a/one.md", "a/sub/deep/two.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let a = t.appendingPathComponent("a", isDirectory: true)
        #expect(switched(t.appendingPathComponent("a/one.md"), root: a) == nil)
        #expect(switched(t.appendingPathComponent("a/sub/deep/two.md"), root: a) == nil)
        // `..` in the path, and a root given with a trailing slash.
        #expect(switched(URL(fileURLWithPath: a.path + "/sub/../one.md"), root: URL(fileURLWithPath: a.path + "/")) == nil)
    }

    @Test func symlinkedPathIntoTheRootDoesNotSwitch() throws {
        let t = try tree(["a/sub/one.md", "elsewhere/keep.txt"])
        defer { try? FileManager.default.removeItem(at: t) }
        let a = t.appendingPathComponent("a", isDirectory: true)
        let fm = FileManager.default
        // A folder link outside the root pointing into it.
        try fm.createSymbolicLink(atPath: t.appendingPathComponent("elsewhere/link").path, withDestinationPath: a.appendingPathComponent("sub").path)
        #expect(switched(t.appendingPathComponent("elsewhere/link/one.md"), root: a) == nil)
        // A file link outside the root to a file inside it.
        try fm.createSymbolicLink(atPath: t.appendingPathComponent("elsewhere/one-link.md").path, withDestinationPath: a.appendingPathComponent("sub/one.md").path)
        #expect(switched(t.appendingPathComponent("elsewhere/one-link.md"), root: a) == nil)
        // The root itself reached through a link (the root as loaded is the link).
        try fm.createSymbolicLink(atPath: t.appendingPathComponent("a-link").path, withDestinationPath: a.path)
        #expect(switched(t.appendingPathComponent("a/sub/one.md"), root: t.appendingPathComponent("a-link", isDirectory: true)) == nil)
        #expect(switched(t.appendingPathComponent("a-link/sub/one.md"), root: a) == nil)
    }

    @Test func privateVarAndVarSpellingsAreTheSameFolder() throws {
        let t = try tree(["a/one.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        // The temp folder is /private/var/folders/… resolved; /var/… is the same.
        guard t.path.hasPrefix("/private/var/") else { return }
        let short = URL(fileURLWithPath: String(t.path.dropFirst("/private".count)))
        let a = t.appendingPathComponent("a", isDirectory: true)
        let aShort = short.appendingPathComponent("a", isDirectory: true)
        #expect(switched(short.appendingPathComponent("a/one.md"), root: a) == nil)
        #expect(switched(t.appendingPathComponent("a/one.md"), root: aShort) == nil)
        // /tmp is /private/tmp.
        let name = "cedric-switch-\(UUID().uuidString)"
        let tmpDir = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try Data("x".utf8).write(to: tmpDir.appendingPathComponent("n.md"))
        #expect(switched(URL(fileURLWithPath: "/tmp/\(name)/n.md"), root: tmpDir) == nil)
        #expect(switched(tmpDir.appendingPathComponent("n.md"), root: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)) == nil)
    }

    @Test func noSidebarOrHiddenSidebarDoesNotSwitch() throws {
        let t = try tree(["a/one.md", "b/two.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let file = t.appendingPathComponent("b/two.md")
        #expect(switched(file, root: nil) == nil)
        #expect(switched(file, root: nil, shown: false) == nil)
        #expect(switched(file, root: t.appendingPathComponent("a", isDirectory: true), shown: false) == nil)
    }

    @Test func fileAtTheVolumeRootDoesNotSwitch() {
        // No file can be made at / here: the regular-file test is the seam.
        let got = FolderTree.folderToSwitchTo(opening: URL(fileURLWithPath: "/notes.txt"),
                                              loadedRoot: URL(fileURLWithPath: "/Users", isDirectory: true),
                                              sidebarShown: true, isRegularFile: { _ in true })
        #expect(got == nil)
        // The seam on: a file one folder down does switch (so the nil above is the volume root).
        let below = FolderTree.folderToSwitchTo(opening: URL(fileURLWithPath: "/cedric-no-such-dir/notes.txt"),
                                                loadedRoot: URL(fileURLWithPath: "/Users", isDirectory: true),
                                                sidebarShown: true, isRegularFile: { _ in true })
        #expect(below?.path == "/cedric-no-such-dir")
    }

    @Test func siblingWithTheSameNamePrefixSwitches() throws {
        let t = try tree(["foo/in.md", "foobar/out.md", "foo bar/space.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let foo = t.appendingPathComponent("foo", isDirectory: true)
        #expect(switched(t.appendingPathComponent("foobar/out.md"), root: foo) == t.appendingPathComponent("foobar").path)
        #expect(switched(t.appendingPathComponent("foo bar/space.md"), root: foo) == t.appendingPathComponent("foo bar").path)
    }

    @Test func folderOrMissingFileDoesNotSwitch() throws {
        let t = try tree(["a/one.md", "b/sub/two.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let a = t.appendingPathComponent("a", isDirectory: true)
        #expect(switched(t.appendingPathComponent("b/sub", isDirectory: true), root: a) == nil)
        #expect(switched(t.appendingPathComponent("b/missing.md"), root: a) == nil)
        // A link to a folder outside is a folder, not a file.
        try FileManager.default.createSymbolicLink(atPath: t.appendingPathComponent("b/dirlink").path,
                                                   withDestinationPath: t.appendingPathComponent("b/sub").path)
        #expect(switched(t.appendingPathComponent("b/dirlink"), root: a) == nil)
    }
}
