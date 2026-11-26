import Foundation
import Testing
@testable import CedricCore

private func names(_ line: String) -> [String] { Tags.tags(inLine: line).map(\.name) }
private func refNames(_ text: String) -> [String] { Tags.refs(in: text).map(\.name) }

@Suite struct TagParsingTests {
    @Test func inlineAndNested() {
        #expect(names("#todo and #project/alpha, then #a-b_c.") == ["todo", "project/alpha", "a-b_c"])
        let f = Tags.tags(inLine: "x #tag y")[0]
        #expect(f.range == NSRange(location: 2, length: 4))
        #expect(names("#start of line") == ["start"])
        // Empty parts are dropped; a trailing slash ends nothing.
        #expect(names("#a//b/ #c/") == ["a/b", "c"])
        #expect(names("#/") == [])
    }

    @Test func onlyAfterSpaceSoUrlsAnchorsAndEntitiesAreNot() {
        #expect(names("see https://example.com/page#section here") == [])
        #expect(names("[jump](#anchor) and [doc](other.md#part)") == [])
        #expect(names("<https://x.org/#frag> a#b &#123;") == [])
        #expect(names("[[Note#Heading]]") == [])
        #expect(names("tab\t#yes and nbsp\u{00A0}#also") == ["yes", "also"])
    }

    @Test func headingsAreNotTags() {
        #expect(names("# Heading") == [])
        #expect(names("## Heading two") == [])
        #expect(names("###### Deep") == [])
        #expect(names("## Heading with #tag") == ["tag"])
        #expect(refNames("# Title\n\nText #real\n") == ["real"])
    }

    @Test func pureNumbersAreNot() {
        #expect(names("issue #123 and #2024/11 and #42nd and #y2k and #1984a") == ["42nd", "y2k", "1984a"])
    }

    @Test func escapesAndPunctuationEndATag() {
        #expect(names(#"\#nope #yes"#) == ["yes"])
        #expect(names("#end. #comma, #paren) #q? #colon: #semi;") == ["end", "comma", "paren", "q", "colon", "semi"])
        #expect(names("#a.b") == ["a"])
        #expect(names("#") == [] && names("# ") == [] && names("#!") == [])
    }

    @Test func codeSpansAreSkipped() {
        #expect(names("`#code` and #real") == ["real"])
        #expect(names("``a `#b` c`` #d") == ["d"])
        // An unclosed backtick run is text.
        #expect(names("` #open") == ["open"])
    }

    @Test func fencesAreSkipped() {
        let text = "#before\n```\n#inside\n```\n~~~~ swift\n#tilde\n~~~~\n  ```\n#indented\n  ```\n#after\n"
        #expect(refNames(text) == ["before", "after"])
        let refs = Tags.refs(in: text)
        #expect(refs.map(\.line) == [0, 10])
    }

    @Test func unicodeAndEmoji() {
        #expect(names("#café #日本語 #éé/ñ #Ünïcödé") == ["café", "日本語", "éé/ñ", "Ünïcödé"])
        #expect(names("#emoji🦉 #👍🏽 #family👨‍👩‍👧") == ["emoji🦉", "👍🏽", "family👨‍👩‍👧"])
        let f = Tags.tags(inLine: "a #🦉b c")[0]
        #expect(f.range == NSRange(location: 2, length: 4))
        // Decomposed é (e + combining acute) stays one name.
        #expect(names("#cafe\u{301}!") == ["cafe\u{301}"])
    }

    @Test func frontMatterList() {
        let text = "---\ntitle: Note\ntags:\n  - alpha\n  - \"#beta/gamma\"\n  - 'quoted'\n\n  - 123\naliases: [x]\n---\n#inline\n"
        let refs = Tags.refs(in: text)
        #expect(refs.map(\.name) == ["alpha", "beta/gamma", "quoted", "inline"])
        #expect(refs.map(\.line) == [3, 4, 5, 10])
        #expect(refs[0].snippet == "- alpha")
    }

    @Test func frontMatterInline() {
        #expect(refNames("---\ntags: [one, \"two\", #three]\n---\n") == ["one", "two", "three"])
        #expect(refNames("---\ntags: one, two three\n---\n") == ["one", "two", "three"])
        #expect(refNames("---\nTag: solo # a comment\n---\n") == ["solo"])
        #expect(refNames("\u{FEFF}---\ntags: [bom]\n---\n") == ["bom"])
        // A `#` in front matter is a YAML comment, not an inline tag; not front matter after line 1.
        #expect(refNames("---\n# comment #nope\nother: #nope\n---\n") == [])
        #expect(refNames("Intro\n---\ntags: [late]\n---\n") == [])
        // A value with a space or punctuation is no tag.
        #expect(refNames("---\ntags:\n  - two words\n  - ok\n---\n") == ["ok"])
        // `...` ends front matter too.
        #expect(refNames("---\ntags: [a]\n...\n#b\n") == ["a", "b"])
    }

    @Test func oneRefPerTagPerNoteIgnoringCase() {
        let refs = Tags.refs(in: "#Todo first\nthen #todo again\n#other #TODO\n")
        #expect(refs.map(\.name) == ["Todo", "other"])
        #expect(refs.map(\.line) == [0, 2])
    }
}

@Suite struct TagTreeTests {
    @Test func countsNestingAndOrder() {
        let files: [String: [Tags.Ref]] = [
            "a.md": [.init(name: "project/alpha", line: 3, snippet: "a3"), .init(name: "todo", line: 1, snippet: "a1")],
            "b.md": [.init(name: "Todo", line: 0, snippet: "b0"), .init(name: "project", line: 5, snippet: "b5")],
            "c.md": [.init(name: "project/beta", line: 2, snippet: "c2"), .init(name: "zebra", line: 0, snippet: "c0")],
            "d.md": [.init(name: "apple", line: 0, snippet: "d0")],
        ]
        let t = TagTree(files: files)
        // project: a (via alpha), b, c (via beta) = 3; todo: 2; apple, zebra: 1 each, by name.
        #expect(t.roots.map(\.name) == ["project", "todo", "apple", "zebra"])
        #expect(t.roots.map(\.count) == [3, 2, 1, 1])
        #expect(t.roots[0].children.map(\.path) == ["project/alpha", "project/beta"])
        #expect(t.tagCount == 6)
        // Shown as first written, by note path.
        #expect(t.roots[1].name == "todo")
        #expect(t.notes(for: "TODO").map(\.source) == ["a.md", "b.md"])
        #expect(t.notes(for: "project").map(\.line) == [3, 5, 2])
        #expect(t.notes(for: "project/alpha").map(\.snippet) == ["a3"])
        #expect(t.node("Project/Beta")?.count == 1)
        #expect(t.node("nope") == nil)
        #expect(t.notes(for: "nope").isEmpty)
    }

    @Test func parentHitIsTheFirstLineInEachNote() {
        let t = TagTree(files: ["n.md": [.init(name: "a/b", line: 7, snippet: "s7"), .init(name: "a/c", line: 2, snippet: "s2")]])
        #expect(t.notes(for: "a").map(\.line) == [2])
        #expect(t.roots.first?.count == 1)
    }
}

private func writeTagTree(_ files: [String: String]) throws -> URL {
    let root = tempDir()
    for (f, text) in files {
        let u = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    return root
}

@Suite struct TagScanIncrementalTests {
    private func tree(_ scan: BacklinkScan) -> TagTree { TagTree(files: scan.tagsByNote) }

    @Test func addRenameDeleteUpdateCounts() throws {
        let root = try writeTagTree(["Alpha.md": "# A\n#todo #project/x\n", "Beta.md": "---\ntags: [todo]\n---\n",
                                     "sub/Gamma.md": "no tags\n", "code.md": "```\n#todo\n```\n"])
        let fm = FileManager.default
        var files = FileIndex.build(root: root, showHidden: false)
        var scan = BacklinkScan(root: root)
        scan.update(notes: NoteIndex(paths: files.paths).paths, dirty: nil, tags: true)
        #expect(scan.lastRead == 4)
        #expect(tree(scan).node("todo")?.count == 2)
        #expect(tree(scan).notes(for: "todo").map(\.source) == ["Alpha.md", "Beta.md"])
        #expect(tree(scan).notes(for: "todo").map(\.line) == [1, 1])

        // Add, in one folder: only that folder's notes are looked at.
        try Data("#todo #new\n".utf8).write(to: root.appendingPathComponent("sub/Delta.md"))
        files.refresh("sub", recursive: false)
        scan.update(notes: NoteIndex(paths: files.paths).paths, dirty: ["sub"], tags: true)
        #expect(scan.lastRead == 1)
        #expect(tree(scan).node("todo")?.count == 3)
        #expect(tree(scan).node("new")?.count == 1)

        // Rename: the note's tags move with it.
        try fm.moveItem(at: root.appendingPathComponent("Beta.md"), to: root.appendingPathComponent("Bravo.md"))
        files.refresh("", recursive: false)
        scan.update(notes: NoteIndex(paths: files.paths).paths, dirty: [""], tags: true)
        #expect(tree(scan).notes(for: "todo").map(\.source) == ["Alpha.md", "Bravo.md", "sub/Delta.md"])

        // Edit: a tag taken out.
        try Data("# A\n#project/x #project/y\n".utf8).write(to: root.appendingPathComponent("Alpha.md"))
        scan.update(notes: NoteIndex(paths: files.paths).paths, dirty: [""], tags: true)
        #expect(tree(scan).node("todo")?.count == 2)
        #expect(tree(scan).node("project")?.children.map(\.name) == ["x", "y"])

        // Delete.
        try fm.removeItem(at: root.appendingPathComponent("sub/Delta.md"))
        files.refresh("sub", recursive: false)
        scan.update(notes: NoteIndex(paths: files.paths).paths, dirty: ["sub"], tags: true)
        #expect(tree(scan).node("todo")?.count == 1)
        #expect(tree(scan).node("new") == nil)
        #expect(!scan.isPartial)
    }

    @Test func tagsAskedLaterReadCachedNotesAgainOnce() throws {
        let root = try writeTagTree(["a.md": "[[b]] #x\n", "b.md": "#y\n"])
        let paths = NoteIndex(paths: FileIndex.build(root: root, showHidden: false).paths).paths
        var scan = BacklinkScan(root: root)
        scan.update(notes: paths, dirty: nil)
        #expect(scan.lastRead == 2 && scan.tagsByNote.isEmpty)
        // Nothing changed on disk, but the cached notes have no tags yet.
        scan.update(notes: paths, dirty: [], tags: true)
        #expect(scan.lastRead == 2)
        #expect(tree(scan).roots.map(\.name) == ["x", "y"])
        #expect(scan.files["a.md"]?.refs.map(\.target) == ["b"])
        scan.update(notes: paths, dirty: nil, tags: true)
        #expect(scan.lastRead == 0)
    }

    @Test func bigFilesAreSkippedAndMarkPartial() throws {
        let big = String(repeating: "#big ", count: BacklinkScan.maxFileBytes / 5 + 10)
        let root = try writeTagTree(["Big.md": big, "Small.md": "#small\n"])
        var scan = BacklinkScan(root: root)
        scan.update(notes: ["Big.md", "Small.md"], dirty: nil, tags: true)
        #expect(scan.isPartial)
        #expect(tree(scan).roots.map(\.name) == ["small"])
    }
}
