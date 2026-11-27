import Foundation

/// Mermaid diagrams and KaTeX math in the Markdown preview, only with the
/// preview's Allow JavaScript on. Both libraries ship inside the app
/// (Resources/Preview, docs/THIRD_PARTY.md) and are served to the page by
/// the app's own `cedric-asset://vendor/…` scheme handler, which hands out
/// the fixed files below and nothing else; nothing is fetched from the
/// network. A page whose Markdown has no ```` ```mermaid ```` block and no
/// math gets none of this: the same HTML and the same
/// Content-Security-Policy as without it.
public enum PreviewRich {
    public static let scheme = "cedric-asset"
    public static let host = "vendor"
    static let base = "\(scheme)://\(host)/"

    /// What a rendered body needs.
    public struct Needs: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let mermaid = Needs(rawValue: 1)
        public static let math = Needs(rawValue: 2)
    }

    public static let mermaidScript = "mermaid/mermaid.min.js"
    public static let katexScript = "katex/katex.min.js"
    public static let katexStyle = "katex/katex.min.css"
    public static let glueScript = "owlink-rich.js"
    static let katexFonts = "katex/fonts/"
    static let fontNames: Set<String> = [
        "AMS-Regular", "Caligraphic-Bold", "Caligraphic-Regular", "Fraktur-Bold", "Fraktur-Regular", "Main-Bold",
        "Main-BoldItalic", "Main-Italic", "Main-Regular", "Math-BoldItalic", "Math-Italic", "SansSerif-Bold",
        "SansSerif-Italic", "SansSerif-Regular", "Script-Regular", "Size1-Regular", "Size2-Regular", "Size3-Regular",
        "Size4-Regular", "Typewriter-Regular",
    ]

    /// Every file the scheme handler may serve, relative to Resources/Preview.
    public static let files: Set<String> = Set([mermaidScript, katexScript, katexStyle, glueScript]
        + fontNames.map { "\(katexFonts)KaTeX_\($0).woff2" })

    /// The page's root attribute the glue script sets to "done" once every
    /// diagram and formula is drawn (or has failed and shows its error).
    public static let doneAttribute = "data-owlink-rich"

    /// What `body` (Markdown.render's output) holds: a mermaid fence
    /// (`<code class="language-mermaid">`) or math (Options.math's spans
    /// and blocks).
    public static func needs(body: String) -> Needs {
        var n: Needs = []
        if body.range(of: "<code class=\"language-mermaid\">", options: .caseInsensitive) != nil { n.insert(.mermaid) }
        if body.contains("class=\"math math-") { n.insert(.math) }
        return n
    }

    /// The file a `cedric-asset://vendor/<path>` URL names, relative to
    /// Resources/Preview: only one of `files`, nothing else (no `..`, no
    /// other host, no query).
    public static func assetPath(for url: URL) -> String? {
        guard url.scheme == scheme, url.host == host, url.query == nil, url.user == nil, url.port == nil,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path else { return nil }
        let rel = String(path.drop { $0 == "/" })
        return files.contains(rel) ? rel : nil
    }

    /// The preview's Content-Security-Policy. With `needs` empty it is the
    /// policy the preview has always had. Otherwise (JavaScript on), the
    /// exact URLs of the bundled scripts, KaTeX's style sheet and its font
    /// folder are added, and no other source. `pageScripts` false (an
    /// export): the page's own scripts stay off, only the bundled ones run.
    public static func csp(allowJavaScript: Bool, allowNetwork: Bool, needs: Needs = [], pageScripts: Bool = true) -> String {
        let net = allowNetwork ? " https: http:" : ""
        let doc = " \(PreviewFolder.scheme): file:"
        let bundled = allowJavaScript ? needs : []
        var script = allowJavaScript && pageScripts ? "'unsafe-inline'\(doc)\(net)" : "'none'"
        var style = "'unsafe-inline'\(doc)\(net)"
        var font = "\(doc) data:\(net)"
        if !bundled.isEmpty {
            var urls: [String] = []
            if bundled.contains(.math) { urls.append(base + katexScript) }
            if bundled.contains(.mermaid) { urls.append(base + mermaidScript) }
            urls.append(base + glueScript)
            script = (script == "'none'" ? "" : script + " ") + urls.joined(separator: " ")
            if bundled.contains(.math) {
                style += " " + base + katexStyle
                font += " " + base + katexFonts
            }
        }
        return "default-src 'none'; img-src\(doc) data:\(net); media-src\(doc) data:\(net); style-src \(style); font-src\(font); script-src \(script); connect-src \(allowNetwork ? "*" : "'none'")"
    }

    /// What goes at the end of `<head>`: KaTeX's style sheet ("" without math).
    public static func headTags(_ needs: Needs) -> String {
        needs.contains(.math) ? "<link rel=\"stylesheet\" href=\"\(base + katexStyle)\">\n" : ""
    }

    /// What goes at the end of `<body>`: the libraries, then the glue that
    /// draws each diagram and formula ("" for no needs). `dark`: Mermaid's
    /// dark theme.
    public static func tailTags(_ needs: Needs, dark: Bool) -> String {
        guard !needs.isEmpty else { return "" }
        var s = ""
        if needs.contains(.math) { s += "<script src=\"\(base + katexScript)\"></script>\n" }
        if needs.contains(.mermaid) { s += "<script src=\"\(base + mermaidScript)\"></script>\n" }
        s += "<script src=\"\(base + glueScript)\" data-dark=\"\(dark ? 1 : 0)\"></script>\n"
        return s
    }
}
