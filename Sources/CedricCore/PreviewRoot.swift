import Foundation

/// Where a site-root-absolute path (`/images/logo.webp`, as a static site
/// generator writes it) lives on disk, for the preview. Files only, never
/// the network.
///
/// The search, first hit wins:
/// 1. the document's own folder, then each folder above it (up to
///    `maxLevels`), stopping at the opened folder when there is one, and
///    at the first folder that may not be a vault root
///    (`WikiVault.mayBeVaultRoot`: `/`, a top-level folder such as
///    `/Users`, a volume such as `/Volumes/<disk>`, the home folder or a
///    folder holding it), unless that is the opened folder;
/// 2. at each of those folders, the site layouts' own roots as well:
///    `static/`, `public/`, `quartz/static/` and `content/` (Hugo, Jekyll,
///    Quartz and the like);
/// 3. the opened folder (and its site layouts), when the walk didn't reach it.
public enum PreviewRoot {
    /// Sub-folders a site generator serves at its root ("" is the folder itself).
    public static let siteFolders = ["", "static", "public", "quartz/static", "content"]
    public static let maxLevels = 8

    /// The folders to try, nearest first. The walk up has the vault walk's
    /// bounds (S2, 0.5.2): before 0.5.4 it stopped only at the home folder
    /// itself and top-level folders, so a document on a disk searched the
    /// disk's root (`/Volumes/<disk>`) and one beside the home folder
    /// searched the folder holding it.
    public static func searchFolders(from folder: URL, openedRoot: URL?, home: URL? = nil) -> [URL] {
        let home = home ?? URL(fileURLWithPath: NSHomeDirectory())
        let rootPath = openedRoot?.standardizedFileURL.path
        var dirs: [URL] = []
        var dir = folder.standardizedFileURL
        for _ in 0..<maxLevels {
            let p = dir.path
            if p != rootPath, !WikiVault.mayBeVaultRoot(dir, home: home) { break }
            dirs.append(dir)
            if p == rootPath { break }
            dir = dir.deletingLastPathComponent()
        }
        if let openedRoot, !dirs.contains(where: { $0.path == rootPath }) { dirs.append(openedRoot.standardizedFileURL) }
        return dirs
    }

    /// The parts of a root-absolute path, decoded; nil for one that isn't
    /// (relative, a scheme, `//host`) or that climbs with `..`.
    public static func parts(of path: String) -> [String]? {
        var p = path
        if let cut = p.firstIndex(where: { $0 == "?" || $0 == "#" }) { p = String(p[..<cut]) }
        guard p.hasPrefix("/"), !p.hasPrefix("//") else { return nil }
        p = p.removingPercentEncoding ?? p
        let parts = p.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts
    }

    /// The file `path` stands for, and the root it was found under.
    /// `pages`: a link may also name a page (`/projects/intelbrew` is
    /// `projects/intelbrew.md` or `projects/intelbrew/index.md`).
    public static func resolve(_ path: String, from folder: URL, openedRoot: URL?, pages: Bool = false,
                               fileManager fm: FileManager = .default, home: URL? = nil) -> (root: URL, file: URL)? {
        guard let parts = parts(of: path) else { return nil }
        let rel = parts.joined(separator: "/")
        var tries = [rel]
        if pages, (rel as NSString).pathExtension.isEmpty { tries += [rel + ".md", rel + "/index.md"] }
        for dir in searchFolders(from: folder, openedRoot: openedRoot, home: home) {
            for sub in siteFolders {
                let root = sub.isEmpty ? dir : dir.appendingPathComponent(sub, isDirectory: true)
                for t in tries {
                    let file = root.appendingPathComponent(t)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue { return (root, file) }
                }
            }
        }
        return nil
    }
}

extension PreviewFolder {
    /// The `cedric-doc:` URL a page uses for `file`.
    public static func pageURL(forFile file: URL) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "doc"
        c.path = file.standardizedFileURL.path
        return c.url
    }

    /// What the preview's file handler serves for `url`: a file inside
    /// `folder` as before, or else a site-root-absolute path
    /// (`cedric-doc://doc/images/x.webp`, from `src="/images/x.webp"`)
    /// found by `PreviewRoot`, under the same rules (symbolic links, and
    /// with `scriptOn` images, fonts and CSS only, no dotfiles) judged
    /// against the root it was found under.
    /// `vaultRoot`: the Obsidian vault's folder, for `![[embeds]]` found there.
    public static func file(for url: URL, in folder: URL, openedRoot: URL?, vaultRoot: URL? = nil, scriptOn: Bool,
                            vault: WikiVault? = nil) -> URL? {
        func containsFolder(_ root: URL) -> Bool {
            let base = resolved(root).path
            let path = resolved(folder).path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        if let f = file(for: url, in: folder, scriptOn: scriptOn), FileManager.default.fileExists(atPath: f.path) { return f }
        if let requested = fileURL(for: url), requested.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            let resolver = vault ?? WikiVault(documentFolder: folder, openedRoot: openedRoot)
            if resolver.documentFolder == folder.standardizedFileURL, containsFolder(resolver.root),
               let hit = resolver.resolveImage(requested.lastPathComponent), let page = pageURL(forFile: hit),
               let safe = file(for: page, in: resolver.root, scriptOn: scriptOn) { return safe }
        }
        for root in [openedRoot, vaultRoot].compactMap({ $0 }).filter(containsFolder) {
            if let f = file(for: url, in: root, scriptOn: scriptOn), FileManager.default.fileExists(atPath: f.path) { return f }
        }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let hit = PreviewRoot.resolve(path, from: folder, openedRoot: openedRoot),
              let page = pageURL(forFile: hit.file) else { return nil }
        return file(for: page, in: hit.root, scriptOn: scriptOn)
    }
}

/// Images the preview can't show because the app may not read the
/// document's folder (iOS, a file opened on its own from Files): they are
/// taken out and one quiet hint is shown in their place, rather than empty
/// boxes.
public enum PreviewImageAccess {
    nonisolated(unsafe) static let img = try! NSRegularExpression(
        pattern: #"<img\b(?:"[^"]*"|'[^']*'|[^'">])*?\ssrc\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)(?:"[^"]*"|'[^']*'|[^'">])*>"#,
        options: [.caseInsensitive])

    /// The local `src`s of `html`'s images (not `data:`, not web URLs).
    public static func localSources(_ html: String) -> [String] {
        let ns = html as NSString
        return img.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let v = unquote(ns.substring(with: m.range(at: 1)))
            return isLocal(v) ? v : nil
        }
    }

    static func unquote(_ v: String) -> String {
        guard let f = v.first, f == "\"" || f == "'", v.count >= 2 else { return v }
        return MarkdownRenderer.unescapeEntities(String(v.dropFirst().dropLast()))
    }

    static func isLocal(_ src: String) -> Bool {
        let t = src.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t.hasPrefix("data:") || t.hasPrefix("//") { return false }
        if let colon = t.firstIndex(of: ":"), !t[..<colon].contains("/") {
            return t.hasPrefix(PreviewFolder.scheme + ":") || t.hasPrefix("file:")
        }
        return true
    }

    /// Whether the preview can read `src`, for a document in `folder`.
    public static func readable(_ src: String, folder: URL, openedRoot: URL?, fileManager fm: FileManager = .default) -> Bool {
        if src.lowercased().hasPrefix(PreviewFolder.scheme + ":") || src.lowercased().hasPrefix("file:") {
            guard let u = URL(string: src) else { return false }
            let vault = WikiVault(documentFolder: folder, openedRoot: openedRoot, fileManager: fm)
            let page = u.isFileURL ? PreviewFolder.pageURL(forFile: u) : u
            guard let page, let f = PreviewFolder.file(for: page, in: vault.root, scriptOn: false) else { return false }
            return fm.isReadableFile(atPath: f.path)
        }
        if src.hasPrefix("/") {
            guard let hit = PreviewRoot.resolve(src, from: folder, openedRoot: openedRoot, fileManager: fm) else { return false }
            guard let page = PreviewFolder.pageURL(forFile: hit.file),
                  let file = PreviewFolder.file(for: page, in: hit.root, scriptOn: false) else { return false }
            return fm.isReadableFile(atPath: file.path)
        }
        var p = src
        if let cut = p.firstIndex(where: { $0 == "?" || $0 == "#" }) { p = String(p[..<cut]) }
        p = p.removingPercentEncoding ?? p
        let vault = WikiVault(documentFolder: folder, openedRoot: openedRoot, fileManager: fm)
        guard !p.hasPrefix("/") else { return false }
        let relative = folder.appendingPathComponent(p).standardizedFileURL
        if let page = PreviewFolder.pageURL(forFile: relative),
           PreviewFolder.file(for: page, in: vault.root, scriptOn: false) != nil,
           let file = PreviewFolder.file(for: page, in: folder, openedRoot: openedRoot, vaultRoot: vault.root, scriptOn: false, vault: vault) {
            return fm.isReadableFile(atPath: file.path)
        }
        return false
    }

    /// `html` with the images it can't read taken out and `hint` (HTML) put
    /// first, when `folderReadable` is false (the app has no access to the
    /// document's folder); unchanged otherwise, so a genuinely missing
    /// image still shows its alt text as it would on the site.
    public static func hideUnreadable(_ html: String, folder: URL, openedRoot: URL?, folderReadable: Bool, hint: String,
                                      fileManager fm: FileManager = .default) -> (html: String, hidden: Int) {
        guard !folderReadable, html.range(of: "<img", options: .caseInsensitive) != nil else { return (html, 0) }
        let ns = html as NSString
        var out = ""
        var last = 0
        var hidden = 0
        for m in img.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let v = unquote(ns.substring(with: m.range(at: 1)))
            guard isLocal(v), !readable(v, folder: folder, openedRoot: openedRoot, fileManager: fm) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            hidden += 1
        }
        guard hidden > 0 else { return (html, 0) }
        out += ns.substring(from: last)
        return (hint + out, hidden)
    }
}
