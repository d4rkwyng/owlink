import Foundation

/// The standalone light page used by Markdown HTML and PDF exports.
public enum MarkdownExport {
    /// File › Export as HTML: script, objects and frames are forbidden.
    /// Remote images stay, as on the Mac's saved HTML file.
    public static let csp = "script-src 'none'; object-src 'none'; frame-src 'none'"

    /// Print and PDF: nothing is loaded from the network (the Mac's PDF
    /// goes through the preview, which uses this policy).
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

    /// `remote` false: also drop network URLs, for print and PDF.
    public static func page(markdown: String, title: String, vault: WikiVault? = nil, remote: Bool) -> String {
        let rendered = Markdown.render(markdown, options: .export(vault: vault))
        let body = remote ? HTMLScrub.noScript(rendered) : HTMLScrub.noScriptNoRemote(rendered)
        return PreviewHTML.page(body: body, palette: EditorPalettes.light, csp: remote ? csp : sandboxedCSP, title: title)
    }
}
