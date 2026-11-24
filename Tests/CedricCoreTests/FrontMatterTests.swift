import Testing
@testable import CedricCore

/// YAML front matter in the preview (0.5.2 (17)): one collapsed line,
/// "Front matter · <title>", a `<details>` that opens without page script;
/// open when the reader left it open; nested values as nested tables and
/// lists, never YAML text; everything escaped.
@Suite struct FrontMatterTests {
    let doc = """
    ---
    title: "Owls of the World"
    date: 2026-11-23
    hero:
      icon: owl.png
      alt: A barn owl
      links:
        - text: Home
          url: /
        - text: About
          url: /about
    tags: [birds, night]
    ---
    # Owls
    """

    @Test func collapsedByDefaultWithTheTitleInTheSummary() {
        let html = Markdown.render(doc, options: .preview(vault: nil))
        #expect(html.hasPrefix("<details class=\"frontmatter\" data-line=\"0\">\n<summary>Front matter · Owls of the World</summary>\n"))
        #expect(!html.hasPrefix("<details class=\"frontmatter\" data-line=\"0\" open>"))
        #expect(html.contains("</details>\n<h1 data-line=\"13\" id=\"owls\">Owls</h1>"))
    }

    @Test func openWhenThePreferenceSaysSo() {
        let html = Markdown.render(doc, options: .preview(vault: nil, frontMatterExpanded: true))
        #expect(html.hasPrefix("<details class=\"frontmatter\" data-line=\"0\" open>\n<summary>"))
        // Export and print: open (no one to tap a printed page).
        #expect(Markdown.render(doc, options: .export(vault: nil)).hasPrefix("<details class=\"frontmatter\" data-line=\"0\" open>"))
    }

    @Test func withoutATitleJustFrontMatter() {
        let html = Markdown.render("---\nauthor: Sam\n---\nText\n")
        #expect(html.contains("<summary>Front matter</summary>"))
        #expect(Markdown.render("---\ntitle: \"\"\n---\n").contains("<summary>Front matter</summary>"))
    }

    @Test func nestedMapsAndListsAreTablesAndLists() {
        let html = Markdown.render(doc)
        #expect(html.contains("<tr><th>title</th><td>Owls of the World</td></tr>"))
        #expect(html.contains("<tr><th>date</th><td>2026-11-23</td></tr>"))
        let hero = "<tr><th>hero</th><td><table class=\"fm-map\"><tbody>"
            + "<tr><th>icon</th><td>owl.png</td></tr><tr><th>alt</th><td>A barn owl</td></tr>"
            + "<tr><th>links</th><td><ul class=\"fm-list\">"
            + "<li><table class=\"fm-map\"><tbody><tr><th>text</th><td>Home</td></tr><tr><th>url</th><td>/</td></tr></tbody></table></li>"
            + "<li><table class=\"fm-map\"><tbody><tr><th>text</th><td>About</td></tr><tr><th>url</th><td>/about</td></tr></tbody></table></li>"
            + "</ul></td></tr></tbody></table></td></tr>"
        #expect(html.contains(hero), "\(html)")
        #expect(html.contains("<tr><th>tags</th><td><ul class=\"fm-list\"><li>birds</li><li>night</li></ul></td></tr>"))
        // No raw YAML left over.
        #expect(!html.contains("- text:") && !html.contains("icon: owl.png"))
    }

    @Test func parserShapes() {
        #expect(FrontMatter.parse(["a: 1", "b:", "  - x", "  - y"]) == .map([("a", .scalar("1")), ("b", .list([.scalar("x"), .scalar("y")]))]))
        // A list at the key's own indent, block text, a flow map.
        #expect(FrontMatter.parse(["k:", "- 1", "- 2"]) == .map([("k", .list([.scalar("1"), .scalar("2")]))]))
        #expect(FrontMatter.parse(["t: |", "  one", "  two"]) == .map([("t", .scalar("one\ntwo"))]))
        #expect(FrontMatter.parse(["m: {a: 1, b: 'x, y'}"]) == .map([("m", .map([("a", .scalar("1")), ("b", .scalar("x, y"))]))]))
        #expect(FrontMatter.parse(["- a", "- b"]) == .list([.scalar("a"), .scalar("b")]))
        #expect(FrontMatter.title(FrontMatter.parse(["Title: Hi"])) == "Hi")
        // Very deep nesting stops, as text, without running away.
        let deep = (0..<40).map { String(repeating: " ", count: $0 * 2) + "k\($0):" } + [String(repeating: " ", count: 80) + "end"]
        if case .map = FrontMatter.parse(deep) {} else { Issue.record("deep front matter isn't a map") }
    }

    /// Codex review of 0.5.2 (17), should-fix 1: a block scalar keeps its
    /// blank and `#` lines (they were dropped before the parser knew they
    /// were text); elsewhere they are still skipped.
    @Test func blockTextKeepsItsBlankAndHashLines() {
        let lines = ["title: Owls", "", "# a comment", "description: |", "  # Heading", "", "  Body line", "    indented", "",
                     "# after", "tags: [a]"]
        #expect(FrontMatter.parse(lines) == .map([
            ("title", .scalar("Owls")),
            ("description", .scalar("# Heading\n\nBody line\n  indented")),
            ("tags", .list([.scalar("a")])),
        ]))
        // Folded: lines join, a blank line breaks.
        #expect(FrontMatter.parse(["f: >", "  one", "  two", "", "  # three"]) == .map([("f", .scalar("one two\n# three"))]))
        // In a list item's map, and with a header comment.
        #expect(FrontMatter.parse(["- d: |  # note", "    a", "", "    # b"]) == .list([.map([("d", .scalar("a\n\n# b"))])]))
        // Through the renderer, on the page.
        let html = Markdown.render("---\ndescription: |\n  # Heading\n\n  Body\n---\nText\n")
        #expect(html.contains("<tr><th>description</th><td># Heading\n\nBody</td></tr>"), "\(html)")
    }

    /// Nested flow values are values, not raw YAML.
    @Test func nestedFlowValues() {
        #expect(FrontMatter.parse(["hero: {links: [home, about]}"]) == .map([
            ("hero", .map([("links", .list([.scalar("home"), .scalar("about")]))])),
        ]))
        #expect(FrontMatter.parse(["x: [a, {b: 'c, d'}, [e]]"]) == .map([
            ("x", .list([.scalar("a"), .map([("b", .scalar("c, d"))]), .list([.scalar("e")])])),
        ]))
        #expect(FrontMatter.parse(["e: {}", "l: []"]) == .map([("e", .map([])), ("l", .list([]))]))
        // Unbalanced, or brackets in plain text: text.
        #expect(FrontMatter.parse(["t: [a, [b]"]) == .map([("t", .scalar("[a, [b]"))]))
        #expect(FrontMatter.parse(["t: [x] and [y]"]) == .map([("t", .scalar("[x] and [y]"))]))
        let html = Markdown.render("---\nhero: {links: [home, about]}\n---\n")
        #expect(html.contains("<tr><th>links</th><td><ul class=\"fm-list\"><li>home</li><li>about</li></ul></td></tr>"), "\(html)")
        #expect(!html.contains("{links"))
    }

    @Test func everythingIsEscaped() {
        let evil = """
        ---
        title: "<script>alert(1)</script>"
        "<b>key</b>": <img src=x onerror=alert(1)>
        list:
          - <iframe src="https://evil">
          - x: "&amp; <svg/onload=1>"
        ---
        """
        let html = Markdown.render(evil, options: .preview(vault: nil))
        #expect(!html.contains("<script") && !html.contains("<img") && !html.contains("<iframe") && !html.contains("<svg") && !html.contains("<b>"))
        #expect(html.contains("<summary>Front matter · &lt;script&gt;alert(1)&lt;/script&gt;</summary>"))
        #expect(html.contains("<th>&lt;b&gt;key&lt;/b&gt;</th><td>&lt;img src=x onerror=alert(1)&gt;</td>"))
        #expect(html.contains("<li>&lt;iframe src=&quot;https://evil&quot;&gt;</li>"))
        #expect(html.contains("<td>&amp;amp; &lt;svg/onload=1&gt;</td>"))
    }
}

/// The block as the reader leaves it (Codex review of 0.5.2 (17), must-fix
/// 2 on iOS and 3 on the Mac).
@Suite struct FrontMatterDisclosureTests {
    let doc = "---\ntitle: Owls\n---\n# Owls\n"

    @Test func readsAndSetsTheBlocksState() {
        let closed = Markdown.render(doc, options: .preview(vault: nil))
        let open = Markdown.render(doc, options: .preview(vault: nil, frontMatterExpanded: true))
        #expect(FrontMatterDisclosure.isOpen(in: closed) == false)
        #expect(FrontMatterDisclosure.isOpen(in: open) == true)
        #expect(FrontMatterDisclosure.isOpen(in: "<h1>Owls</h1>") == nil)
        #expect(FrontMatterDisclosure.setting(open: true, in: closed) == open)
        #expect(FrontMatterDisclosure.setting(open: false, in: open) == closed)
        #expect(FrontMatterDisclosure.setting(open: true, in: open) == open)
        #expect(FrontMatterDisclosure.setting(open: true, in: "<p>x</p>") == "<p>x</p>")
    }

    /// Only a change from what the page last had, on the page still shown.
    @Test func keepsOnlyTheReadersChange() {
        #expect(FrontMatterDisclosure.change(read: true, applied: false, readFor: 3, shown: 3) == true)
        #expect(FrontMatterDisclosure.change(read: false, applied: true, readFor: 3, shown: 3) == false)
        #expect(FrontMatterDisclosure.change(read: false, applied: false, readFor: 3, shown: 3) == nil)
        #expect(FrontMatterDisclosure.change(read: true, applied: true, readFor: 3, shown: 3) == nil)
        #expect(FrontMatterDisclosure.change(read: true, applied: false, readFor: 3, shown: 4) == nil)
        #expect(FrontMatterDisclosure.change(read: true, applied: false, readFor: 3, shown: nil) == nil)
        #expect(FrontMatterDisclosure.change(read: nil, applied: false, readFor: 3, shown: 3) == nil)
        #expect(FrontMatterDisclosure.change(read: true, applied: nil, readFor: 3, shown: 3) == nil)
    }
}
