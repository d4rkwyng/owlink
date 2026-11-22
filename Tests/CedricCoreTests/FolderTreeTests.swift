import Foundation
import Testing
@testable import CedricCore

private func e(_ name: String, dir: Bool = false, hidden: Bool = false) -> FolderEntry {
    FolderEntry(name: name, isDirectory: dir, isHidden: hidden)
}

private func makeTree(_ files: [String], dirs: [String] = []) throws -> URL {
    let root = tempDir()
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for d in dirs { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
    for f in files {
        let u = root.appendingPathComponent(f)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(f.utf8).write(to: u)
    }
    return root
}

@Suite struct FolderTreeTests {
    @Test func explorerCreateAndRenameNeverOverwrite() throws {
        let root = try makeTree(["existing.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try FolderActions.create(in: root, name: "new.txt", directory: false)
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(throws: (any Error).self) { try FolderActions.create(in: root, name: "existing.txt", directory: false) }
        #expect(throws: (any Error).self) { try FolderActions.create(in: root, name: "existing.txt", directory: true) }
        #expect(throws: (any Error).self) { try FolderActions.rename(created, name: "existing.txt") }
        #expect(try String(contentsOf: root.appendingPathComponent("existing.txt"), encoding: .utf8) == "existing.txt")
        #expect(FileManager.default.fileExists(atPath: created.path))
        let folder = try FolderActions.create(in: root, name: "folder", directory: true)
        #expect(try FolderActions.rename(folder, name: "renamed").lastPathComponent == "renamed")
        for invalid in ["", ".", "..", "a/b", "a\0b"] {
            #expect(throws: (any Error).self) { try FolderActions.create(in: root, name: invalid, directory: false) }
        }
    }

    @Test func explorerMovesOnlyTheRenamedPathAndDescendants() {
        let old = URL(fileURLWithPath: "/p/dir")
        let new = URL(fileURLWithPath: "/p/new")
        #expect(FolderActions.movedURL(old, from: old, to: new, directory: false) == new)
        #expect(FolderActions.movedURL(URL(fileURLWithPath: "/p/dir/a.txt"), from: old, to: new, directory: true)?.path == "/p/new/a.txt")
        #expect(FolderActions.movedURL(URL(fileURLWithPath: "/p/dir/a.txt"), from: old, to: new, directory: false) == nil)
        #expect(FolderActions.movedURL(URL(fileURLWithPath: "/p/dir2/a.txt"), from: old, to: new, directory: true) == nil)
    }

    @Test func textNamedPDFKeepsItsSessionKind() throws {
        let tab = SessionTab(path: "/p/empty.pdf", explicitText: true)
        let saved = try JSONEncoder().encode(tab)
        #expect(try JSONDecoder().decode(SessionTab.self, from: saved).explicitText == true)
        let old = try JSONEncoder().encode(SessionTab(path: "/p/old.pdf"))
        #expect(try JSONDecoder().decode(SessionTab.self, from: old).explicitText == nil)
    }

    @Test func foldersFirstThenFinderOrder() {
        let sorted = FolderTree.sorted([e("b.txt"), e("file10.txt"), e("Zed", dir: true), e("file2.txt"), e("alpha", dir: true), e("A.txt")])
        #expect(sorted.map(\.name) == ["alpha", "Zed", "A.txt", "b.txt", "file2.txt", "file10.txt"])
    }

    @Test func hiddenFilter() {
        let all = [e(".git", dir: true, hidden: true), e(".DS_Store", hidden: true), e(".env", hidden: true), e("src", dir: true), e("a.txt")]
        #expect(FolderTree.filter(all, showHidden: false).map(\.name) == ["src", "a.txt"])
        // .git and .DS_Store never show, hidden files on or off.
        #expect(FolderTree.filter(all, showHidden: true).map(\.name) == [".env", "src", "a.txt"])
    }

    @Test func listsOneLevelFilteredAndSorted() throws {
        let root = try makeTree([".git/HEAD", ".DS_Store", ".hidden", "src/deep/x.swift", "b.md", "a10.txt", "a9.txt"], dirs: ["Thing.app/Contents"])
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try FolderTree.list(root)
        #expect(list.map(\.name) == ["src", "a9.txt", "a10.txt", "b.md", "Thing.app"])
        // A package is a file; nothing below the first level is listed.
        #expect(list.first { $0.name == "Thing.app" }?.isDirectory == false)
        #expect(list.first { $0.name == "src" }?.isDirectory == true)
        let withHidden = try FolderTree.list(root, showHidden: true)
        #expect(withHidden.map(\.name) == ["src", ".hidden", "a9.txt", "a10.txt", "b.md", "Thing.app"])
        #expect(withHidden.first { $0.name == ".hidden" }?.isHidden == true)
    }

    @Test func listingAMissingFolderThrows() {
        #expect(throws: (any Error).self) { try FolderTree.list(tempDir()) }
    }

    @Test func diffAddRemoveRename() {
        let old = [e("docs", dir: true), e("a.txt"), e("b.txt"), e("c.txt")]
        // b.txt removed, d.txt added, c.txt renamed to aa.txt.
        let new = FolderTree.sorted([e("docs", dir: true), e("a.txt"), e("aa.txt"), e("d.txt")])
        let d = FolderTree.diff(old: old, new: new)
        #expect(d.removed == [2, 3])
        #expect(d.inserted == [2, 3])
        #expect(FolderTree.diff(old: old, new: old).isEmpty)
        // A file replaced by a folder of the same name: a removal and an insertion.
        let swapped = FolderTree.diff(old: [e("x")], new: [e("x", dir: true)])
        #expect(swapped.removed == [0] && swapped.inserted == [0])
    }

    @Test func diffAppliedInOrderGivesTheNewList() {
        let old = FolderTree.sorted((0..<30).map { e("f\($0).txt") } + [e("d1", dir: true)])
        let new = FolderTree.sorted(old.filter { $0.name.hasSuffix("3.txt") == false } + [e("f100.txt"), e("d0", dir: true)])
        let d = FolderTree.diff(old: old, new: new)
        var rows = old
        for i in d.removed.reversed() { rows.remove(at: i) }
        for i in d.inserted { rows.insert(new[i], at: i) }
        #expect(rows == new)
    }

    @Test func nodesLoadLazilyAndKeepTheirChildrenAcrossRelistings() {
        let root = FolderNode(root: URL(fileURLWithPath: "/p"))
        #expect(!root.isLoaded && root.children == nil)
        root.apply([e("src", dir: true), e("a.txt")])
        #expect(root.isLoaded)
        let src = root.child(named: "src")!
        #expect(!src.isLoaded && src.parent === root)
        #expect(src.url.path == "/p/src")
        src.apply([e("x.swift")])
        // Re-listing the root: src is the same node, still loaded.
        let d = root.apply([e("src", dir: true), e("b.txt")])
        #expect(d == FolderTree.Diff(removed: [1], inserted: [1]))
        #expect(root.child(named: "src") === src && src.isLoaded)
        #expect(root.descendant("src/x.swift")?.url.path == "/p/src/x.swift")
        #expect(root.descendant("nope/x") == nil)
        #expect(root.loadedFolders.map(\.name) == ["p", "src"])
        #expect(src.child(named: "x.swift")?.ancestors.map(\.name) == ["src", "p"])
        src.unload()
        #expect(root.loadedFolders.map(\.name) == ["p"])
    }

    @Test func symlinkLoopGuard() throws {
        let root = try makeTree(["src/a.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("src/up").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("src/self").path, withDestinationPath: ".")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-to-src").path, withDestinationPath: "src")
        let src = root.appendingPathComponent("src")
        let list = try FolderTree.list(src)
        #expect(list.filter(\.isSymlink).map(\.name) == ["self", "up"])
        #expect(list.filter(\.isSymlink).allSatisfy { $0.isDirectory })
        #expect(FolderTree.wouldLoop(src.appendingPathComponent("up"), ancestors: [src, root]))
        #expect(FolderTree.wouldLoop(src.appendingPathComponent("self"), ancestors: [src, root]))
        // A link to a sibling folder is fine to expand.
        #expect(!FolderTree.wouldLoop(root.appendingPathComponent("link-to-src"), ancestors: [root]))
    }

    @Test func reListingReportsChangedFlags() {
        let root = FolderNode(root: URL(fileURLWithPath: "/p"))
        root.apply([e("build", dir: true), e("a.txt")])
        var ignored = e("build", dir: true)
        ignored.isIgnored = true
        let d = root.apply([ignored, e("a.txt")])
        #expect(d.removed.isEmpty && d.inserted.isEmpty && d.changed == [0])
        #expect(root.child(named: "build")?.entry.isIgnored == true)
        #expect(FolderTree.diff(old: [e("a")], new: [e("a")]).changed.isEmpty)
    }

    @Test func listingMarksGitIgnoredEntries() throws {
        let root = try makeTree([".gitignore", "a.swift", "a.log", "build/out.o", "src/.gitignore", "src/keep.swift", "src/gen.swift",
                                 "docs/x.log", "docs/important.log"], dirs: [".git/info"])
        defer { try? FileManager.default.removeItem(at: root) }
        try "*.log\nbuild/\n!docs/important.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "gen.swift\n".write(to: root.appendingPathComponent("src/.gitignore"), atomically: true, encoding: .utf8)
        try "keep.swift\n".write(to: root.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let ignore = FolderIgnore(root: root)
        func ignoredNames(_ rel: String) throws -> [String] {
            try FolderTree.list(rel.isEmpty ? root : root.appendingPathComponent(rel), showHidden: true, ignore: ignore).filter(\.isIgnored).map(\.name)
        }
        #expect(try ignoredNames("") == ["build", "a.log"])
        // Nested .gitignore and info/exclude.
        #expect(try ignoredNames("src") == ["gen.swift", "keep.swift"])
        #expect(try ignoredNames("docs") == ["x.log"])
        // Inside an ignored folder: everything.
        #expect(try ignoredNames("build") == ["out.o"])
        // Without a matcher nothing is marked.
        #expect(try FolderTree.list(root).allSatisfy { !$0.isIgnored })
        // A .gitignore changed on disk is read again after invalidate().
        try "*.swift\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(try ignoredNames("") == ["build", "a.log"])
        ignore.invalidate()
        #expect(try ignoredNames("") == ["a.swift"])
    }

    @Test func ignoreMatchesFromAFolderBelowTheRepository() throws {
        let repo = try makeTree([".gitignore", "sub/a.tmp", "sub/b.txt", "sub/deep/c.tmp"], dirs: [".git"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try "sub/b.txt\n*.tmp\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let sub = repo.appendingPathComponent("sub")
        let ignore = FolderIgnore(root: sub)
        #expect(try FolderTree.list(sub, ignore: ignore).filter(\.isIgnored).map(\.name) == ["a.tmp", "b.txt"])
        #expect(try FolderTree.list(sub.appendingPathComponent("deep"), ignore: ignore).filter(\.isIgnored).map(\.name) == ["c.tmp"])
        // A folder outside the sidebar's root is left alone.
        var entries = [e("x.tmp")]
        ignore.mark(&entries, in: repo)
        #expect(!entries[0].isIgnored)
    }

    @Test func relativePaths() {
        let root = URL(fileURLWithPath: "/a/b")
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/a/b"), in: root) == "")
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/a/b/c/d.txt"), in: root) == "c/d.txt")
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/a/bc/d.txt"), in: root) == nil)
        #expect(FolderTree.relativePath(of: URL(fileURLWithPath: "/x"), in: root) == nil)
    }

    @Test func enclosingFolderOfAFile() {
        #expect(FolderTree.enclosingFolder(of: URL(fileURLWithPath: "/a/b/c.md"))?.path == "/a/b")
        #expect(FolderTree.enclosingFolder(of: URL(fileURLWithPath: "/a/b/c.md"))?.hasDirectoryPath == true)
        // Standardized first: the real parent, not "..".
        #expect(FolderTree.enclosingFolder(of: URL(fileURLWithPath: "/a/x/../b/c.md"))?.path == "/a/b")
        #expect(FolderTree.enclosingFolder(of: URL(fileURLWithPath: "/c.md"))?.path == "/")
    }

    @Test func noEnclosingFolderForUntitledOrRoot() {
        #expect(FolderTree.enclosingFolder(of: nil) == nil)
        #expect(FolderTree.enclosingFolder(of: URL(string: "https://example.com/a/b.md")) == nil)
        #expect(FolderTree.enclosingFolder(of: URL(fileURLWithPath: "/")) == nil)
    }

    @Test func enclosingFolderContainsTheFile() {
        let file = URL(fileURLWithPath: "/Users/me/notes/todo.md")
        let dir = FolderTree.enclosingFolder(of: file)!
        #expect(FolderTree.relativePath(of: file, in: dir) == "todo.md")
    }

    @Test(.offPool) func twentyThousandEntriesListQuickly() throws {
        let root = tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<20_000 { fm.createFile(atPath: root.appendingPathComponent("f\(i).txt").path, contents: nil) }
        let start = Date()
        let list = try FolderTree.list(root)
        let elapsed = Date().timeIntervalSince(start)
        #expect(list.count == 20_000)
        #expect(list[1].name == "f1.txt" && list[2].name == "f2.txt")
        // Listed off the main thread in the app; generous for a CI runner.
        #expect(elapsed < 5, "20,000 entries took \(elapsed) s")
    }
}

@Suite struct FolderSessionTests {
    @Test func sessionWithoutAFolderStillDecodes() throws {
        // A 0.1.x session.json: no "folder" key.
        let json = #"{"version": 1, "untitledCounter": 0, "windows": [{"selectedTab": 0, "tabs": [{"id": "7E1C9B3A-1F2D-4C5B-9A8E-0123456789AB", "path": "/tmp/a.txt", "hasBuffer": false, "encoding": "utf8", "lineEnding": "lf", "selectionLocation": 0, "selectionLength": 0, "topLine": 0}]}]}"#
        let s = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(s.folder == nil)
        #expect(s.allTabs.first?.path == "/tmp/a.txt")
    }

    @Test func folderRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let folder = SessionFolder(path: "/Users/x/proj", visible: true, width: 260, expanded: ["src", "src/util"], showHidden: true)
        try store.save(Session(windows: [SessionWindow(tabs: [SessionTab(path: "/tmp/a.txt")])], folder: folder))
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back.folder == folder)
        // A hidden sidebar is kept too (shown again from the menu).
        try store.save(Session(windows: [], folder: SessionFolder(path: "/p", visible: false)))
        #expect(SessionStore(directory: dir).load()?.folder?.visible == false)
    }

    @Test func expandedFoldersAreCapped() {
        let f = SessionFolder(path: "/p", expanded: (0..<500).map { "d\($0)" })
        #expect(f.expanded?.count == SessionFolder.expandedLimit)
        #expect(f.expanded?.first == "d0")
    }
}
