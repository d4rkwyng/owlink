import Foundation
import Testing
@testable import CedricCore

@Suite struct MarkdownExportTests {
    @Test func copyRenderersScrubScriptsAndRichTextRemoteResources() {
        let markdown = #"<script>alert(1)</script><img src="https://evil.example/x.png" onerror="bad()"> **safe**"#
        let fragment = HTMLScrub.noScript(Markdown.render(markdown, options: .export(vault: nil)))
        #expect(!fragment.localizedCaseInsensitiveContains("<script"))
        #expect(!fragment.localizedCaseInsensitiveContains("onerror"))
        let page = HTMLScrub.noScriptNoRemote(MarkdownExport.page(markdown: markdown, title: "x"))
        #expect(!page.localizedCaseInsensitiveContains("<script"))
        #expect(!page.localizedCaseInsensitiveContains("onerror"))
        #expect(!page.contains("https://evil.example/x.png"))
        #expect(page.contains("safe"))
    }

    @Test func fileNamesUseTheDisplayNameWithoutItsExtension() {
        #expect(MarkdownExport.fileName(displayName: "report.md", ext: "html") == "report.html")
        #expect(MarkdownExport.fileName(displayName: "report", ext: "pdf") == "report.pdf")
        #expect(MarkdownExport.baseName(displayName: ".md") == ".md")
        #expect(MarkdownExport.fileName(displayName: ".md", ext: "html") == ".md.html")
    }

    @Test func pageIsStandaloneLightAndHasNoScripts() {
        let html = MarkdownExport.page(markdown: "# Hello", title: "Report")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<title>Report</title>"))
        #expect(html.contains("color-scheme: light"))
        #expect(html.contains("script-src 'none'"))
        #expect(!html.localizedCaseInsensitiveContains("<script"))
        #expect(html.contains("</html>"))
    }

    @Test func hostileMarkdownIsScrubbedButLocalImageIsKept() {
        let html = MarkdownExport.page(
            markdown: #"<script>alert(1)</script><img src="a.png" onerror="alert(2)">"#,
            title: "Safe"
        )
        #expect(!html.localizedCaseInsensitiveContains("<script"))
        #expect(!html.localizedCaseInsensitiveContains("onerror"))
        #expect(html.contains("a.png"))
    }

    @Test func pageUsesThePreviewRendererAndEscapesItsTitle() {
        let markdown = """
        ---
        title: Example
        ---

        ```swift
        let value = 1
        ```

        A note.[^1]

        [^1]: Footnote text.
        """
        let html = MarkdownExport.page(markdown: markdown, title: "A < B & C")
        #expect(html.contains("class=\"frontmatter\""))
        #expect(html.contains("tk-keyword"))
        #expect(html.contains("id=\"fn-1\""))
        #expect(html.contains("<title>A &lt; B &amp; C</title>"))
        #expect(!html.contains("<title>A < B & C</title>"))
    }

    @Test func hostileURLsAndFramesAreScrubbed() {
        let html = MarkdownExport.page(
            markdown: #"[go](javascript:alert(1))<iframe src="https://evil.example"></iframe><svg onload="alert(2)"></svg><meta http-equiv="refresh" content="0;url=https://evil.example">"#,
            title: "x"
        )
        #expect(!html.localizedCaseInsensitiveContains("<script"))
        #expect(!html.localizedCaseInsensitiveContains("javascript:"))
        #expect(!html.localizedCaseInsensitiveContains("<iframe"))
        #expect(!html.localizedCaseInsensitiveContains("onload"))
        #expect(!html.localizedCaseInsensitiveContains(#"http-equiv="refresh""#))
        #expect(!html.localizedCaseInsensitiveContains("url=https://evil.example"))
    }

    @Test func sandboxedPageUsesPreviewCSPAndKeepsLinks() {
        let markdown = #"[go](https://example.com)<img src="https://evil.example/t.png"><img src="a.png">"#
        let html = MarkdownExport.page(markdown: markdown, title: "x", remote: false)
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("https://example.com"))
        #expect(html.contains("a.png"))
        let exported = MarkdownExport.page(markdown: markdown, title: "x")
        #expect(exported.contains("script-src 'none'"))
        #expect(!exported.contains("default-src 'none'"))
        #expect(exported.contains("https://example.com"))
        #expect(exported.contains("a.png"))
    }
}
