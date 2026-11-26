import Foundation
import Testing
@testable import CedricCore

private func targets(_ line: String) -> [String] { WikiLinks.links(inLine: line).map(\.target) }

@Suite struct WikiLinkParsingTests {
    @Test func plainAliasHeadingAndEmbed() {
        let l = WikiLinks.links(inLine: "See [[Alpha]], [[Beta|the second]], [[Gamma#Part two]] and ![[pic.png]].")
        #expect(l.map(\.target) == ["Alpha", "Beta", "Gamma", "pic.png"])
        #expect(l[0].range == NSRange(location: 4, length: 9))
        #expect(l[1].alias == "the second" && l[1].heading == nil)
        #expect(l[2].heading == "Part two" && l[2].alias == nil)
        #expect(l[3].embed && l[3].range.location == 59)
        let both = WikiLinks.links(inLine: "[[Note#Sub|shown]]")[0]
        #expect(both.target == "Note" && both.heading == "Sub" && both.alias == "shown")
        #expect(WikiLinks.links(inLine: "[[#Local]]")[0].target == "")
    }

    @Test func escapes() {
        #expect(targets(#"\[[not a link]] but [[yes]]"#) == ["yes"])
        // A table cell's `\|` is the alias bar.
        let t = WikiLinks.links(inLine: #"| [[Note\|alias]] |"#)[0]
        #expect(t.target == "Note" && t.alias == "alias")
        // `\![[x]]`: the bang is escaped, the link stays a link (not an embed).
        #expect(WikiLinks.links(inLine: #"\![[x]]"#).first?.embed == false)
    }

    @Test func nestedAndBrokenBrackets() {
        #expect(targets("[[[x]]]") == ["x"])
        #expect(targets("[[a]b]]") == [])
        #expect(targets("[[a[[b]]") == ["b"])
        #expect(targets("[[ ]] [[]] [[open") == [])
        #expect(targets("[x] [[y]] [z](u)") == ["y"])
        #expect(targets("[[" + String(repeating: "a", count: 1_000) + "]]") == [])
    }

    @Test func codeSpansAreSkipped() {
        #expect(targets("`[[no]]` [[yes]] ``a `[[no]]` b`` [[also]]") == ["yes", "also"])
        // An unclosed backtick is a literal backtick.
        #expect(targets("a ` [[yes]]") == ["yes"])
    }

    @Test func linkAtOffset() {
        let u = Array("x [[Alpha]] y".utf16)
        u.withUnsafeBufferPointer { b in
            #expect(WikiLinks.link(at: 2, inLine: b)?.target == "Alpha")
            #expect(WikiLinks.link(at: 10, inLine: b)?.target == "Alpha")
            #expect(WikiLinks.link(at: 11, inLine: b) == nil)
            #expect(WikiLinks.link(at: 0, inLine: b) == nil)
        }
    }

    @Test func typingContext() {
        #expect(WikiLinks.typing(inLine: "See [[", caret: 6) == .init(start: 6, query: ""))
        #expect(WikiLinks.typing(inLine: "See [[Alp", caret: 9) == .init(start: 6, query: "Alp"))
        #expect(WikiLinks.typing(inLine: "See [[Alp]] x", caret: 13) == nil)
        #expect(WikiLinks.typing(inLine: "[[a]] [[b", caret: 9) == .init(start: 8, query: "b"))
        #expect(WikiLinks.typing(inLine: "[[Note|al", caret: 9) == nil)
        #expect(WikiLinks.typing(inLine: "[[Note#He", caret: 9) == nil)
        #expect(WikiLinks.typing(inLine: #"\[[x"#, caret: 4) == nil)
        // In a code span, closed or still being typed.
        #expect(WikiLinks.typing(inLine: "`[[x", caret: 4) == nil)
        #expect(WikiLinks.typing(inLine: "`a` [[x", caret: 7) == .init(start: 6, query: "x"))
        #expect(WikiLinks.typing(inLine: "[[[x", caret: 4) == .init(start: 3, query: "x"))
        // Caret before the `]]` already there.
        #expect(WikiLinks.typing(inLine: "[[Al]]", caret: 4) == .init(start: 2, query: "Al"))
        #expect(WikiLinks.typing(inLine: "[", caret: 1) == nil)
    }

    @Test func refsSkipFencesAndCode() {
        let text = """
        # Title
        Links to [[Alpha]] and [[Beta|b]].
        ```
        [[InFence]]
        ```
        ~~~~
        [[InTilde]]
        ```
        still fenced [[No]]
        ~~~~
        `[[Code]]` then [[Gamma#Part]] and [[#Self]]
        """
        let r = WikiLinks.refs(in: text)
        #expect(r.map(\.target) == ["Alpha", "Beta", "Gamma"])
        #expect(r.map(\.line) == [1, 1, 10])
        #expect(r[0].snippet == "Links to [[Alpha]] and [[Beta|b]].")
    }

    @Test func markdownColoursWikiLinksAsLinks() {
        let ns = "a [[Note|x]] `[[code]]` b\n" as NSString
        var index = LineIndex()
        _ = index.replace(NSRange(location: 0, length: 0), newLength: ns.length, in: ns)
        let t = HighlightEngine(language: .markdown).tokens(forLines: 0..<index.lineCount, in: ns, index: index)
        #expect(t.contains(Token(2, 10, .link)))
        #expect(t.contains(Token(13, 10, .code)))
    }
}

@Suite struct NoteIndexTests {
    let index = NoteIndex(paths: ["Alpha.md", "notes/alpha.md", "deep/er/Alpha.md", "Beta.markdown", "sub/Gamma.md",
                                  "todo.txt", "image.png", "Code.swift", "x/Dup.md", "y/Dup.md", "a/b/Dup.md"])

    @Test func onlyNotes() {
        #expect(index.count == 9)
        #expect(!index.paths.contains("image.png") && !index.paths.contains("Code.swift"))
    }

    @Test func exactThenCaseInsensitiveThenShortest() {
        #expect(index.resolve("Alpha") == "Alpha.md")
        #expect(index.resolve("alpha") == "notes/alpha.md")
        #expect(index.resolve("ALPHA") == "Alpha.md") // caseless: shortest path
        #expect(index.resolve("Gamma") == "sub/Gamma.md")
        #expect(index.resolve("gamma") == "sub/Gamma.md")
        #expect(index.resolve("todo") == "todo.txt")
        #expect(index.resolve("Beta.markdown") == "Beta.markdown")
        #expect(index.resolve("Missing") == nil)
        #expect(index.resolve("") == nil)
        #expect(index.resolve("../Alpha") == nil)
    }

    @Test func deterministicOnAmbiguity() {
        // Same depth, same length: by path, every time.
        #expect(index.resolve("Dup") == "x/Dup.md")
        #expect(NoteIndex(paths: ["y/Dup.md", "x/Dup.md"]).resolve("Dup") == "x/Dup.md")
        #expect(index.resolve("y/Dup") == "y/Dup.md")
        #expect(index.resolve("b/Dup") == "a/b/Dup.md")
        #expect(index.resolve("er/alpha") == "deep/er/Alpha.md")
    }

    @Test func linkTextIsTheNameUnlessAmbiguous() {
        #expect(index.linkText(for: "sub/Gamma.md") == "Gamma")
        #expect(index.linkText(for: "Alpha.md") == "Alpha")
        #expect(index.linkText(for: "notes/alpha.md") == "alpha")
        #expect(index.linkText(for: "deep/er/Alpha.md") == "deep/er/Alpha")
        #expect(index.linkText(for: "y/Dup.md") == "y/Dup")
    }

    @Test func suggestionsPrefixAndFuzzy() {
        let s = index.suggestions("gam")
        #expect(s.first?.path == "sub/Gamma.md" && s.first?.insert == "Gamma" && s.first?.folder == "sub")
        #expect(index.suggestions("bt").first?.name == "Beta") // fuzzy: B…t
        #expect(index.suggestions("").count == 9)
        #expect(index.suggestions("zzzz").isEmpty)
        #expect(index.suggestions("", limit: 3).count == 3)
    }
}

private func writeTree(_ files: [String: String]) throws -> URL {
    let root = tempDir()
    for (f, text) in files {
        let u = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    return root
}

@Suite struct WikiIndexIncrementalTests {
    @Test func addRenameDeleteUpdateNamesAndBacklinks() throws {
        let root = try writeTree(["Alpha.md": "# A\n", "Beta.md": "Back to [[Alpha]].\n", "sub/Gamma.md": "x\n\n[[alpha|first]]\n"])
        let fm = FileManager.default
        var files = FileIndex.build(root: root, showHidden: false)
        var notes = NoteIndex(paths: files.paths)
        var scan = BacklinkScan(root: root)
        scan.update(notes: notes.paths, dirty: nil)
        #expect(scan.lastRead == 3)
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Beta.md", "sub/Gamma.md"])
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.line) == [0, 2])

        // Add: a new note linking to Alpha, in the root folder only.
        try Data("[[Alpha#A]]\n".utf8).write(to: root.appendingPathComponent("Delta.md"))
        files.refresh("", recursive: false)
        notes = NoteIndex(paths: files.paths)
        #expect(notes.suggestions("del").first?.name == "Delta")
        scan.update(notes: notes.paths, dirty: [""])
        #expect(scan.lastRead == 1)
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Beta.md", "Delta.md", "sub/Gamma.md"])

        // Rename: Beta → Bravo.
        try fm.moveItem(at: root.appendingPathComponent("Beta.md"), to: root.appendingPathComponent("Bravo.md"))
        files.refresh("", recursive: false)
        notes = NoteIndex(paths: files.paths)
        #expect(notes.resolve("Beta") == nil && notes.resolve("Bravo") == "Bravo.md")
        #expect(!notes.suggestions("").map(\.name).contains("Beta"))
        scan.update(notes: notes.paths, dirty: [""])
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Bravo.md", "Delta.md", "sub/Gamma.md"])

        // Edit: a changed note is read again (a new size).
        try Data("no links now\n".utf8).write(to: root.appendingPathComponent("sub/Gamma.md"))
        files.refresh("sub", recursive: false)
        scan.update(notes: notes.paths, dirty: ["sub"])
        #expect(scan.lastRead == 1)
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Bravo.md", "Delta.md"])

        // Delete.
        try fm.removeItem(at: root.appendingPathComponent("Delta.md"))
        files.refresh("", recursive: false)
        notes = NoteIndex(paths: files.paths)
        scan.update(notes: notes.paths, dirty: [""])
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Bravo.md"])
        #expect(notes.resolve("Delta") == nil)

        // Renaming the target: links to the old name no longer count.
        try fm.moveItem(at: root.appendingPathComponent("Alpha.md"), to: root.appendingPathComponent("Alef.md"))
        files.refresh("", recursive: false)
        notes = NoteIndex(paths: files.paths)
        scan.update(notes: notes.paths, dirty: [""])
        #expect(scan.backlinks(to: "Alef.md", in: notes).isEmpty)
        #expect(!scan.isPartial)
    }

    @Test func bigFilesAreSkippedAndMarkPartial() throws {
        let big = String(repeating: "[[Alpha]] ", count: BacklinkScan.maxFileBytes / 10 + 10)
        let root = try writeTree(["Alpha.md": "a\n", "Big.md": big, "Small.md": "[[Alpha]]\n"])
        let notes = NoteIndex(paths: FileIndex.build(root: root, showHidden: false).paths)
        var scan = BacklinkScan(root: root)
        scan.update(notes: notes.paths, dirty: nil)
        #expect(scan.isPartial && scan.skipped == 1)
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Small.md"])
    }

    @Test func selfLinksAndBinariesLeftOut() throws {
        var bin = Data("[[Alpha]]".utf8); bin.append(0)
        let root = try writeTree(["Alpha.md": "[[Alpha]] me\n"])
        try bin.write(to: root.appendingPathComponent("blob.md"))
        let notes = NoteIndex(paths: FileIndex.build(root: root, showHidden: false).paths)
        var scan = BacklinkScan(root: root)
        scan.update(notes: notes.paths, dirty: nil)
        #expect(scan.backlinks(to: "Alpha.md", in: notes).isEmpty)
    }
}
