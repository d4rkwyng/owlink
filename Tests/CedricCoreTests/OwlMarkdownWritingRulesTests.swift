import Foundation
import Testing
@testable import CedricCore

/// 0.4.0's writing checks for Markdown: the nearest-file Fix it for a broken
/// link, a skipped heading level, a duplicate heading, orphan footnotes and
/// empty links. Each fires, each near miss (code, inline code, queries,
/// reference links, percent-encoding) stays quiet, and each Fix it is one edit.
@Suite struct OwlMarkdownWritingRulesTests {
    func find(_ id: String, _ text: String, facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        OwlLanguageRulesTests.check(text, language: "markdown", fileName: "README.md", facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    func range(_ h: OwlHint, in text: String) -> String { (text as NSString).substring(with: h.range!) }

    static let tree = OwlDocumentFacts(fileExists: OwlFileProbe.set(["docs/guide.md", "img/logo.png", "images/photo.png",
                                                                      "notes/old notes.md", "page.md", "a/intro.md", "b/intro.md"]))

    // MARK: 1. Broken relative link: the nearest file

    @Test func brokenLinkFixGoesToTheNearestFile() throws {
        let id = MarkdownRules.relativeLinkID
        let cases: [(String, String)] = [
            ("See [x](docs/gide.md#start).\n", "See [x](docs/guide.md#start).\n"),             // a typo, fragment kept
            ("![p](img/photo.png)\n", "![p](images/photo.png)\n"),                             // same name, sibling folder
            ("[n](notes/old%20note.md)\n", "[n](notes/old%20notes.md)\n"),                     // percent-encoded
            ("[g](docs/gide.md?plain=1)\n", "[g](docs/guide.md?plain=1)\n"),                   // a query string
            ("[g]: docs/gide.md\n", "[g]: docs/guide.md\n"),                                    // a reference definition
            ("[g](./docs/gide.md)\n", "[g](./docs/guide.md)\n"),                               // ./ kept
            ("<img src=\"img/logo.svg\">\n", "<img src=\"img/logo.png\">\n"),                   // another image extension
            ("[a](docs/gide.md) and [b](docs/gide.md)\n", "[a](docs/guide.md) and [b](docs/guide.md)\n"),   // both, one edit
        ]
        for (text, fixed) in cases {
            let h = try #require(find(id, text, facts: Self.tree), "\(text)")
            #expect(h.kind == .fix, "\(text)")
            #expect(apply(h, to: text) == fixed, "\(text)")
            #expect(h.title.count <= 60, "\(h.title)")
        }
        let h = try #require(find(id, "See [x](docs/gide.md).\n", facts: Self.tree))
        #expect(h.title == "No file “gide.md”. Link to “docs/guide.md”?")
    }

    @Test func brokenLinkWithoutOneClearMatchIsAWarning() throws {
        let id = MarkdownRules.relativeLinkID
        // Two equally near (a/intro.md, b/intro.md), nothing near, outside the folder, no extension.
        for text in ["[i](c/intro.md)\n", "[x](zebra.md)\n", "[u](../up.md)\n", "[p](gide)\n"] {
            let h = try #require(find(id, text, facts: Self.tree), "\(text)")
            #expect(h.kind == .warning && h.replacement == nil, "\(text)")
        }
        // One fixable and one not: no partial fix.
        let mixed = try #require(find(id, "[a](docs/gide.md) [b](zebra.md)\n", facts: Self.tree))
        #expect(mixed.kind == .warning && mixed.replacement == nil)
        // A probe without a listing: the 0.3.0 warning.
        let noList = OwlDocumentFacts(fileExists: OwlFileProbe(exists: { _ in false }))
        #expect(find(id, "[x](docs/gide.md)\n", facts: noList)?.kind == .warning)
        // The listing not made yet: wait for the query that has it.
        let pending = OwlDocumentFacts(fileExists: OwlFileProbe(exists: { _ in false }, files: { nil }))
        #expect(find(id, "[x](docs/gide.md)\n", facts: pending) == nil)
        // Code, inline code and comments are never looked at.
        for t in ["`[x](docs/gide.md)`\n", "```\n[x](docs/gide.md)\n```\n", "<!-- [x](docs/gide.md) -->\n"] {
            #expect(find(id, t, facts: Self.tree) == nil, "\(t)")
        }
        // A footnote's note isn't a link definition.
        #expect(find(id, "Text[^1].\n\n[^1]: Some words here.\n", facts: Self.tree) == nil)
    }

    @Test func nearestFileRanking() {
        func index(_ files: [String]) -> [(path: String, lower: String, stem: String, ext: String)] {
            files.map { f in
                let l = f.lowercased(), n = (l as NSString).lastPathComponent as NSString
                return (f, l, n.deletingPathExtension, n.pathExtension)
            }
        }
        #expect(MarkdownRules.nearestFile("img/a.png", index: index(["images/a.png", "img/b.md"])) == "images/a.png")
        // A Markdown link never goes to an image, nor a PDF to either.
        #expect(MarkdownRules.nearestFile("guide.md", index: index(["guide.png"])) == nil)
        #expect(MarkdownRules.nearestFile("spec.pdf", index: index(["spec.md", "spec.png"])) == nil)
        // Short names allow one letter off, longer ones two or three.
        #expect(MarkdownRules.nearestFile("ab.md", index: index(["xy.md"])) == nil)
        #expect(MarkdownRules.nearestFile("installation.md", index: index(["instalation-guide.md", "installaton.md"])) == "installaton.md")
        #expect(MarkdownRules.rewrite("old%20a.md#x", to: "new b.md", encode: true) == "new%20b.md#x")
        #expect(MarkdownRules.rewrite("a.md", to: "new b.md", encode: false) == "new b.md")
    }

    /// Astra batch 9b: Markdown and images in a folder whose name starts
    /// with a combining mark, first-level and nested, are listed by their
    /// own paths (a text prefix test fused "folder/" and the mark and
    /// dropped them); a sibling named folder + mark isn't.
    @Test func folderScanKeepsCombiningMarkFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("owl-scan-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("doc")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for p in ["doc/\u{301}m/a.md", "doc/\u{301}m/i.png", "doc/s/\u{301}n/b.md", "doc/c.md", "doc\u{301}/out.md"] {
            let u = base.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        let got = Set(OwlFileProbe.scan(folder: dir).map { Array($0.utf8) })
        #expect(got == Set(["\u{301}m/a.md", "\u{301}m/i.png", "s/\u{301}n/b.md", "c.md"].map { Array($0.utf8) }))
    }

    /// Astra batch 12b: symlink resolution is now deferred to the
    /// fallback. Scanned through a symlinked folder, a real file, a
    /// symlinked file (one pointing inside, one outside the folder) and a
    /// file in a combining-mark folder are still listed by their own
    /// relative paths.
    @Test func folderScanResolvesThroughSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("owl-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for p in ["real/a.md", "real/\u{301}m/b.md", "elsewhere/x.md"] {
            let u = base.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        try fm.createSymbolicLink(at: base.appendingPathComponent("real/in.md"), withDestinationURL: base.appendingPathComponent("real/a.md"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("real/out.md"), withDestinationURL: base.appendingPathComponent("elsewhere/x.md"))
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("real"))
        let want = Set(["a.md", "\u{301}m/b.md", "in.md", "out.md"].map { Array($0.utf8) })
        #expect(Set(OwlFileProbe.scan(folder: link).map { Array($0.utf8) }) == want)
        #expect(Set(OwlFileProbe.scan(folder: base.appendingPathComponent("real")).map { Array($0.utf8) }) == want)
    }

    @Test func folderScanIsBoundedAndSkipsHiddenAndInstalledCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owl-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for p in ["a.md", "docs/b.markdown", "img/c.png", "notes.txt", ".hidden/d.md", "node_modules/pkg/e.md"] {
            let u = dir.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        #expect(Set(OwlFileProbe.scan(folder: dir)) == ["a.md", "docs/b.markdown", "img/c.png"])
        for i in 0..<(OwlFileProbe.scanLimit + 50) { try Data().write(to: dir.appendingPathComponent("f\(i).md")) }
        #expect(OwlFileProbe.scan(folder: dir).count <= OwlFileProbe.scanLimit)
    }

    // MARK: 2. Broken in-document anchor (0.3.0's fix, the preview's slugs)

    @Test func anchorFixUsesThePreviewsSlugs() throws {
        let text = "# Getting Started!\n\n## Setup & Use\n\n[a](#getting-startd) [b](#setup--use)\n"
        let html = Markdown.render(text)
        #expect(html.contains("id=\"getting-started\"") && html.contains("id=\"setup--use\""))
        let h = try #require(find(MarkdownRules.anchorID, text))
        #expect(apply(h, to: text).contains("[a](#getting-started)"))
    }

    // MARK: 3. Skipped heading level

    @Test func skippedHeadingLevel() throws {
        let id = MarkdownRules.headingSkipID
        let text = "# Title\n\n### Install\n\ntext\n\n#### Linux\n\n### Use\n\n## API\n"
        let h = try #require(find(id, text))
        #expect(h.kind == .fix && h.title == "This heading jumps from H1 to H3. Make it H2?")
        #expect(apply(h, to: text) == "# Title\n\n## Install\n\ntext\n\n### Linux\n\n## Use\n\n## API\n")
        // After an underlined heading.
        #expect(find(id, "Title\n=====\n\n### A\n").map { apply($0, to: "Title\n=====\n\n### A\n") } == "Title\n=====\n\n## A\n")
        let ok = ["# A\n## B\n### C\n# D\n",
                  "### Only one\n", "## A\n### B\n## C\n",
                  "# A\n```\n### not a heading\n```\n", "# A\n\n`### code`\n", "# A\n<!--\n### hidden\n-->\n",
                  "# A\n\n    ### indented code\n", "#hashtag\n###also not\n"]
        for t in ok { #expect(find(id, t) == nil, "\(t)") }
        // A window that may start inside a fence: quiet.
        #expect(find(id, "# c\n```\n### x\n", facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
        #expect(find(id, "# a\n### b\n", facts: OwlDocumentFacts(isWholeDocument: false)) != nil)
    }

    // MARK: 4. Duplicate heading

    @Test func duplicateHeading() throws {
        let id = MarkdownRules.duplicateHeadingID
        let text = "# Guide\n\n## Setup\n\ntext\n\n## Setup\n"
        let h = try #require(find(id, text))
        #expect(h.kind == .tip && h.replacement == nil)
        #expect(h.title == "Two headings “Setup” share one anchor.")
        #expect(h.range!.location == (text as NSString).range(of: "## Setup", options: .backwards).location)
        #expect(h.detail?.contains("#setup-1") == true)
        // Under different parents, only when a link uses the anchor.
        let changelog = "# Log\n## 1.0\n### Added\n## 0.9\n### Added\n"
        #expect(find(id, changelog) == nil)
        #expect(find(id, changelog + "\nSee [what's new](#added).\n") != nil)
        #expect(find(id, "# A\n```\n## A\n```\n") == nil)
        #expect(find(id, text, facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    // MARK: 5. Orphan footnotes

    @Test func orphanFootnotes() throws {
        let id = MarkdownRules.footnoteID
        let missing = "Text[^1] and more[^2].\n\n[^1]: One.\n"
        let h = try #require(find(id, missing))
        #expect(h.title == "Footnote [^2] has no note." && range(h, in: missing) == "[^2]")
        let unused = "Text.\n\n[^note]: Never cited.\n"
        let u = try #require(find(id, unused))
        #expect(u.title == "The note [^note] is never used." && range(u, in: unused) == "[^note]")
        #expect(find(id, "See[^1].\n") != nil)                                  // numbered, no notes at all
        let ok = ["A[^Note].\n\n[^note]: Labels ignore case.\n",
                  "Match with [^a-z] in a regex.\n",                             // no notes: not a footnote
                  "`[^1]` and\n```\n[^2]\n```\n",
                  "A[^1].\n\n[^1]: One, citing[^2].\n[^2]: Two.\n",
                  "[^x](https://example.com) is a link.\n"]
        for t in ok { #expect(find(id, t) == nil, "\(t)") }
        #expect(find(id, missing, facts: OwlDocumentFacts(isWholeDocument: false)) == nil)
    }

    // MARK: 6. Empty links

    @Test func emptyLinks() throws {
        let id = MarkdownRules.emptyLinkID
        let a = "Read [the guide]() first.\n"
        let h = try #require(find(id, a))
        #expect(h.title == "This link has no address." && range(h, in: a) == "[the guide]()")
        #expect(find(id, "Go [](https://example.com).\n")?.title == "This link has no text to click.")
        #expect(find(id, "![logo]()\n")?.title == "This image has no address.")
        #expect(find(id, "[x](<>)\n") != nil)
        let ok = ["![](img.png)\n", "`[x]()`\n", "```\n[x]()\n```\n", "[x](#)\n", "[![badge](b.svg)](https://x.y)\n",
                  "[x](<a b.md>)\n", "{{ page }} [x]()\n"]
        for t in ok { #expect(find(id, t) == nil, "\(t)") }
    }

    // MARK: All six

    @Test func everyWritingCheckIsInTheTableAndHasACategory() {
        let ids = RulesHintProvider.languageRuleIDs
        for id in [MarkdownRules.headingSkipID, MarkdownRules.duplicateHeadingID, MarkdownRules.footnoteID, MarkdownRules.emptyLinkID] {
            #expect(ids.contains(id), "\(id)")
        }
    }
}
