import Foundation

/// The standalone light page used by Markdown HTML and PDF exports.
public enum MarkdownExport {
    public static let csp = "script-src 'none'; object-src 'none'; frame-src 'none'"

    public static func baseName(displayName: String) -> String {
        let base = (displayName as NSString).deletingPathExtension
        return base.isEmpty ? displayName : base
    }

    public static func fileName(displayName: String, ext: String) -> String {
        baseName(displayName: displayName) + "." + ext
    }

    public static func page(markdown: String, title: String, vault: WikiVault? = nil) -> String {
        PreviewHTML.page(
            body: HTMLScrub.noScript(Markdown.render(markdown, options: .export(vault: vault))),
            palette: EditorPalettes.light,
            csp: csp,
            title: title
        )
    }
}
