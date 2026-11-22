import Foundation
import Testing
@testable import CedricCore

/// Obsidian-flavoured output with the data-line attributes stripped.
func ob(_ s: String, vault: WikiVault? = nil) -> String {
    Markdown.render(s, options: .preview(vault: vault)).replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
}

@Suite struct ObsidianMarkdownTests {
    @Test func offByDefault() {
        #expect(md("[[note]] ==hi== #tag %%x%%") == "<p>[[note]] ==hi== #tag %%x%%</p>\n")
    }

    @Test func wikilinksResolveByNameShortestPathWins() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/deep/a/b/Target.md", "v/x/Target.md", "v/Other Note.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("v/notes"))
        #expect(vault.root.path == t.appendingPathComponent("v").path, "the folder holding .obsidian/")
        let x = t.appendingPathComponent("v/x/Target.md").path
        #expect(vault.resolve("target")?.path == x)
        #expect(vault.resolve("Target.md")?.path == x)
        #expect(vault.resolve("a/b/Target")?.path == t.appendingPathComponent("v/deep/a/b/Target.md").path)
        #expect(vault.resolve("Nope") == nil)
        #expect(vault.resolve("../notes/doc") == nil)

        let html = ob("See [[Target|the target]], [[Other Note]] and [[Missing]].", vault: vault)
        #expect(html.contains(#"<a class="wikilink" href="cedric-doc://doc"#) && html.contains("/v/x/Target.md\">the target</a>"))
        #expect(html.contains("Other%20Note.md\">Other Note</a>"))
        #expect(html.contains(#"<a class="wikilink is-unresolved" title="Missing (not found)">Missing</a>"#))
    }

    @Test func headingAndBlockLinksFallBackToTheNote() throws {
        let t = try makeTree(["n/doc.md", "n/Note.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("n"))
        let h = ob("[[Note#Setup]] [[Note#^abc123|alias]] [[#Local]]", vault: vault)
        #expect(h.contains("Note.md\">Note › Setup</a>"))
        #expect(h.contains("Note.md\">alias</a>"))
        #expect(h.contains(#"is-unresolved" title=" (not found)">Local</a>"#))
        // No vault: shown as unresolved links, not raw text.
        #expect(ob("[[a|B]]") == "<p><a class=\"wikilink is-unresolved\" title=\"a (not found)\">B</a></p>\n")
    }

    @Test func neverInsideCode() {
        #expect(ob("`[[a]] ==b== #c %%d%%`") == "<p><code>[[a]] ==b== #c %%d%%</code></p>\n")
        let fenced = ob("```\n[[a]] ==b== #c\n%%\n```")
        #expect(fenced.contains("[[a]] ==b== #c\n%%") && !fenced.contains("wikilink") && !fenced.contains("<mark>"))
    }

    @Test func imageEmbedsWithWidth() throws {
        let t = try makeTree(["v/.obsidian/x", "v/doc/d.md", "v/attachments/pic one.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("v/doc"))
        let h = ob("![[pic one.png|300]] ![[pic one.png|200x100]] ![[pic one.png]] ![[gone.png]]", vault: vault)
        #expect(h.contains(#"pic%20one.png" alt="pic one.png" width="300">"#))
        #expect(h.contains(#"width="200" height="100">"#))
        #expect(h.contains(#"pic%20one.png" alt="pic one.png">"#))
        #expect(h.contains("![[gone.png]]"), "an embed not found stays as typed")
        // The handler serves a vault file outside the document's folder.
        let src = try #require(PreviewFolder.pageURL(forFile: t.appendingPathComponent("v/attachments/pic one.png")))
        #expect(PreviewFolder.file(for: src, in: vault.documentFolder, openedRoot: nil, vaultRoot: vault.root, scriptOn: false) != nil)
        #expect(PreviewFolder.file(for: src, in: vault.documentFolder, openedRoot: nil, scriptOn: false) == nil)
    }

    @Test func bareImagesUseVaultAndPreserveAttributes() throws {
        let name = "sg-logo-roger-graham-400x400.webp"
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/Images/\(name)"])
        defer { try? FileManager.default.removeItem(at: t) }
        try #"{"attachmentFolderPath":"Images"}"#.write(to: t.appendingPathComponent("v/.obsidian/app.json"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: t.appendingPathComponent("v/notes"))
        let html = ob("""
        <img src="\(name)" alt="Sierra Vault" width="200" style="float: right; margin: 0 0 10px 10px;">

        ![md](\(name)) ![[\(name)]]
        """, vault: vault)
        #expect(html.components(separatedBy: #"src="\#(name)""#).count == 3)
        #expect(html.contains("/Images/\(name)"))
        #expect(html.contains(#"alt="Sierra Vault" width="200" style="float: right; margin: 0 0 10px 10px;""#))
        #expect(PreviewImageAccess.readable(name, folder: vault.documentFolder, openedRoot: nil))
        let page = try #require(PreviewFolder.pageURL(for: vault.documentFolder))
        let src = try #require(URL(string: name, relativeTo: page)?.absoluteURL)
        #expect(PreviewFolder.file(for: src, in: vault.documentFolder, openedRoot: nil, vaultRoot: vault.root, scriptOn: true, vault: vault)?.path == t.appendingPathComponent("v/Images/\(name)").path)
        for source in PreviewImageAccess.localSources(html) {
            let url = try #require(URL(string: source, relativeTo: page)?.absoluteURL)
            #expect(PreviewFolder.file(for: url, in: vault.documentFolder, openedRoot: nil, vaultRoot: vault.root, scriptOn: true, vault: vault)?.path == t.appendingPathComponent("v/Images/\(name)").path)
        }
        #expect(ob("![missing](missing.webp)", vault: vault).contains(#"src="missing.webp""#))
    }

    @Test func bareImagePreferenceAndConfinement() throws {
        let t = try makeTree(["v/.obsidian/app.json", "v/notes/doc.md", "v/a/pic.webp", "v/b/pic.webp",
                              "v/preferred/deep/pic.webp", "outside.webp"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("v"), folder = root.appendingPathComponent("notes")
        try "{}".write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        var vault = WikiVault(documentFolder: folder)
        #expect(vault.resolveImage("pic.webp")?.path == root.appendingPathComponent("a/pic.webp").path)
        try #"{"attachmentFolderPath":"preferred"}"#.write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        vault = WikiVault(documentFolder: folder)
        #expect(vault.resolveImage("pic.webp")?.path == root.appendingPathComponent("preferred/deep/pic.webp").path)
        try "local".write(to: folder.appendingPathComponent("pic.webp"), atomically: true, encoding: .utf8)
        #expect(vault.resolveImage("pic.webp")?.path == folder.appendingPathComponent("pic.webp").path)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.webp"), withDestinationURL: t.appendingPathComponent("outside.webp"))
        #expect(vault.resolveImage("escape.webp") == nil)
        #expect(vault.resolve("../outside.webp") == nil)
        #expect(vault.resolve("/outside.webp") == nil)
        #expect(!PreviewImageAccess.readable("../outside.webp", folder: folder, openedRoot: root))
        #expect(!PreviewImageAccess.readable(t.appendingPathComponent("outside.webp").absoluteString, folder: folder, openedRoot: root))
        let escape = try #require(PreviewFolder.pageURL(forFile: folder.appendingPathComponent("escape.webp")))
        #expect(PreviewFolder.file(for: escape, in: folder, openedRoot: root, vaultRoot: root, scriptOn: false, vault: vault) == nil)
    }

    @Test func noteEmbedsAreOneLevelDeep() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        try "---\ntags: x\n---\nIntro **bold**\n\n## Part\nIn part ![[Inner]]\n\n## Next\nafter\n\nA para ^blk\n".write(to: n.appendingPathComponent("Outer.md"), atomically: true, encoding: .utf8)
        try "inner text".write(to: n.appendingPathComponent("Inner.md"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: n)
        let whole = ob("![[Outer]]", vault: vault)
        #expect(whole.contains(#"<blockquote class="embed">"#) && whole.contains("<strong>bold</strong>"))
        #expect(!whole.contains("tags: x"), "frontmatter is left out")
        #expect(!whole.contains("inner text") && whole.contains("Inner.md\">Inner</a>"), "nested embeds stay links")
        let part = ob("![[Outer#Part]]", vault: vault)
        #expect(part.contains("In part") && !part.contains("after") && !part.contains("Intro"))
        let block = ob("![[Outer#^blk]]", vault: vault)
        #expect(block.contains("A para") && !block.contains("^blk") && !block.contains("after"), "\(block)")
    }

    @Test func callouts() {
        let h = ob("> [!info] Read me\n> body *x*")
        #expect(h.contains(#"<div class="markdown-alert markdown-alert-info callout" data-callout="info">"#))
        #expect(h.contains(#"<p class="markdown-alert-title"><span class="callout-icon" aria-hidden="true">ℹ︎</span> Read me</p>"#))
        #expect(h.contains("<p>body <em>x</em></p>"))
        let folded = ob("> [!faq]- Why?\n> because")
        #expect(folded.contains(#"<details class="markdown-alert markdown-alert-question callout" data-callout="faq">"#))
        #expect(folded.contains("<summary class=\"markdown-alert-title\">") && folded.contains("Why?</summary>") && folded.contains("</details>"))
        #expect(ob("> [!tip]+\n> t").contains(#"data-callout="tip" open>"#))
        #expect(ob("> [!custom-thing]\n> t").contains("markdown-alert-note callout\" data-callout=\"custom-thing\"") && ob("> [!custom-thing]\n> t").contains("Custom thing"))
        // GitHub's own alerts are as before.
        #expect(ob("> [!WARNING]\n> w").contains("<div class=\"markdown-alert markdown-alert-warning\">\n<p class=\"markdown-alert-title\">Warning</p>"))
    }

    @Test func highlightsCommentsAndTags() {
        #expect(ob("a ==big **deal**== b") == "<p>a <mark>big <strong>deal</strong></mark> b</p>\n")
        #expect(ob("a == b == c") == "<p>a == b == c</p>\n")
        #expect(ob("keep %%hidden%% this") == "<p>keep  this</p>\n")
        #expect(ob("one\n\n%%\nsecret\nlines\n%%\n\ntwo") == "<p>one</p>\n<p>two</p>\n")
        #expect(!ob("x %%start\nmore%% y").contains("start"))
        #expect(ob("#tag and #nested/tag-1 but #123 and a#b") == "<p><span class=\"tag\">#tag</span> and <span class=\"tag\">#nested/tag-1</span> but #123 and a#b</p>\n")
        #expect(ob("# Heading").hasPrefix("<h1"))
        // data-line numbers still match the source after a comment block.
        let lines = Markdown.render("%%\nx\n%%\npara", options: .preview)
        #expect(lines.contains(#"<p data-line="3">para</p>"#))
    }

    @Test func craftedInputStaysFast() {
        let start = Date()
        _ = ob(String(repeating: "[[a", count: 20_000) + String(repeating: "==b ", count: 20_000) + String(repeating: "%%", count: 5_001))
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
