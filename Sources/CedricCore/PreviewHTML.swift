import Foundation

/// The Markdown preview's page around `Markdown.render`'s body: the
/// palette's colours as CSS, and an optional Content-Security-Policy.
/// Shared by the Mac's preview pane and export and the iOS preview.
public enum PreviewHTML {
    public static func hex(_ c: UInt32) -> String { String(format: "#%06x", c) }

    /// The whole page. `csp` nil: none (an exported file). `viewport`:
    /// laid out at the device's width (iOS; without it WebKit lays the page
    /// out 980 px wide and scales it down to fit, shrinking the text).
    public static func page(body: String, palette p: EditorPalette, csp: String?, title: String? = nil,
                            viewport: Bool = false) -> String {
        var meta = csp.map { "<meta http-equiv=\"Content-Security-Policy\" content=\"\($0)\">\n" } ?? ""
        if viewport { meta += viewportMeta + "\n" }
        let titleTag = title.map { "<title>\(Markdown.escape($0))</title>\n" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        \(meta)\(titleTag)<style>
        \(styles(p))
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    /// Device width, no WebKit pinch zoom (the app's pinch sets the text size).
    public static let viewportMeta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no\">"

    public static func styles(_ p: EditorPalette) -> String {
        """
        :root { color-scheme: \(p.isDark ? "dark" : "light"); }
        body { font: 15px/1.55 -apple-system, system-ui, sans-serif; color: \(hex(p.foreground)); background: \(hex(p.background));
               max-width: 820px; margin: 0 auto; padding: 18px 24px 60px; }
        h1, h2 { border-bottom: 1px solid \(hex(p.currentLine)); padding-bottom: .25em; }
        h1, h2, h3, h4, h5, h6 { color: \(hex(p.color(for: .heading))); line-height: 1.25; margin: 1.2em 0 .5em; }
        a { color: \(hex(p.color(for: .link))); }
        code, pre { font: 13px ui-monospace, "SF Mono", Menlo, monospace; background: \(hex(p.currentLine)); border-radius: 4px; }
        code { padding: .1em .35em; }
        pre { padding: 10px 12px; overflow-x: auto; }
        pre code { padding: 0; background: none; }
        blockquote { margin: 0; padding: 0 1em; color: \(hex(p.color(for: .comment))); border-left: 4px solid \(hex(p.currentLine)); }
        table { border-collapse: collapse; }
        th, td { border: 1px solid \(hex(p.currentLine)); padding: 4px 10px; }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid \(hex(p.currentLine)); }
        table.frontmatter { font-size: 12px; margin: 0 0 1.2em; color: \(hex(p.color(for: .comment))); }
        table.frontmatter th { text-align: left; font-weight: 600; color: \(hex(p.color(for: .key))); vertical-align: top; }
        table.frontmatter td { white-space: pre-wrap; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        details.frontmatter { font-size: 12px; margin: 0 0 1.2em; color: \(hex(p.color(for: .comment))); }
        details.frontmatter > summary { cursor: pointer; font-weight: 600; color: \(hex(p.color(for: .key))); padding: 2px 0; }
        details.frontmatter > table.frontmatter { margin: .4em 0 0; }
        table.fm-map { font-size: inherit; margin: 0; }
        table.fm-map th { text-align: left; font-weight: 600; color: \(hex(p.color(for: .key))); vertical-align: top; }
        ul.fm-list { margin: 0; padding-left: 1.2em; }
        li:has(> input[type=checkbox]) { list-style: none; }
        li > input[type=checkbox] { margin: 0 .4em 0 -1.3em; }
        .markdown-alert { padding: .1em 1em; margin: 1em 0; border-left: 4px solid var(--alert); }
        .markdown-alert-title { font-weight: 600; color: var(--alert); margin: .5em 0; }
        .markdown-alert-note { --alert: #4493f8; } .markdown-alert-tip { --alert: #3fa34d; }
        .markdown-alert-important { --alert: #a371f7; } .markdown-alert-warning { --alert: #d29922; }
        .markdown-alert-caution { --alert: #e5534b; }
        .markdown-alert-abstract, .markdown-alert-info, .markdown-alert-todo { --alert: #4493f8; }
        .markdown-alert-success { --alert: #3fa34d; } .markdown-alert-question { --alert: #d29922; }
        .markdown-alert-failure, .markdown-alert-danger, .markdown-alert-bug { --alert: #e5534b; }
        .markdown-alert-example { --alert: #a371f7; } .markdown-alert-quote { --alert: #8b949e; }
        details.callout > summary { cursor: pointer; } .callout-icon { font-style: normal; }
        a.wikilink { text-decoration: none; border-bottom: 1px solid; }
        a.wikilink.is-unresolved { opacity: .6; border-bottom-style: dashed; cursor: default; }
        mark { background: #f2cc6066; color: inherit; border-radius: 2px; padding: 0 .1em; }
        span.tag { color: \(hex(p.color(for: .link))); background: \(hex(p.currentLine)); border-radius: 1em; padding: 0 .5em; font-size: .9em; }
        blockquote.embed { border-left-color: \(hex(p.color(for: .link))); }
        .embed-title { font-size: 12px; margin: .5em 0; }
        p.preview-hint { font-size: 12px; color: \(hex(p.color(for: .comment))); text-align: center; margin: 0 0 1em; }
        sup.footnote-ref a { text-decoration: none; }
        section.footnotes { font-size: 13px; color: \(hex(p.color(for: .comment))); }
        \(TokenKind.allCases.filter { $0 != .plain }.map { ".tk-\($0) { color: \(hex(p.color(for: $0))); }" }.joined(separator: " "))
        .tk-comment { font-style: italic; }
        """
    }
}
