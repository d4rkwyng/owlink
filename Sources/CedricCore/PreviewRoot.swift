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
    /// (relative, a scheme, `//host`) or that climbs with `..`. Read as
    /// UTF-8 bytes and split at each `/` byte (`FolderTree.components`): a
    /// slash followed by a combining mark is one Swift character, so a
    /// text test took it for no slash and a text split kept it inside a
    /// name. (From round 4's c261b56; its byte-keyed root lookups are not
    /// taken.)
    public static func parts(of path: String) -> [String]? {
        var p = cutQuery(path)
        let head = Array(p.utf8.prefix(2))
        guard head.first == 0x2f, head.count < 2 || head[1] != 0x2f else { return nil }
        p = p.removingPercentEncoding ?? p
        let parts = FolderTree.components(p).filter { !FolderTree.sameBytes($0, ".") }
        guard !parts.isEmpty, !parts.contains(where: { FolderTree.sameBytes($0, "..") }) else { return nil }
        return parts
    }

    /// `src` up to its first `?` or `#` byte.
    static func cutQuery(_ src: String) -> String {
        guard let cut = src.utf8.firstIndex(where: { $0 == 0x3f || $0 == 0x23 }) else { return src }
        return String(decoding: src.utf8[..<cut], as: UTF8.self)
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
    static func containsFolder(_ folder: URL, in root: URL) -> Bool {
        let base = resolved(root).path
        let path = resolved(folder).path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

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
        approved(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, scriptOn: scriptOn, vault: vault)?.file
    }

    /// `file(for:in:openedRoot:vaultRoot:scriptOn:vault:)` with the root
    /// it was approved under: the file is read from beneath that root's
    /// descriptor, pinned when the root was granted (`PreviewGrants`),
    /// never by its path. `siteRoots: false` leaves out the site-root
    /// search (`PreviewGrants` does that one by descriptor).
    public static func approved(for url: URL, in folder: URL, openedRoot: URL?, vaultRoot: URL? = nil, scriptOn: Bool,
                                vault: WikiVault? = nil, siteRoots: Bool = true) -> (root: URL, file: URL)? {
        // `root` is `folder` or holds it, by bytes (`FolderTree.relativePath`):
        // a text prefix missed a combining-mark folder under it (Astra batch 9b).
        func containsFolder(_ root: URL) -> Bool {
            FolderTree.relativePath(of: resolved(folder), in: resolved(root)) != nil
        }
        if let f = file(for: url, in: folder, scriptOn: scriptOn), isExistingFile(f, .default) { return (folder, f) }
        if let requested = fileURL(for: url), requested.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            let resolver = vault ?? WikiVault(documentFolder: folder, openedRoot: openedRoot)
            if resolver.documentFolder == folder.standardizedFileURL, containsFolder(resolver.root),
               let hit = resolver.resolveImage(requested.lastPathComponent), let page = pageURL(forFile: hit),
               let safe = file(for: page, in: resolver.root, scriptOn: scriptOn) { return (resolver.root, safe) }
        }
        for root in [openedRoot, vaultRoot].compactMap({ $0 }).filter(containsFolder) {
            if let f = file(for: url, in: root, scriptOn: scriptOn), isExistingFile(f, .default) { return (root, f) }
        }
        guard siteRoots, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let hit = PreviewRoot.resolve(path, from: folder, openedRoot: openedRoot),
              let page = pageURL(forFile: hit.file),
              let f = file(for: page, in: hit.root, scriptOn: scriptOn) else { return nil }
        return (hit.root, f)
    }

    /// A clicked link's file, or nil when it must not be opened.
    ///
    /// The real path, symbolic links resolved, has to sit under the
    /// document's folder, a granted folder, the vault, or the site root
    /// the path resolved in. That is the same rule `file(for:in:openedRoot:vaultRoot:scriptOn:)`
    /// uses for images (`..`, an absolute path and a link that leaves its
    /// root are refused). A site-root link may name a page
    /// (`/projects/intelbrew` → `projects/intelbrew.md`). A directory is
    /// not a file, so it is refused too.
    public static func linkTarget(_ url: URL, folder: URL, openedRoot: URL?, vaultRoot: URL? = nil,
                                  fileManager fm: FileManager = .default) -> URL? {
        guard url.scheme == scheme else { return nil }
        for root in [folder, openedRoot, vaultRoot].compactMap({ $0 }) {
            if let file = file(for: url, in: root, scriptOn: false), isExistingFile(file, fm) {
                return file
            }
        }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let hit = PreviewRoot.resolve(path, from: folder, openedRoot: openedRoot, pages: true, fileManager: fm),
              let page = pageURL(forFile: hit.file),
              let file = file(for: page, in: hit.root, scriptOn: false),
              isExistingFile(file, fm) else { return nil }
        return file
    }

    /// `file` exists and is not a directory, following symbolic links.
    private static func isExistingFile(_ file: URL, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: resolved(file).path, isDirectory: &isDir) && !isDir.boolValue
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
    public static func readable(_ src: String, folder: URL, openedRoot: URL?, vault: WikiVault? = nil,
                                fileManager fm: FileManager = .default) -> Bool {
        let vaultRoot = vault.flatMap { $0.documentFolder == folder.standardizedFileURL ? $0.root : nil }
        let roots = [folder, openedRoot, vaultRoot].compactMap { $0 }
            .filter { PreviewFolder.containsFolder(folder, in: $0) }
        if src.lowercased().hasPrefix(PreviewFolder.scheme + ":") || src.lowercased().hasPrefix("file:") {
            guard let u = URL(string: src) else { return false }
            let page = u.isFileURL ? PreviewFolder.pageURL(forFile: u) : u
            guard let page else { return false }
            return roots.contains { root in
                guard let f = PreviewFolder.file(for: page, in: root, scriptOn: false) else { return false }
                return fm.isReadableFile(atPath: f.path)
            }
        }
        // Site-absolute by its first byte: a "/" then a combining mark is
        // one Swift character, which a text test took for a relative link.
        if src.utf8.first == 0x2f {
            guard let hit = PreviewRoot.resolve(src, from: folder, openedRoot: openedRoot, fileManager: fm) else { return false }
            guard let page = PreviewFolder.pageURL(forFile: hit.file),
                  let file = PreviewFolder.file(for: page, in: hit.root, scriptOn: false) else { return false }
            return fm.isReadableFile(atPath: file.path)
        }
        var p = PreviewRoot.cutQuery(src)
        p = p.removingPercentEncoding ?? p
        let vault = WikiVault(documentFolder: folder, openedRoot: openedRoot, fileManager: fm)
        guard p.utf8.first != 0x2f else { return false }
        let relative = folder.appendingPathComponent(p).standardizedFileURL
        guard let page = PreviewFolder.pageURL(forFile: relative) else { return false }
        if p.split(separator: "/").contains("..") {
            return roots.contains { root in
                guard let file = PreviewFolder.file(for: page, in: root, scriptOn: false) else { return false }
                return fm.isReadableFile(atPath: file.path)
            }
        }
        guard let file = PreviewFolder.file(for: page, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot,
                                            scriptOn: false, vault: vault) else { return false }
        return fm.isReadableFile(atPath: file.path)
    }

    /// `html` with the images it can't read taken out and `hint` (HTML) put
    /// first, when `folderReadable` is false (the app has no access to the
    /// document's folder); unchanged otherwise, so a genuinely missing
    /// image still shows its alt text as it would on the site.
    public static func hideUnreadable(_ html: String, folder: URL, openedRoot: URL?, folderReadable: Bool, hint: String,
                                      vault: WikiVault? = nil,
                                      fileManager fm: FileManager = .default) -> (html: String, hidden: Int) {
        guard !folderReadable, html.range(of: "<img", options: .caseInsensitive) != nil else { return (html, 0) }
        let ns = html as NSString
        var out = ""
        var last = 0
        var hidden = 0
        for m in img.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let v = unquote(ns.substring(with: m.range(at: 1)))
            guard isLocal(v), !readable(v, folder: folder, openedRoot: openedRoot, vault: vault, fileManager: fm) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            hidden += 1
        }
        guard hidden > 0 else { return (html, 0) }
        out += ns.substring(from: last)
        return (hint + out, hidden)
    }
}
