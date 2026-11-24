import Foundation
import Testing
@testable import CedricCore

/// The preview page builder, shared by the Mac preview and the iOS app.
@Suite struct PreviewHTMLTests {
    @Test func pageWrapsBodyWithPaletteAndCSP() {
        let html = PreviewHTML.page(body: "<p>hi</p>", palette: EditorPalettes.dracula, csp: "default-src 'none'", title: "T")
        #expect(html.contains("<p>hi</p>"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("<title>T</title>"))
        #expect(html.contains("color-scheme: dark"))
        #expect(html.contains(PreviewHTML.hex(EditorPalettes.dracula.background)))
    }

    @Test func noCSPWhenNil() {
        let html = PreviewHTML.page(body: "", palette: EditorPalettes.light, csp: nil)
        #expect(!html.contains("Content-Security-Policy"))
        #expect(html.contains("color-scheme: light"))
    }

    /// Codex review of 0.5.2 (17), should-fix 2: the front matter summary
    /// is one line however long the title, cut with an ellipsis; the whole
    /// title stays its text (what VoiceOver reads).
    @Test func frontMatterSummaryIsOneLine() {
        let css = PreviewHTML.styles(EditorPalettes.light)
        guard let rule = css.split(separator: "\n").first(where: { $0.contains("details.frontmatter > summary") }) else {
            Issue.record("no summary rule"); return
        }
        #expect(rule.contains("white-space: nowrap") && rule.contains("overflow: hidden") && rule.contains("text-overflow: ellipsis"))
        let title = String(repeating: "Owls of the World ", count: 12).trimmingCharacters(in: .whitespaces)
        let html = Markdown.render("---\ntitle: \(title)\n---\n", options: .preview(vault: nil))
        #expect(html.contains("<summary>Front matter · \(title)</summary>"))
    }
}
