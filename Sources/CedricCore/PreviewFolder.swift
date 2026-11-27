import Foundation

/// The preview page's view of the document's folder. The page's base URL
/// is `cedric-doc://doc/<folder>/`, so relative images, styles and links
/// resolve into it, and the app serves files from that folder (and its
/// subfolders) only. (A plain `file:` base gives a WKWebView page no
/// access at all, and loadFileURL would need the page itself on disk.)
public enum PreviewFolder {
    public static let scheme = "cedric-doc"

    /// The page URL for a document in `folder`.
    public static func pageURL(for folder: URL) -> URL? {
        let path = folder.standardizedFileURL.path
        var c = URLComponents()
        c.scheme = scheme
        c.host = "doc"
        c.path = path.hasSuffix("/") ? path : path + "/"
        return c.url
    }

    /// The file a page URL stands for (nil for any other URL).
    public static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// `url`'s file, if it lies inside `folder` (after `..` and symbolic links).
    public static func file(for url: URL, in folder: URL) -> URL? {
        guard let file = fileURL(for: url), isInside(resolved(file), resolved(folder.standardizedFileURL)) else { return nil }
        return file
    }

    /// Whether `target` lies below `root` (not `root` itself), both already
    /// resolved: compared by UTF-8 bytes with a `/` byte at the boundary
    /// (`FolderTree.relativePath`), not as Swift text, which makes a slash
    /// and a following combining mark one character and calls canonically
    /// equivalent but byte-distinct names equal (Astra batch 9b).
    static func isInside(_ target: URL, _ root: URL) -> Bool {
        guard let rel = FolderTree.relativePath(of: target, in: root) else { return false }
        return !rel.isEmpty
    }

    /// What a page with JavaScript on may still load from its folder:
    /// images, fonts and style sheets. Script could otherwise read any
    /// file next to the document (a `.env`, `.git/config`, `~/.ssh` for a
    /// file in home) and, with Network on, send it out.
    public static let scriptSafeExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "bmp", "ico", "tif", "tiff", "svg",
        "woff", "woff2", "ttf", "otf",
        "css",
    ]

    /// `url`'s file, as `file(for:in:)`, and with `scriptOn` only an image,
    /// font or CSS file, never a dotfile or anything under a dot folder
    /// (`.git`, `.ssh`), judged on both the path asked for and the path
    /// its symbolic links lead to.
    public static func file(for url: URL, in folder: URL, scriptOn: Bool) -> URL? {
        guard let file = file(for: url, in: folder) else { return nil }
        guard scriptOn else { return file }
        // The names below `base` (the whole path when it isn't below it),
        // split at "/" bytes, none starting with a "." byte: as Swift
        // text a dot followed by a combining mark isn't a "." prefix, and
        // a slash followed by one doesn't split (Astra batch 9b).
        func ok(_ path: URL, under base: URL) -> Bool {
            let parts = FolderTree.components(FolderTree.relativePath(of: path, in: base) ?? path.path)
            guard let last = parts.last, !parts.contains(where: { $0.utf8.first == 0x2e }) else { return false }
            let ext = (last as NSString).pathExtension.lowercased()
            return scriptSafeExtensions.contains(ext)
        }
        return ok(file, under: folder.standardizedFileURL) && ok(resolved(file), under: resolved(folder.standardizedFileURL)) ? file : nil
    }

    /// `url` with symbolic links resolved, also when its last parts don't
    /// exist (resolvingSymlinksInPath leaves such a path as it is).
    public static func resolved(_ url: URL) -> URL {
        var head = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.path != "/" {
            tail.insert(head.lastPathComponent, at: 0)
            head.deleteLastPathComponent()
        }
        var r = head.resolvingSymlinksInPath()
        for part in tail { r.appendPathComponent(part) }
        return r
    }
}

/// Where to cut a tall rendered page into PDF pages: at the lowest block
/// bottom that fits on each page (so no line is cut in two), or at the
/// page height when no block ends on it.
public enum PageBreaks {
    public static func cuts(total: CGFloat, pageHeight h: CGFloat, boundaries: [CGFloat]) -> [CGFloat] {
        guard total > 0, h > 0 else { return [0, max(total, 1)] }
        let sorted = Array(Set(boundaries.filter { $0 > 0 && $0 < total })).sorted()
        var cuts: [CGFloat] = [0]
        var y: CGFloat = 0
        while total - y > h {
            // Not less than half a page, so a page is never nearly empty.
            let best = sorted.last { $0 <= y + h && $0 >= y + h / 2 }
            y = best ?? y + h
            cuts.append(y)
        }
        cuts.append(total)
        return cuts
    }
}

/// What a click on a preview link does (security audit H2). Nothing a
/// link names is ever launched: web and mail links open only after the
/// user confirms the full URL, a text file inside the document's folder
/// opens in Cedric, any other local file is only shown in Finder, and
/// every other scheme is ignored.
public enum PreviewLinkAction: Equatable, Sendable {
    /// A Markdown or HTML file inside the document's folder: shown in the preview.
    case openInPreview(URL)
    /// http, https or mailto: ask first, showing the whole URL, then hand it
    /// to the system. A web page never loads inside the preview (0.5.2 S1),
    /// where the JavaScript and Network settings could not apply to it.
    case confirmExternal(URL)
    /// A text file inside the document's folder (symbolic links resolved).
    case openInCedric(URL)
    /// Any other local file or folder, or one outside the document's folder.
    case revealInFinder(URL)
    /// A scheme Cedric doesn't follow, or a file that isn't there.
    case ignore(String)

    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// Preview browsing uses the same confinement and special-file rules as
    /// the editor/PDF routes. Only local Markdown and HTML open in the
    /// preview (⌘-click opens them in a tab instead); web and mail links
    /// always ask first, clicked or ⌘-clicked.
    public static func previewAction(for url: URL, folder: URL?, command: Bool, isText: (URL) -> Bool,
                                     fileManager fm: FileManager = .default) -> PreviewLinkAction {
        let action = action(for: url, folder: folder, isText: isText, fileManager: fm)
        switch action {
        case .openInCedric(let u) where !command:
            let language = LanguageDetector.language(forFileName: u.lastPathComponent)
            return language == .markdown || language == .html ? .openInPreview(u) : action
        default: return action
        }
    }

    /// `folder`: the document's folder (nil for an untitled document).
    /// `isText`: whether Cedric edits a file of that name and kind.
    public static func action(for url: URL, folder: URL?, isText: (URL) -> Bool,
                              fileManager fm: FileManager = .default) -> PreviewLinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        if externalSchemes.contains(scheme) {
            if scheme != "mailto", url.host?.isEmpty ?? true { return .ignore(scheme) }
            return .confirmExternal(url)
        }
        let file: URL
        if scheme == PreviewFolder.scheme, let f = PreviewFolder.fileURL(for: url) {
            file = f
        } else if url.isFileURL {
            file = url.standardizedFileURL
        } else {
            return .ignore(scheme.isEmpty ? "?" : scheme)
        }
        let target = PreviewFolder.resolved(file)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else { return .ignore("missing") }
        guard let folder else { return .revealInFinder(file) }
        let inside = PreviewFolder.isInside(target, PreviewFolder.resolved(folder.standardizedFileURL))
        // A folder (an .app bundle is one) is never opened, only shown.
        if inside, !isDir.boolValue, isText(target) { return .openInCedric(file) }
        return .revealInFinder(file)
    }
}

extension PreviewLinkAction {
    /// The document a linked preview page shows (0.5.1 S3): `url` with its
    /// symbolic links resolved once, that path checked (a Markdown or HTML
    /// file inside `root`) and that same path read, so a link swapped
    /// after the check can't point the read outside `root`. `file` is that
    /// path (its kind and folder are the page's). Nil when it isn't one.
    /// `read` is the file read (a test swaps a link inside it).
    public static func previewDocument(at url: URL, root: URL, isText: (URL) -> Bool,
                                       read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> (file: URL, data: Data)? {
        let target = PreviewFolder.resolved(url)
        guard case .openInPreview = previewAction(for: target, folder: root, command: false, isText: isText),
              let data = read(target) else { return nil }
        return (target, data)
    }

    /// A link clicked in a PDF: stricter than the Markdown preview's, as a
    /// PDF has no folder of its own. http, https and mailto ask first; a
    /// `file:` link is only shown in Finder, never opened (not even a text
    /// file); every other scheme, `cedric-doc:` included, is ignored.
    public static func pdfAction(for url: URL, fileManager fm: FileManager = .default) -> PreviewLinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        if externalSchemes.contains(scheme) || url.isFileURL {
            return action(for: url, folder: nil, isText: { _ in false }, fileManager: fm)
        }
        return .ignore(scheme.isEmpty ? "?" : scheme)
    }
}

/// Text from outside (a link's path or URL) made safe to show in a prompt:
/// control characters and the bidirectional overrides and isolates that
/// could make `~/.ssh/id_ed25519` read as something else are shown as
/// visible `<U+202E>` escapes instead of acting on the text around them.
public enum PromptText {
    static func isHidden(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F: return true          // C0 and C1 controls
        case 0x200B...0x200F: return true                  // zero-width chars, LRM, RLM
        case 0x2028...0x202E: return true                  // line/para separators, LRE…RLO
        case 0x2060...0x206F: return true                  // word joiner, invisible operators, LRI…PDI
        case 0x061C, 0xFEFF: return true                   // Arabic letter mark, BOM
        default: return false
        }
    }

    public static func visible(_ text: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars {
            if isHidden(s) {
                out += String(format: "<U+%04X>", s.value)
            } else {
                out.unicodeScalars.append(s)
            }
        }
        return out
    }
}
