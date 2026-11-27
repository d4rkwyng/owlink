import Foundation
import Testing
@testable import CedricCore

/// .gitignore semantics, table-driven after git's t0008-ignores and
/// gitignore(5). Every expectation in `rootCases` and `treeCases` was
/// checked against `git check-ignore` (git 2.x) on the same tree.
@Suite struct GitIgnoreTests {
    /// (pattern line(s) in the root .gitignore, path, is a folder, ignored).
    static let rootCases: [(String, String, Bool, Bool)] = [
        // Plain names match at any depth.
        ("foo", "foo", false, true),
        ("foo", "a/foo", false, true),
        ("foo", "a/b/foo", true, true),
        ("foo", "foobar", false, false),
        ("foo", "a/foo/bar", false, true),          // inside an ignored folder
        // Globs.
        ("*.log", "x.log", false, true),
        ("*.log", "logs/x.log", false, true),
        ("*.log", "x.log.txt", false, false),
        ("*.log", ".log", false, true),
        ("?.c", "a.c", false, true),
        ("?.c", "ab.c", false, false),
        ("[ab].c", "a.c", false, true),
        ("[ab].c", "c.c", false, false),
        ("[!ab].c", "c.c", false, true),
        ("[!ab].c", "a.c", false, false),
        ("[a-c]x", "bx", false, true),
        ("[a-c]x", "dx", false, false),
        // Dir-only.
        ("build/", "build", true, true),
        ("build/", "build", false, false),
        ("build/", "src/build", true, true),
        ("build/", "build/out.o", false, true),
        // Anchoring: leading or middle slash.
        ("/top", "top", false, true),
        ("/top", "a/top", false, false),
        ("doc/frotz", "doc/frotz", false, true),
        ("doc/frotz", "a/doc/frotz", false, false),
        ("doc/*.txt", "doc/a.txt", false, true),
        ("doc/*.txt", "doc/sub/a.txt", false, false),
        ("/*.c", "x.c", false, true),
        ("/*.c", "sub/x.c", false, false),
        // **.
        ("**/foo", "foo", false, true),
        ("**/foo", "a/b/foo", false, true),
        ("**/foo/bar", "x/foo/bar", false, true),
        ("abc/**", "abc/x", false, true),
        ("abc/**", "abc/x/y", false, true),
        ("abc/**", "abc", true, false),
        ("a/**/b", "a/b", false, true),
        ("a/**/b", "a/x/b", false, true),
        ("a/**/b", "a/x/y/b", false, true),
        ("a/**/b", "a/xb", false, false),
        ("a**b", "axxb", false, true),             // not between slashes: a plain star
        ("a**b", "ax/xb", false, false),
        // Negation.
        ("*.log\n!keep.log", "keep.log", false, false),
        ("*.log\n!keep.log", "drop.log", false, true),
        ("!keep.log\n*.log", "keep.log", false, true), // the last match wins
        ("logs/\n!logs/keep.log", "logs/keep.log", false, true), // parent excluded: can't re-include
        ("logs/*\n!logs/keep.log", "logs/keep.log", false, false),
        ("logs/*\n!logs/keep.log", "logs/drop.log", false, true),
        // Comments, escapes, spaces.
        ("# comment", "# comment", false, false),
        ("\\#hash", "#hash", false, true),
        ("\\!bang", "!bang", false, true),
        ("trail   ", "trail", false, true),
        ("space\\ ", "space ", false, true),
        ("space\\ ", "space", false, false),
        ("\n\n", "anything", false, false),
        ("a\\*b", "a*b", false, true),
        ("a\\*b", "axb", false, false),
        // CRLF .gitignore.
        ("one\r\ntwo\r\n", "two", false, true),
    ]

    func makeRepo() throws -> URL {
        let root = tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        return root
    }

    func write(_ root: URL, _ rel: String, _ s: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    @Test func rootPatternsMatchGit() throws {
        var failures: [String] = []
        for (pattern, path, isDir, ignored) in Self.rootCases {
            let root = try makeRepo()
            defer { try? FileManager.default.removeItem(at: root) }
            try write(root, ".gitignore", pattern)
            let g = GitIgnore(folder: root)
            if g.isIgnored(relative: path, isDirectory: isDir) != ignored { failures.append("\(pattern.debugDescription) \(path) dir=\(isDir) want \(ignored)") }
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(Self.rootCases.count >= 55)
    }

    @Test func nestedFilesOverrideAndInfoExclude() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, ".gitignore", "*.tmp\nsecret\n")
        try write(root, "sub/.gitignore", "!keep.tmp\n/local\n")
        try write(root, "sub/deeper/.gitignore", "*.md\n")
        try write(root, ".git/info/exclude", "excluded.txt\n*.md\n")
        let g = GitIgnore(folder: root)
        let cases: [(String, Bool, Bool)] = [
            ("a.tmp", false, true),
            ("sub/a.tmp", false, true),
            ("sub/keep.tmp", false, false),      // the deeper file re-includes
            ("keep.tmp", false, true),           // …only below its own folder
            ("sub/local", false, true),          // anchored to sub/
            ("local", false, false),
            ("sub/x/local", false, false),
            ("sub/deeper/r.md", false, true),
            ("r.md", false, true),               // info/exclude
            ("excluded.txt", false, true),
            ("sub/excluded.txt", false, true),
            ("secret", true, true),
            ("secret/inner.txt", false, true),
        ]
        for (path, isDir, want) in cases {
            #expect(g.isIgnored(relative: path, isDirectory: isDir) == want, "\(path)")
        }
    }

    @Test func searchFolderBelowTheRepoRoot() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, ".gitignore", "/src/gen/\n")
        let g = GitIgnore(folder: root.appendingPathComponent("src"))
        #expect(g.root.path == root.resolvingSymlinksInPath().path)
        let gen = root.appendingPathComponent("src/gen").resolvingSymlinksInPath()
        #expect(g.isIgnored(gen, isDirectory: true))
        #expect(!g.isIgnored(root.appendingPathComponent("src/main.c").resolvingSymlinksInPath(), isDirectory: false))
        #expect(!g.isIgnored(URL(fileURLWithPath: "/elsewhere/gen"), isDirectory: true))
    }

    @Test func worktreeGitFileFindsCommonExclude() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(base, "main/.git/info/exclude", "wt-ignored\n")
        try write(base, "main/.git/worktrees/wt/commondir", "../..\n")
        try write(base, "wt/.git", "gitdir: \(base.appendingPathComponent("main/.git/worktrees/wt").path)\n")
        let g = GitIgnore(folder: base.appendingPathComponent("wt"))
        #expect(g.isIgnored(relative: "wt-ignored", isDirectory: false))
        #expect(!g.isIgnored(relative: "other", isDirectory: false))
    }

    /// 0.2.0 VM test, macOS 15: a folder with no .git in it or above it
    /// looped forever (URL parent of "/" is "/.." there). The walk must end
    /// at "/" and fall back to the folder itself; its .gitignore still applies.
    @Test(.timeLimit(.minutes(1))) func folderOutsideAnyRepoEndsTheWalk() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, ".gitignore", "*.log\n")
        let g = GitIgnore(folder: root)
        #expect(g.root.standardizedFileURL.resolvingSymlinksInPath().path
                == root.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(g.isIgnored(relative: "a.log", isDirectory: false))
        #expect(!g.isIgnored(relative: "a.txt", isDirectory: false))
        // From "/" itself (no repo above it either).
        #expect(GitIgnore(folder: URL(fileURLWithPath: "/")).root.path == "/")
    }

    /// Astra batch 9b: a folder whose name starts with a combining mark.
    /// The URL entry point keeps a first-level one inside the repository
    /// (a text prefix test fused "root/" and the mark), the path splits at
    /// the "/" bytes so an intermediate parent's .gitignore is read (a text
    /// split fused "p/" and the mark and skipped "p"), and a leading "/"
    /// before a mark anchors the pattern. Both entry points; a sibling named
    /// root + mark and the root itself are never ignored.
    @Test func combiningMarkFoldersReadTheirParentsRules() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try write(root, "p/.gitignore", "*.log\n/\u{301}r/\n")
        try write(root, "\u{301}m/.gitignore", "*.log\n")
        try write(base, "repo\u{301}/x.log", "")
        let g = GitIgnore(folder: root)
        let real = g.root
        let cases: [(String, Bool, Bool)] = [
            ("p/\u{301}q/b.log", false, true),    // only p/.gitignore has the rule
            ("p/\u{301}q/c.txt", false, false),
            ("p/\u{301}r", true, true),           // "/\u{301}r/" anchored in p
            ("p/\u{301}r/c.txt", false, true),    // inside the ignored folder
            ("p/x/\u{301}r", true, false),        // anchored: not one level down
            ("\u{301}m/a.log", false, true),      // a first-level folder's own rules
            ("\u{301}m/a.txt", false, false),
        ]
        for (rel, isDir, want) in cases {
            #expect(g.isIgnored(relative: rel, isDirectory: isDir) == want, "relative \(rel)")
            #expect(g.isIgnored(real.appendingPathComponent(rel), isDirectory: isDir) == want, "URL \(rel)")
        }
        #expect(!g.isIgnored(real, isDirectory: true), "the root itself")
        let sibling = URL(fileURLWithPath: real.path + "\u{301}").appendingPathComponent("x.log")
        #expect(!g.isIgnored(sibling, isDirectory: false), "a sibling named root + mark is outside")
        #expect(GitIgnoreRules("/\u{301}r/\n").patterns == [.init(glob: "\u{301}r", negated: false, dirOnly: true, anchored: true)])
        #expect(GitIgnoreRules("a/\u{301}r\n").patterns.first?.anchored == true)
    }

    @Test func parsesPatternFlags() {
        let r = GitIgnoreRules("# c\n!/a/b/\n\\#x\nplain\n")
        #expect(r.patterns.count == 3)
        #expect(r.patterns[0] == .init(glob: "a/b", negated: true, dirOnly: true, anchored: true))
        #expect(r.patterns[1] == .init(glob: "#x", negated: false, dirOnly: false, anchored: false))
        #expect(r.patterns[2].anchored == false)
    }

    @Test func walkerSkipsIgnoredFiles() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, ".gitignore", "gen/\n*.out\n")
        try write(root, "a.txt", "needle\n")
        try write(root, "b.out", "needle\n")
        try write(root, "gen/c.txt", "needle\n")
        try write(root, "src/.gitignore", "!*.out\n")
        try write(root, "src/d.out", "needle\n")
        var o = FileSearchOptions(root: root, query: "needle", respectGitIgnore: true)
        var seen: [String] = []
        _ = try FileSearch(o).run { seen.append($0.relativePath) }
        #expect(seen == ["a.txt", "src/d.out"])
        o.respectGitIgnore = false
        seen = []
        _ = try FileSearch(o).run { seen.append($0.relativePath) }
        #expect(seen == ["a.txt", "b.out", "gen/c.txt", "src/d.out"])
    }

    @Test func searchResultsCarryFileOffsetsAndStamp() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "f.txt", "one\r\ntwo needle needle\r\n")
        var rs: [FileSearchResult] = []
        _ = try FileSearch(FileSearchOptions(root: root, query: "needle")).run { rs.append($0) }
        #expect(rs.count == 1)
        // LF-normalised offsets: "one\ntwo " is 8 units.
        #expect(rs.first?.matchRanges == [NSRange(location: 8, length: 6), NSRange(location: 15, length: 6)])
        #expect(rs.first?.stamp?.size == 24)
        #expect(rs.first?.stamp?.modified != nil)
    }
}
