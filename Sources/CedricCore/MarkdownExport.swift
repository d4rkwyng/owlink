import Foundation

/// The standalone light page used by Markdown HTML and PDF exports.
public enum MarkdownExport {
    /// File › Export as HTML: script, objects and frames are forbidden.
    /// Remote images stay, as on the Mac's saved HTML file.
    public static let csp = "script-src 'none'; object-src 'none'; frame-src 'none'"

    /// Print and PDF: the preview CSP, so the web view loads nothing from
    /// the network. External links stay in the HTML, as on the Mac's PDF.
    public static let sandboxedCSP = "default-src 'none'; img-src data: \(PreviewFolder.scheme):; media-src data: \(PreviewFolder.scheme):; style-src 'unsafe-inline'; font-src data:; script-src 'none'; connect-src 'none'"

    public static func baseName(displayName: String) -> String {
        let base = (displayName as NSString).deletingPathExtension
        return base.isEmpty ? displayName : base
    }

    public static func fileName(displayName: String, ext: String) -> String {
        baseName(displayName: displayName) + "." + ext
    }

    public static func page(markdown: String, title: String, vault: WikiVault? = nil) -> String {
        page(markdown: markdown, title: title, vault: vault, remote: true)
    }

    /// `remote` false: print and PDF use the preview CSP. Scripts are still
    /// scrubbed; https links are kept (the Mac's PDF does not use
    /// `noScriptNoRemote`).
    public static func page(markdown: String, title: String, vault: WikiVault? = nil, remote: Bool) -> String {
        let body = HTMLScrub.noScript(Markdown.render(markdown, options: .export(vault: vault)))
        return PreviewHTML.page(body: body, palette: EditorPalettes.light, csp: remote ? csp : sandboxedCSP, title: title)
    }
}
