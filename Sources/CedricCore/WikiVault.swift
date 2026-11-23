import Foundation

/// Resolves Obsidian `[[wikilinks]]` and `![[embeds]]` for the preview, as
/// Obsidian does: by file name anywhere under the vault, the shortest path
/// winning, `.md` implied for notes. The vault is the opened folder, else
/// the nearest folder above the document holding `.obsidian/` (within the
/// bounds `mayBeVaultRoot` sets: never the home folder, a folder above it,
/// `/`, a top-level folder or a volume root), else the document's own folder. Files only; the name index is built once per
/// `refreshSeconds` (bounded: `maxEntries` entries, `maxDepth` levels,
/// dot folders and `node_modules` skipped).
public final class WikiVault: @unchecked Sendable {
    public let documentFolder: URL
    public let root: URL
    public static let maxEntries = 20_000
    public static let maxDepth = 10
    public static let refreshSeconds: TimeInterval = 15
    /// The most a transcluded note may be (bytes); larger ones stay a link.
    public static let maxEmbedBytes = 256 * 1024

    private let fm: FileManager
    private let lock = NSLock()
    private var index: [String: [URL]] = [:]
    private var attachmentFolder: URL?
    private var built: Date?
    /// How many folder levels the name index reads: `maxDepth`, or 1 (the
    /// root's own files) when the root is only the document's folder and
    /// that folder may not be a vault root (a note saved straight in `~`
    /// or at a disk's root): bare names then don't search the whole home
    /// folder or disk.
    public let indexDepth: Int

    public init(documentFolder: URL, openedRoot: URL? = nil, fileManager: FileManager = .default, home: URL? = nil) {
        self.fm = fileManager
        self.documentFolder = documentFolder.standardizedFileURL
        let folder = documentFolder.standardizedFileURL
        let opened = openedRoot?.standardizedFileURL
        let validRoot = opened.flatMap { Self.contains(folder, in: $0) ? $0 : nil }
        let found = validRoot ?? Self.obsidianRoot(above: folder, fileManager: fileManager, home: home)
        self.root = (found ?? folder).standardizedFileURL
        let confined = found == nil && !Self.mayBeVaultRoot(folder, home: home ?? URL(fileURLWithPath: NSHomeDirectory()))
        self.indexDepth = confined ? 1 : Self.maxDepth
    }

    /// The nearest folder at or above `folder` that holds `.obsidian/`, as
    /// long as it may be a vault root (`mayBeVaultRoot`). The walk stops at
    /// the first folder that may not: a stray `~/.obsidian` or one at a
    /// disk's root never widens the vault to the whole home folder or disk.
    /// (An opened folder still wins over this walk, whatever it is.)
    public static func obsidianRoot(above folder: URL, fileManager fm: FileManager = .default, home: URL? = nil) -> URL? {
        let home = home ?? URL(fileURLWithPath: NSHomeDirectory())
        var dir = folder.standardizedFileURL
        for _ in 0..<PreviewRoot.maxLevels {
            guard mayBeVaultRoot(dir, home: home) else { return nil }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(".obsidian").path, isDirectory: &isDir), isDir.boolValue { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Whether `dir` may be found as a vault root by the `.obsidian` walk:
    /// not `/` or a top-level folder (`/Users`, `/Volumes`), not a volume
    /// root (`/Volumes/<disk>` or any mount point), and not the home folder
    /// or a folder holding it (`/Users`, …). Every rule applies to the path
    /// both as written and with symbolic links resolved, so a link to
    /// `/System/Volumes/Data` or a disk is refused like the volume itself.
    public static func mayBeVaultRoot(_ dir: URL, home: URL) -> Bool {
        let d = dir.standardizedFileURL
        let candidates = [d, d.resolvingSymlinksInPath()]
        let homes = [home.standardizedFileURL, home.standardizedFileURL.resolvingSymlinksInPath()]
        for c in candidates {
            let comps = c.pathComponents
            if comps.count < 3 { return false }
            if comps.count == 3, comps[1] == "Volumes" { return false }
            for h in homes {
                let hp = h.pathComponents
                if hp.count >= comps.count, Array(hp.prefix(comps.count)) == comps { return false }
            }
            // A fresh URL per candidate: resource values are cached on the URL.
            if let v = try? URL(fileURLWithPath: c.path).resourceValues(forKeys: [.isVolumeKey]).isVolume, v { return false }
        }
        return true
    }

    /// A `[[target]]`'s parts: the file part and the `#Heading` or `#^block` part.
    public static func split(_ target: String) -> (name: String, fragment: String?) {
        guard let hash = target.firstIndex(of: "#") else { return (target.trimmingCharacters(in: .whitespaces), nil) }
        let frag = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
        return (String(target[..<hash]).trimmingCharacters(in: .whitespaces), frag.isEmpty ? nil : frag)
    }

    /// The file a link names (`name` without its `#…`), or nil.
    public func resolve(_ name: String) -> URL? {
        var n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("\0") else { return nil }
        // A leading slash is a path from the vault root (Obsidian), not a refusal.
        let fromVaultRoot = n.hasPrefix("/")
        if fromVaultRoot { n.removeFirst() }
        let parts = n.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.isEmpty else { return nil }
        let hasExt = !(n as NSString).pathExtension.isEmpty
        let names = hasExt ? [n, n + ".md"] : [n + ".md", n]
        // A path: from the vault root when the link is root-absolute,
        // otherwise relative to the document, then the vault.
        if parts.count > 1 || fromVaultRoot {
            let bases = fromVaultRoot ? [root] : [documentFolder, root]
            for base in bases {
                for t in names {
                    let f = base.appendingPathComponent(t).standardizedFileURL
                    if isFile(f) { return f }
                }
            }
            if fromVaultRoot { return nil }
        }
        // A name: the document's own folder first, then anywhere in the vault.
        for t in names where parts.count == 1 {
            let f = documentFolder.appendingPathComponent(t)
            if isFile(f) { return f }
        }

        let (idx, _) = currentIndex()
        for t in names {
            let key = (t as NSString).lastPathComponent.lowercased()
            guard var hits = idx[key] else { continue }
            if parts.count > 1 {
                let suffix = "/" + t.lowercased()
                hits = hits.filter { $0.path.lowercased().hasSuffix(suffix) }
            }
            if let best = hits.filter({ isFile($0) }).min(by: { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }) { return best }
        }
        return nil
    }

    private func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return Self.contains(url, in: root) && fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        let base = PreviewFolder.resolved(root).path
        let path = PreviewFolder.resolved(url).path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Resolve an exact, bare image name, preferring the note's folder and
    /// then Obsidian's configured attachment folder.
    public func resolveImage(_ name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\\"), !name.contains("\0"), !name.contains(":"),
              Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        let local = documentFolder.appendingPathComponent(name)
        if isFile(local) { return local }
        let (idx, attachments) = currentIndex()
        let hits = (idx[name.lowercased()] ?? []).filter { isFile($0) }
        return hits.min { a, b in
            let aLocal = a.deletingLastPathComponent().standardizedFileURL == documentFolder
            let bLocal = b.deletingLastPathComponent().standardizedFileURL == documentFolder
            if aLocal != bLocal { return aLocal }
            let aPreferred = attachments.map { Self.contains(a, in: $0) } ?? false
            let bPreferred = attachments.map { Self.contains(b, in: $0) } ?? false
            if aPreferred != bPreferred { return aPreferred }
            return (a.pathComponents.count, a.path) < (b.pathComponents.count, b.path)
        }
    }

    private func currentIndex() -> ([String: [URL]], URL?) {
        lock.lock(); defer { lock.unlock() }
        if let built, Date().timeIntervalSince(built) < Self.refreshSeconds { return (index, attachmentFolder) }
        index = Self.buildIndex(root, fm, depth: indexDepth)
        attachmentFolder = nil
        let config = root.appendingPathComponent(".obsidian/app.json")
        if Self.contains(config, in: root),
           let attrs = try? fm.attributesOfItem(atPath: config.path), let size = attrs[.size] as? Int, size <= 256 * 1024,
           let data = fm.contents(atPath: config.path),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let path = json["attachmentFolderPath"] as? String {
            let parts = path.split(separator: "/")
            if path.isEmpty || path == "current" {
                attachmentFolder = documentFolder
            } else if !path.hasPrefix("/"), !parts.contains(".."), !path.contains("\\") {
                let folder = root.appendingPathComponent(path).standardizedFileURL
                if Self.contains(folder, in: root) { attachmentFolder = folder }
            }
        }
        built = Date()
        return (index, attachmentFolder)
    }

    /// Builds the note-name index when it is older than `refreshSeconds`.
    /// Copy as Rich Text calls this off the main thread, then writes the
    /// pasteboard, so a vault of up to `maxEntries` names does not pause the app.
    public func prepareIndex() {
        _ = currentIndex()
    }

    /// Whether a resolve or `prepareIndex` has built the index within `refreshSeconds`.
    public var indexIsFresh: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let built else { return false }
        return Date().timeIntervalSince(built) < Self.refreshSeconds
    }

    static func buildIndex(_ root: URL, _ fm: FileManager, depth maxDepth: Int = WikiVault.maxDepth) -> [String: [URL]] {
        var idx: [String: [URL]] = [:]
        var count = 0
        var queue: [(URL, Int)] = [(root, 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        while !queue.isEmpty, count < maxEntries {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                count += 1
                if count >= maxEntries { break }
                let name = item.lastPathComponent
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    var isDir: ObjCBool = false
                    if contains(item, in: root), fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue {
                        idx[name.lowercased(), default: []].append(item.standardizedFileURL)
                    }
                    continue
                }
                if values?.isDirectory == true {
                    if depth + 1 < maxDepth, name != "node_modules" { queue.append((item, depth + 1)) }
                } else {
                    idx[name.lowercased(), default: []].append(item.standardizedFileURL)
                }
            }
        }
        return idx
    }

    /// The text of a note to transclude, or the part a `#Heading` or
    /// `#^block` names (the whole note when that part isn't found).
    public func embedText(_ file: URL, fragment: String?) -> String? {
        guard let attrs = try? fm.attributesOfItem(atPath: file.path), let size = attrs[.size] as? Int, size <= Self.maxEmbedBytes,
              let data = fm.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.section(of: text, fragment: fragment)
    }

    /// The lines under heading `fragment` (to the next heading of its level
    /// or higher), or the paragraph ending in `^block`; else the whole text
    /// without its frontmatter.
    public static func section(of text: String, fragment: String?) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        guard let fragment else { return lines.joined(separator: "\n") }
        if fragment.hasPrefix("^") {
            let id = fragment
            guard let k = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(" " + id) || $0.trimmingCharacters(in: .whitespaces) == id }) else {
                return lines.joined(separator: "\n")
            }
            var start = k
            while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
            let block = lines[start...k].map { l -> String in
                let t = l.trimmingCharacters(in: .whitespaces)
                return t.hasSuffix(id) ? String(t.dropLast(id.count)).trimmingCharacters(in: .whitespaces) : l
            }
            return block.joined(separator: "\n")
        }
        func heading(_ l: String) -> (Int, String)? {
            let t = l.trimmingCharacters(in: .whitespaces)
            let level = t.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level), t.dropFirst(level).first == " " else { return nil }
            return (level, t.dropFirst(level).trimmingCharacters(in: .whitespaces))
        }
        let want = fragment.lowercased()
        guard let k = lines.firstIndex(where: { heading($0).map { $0.1.lowercased() == want } ?? false }), let (level, _) = heading(lines[k]) else {
            return lines.joined(separator: "\n")
        }
        var end = k + 1
        while end < lines.count {
            if let (l, _) = heading(lines[end]), l <= level { break }
            end += 1
        }
        return lines[k..<end].joined(separator: "\n")
    }

    /// The `cedric-doc:` link for a resolved file, with `#<slug>` for a
    /// heading (`[[note#Part]]` → `…/note.md#part`; a block reference
    /// `#^id` adds nothing, the preview has no block ids).
    public static func href(_ file: URL, heading: String? = nil) -> String? {
        guard let page = PreviewFolder.pageURL(forFile: file) else { return nil }
        guard let heading, !heading.hasPrefix("^") else { return page.absoluteString }
        let id = PreviewAnchor.headingID(heading)
        guard !id.isEmpty, var c = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return page.absoluteString }
        c.fragment = id
        return c.url?.absoluteString ?? page.absoluteString
    }

    /// A link to `file` relative to `folder` (`../attachments/a%20b.png`),
    /// percent-encoded, for an exported page saved beside the document.
    public static func relativeHref(_ file: URL, from folder: URL) -> String {
        let to = file.standardizedFileURL.pathComponents
        let from = folder.standardizedFileURL.pathComponents
        var common = 0
        while common < to.count - 1, common < from.count, to[common] == from[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + to[common...]
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "bmp", "svg", "tif", "tiff", "ico"]
}
