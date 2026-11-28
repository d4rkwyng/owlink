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
        // An unclosed [[ before a code span being typed.
        #expect(WikiLinks.typing(inLine: "[[zz `[[", caret: 8) == nil)
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

    /// iOS reads notes through the granted folder's descriptor
    /// (`readBeneath`): a note replaced by a link out, or reached through a
    /// folder link that leads out, is skipped, never read.
    @Test func readBeneathSkipsLinksOut() throws {
        let root = try writeTree(["Alpha.md": "a\n", "Beta.md": "[[Alpha]]\n", "Gone.md": "[[Alpha]]\n"])
        let outside = try writeTree(["Secret.md": "[[Alpha]] secret\n", "dir/Deep.md": "[[Alpha]] deep\n"])
        let fm = FileManager.default
        try fm.removeItem(at: root.appendingPathComponent("Gone.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Gone.md"), withDestinationURL: outside.appendingPathComponent("Secret.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside.appendingPathComponent("dir"))
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        if case .read(_, _, let data) = BacklinkScan.readBeneath("Beta.md", root: fd) {
            #expect(String(decoding: data, as: UTF8.self) == "[[Alpha]]\n")
        } else { Issue.record("Beta.md should be read") }
        guard case .skipped = BacklinkScan.readBeneath("Gone.md", root: fd) else { Issue.record("a note replaced by a link is read"); return }
        guard case .skipped = BacklinkScan.readBeneath("out/Deep.md", root: fd) else { Issue.record("a folder link out is followed"); return }
        guard case .gone = BacklinkScan.readBeneath("Missing.md", root: fd) else { Issue.record("a missing note isn't gone"); return }
        guard case .skipped = BacklinkScan.readBeneath("Beta.md", root: fd, maxBytes: 3) else { Issue.record("over maxBytes is read"); return }
        let names = ["Alpha.md", "Beta.md", "Gone.md", "out/Deep.md"]
        let notes = NoteIndex(paths: names)
        var scan = BacklinkScan(root: root)
        scan.update(notes: names, dirty: nil, read: { BacklinkScan.readBeneath($0, root: fd) })
        #expect(scan.backlinks(to: "Alpha.md", in: notes).map(\.source) == ["Beta.md"])
        #expect(scan.isPartial && scan.skipped == 2)
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

    /// iOS's one pass (`collect`) finds what `update` and `backlinks(to:)`
    /// and `tagsByNote` find, in the same order, within its limits; past
    /// them it stops collecting and says so, and a cancel stops it
    /// (Sol round 2, must-fix 4).
    @Test func collectMatchesTheCacheWithinItsLimits() throws {
        let root = try writeTree([
            "Alpha.md": "# A #self\n[[Alpha]] me\n",
            "Beta.md": "[[Alpha]] one #x\n```\n[[Alpha]] code\n```\n[[alpha]] two #y #x\n",
            "sub/Gamma.md": "---\ntags: [front]\n---\n[[sub/Alpha]] nope [[Alpha#H|a]] #z\n",
            "Delta.txt": "no links #w\n",
        ])
        let notes = NoteIndex(paths: FileIndex.build(root: root, showHidden: false).paths)
        var scan = BacklinkScan(root: root)
        scan.update(notes: notes.paths, dirty: nil, tags: true)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(fd) }
        let all = BacklinkScan.collect(notes: notes.paths, to: "Alpha.md", in: notes, maxBacklinks: 100, maxTagRefs: 100) {
            BacklinkScan.readBeneath($0, root: fd)
        }
        #expect(all.backlinks == scan.backlinks(to: "Alpha.md", in: notes))
        #expect(all.tagsByNote.mapValues { $0.map(\.name) } == scan.tagsByNote.mapValues { $0.map(\.name) })
        #expect(!all.truncated && !all.cancelled && all.skipped == 0)
        // Limits: the first ones in that order, and truncated.
        let few = BacklinkScan.collect(notes: notes.paths, to: "Alpha.md", in: notes, maxBacklinks: 1, maxTagRefs: 2) {
            BacklinkScan.readBeneath($0, root: fd)
        }
        #expect(few.backlinks == Array(all.backlinks.prefix(1)))
        #expect(few.tagsByNote.values.reduce(0) { $0 + $1.count } == 2)
        #expect(few.truncated)
        // Cancelled before anything: nothing collected.
        let none = BacklinkScan.collect(notes: notes.paths, to: "Alpha.md", in: notes, maxBacklinks: 100, maxTagRefs: 100,
                                        cancelled: { true }) { BacklinkScan.readBeneath($0, root: fd) }
        #expect(none.cancelled && none.backlinks.isEmpty && none.tagsByNote.isEmpty && none.parsed == 0)
    }
}
/// The round-3 parsers, kept here as they were (whole-line arrays): the
/// streaming ones must find exactly the same links and tags.
enum OldLineParsers {
    static func links(_ b: UnsafeBufferPointer<UInt16>) -> [WikiLinks.Link] {
        var out: [WikiLinks.Link] = []
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c == WikiLinks.bs { i += 2; continue }
            if c == WikiLinks.tick {
                let (runEnd, span) = WikiLinks.codeSpanEnd(b, at: i)
                i = span ?? runEnd
                continue
            }
            if c == WikiLinks.lb, let e = WikiLinks.end(in: b, open: i) {
                let embed = i > 0 && b[i - 1] == WikiLinks.bang && !(i > 1 && b[i - 2] == WikiLinks.bs)
                let start = embed ? i - 1 : i
                out.append(WikiLinks.parse(b, open: i, end: e, start: start, embed: embed))
                i = e
                continue
            }
            i += 1
        }
        return out
    }

    static func refs(_ text: String) -> [WikiLinks.Ref] {
        var out: [WikiLinks.Ref] = []
        var fence: (UInt16, Int)?
        var line = 0
        text.enumerateLines { l, _ in
            defer { line += 1 }
            let u = Array(l.utf16)
            if WikiLinks.fenceLine(u, fence: &fence) { return }
            guard u.count >= 5 else { return }
            let found = u.withUnsafeBufferPointer { links($0) }
            guard !found.isEmpty else { return }
            let snippet = WikiLinks.snippet(l)
            for f in found where !f.target.isEmpty { out.append(WikiLinks.Ref(target: f.target, line: line, snippet: snippet)) }
        }
        return out
    }

    static let corpus: [String] = [
        "# Alpha\nSee [[Beta]] for more. #project\n",
        "[[a]] [[b|B]] ![[c.png]] \\![[d]] `[[code]]` ``[[x]]`` [[e#H]] [[#Self]] [[ ]] [[f\n[[g]]\n",
        "```\n[[fenced]]\n```\n~~~~\n[[tilde]]\n~~~\n~~~~\n[[after]] #t\n",
        "---\ntags: [one, \"two\", #three]\n---\n#inline #a/b//c/ #123 #2024/11 a#b &#123; # Heading\n",
        "---\ntags:\n  - x\n  # note\n  - 'y z'\nother: 1\n---\nbody #x #X\n",
        "---\ntag: a, b c\t d # comment\n---\n",
        "\u{FEFF}---\ntags: [u]\n---\n#ü #日本 #😀 #a_b-c `#code` \\#esc\n",
        String(repeating: "[[Beta]] #t ", count: 3_000) + "\n" + String(repeating: "word ", count: 400) + "[[Last]]\n",
        (0..<500).map { "line \($0) [[n\($0 % 7)]] #k\($0 % 11)" }.joined(separator: "\n"),
        "[[" + String(repeating: "x", count: 600) + "]] [[ok]]\n[[a]]]] [[[b]] [[c|]] [[|d]]\n",
    ]
}

@Suite struct StreamingParsersTests {
    @Test func linksAndRefsMatchTheWholeLineParser() {
        for text in OldLineParsers.corpus {
            #expect(WikiLinks.refs(in: text) == OldLineParsers.refs(text))
            text.enumerateLines { l, _ in
                let u = Array(l.utf16)
                u.withUnsafeBufferPointer { b in #expect(WikiLinks.links(inLine: b) == OldLineParsers.links(b)) }
            }
        }
    }

    @Test func streamingStopsWhenAskedAndWhenCancelled() {
        let line = Array(String(repeating: "[[x]] ", count: 10_000).utf16)
        var seen = 0
        let stopped = line.withUnsafeBufferPointer { WikiLinks.forEachLink(inLine: $0) { _ in seen += 1; return seen < 5 } }
        #expect(!stopped && seen == 5)
        seen = 0
        var asked = 0
        let cancelled = line.withUnsafeBufferPointer { b in
            WikiLinks.forEachLink(inLine: b, cancelled: { asked += 1; return asked >= 2 }) { _ in seen += 1; return true }
        }
        // Asked first after `cancelInterval` units, then again after as many.
        #expect(!cancelled && asked == 2 && seen <= 2 * WikiLinks.cancelInterval / 6 + 1)
    }
}
