import Foundation
import Testing
@testable import CedricCore

/// The renderer's output with the data-line attributes stripped.
func md(_ s: String) -> String {
    Markdown.render(s).replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
}

@Suite struct MarkdownTests {
    @Test func headings() {
        #expect(md("# One\n## Two ##\n###### Six") == "<h1 id=\"one\">One</h1>\n<h2 id=\"two\">Two</h2>\n<h6 id=\"six\">Six</h6>\n")
        #expect(md("#NoSpace") == "<p>#NoSpace</p>\n")
        #expect(md("Title\n=====\nSub\n---") == "<h1 id=\"title\">Title</h1>\n<h2 id=\"sub\">Sub</h2>\n")
    }

    @Test func paragraphsAndBreaks() {
        #expect(md("a\nb\n\nc") == "<p>a\nb</p>\n<p>c</p>\n")
        #expect(md("hard  \nbreak") == "<p>hard<br>\nbreak</p>\n")
    }

    @Test func inlineFormatting() {
        #expect(md("*em* _em_ **strong** __strong__ ~~del~~ `co*de*`")
                == "<p><em>em</em> <em>em</em> <strong>strong</strong> <strong>strong</strong> <del>del</del> <code>co*de*</code></p>\n")
        #expect(md("snake_case_name stays") == "<p>snake_case_name stays</p>\n")
        #expect(md("***both***") == "<p><em><strong>both</strong></em></p>\n")
    }

    @Test func escapesHTMLAndBackslashes() {
        #expect(md("a < b & \"c\" \\*not em\\*") == "<p>a &lt; b &amp; &quot;c&quot; *not em*</p>\n")
        #expect(md("`<script>`") == "<p><code>&lt;script&gt;</code></p>\n")
    }

    @Test func links() {
        #expect(md("[Cedric](https://example.com/a_b \"T\")") == "<p><a href=\"https://example.com/a_b\" title=\"T\">Cedric</a></p>\n")
        #expect(md("![alt](img.png)") == "<p><img src=\"img.png\" alt=\"alt\"></p>\n")
        #expect(md("<https://x.org>") == "<p><a href=\"https://x.org\">https://x.org</a></p>\n")
        #expect(md("see https://x.org/p.") == "<p>see <a href=\"https://x.org/p\">https://x.org/p</a>.</p>\n")
        #expect(md("[x](javascript:alert(1))").contains("href=\"#\""))
    }

    @Test func fencedCodeIsEscapedAndNotParsed() {
        #expect(md("```swift\nlet a = 1 < 2 // *x*\n```") == "<pre><code class=\"language-swift\">let a = 1 &lt; 2 // *x*\n</code></pre>\n")
        #expect(md("~~~\n# not a heading\n~~~") == "<pre><code># not a heading\n</code></pre>\n")
    }

    @Test func indentedCode() {
        #expect(md("    code here\n    more") == "<pre><code>code here\nmore\n</code></pre>\n")
    }

    @Test func lists() {
        #expect(md("- a\n- b\n  - nested\n- c") == "<ul>\n<li>a</li>\n<li>b\n<ul>\n<li>nested</li>\n</ul></li>\n<li>c</li>\n</ul>\n")
        #expect(md("3. three\n4. four") == "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n")
        #expect(md("- a\n\n- b") == "<ul>\n<li><p>a</p></li>\n<li><p>b</p></li>\n</ul>\n")
        #expect(md("- [ ] todo\n- [x] done") == "<ul>\n<li><input type=\"checkbox\" disabled> todo</li>\n<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>\n")
    }

    @Test func blockquote() {
        #expect(md("> quoted *text*\n> more") == "<blockquote>\n<p>quoted <em>text</em>\nmore</p>\n</blockquote>\n")
    }

    @Test func thematicBreak() {
        #expect(md("a\n\n---\n\n* * *") == "<p>a</p>\n<hr>\n<hr>\n")
    }

    @Test func tables() {
        let out = md("| Name | Size |\n|:-----|-----:|\n| a | 1 |\n| `b|c` | 2 |")
        #expect(out == "<table>\n<thead>\n<tr><th style=\"text-align:left\">Name</th><th style=\"text-align:right\">Size</th></tr>\n</thead>\n"
                + "<tbody>\n<tr><td style=\"text-align:left\">a</td><td style=\"text-align:right\">1</td></tr>\n"
                + "<tr><td style=\"text-align:left\"><code>b|c</code></td><td style=\"text-align:right\">2</td></tr>\n</tbody>\n</table>\n")
    }

    @Test func htmlBlockPassesThrough() {
        #expect(md("<div class=\"x\">\n*raw*\n</div>\n\npara") == "<div class=\"x\">\n*raw*\n</div>\n<p>para</p>\n")
    }

    @Test func dataLineAttributesForScrollSync() {
        let html = Markdown.render("# A\n\ntext\n\n- item")
        #expect(html.contains("<h1 data-line=\"0\""))
        #expect(html.contains("<p data-line=\"2\">"))
        #expect(html.contains("<ul data-line=\"4\">"))
    }
}

@Suite struct PreviewSyncTests {
    @Test func nestedBlocksCarryTheirSourceLines() {
        let html = Markdown.render("- a\n- b\n\n  more b\n\n> q1\n>\n> q2\n")
        #expect(html.contains("<li data-line=\"0\">"))
        #expect(html.contains("<li data-line=\"1\">"))
        #expect(html.contains("<p data-line=\"3\">more b</p>"))
        #expect(html.contains("<blockquote data-line=\"5\">"))
        #expect(html.contains("<p data-line=\"7\">q2</p>"))
    }

    @Test func tightListItemsStayUnwrapped() {
        #expect(Markdown.render("- one\n- two\n") == "<ul data-line=\"0\">\n<li data-line=\"0\">one</li>\n<li data-line=\"1\">two</li>\n</ul>\n")
    }

    @Test func previewFolderServesOnlyTheDocumentsFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cedric-pf-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("docs folder")
        try fm.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let page = try #require(PreviewFolder.pageURL(for: folder))
        #expect(page.scheme == "cedric-doc")
        let inside = try #require(URL(string: "img/a%20b.png", relativeTo: page)?.absoluteURL)
        #expect(PreviewFolder.file(for: inside, in: folder)?.path == folder.appendingPathComponent("img/a b.png").path)
        let outside = try #require(URL(string: "../secret.txt", relativeTo: page)?.absoluteURL)
        #expect(PreviewFolder.file(for: outside, in: folder) == nil)
        #expect(PreviewFolder.file(for: URL(string: "cedric-doc://doc/etc/passwd")!, in: folder) == nil)
        #expect(PreviewFolder.file(for: URL(fileURLWithPath: folder.appendingPathComponent("x.png").path), in: folder) == nil)
        // A link inside the folder that points out of it is refused too.
        try fm.createSymbolicLink(at: folder.appendingPathComponent("out"), withDestinationURL: root)
        let viaLink = try #require(URL(string: "out/x.txt", relativeTo: page)?.absoluteURL)
        #expect(PreviewFolder.file(for: viaLink, in: folder) == nil)
    }
}

@Suite struct MarkdownGapsTests {
    @Test func yamlFrontmatterIsAMetadataTableNotARuleAndHeading() {
        let html = Markdown.render("---\ntitle: \"Hello\"\ntags: [a, b]\nnested:\n  - x\n---\n# Doc\n")
        // 0.5.2 (17): a collapsed <details> block (FrontMatterTests), the
        // flow and block lists as lists rather than their YAML text.
        #expect(html.hasPrefix("<details class=\"frontmatter\" data-line=\"0\">"))
        #expect(html.contains("<tr><th>title</th><td>Hello</td></tr>"))
        #expect(html.contains("<tr><th>tags</th><td><ul class=\"fm-list\"><li>a</li><li>b</li></ul></td></tr>"))
        #expect(html.contains("<tr><th>nested</th><td><ul class=\"fm-list\"><li>x</li></ul></td></tr>"))
        #expect(!html.contains("<hr") && !html.contains("<h2"))
        #expect(html.contains("<h1 data-line=\"6\" id=\"doc\">Doc</h1>"))
        // Not at the top, or never closed: a thematic break as before.
        #expect(md("text\n\n---\ntitle: x\n") == "<p>text</p>\n<hr>\n<p>title: x</p>\n")
        #expect(md("---\nno end") == "<hr>\n<p>no end</p>\n")
    }

    @Test func footnotes() {
        let html = md("Text[^1] and more[^note].\n\n[^1]: First *note*.\n[^note]: Second\n    continued.\n")
        #expect(html.contains("Text<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup> and more"))
        #expect(html.contains("<a href=\"#fn-note\" id=\"fnref-note\">2</a>"))
        #expect(html.contains("<section class=\"footnotes\">"))
        #expect(html.contains("<li id=\"fn-1\">\n<p>First <em>note</em>. <a href=\"#fnref-1\" class=\"footnote-backref\">↩</a></p>"))
        #expect(html.contains("<li id=\"fn-note\">\n<p>Second\ncontinued."))
        #expect(!html.contains("[^1]:"))
        // Undefined: left as text.
        #expect(md("see [^missing]") == "<p>see [^missing]</p>\n")
    }

    @Test func referenceLinks() {
        let src = "[Cedric][c], [c], [C][] and ![logo][img].\n\n[c]: https://c.example/a_b \"The *title*\"\n[img]: <logo one.png>\n"
        #expect(md(src) == "<p><a href=\"https://c.example/a_b\" title=\"The *title*\">Cedric</a>, "
                + "<a href=\"https://c.example/a_b\" title=\"The *title*\">c</a>, <a href=\"https://c.example/a_b\" title=\"The *title*\">C</a>"
                + " and <img src=\"logo one.png\" alt=\"logo\">.</p>\n")
        // Definitions inside code stay code; unknown labels stay text.
        #expect(md("```\n[c]: /x\n```\n[nope] [c]") == "<pre><code>[c]: /x\n</code></pre>\n<p>[nope] [c]</p>\n")
    }

    @Test func githubAlerts() {
        let html = md("> [!WARNING]\n> Mind the *gap*.\n\n> [!note]\n> ok\n\n> [!BOGUS]\n> x")
        #expect(html.contains("<div class=\"markdown-alert markdown-alert-warning\">\n<p class=\"markdown-alert-title\">Warning</p>\n<p>Mind the <em>gap</em>.</p>\n</div>"))
        #expect(html.contains("markdown-alert-note"))
        #expect(html.contains("<blockquote>\n<p>[!BOGUS]\nx</p>\n</blockquote>"))
    }

    @Test func nestedEmphasisFollowsCommonMark() {
        #expect(md("**bold *mix***") == "<p><strong>bold <em>mix</em></strong></p>\n")
        #expect(md("*a **b** c*") == "<p><em>a <strong>b</strong> c</em></p>\n")
        #expect(md("***a** b*") == "<p><em><strong>a</strong> b</em></p>\n")
        #expect(md("**a*") == "<p>*<em>a</em></p>\n")
        #expect(md("snake_case_name and 2*3*4") == "<p>snake_case_name and 2<em>3</em>4</p>\n")
        #expect(md("*em\nacross lines*") == "<p><em>em\nacross lines</em></p>\n")
        #expect(md("~~gone~~ ~kept~ ~~~x~~~") == "<p><del>gone</del> <del>kept</del> ~~~x~~~</p>\n")
        #expect(md("**not closed") == "<p>**not closed</p>\n")
    }

    @Test func linksWithMarkupInside() {
        #expect(md("[![badge](b.svg)](https://ci.example) *[em link](/x)*")
                == "<p><a href=\"https://ci.example\"><img src=\"b.svg\" alt=\"badge\"></a> <em><a href=\"/x\">em link</a></em></p>\n")
        #expect(md("[a **b**](https://en.wikipedia.org/wiki/Foo_(bar))")
                == "<p><a href=\"https://en.wikipedia.org/wiki/Foo_(bar)\"><strong>b</strong></a></p>\n".replacingOccurrences(of: "><strong>", with: ">a <strong>"))
        #expect(md("see https://x.org/a_(b)_c, ok") == "<p>see <a href=\"https://x.org/a_(b)_c\">https://x.org/a_(b)_c</a>, ok</p>\n")
    }

    @Test func taskListsAndHeadingAnchors() {
        #expect(md("- [x] done\n- [ ] todo").contains("<input type=\"checkbox\" checked disabled> done"))
        let html = md("# Intro\n## Intro\n## *Fancy* `code`")
        #expect(html.contains("<h1 id=\"intro\">") && html.contains("<h2 id=\"intro-1\">"))
        #expect(html.contains("<h2 id=\"fancy-code\">"))
    }
}

@Suite struct CodeHTMLTests {
    @Test func spansFromCedricsTokenizers() {
        #expect(CodeHTML.highlight("let a = \"<b>\" // x & y", language: .swift)
                == "<span class=\"tk-keyword\">let</span> a = <span class=\"tk-string\">&quot;&lt;b&gt;&quot;</span> <span class=\"tk-comment\">// x &amp; y</span>")
        #expect(CodeHTML.highlight("/* a\nb */ x", language: .c) == "<span class=\"tk-comment\">/* a</span>\n<span class=\"tk-comment\">b */</span> x")
        #expect(CodeHTML.highlight("<a> & b", language: .plain) == "&lt;a&gt; &amp; b")
    }

    @Test func previewColoursFencesPlainRenderDoesNot() {
        let src = "```swift\nlet a = 1\n```\n\n```\nlet a = 1\n```"
        let html = Markdown.render(src, options: .preview)
        #expect(html.contains("<code class=\"language-swift\"><span class=\"tk-keyword\">let</span> a = <span class=\"tk-number\">1</span>\n</code>"))
        #expect(html.contains("<code>let a = 1\n</code>"))
        #expect(!Markdown.render(src).contains("tk-"))
    }
}
