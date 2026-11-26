import Foundation

/// One entry of a folder listing, as the folder sidebar shows it.
public struct FolderEntry: Equatable, Hashable, Sendable {
    public var name: String
    /// A folder the sidebar can expand (packages are files; a symbolic
    /// link to a folder is a folder, flagged `isSymlink`).
    public var isDirectory: Bool
    /// A dot file or a file with the hidden flag.
    public var isHidden: Bool
    public var isSymlink: Bool
    /// Ignored by the folder's .gitignore files (the sidebar dims it).
    public var isIgnored: Bool

    public init(name: String, isDirectory: Bool, isHidden: Bool = false, isSymlink: Bool = false, isIgnored: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isIgnored = isIgnored
    }

    /// What a re-listing matches entries by: a file that became a folder
    /// of the same name is a remove and an insert.
    public var key: String { (isDirectory ? "d:" : "f:") + name }
}

/// The folder sidebar's model (plan-0.2.0.md §6): listing one folder
/// (only folders the user expands are listed), Finder's order, the hidden
/// filter, diffing a re-listing against what is shown, and the symlink
/// loop guard. Foundation only; the app lists off the main thread.
public enum FolderTree {
    /// Never shown, hidden files on or off.
    public static let alwaysHidden: Set<String> = [".git", ".DS_Store"]

    /// The entries of `url`, filtered and sorted. Throws if the folder
    /// can't be read. Doesn't recurse.
    /// `ignore`: marks the entries its .gitignore files ignore (`isIgnored`).
    public static func list(_ url: URL, showHidden: Bool = false, ignore: FolderIgnore? = nil, revealed: Set<String> = []) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        var out: [FolderEntry] = []
        out.reserveCapacity(urls.count)
        for u in urls {
            let name = u.lastPathComponent
            if alwaysHidden.contains(name) { continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            let hidden = v?.isHidden ?? name.hasPrefix(".")
            if hidden && !showHidden && !revealed.contains(name) { continue }
            let link = v?.isSymbolicLink ?? false
            var dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            if link {
                // A link to a folder (not a package) can be expanded; the
                // loop guard stops it at an ancestor.
                var isDir: ObjCBool = false
                dir = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
                    && !isPackage(u.resolvingSymlinksInPath())
            }
            out.append(FolderEntry(name: name, isDirectory: dir, isHidden: hidden, isSymlink: link))
        }
        ignore?.mark(&out, in: url)
        return sorted(out)
    }

    private static func isPackage(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    /// `entries` without the always-hidden names, and without hidden ones
    /// unless `showHidden`.
    public static func filter(_ entries: [FolderEntry], showHidden: Bool, revealed: Set<String> = []) -> [FolderEntry] {
        entries.filter { !alwaysHidden.contains($0.name) && (showHidden || !$0.isHidden || revealed.contains($0.name)) }
    }

    /// Finder's order: folders first, then names compared as Finder does
    /// (numbers by value, case-insensitive).
    public static func sorted(_ entries: [FolderEntry]) -> [FolderEntry] {
        entries.sorted(by: precedes)
    }

    public static func precedes(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name < b.name
        }
    }

    /// How a re-listing differs from what is shown: indexes into `old`
    /// that went (apply first) and indexes into `new` that came. Both
    /// lists are in `sorted` order, so the entries kept keep their order
    /// and an outline view can apply the two steps in turn without
    /// disturbing the rows (and expansion) in between. A rename is one
    /// removal and one insertion.
    /// `changed`: indexes into `new` of entries kept whose flags changed
    /// (hidden, ignored, link): their rows are redrawn, not replaced.
    public struct Diff: Equatable, Sendable {
        public var removed: [Int]
        public var inserted: [Int]
        public var changed: [Int]
        public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
        public init(removed: [Int], inserted: [Int], changed: [Int] = []) {
            self.removed = removed; self.inserted = inserted; self.changed = changed
        }
    }

    public static func diff(old: [FolderEntry], new: [FolderEntry]) -> Diff {
        var oldByKey: [String: FolderEntry] = [:]
        for e in old { oldByKey[e.key] = e }
        let newKeys = Set(new.map(\.key))
        return Diff(removed: old.indices.filter { !newKeys.contains(old[$0].key) },
                    inserted: new.indices.filter { oldByKey[new[$0].key] == nil },
                    changed: new.indices.filter { i in oldByKey[new[i].key].map { $0 != new[i] } ?? false })
    }

    /// True if expanding `url` would loop: its real path (symbolic links
    /// resolved) is that of one of `ancestors` (the folders above it).
    public static func wouldLoop(_ url: URL, ancestors: [URL]) -> Bool {
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        return ancestors.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == real }
    }

    /// `url`'s path relative to `root` ("" for the root itself), or nil if
    /// it isn't inside it. Compared as the UTF-8 bytes the kernel gets, not
    /// as Swift text: a slash followed by a combining mark is one Swift
    /// character, so a text prefix test misses a folder whose name starts
    /// with one (Astra batch 7b). Inside means the same bytes, or the
    /// root's bytes followed by a `/` byte; the root's name with a mark
    /// appended is a sibling, outside.
    public static func relativePath(of url: URL, in root: URL) -> String? {
        var r = Array(root.standardizedFileURL.path.utf8)
        let p = Array(url.standardizedFileURL.path.utf8)
        while r.count > 1, r.last == 0x2f { r.removeLast() }
        if p == r { return "" }
        let cut = r == [0x2f] ? 1 : r.count + 1
        guard p.count > cut, p.starts(with: r), p[cut - 1] == 0x2f else { return nil }
        return String(decoding: p[cut...], as: UTF8.self)
    }

    /// The names in `relativePath` (as `relativePath(of:in:)` gives it),
    /// split at each `/` byte, empty ones dropped: a text split keeps a
    /// slash before a combining mark inside a name.
    public static func components(_ relativePath: String) -> [String] {
        relativePath.utf8.split(separator: 0x2f).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The folder holding the file at `url` (File › Open Enclosing Folder),
    /// or nil for an untitled document, a non-file URL or the volume root.
    public static func enclosingFolder(of url: URL?) -> URL? {
        guard let url, url.isFileURL, !url.path.isEmpty else { return nil }
        let file = url.standardizedFileURL
        let parent = file.deletingLastPathComponent().standardizedFileURL
        guard parent.path != file.path, !parent.path.isEmpty else { return nil }
        return URL(fileURLWithPath: parent.path, isDirectory: true)
    }
}

/// Which listed entries the folder's .gitignore files ignore, for the
/// sidebar to dim. Lazy: `GitIgnore` reads a .gitignore only when a
/// listing reaches its folder (and the ones above it), never walks the
/// tree, and is made on the first listing, so it costs nothing until a
/// folder is open. Listings run on background threads: one lock.
/// Paths are taken by their place in the tree (below the sidebar's
/// root), so a folder reached through a symbolic link is matched where
/// it shows.
public final class FolderIgnore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var ignore: GitIgnore?
    /// The sidebar root relative to the repository root ("" if it is the
    /// repository root), set with `ignore`.
    private var rootRel = ""

    /// `root`: the sidebar's folder, as opened.
    public init(root: URL) { self.root = root.standardizedFileURL }

    /// Forgets the .gitignore files read so far (one changed on disk).
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        ignore = nil
    }

    /// Sets `isIgnored` on each entry of the listing of `dir`.
    public func mark(_ entries: inout [FolderEntry], in dir: URL) {
        guard let dirRel = FolderTree.relativePath(of: dir, in: root) else { return }
        lock.lock(); defer { lock.unlock() }
        if ignore == nil {
            let g = GitIgnore(folder: root)
            ignore = g
            let real = root.resolvingSymlinksInPath().standardizedFileURL
            rootRel = FolderTree.relativePath(of: real, in: g.root.standardizedFileURL) ?? ""
        }
        guard let g = ignore else { return }
        let base = [rootRel, dirRel].filter { !$0.isEmpty }.joined(separator: "/")
        for i in entries.indices {
            let rel = base.isEmpty ? entries[i].name : base + "/" + entries[i].name
            // git sees a symbolic link as a file, whatever it points to.
            entries[i].isIgnored = g.isIgnored(relative: rel, isDirectory: entries[i].isDirectory && !entries[i].isSymlink)
        }
    }
}

/// One row of the folder tree. `children` is nil until the folder has
/// been listed (lazy loading); a re-listing keeps the nodes that stayed,
/// so their own loaded children and expansion survive.
public final class FolderNode {
    public let url: URL
    public private(set) var entry: FolderEntry
    public private(set) weak var parent: FolderNode?
    public private(set) var children: [FolderNode]?
    /// A listing is under way (the app shows nothing new until it lands).
    public var isLoading = false
    /// The folder couldn't be read (permissions); shown empty.
    public var loadError: String?

    public init(url: URL, entry: FolderEntry, parent: FolderNode? = nil) {
        self.url = url
        self.entry = entry
        self.parent = parent
    }

    /// The root of a tree: `url`, a folder.
    public convenience init(root url: URL) {
        self.init(url: url, entry: FolderEntry(name: url.lastPathComponent, isDirectory: true))
    }

    public var name: String { entry.name }
    public var isDirectory: Bool { entry.isDirectory }
    public var isLoaded: Bool { children != nil }

    /// The folders above this one, nearest first.
    public var ancestors: [FolderNode] {
        var out: [FolderNode] = []
        var p = parent
        while let n = p { out.append(n); p = n.parent }
        return out
    }

    /// Takes a listing of this folder. Returns the change against what was
    /// loaded before (everything inserted on the first listing).
    @discardableResult
    public func apply(_ listing: [FolderEntry]) -> FolderTree.Diff {
        let old = children ?? []
        let d = FolderTree.diff(old: old.map(\.entry), new: listing)
        var byKey: [String: FolderNode] = [:]
        for c in old { byKey[c.entry.key] = c }
        children = listing.map { e in
            if let kept = byKey[e.key] { kept.entry = e; return kept }
            return FolderNode(url: url.appendingPathComponent(e.name, isDirectory: e.isDirectory), entry: e, parent: self)
        }
        return d
    }

    /// Forgets the listing (the folder reads as not loaded again).
    public func unload() { children = nil }

    /// The child with this name, if loaded.
    public func child(named name: String) -> FolderNode? { children?.first { $0.name == name } }

    /// The node at `relativePath` below this one, walking only loaded folders.
    public func descendant(_ relativePath: String) -> FolderNode? {
        var n: FolderNode? = self
        for part in FolderTree.components(relativePath) {
            n = n?.child(named: part)
        }
        return n
    }

    /// Every loaded folder in this subtree, this one first, parents before children.
    public var loadedFolders: [FolderNode] {
        guard let children else { return [] }
        return [self] + children.flatMap(\.loadedFolders)
    }
}
