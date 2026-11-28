import Foundation
import WebKit
import CedricCore

/// Serves the bundled Mermaid and KaTeX files (`Owlink.app/Preview`, from
/// Resources/Preview) to the preview at `cedric-asset://vendor/…`, as the
/// Mac's PreviewAssets: only the fixed files `PreviewRich.assetPath`
/// allows, and only while the page being shown asked for them (Draw
/// Diagrams and Math on, the page has a diagram or math). Anything else
/// is refused. Nothing is fetched from the network.
final class PreviewRichAssets: NSObject, WKURLSchemeHandler {
    /// The current page may load the bundled files.
    var scriptOn = false
    /// Served and refused paths (tests).
    private(set) var served: [String] = []
    private(set) var refused = 0

    /// The bundle's Preview folder, or nil when it is missing (fails closed).
    /// The app's bundle (the snapshot tests compile these sources into
    /// their own bundle, which carries the same folder).
    static let directory: URL? = {
        [Bundle.main, Bundle(for: PreviewRichAssets.self)].lazy
            .compactMap { $0.resourceURL?.appendingPathComponent("Preview") }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(PreviewRich.glueScript).path) }
    }()

    static var available: Bool { directory != nil }

    static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension {
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard scriptOn, let url = task.request.url, let rel = PreviewRich.assetPath(for: url), let dir = Self.directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent(rel), options: .mappedIfSafe) else {
            refused += 1
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        if served.count < 64 { served.append(rel) }
        task.didReceive(URLResponse(url: url, mimeType: Self.mimeType(rel), expectedContentLength: data.count,
                                    textEncodingName: rel.hasSuffix(".woff2") ? nil : "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

extension PreviewController {
    /// The page's policy with the bundled files `needs` asks for: their
    /// exact URLs in script-src (no inline or page scripts: the page's own
    /// stay stripped and blocked), KaTeX's style sheet and font folder.
    /// The rest is the preview's strict policy (`csp`), connect-src 'none'.
    static func richCSP(_ needs: PreviewRich.Needs) -> String {
        guard !needs.isEmpty else { return csp }
        let base = "\(PreviewRich.scheme)://\(PreviewRich.host)/"
        var scripts: [String] = []
        if needs.contains(.math) { scripts.append(base + PreviewRich.katexScript) }
        if needs.contains(.mermaid) { scripts.append(base + PreviewRich.mermaidScript) }
        scripts.append(base + PreviewRich.glueScript)
        let style = "'unsafe-inline'" + (needs.contains(.math) ? " " + base + PreviewRich.katexStyle : "")
        let font = "data:" + (needs.contains(.math) ? " " + base + "katex/fonts/" : "")
        return "default-src 'none'; img-src data: \(PreviewFolder.scheme):; media-src data: \(PreviewFolder.scheme):; style-src \(style); font-src \(font); script-src \(scripts.joined(separator: " ")); connect-src 'none'"
    }

    /// `page` with the bundled tags: KaTeX's style sheet in the head, the
    /// libraries and the glue at the end of the body.
    static func richPage(_ page: String, needs: PreviewRich.Needs, dark: Bool) -> String {
        guard !needs.isEmpty else { return page }
        var out = page
        let head = PreviewRich.headTags(needs)
        if !head.isEmpty, let r = out.range(of: "</head>") { out.replaceSubrange(r, with: head + "</head>") }
        let tail = PreviewRich.tailTags(needs, dark: dark)
        if let r = out.range(of: "</body>", options: .backwards) { out.replaceSubrange(r, with: tail + "</body>") } else { out += tail }
        return out
    }
}
