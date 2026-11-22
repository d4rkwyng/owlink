import Foundation
import Testing
@testable import CedricCore

@Suite struct MarkdownExportTests {
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
}
