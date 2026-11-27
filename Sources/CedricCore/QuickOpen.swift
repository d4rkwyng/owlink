import Foundation

/// File › Open Quickly… (0.4.0; CommandPalette.swift in the app): the
/// command palette's file mode. Pure and Foundation only, so the index,
/// the ranking and the query prefixes are unit-tested here.
///
/// - **Query prefixes**, as in VS Code: `#` searches the headings of the
///   current Markdown document, `>` the menu commands; anything else in
///   file mode is a file name.
/// - **The index** (`FileIndex`) lists the sidebar's folder breadth first,
///   so the files nearest the top are in it when the cap stops the walk.
///   Hidden files follow the sidebar's Show Hidden Files switch, and what
///   the folder's .gitignore files ignore is left out (`FolderIgnore`).
///   Folders reached through a symbolic link are not walked (no loops, no
///   file listed twice). Built off the main thread; a change the folder
///   watcher reports re-lists that folder only (`refresh`).
/// - **Ranking** (`FileMatchIndex`): CommandMatcher's fuzzy scoring, on
///   the file name first (a name match always beats a match that needs the
///   folders), else on the whole relative path, which is also what a query
///   with a `/` in it matches ("app/del" finds Sources/CedricApp/AppDelegate.swift).
///   A query made of the name's word starts ("fs", FolderSidebar.swift)
///   earns a bonus over a name that only contains it (offsets.txt).
///   Ties: the shorter name, then the shallower path, then by name.
public enum QuickOpen {
    /// Files indexed at most (VS Code's quick open stops at a similar
    /// order of magnitude); `FileIndex.truncated` says when it stopped.
    public static let fileLimit = 20_000
    /// Rows shown at most for one query.
    public static let shownLimit = 200

    public enum Query: Equatable, Sendable {
        case files(String)
        case headings(String)
        case commands(String)
    }

    /// What `raw` asks for in a palette opened for files (`filesMode`) or
    /// for commands: a leading `#` is headings, `>` commands (whitespace
    /// before them, and after them, ignored).
    public static func parse(_ raw: String, filesMode: Bool) -> Query {
        let t = raw.drop { $0.isWhitespace }
        if t.hasPrefix("#") { return .headings(String(t.dropFirst().drop { $0.isWhitespace })) }
        if t.hasPrefix(">") { return .commands(String(t.dropFirst().drop { $0.isWhitespace })) }
        return filesMode ? .files(raw) : .commands(raw)
    }

    /// The headings to show for `query`, as indices into `headings`: all
    /// of them in document order for an empty query, else the fuzzy
    /// matches, best first (document order on a tie).
    public static func rankHeadings(_ headings: [MarkdownOutline.Heading], query: String) -> [Int] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return Array(headings.indices) }
        let candidates = headings.enumerated().map { i, h in
            CommandMatcher.Candidate(id: "\(i)", title: h.title, path: "")
        }
        return CommandIndex(candidates).rank(query: query)
    }
}

/// The files below a folder, for Open Quickly: names per folder (relative
/// paths, "" for the root), walked breadth first up to `limit` files.
public struct FileIndex: Sendable {
    struct Dir: Sendable, Equatable {
        var files: [String]
        var subdirs: [String]
    }

    public let root: URL
    public let showHidden: Bool
    public let limit: Int
    /// By the listed relative paths' bytes (`FolderTree.PathKey`): two
    /// canonically equivalent folders keep two listings. A watcher event's
    /// spelling is matched to these keys in `refresh`.
    var dirs: FolderTree.PathMap<Dir> = [:]
    /// The walk stopped at `limit`: some files aren't in the index.
    public private(set) var truncated = false
    public private(set) var fileCount = 0

    /// Lists `root` (breadth first, off the main thread: this reads the
    /// disk). `cancelled` is polled between folders.
    public static func build(root: URL, showHidden: Bool, limit: Int = QuickOpen.fileLimit,
                             cancelled: () -> Bool = { false }) -> FileIndex {
        var idx = FileIndex(root: root.standardizedFileURL, showHidden: showHidden, limit: limit)
        idx.walk(from: [""], ignore: FolderIgnore(root: idx.root), cancelled: cancelled)
        return idx
    }

    init(root: URL, showHidden: Bool, limit: Int) {
        self.root = root
        self.showHidden = showHidden
        self.limit = limit
    }

    /// Every file's path relative to the root (unordered).
    public var paths: [String] {
        var out: [String] = []
        out.reserveCapacity(fileCount)
        for (rel, d) in dirs {
            for f in d.files { out.append(rel.isEmpty ? f : rel + "/" + f) }
        }
        return out
    }

    private func url(_ rel: String) -> URL {
        rel.isEmpty ? root : root.appendingPathComponent(rel, isDirectory: true)
    }

    /// One folder's listing: files and the folders to walk into, without
    /// what is ignored (and hidden, unless `showHidden`). nil: unreadable.
    private func list(_ rel: String, ignore: FolderIgnore) -> Dir? {
        guard let entries = try? FolderTree.list(url(rel), showHidden: showHidden, ignore: ignore) else { return nil }
        var d = Dir(files: [], subdirs: [])
        for e in entries where !e.isIgnored {
            if e.isDirectory {
                if !e.isSymlink { d.subdirs.append(e.name) }
            } else {
                d.files.append(e.name)
            }
        }
        return d
    }

    /// Lists the folders in `queue` and everything below them, breadth
    /// first, while there is room under `limit`.
    private mutating func walk(from queue: [String], ignore: FolderIgnore, cancelled: () -> Bool) {
        var queue = queue[...]
        while let rel = queue.popFirst() {
            if cancelled() { truncated = true; return }
            guard var d = list(rel, ignore: ignore) else { continue }
            let room = limit - fileCount
            if d.files.count > room { d.files.removeLast(d.files.count - room); truncated = true }
            fileCount += d.files.count
            dirs[rel] = d
            if fileCount >= limit {
                if !queue.isEmpty || !d.subdirs.isEmpty { truncated = true }
                // Folders not reached aren't in `dirs`: a refresh can add them.
                return
            }
            for s in d.subdirs { queue.append(rel.isEmpty ? s : rel + "/" + s) }
        }
    }

    /// Forgets `rel` and every folder below it: by the path bytes, `rel`
    /// itself or `rel` then a "/" byte (a text prefix test fused "rel/"
    /// with a child whose name starts with a combining mark, and kept it).
    private mutating func dropSubtree(_ rel: String) {
        let r = Array(rel.utf8)
        func inside(_ k: String) -> Bool {
            if r.isEmpty { return true }
            let b = Array(k.utf8)
            return b == r || (b.count > r.count && b.starts(with: r) && b[r.count] == 0x2f)
        }
        for k in Array(dirs.keys) where inside(k) {
            fileCount -= dirs[k]?.files.count ?? 0
            dirs[k] = nil
        }
    }

    /// The folder `rel` changed on disk (the folder watcher): list it
    /// again. Its files are replaced; folders that went are forgotten with
    /// everything below them, new ones are walked. `recursive`: the whole
    /// subtree is listed again (events were coalesced, or a .gitignore
    /// there changed). Refresh parents before children (one batch of
    /// events: shallowest first).
    ///
    /// `rel` is the event's spelling (FSEvents'), `base` the event-spelled
    /// root path (default: `root`'s). The index keeps the listing's own
    /// spelling: an exact key is that folder; on a miss the folder is
    /// matched to a listed one by identity, walking down from the root
    /// (`FolderTree.listedFolder`), and a folder gone under another
    /// spelling relists its nearest listed ancestor. A miss alone never
    /// skips a folder the index lists.
    public mutating func refresh(_ rel: String, base: String? = nil, recursive: Bool, cancelled: () -> Bool = { false }) {
        let ignore = FolderIgnore(root: root)
        var rel = rel
        // A folder the index doesn't hold, and that its (indexed) parent
        // doesn't list either, is ignored, hidden or past the cap: skipped
        // (a build folder's churn costs nothing).
        if !rel.isEmpty, dirs[rel] == nil {
            switch FolderTree.listedFolder(rel, base: base ?? root.path, root: root, subfolders: { dirs[$0]?.subdirs }) {
            case .listed(let k): rel = k
            case .ancestor(let k): rel = k
            case .unlisted: return
            }
        }
        if recursive {
            dropSubtree(rel)
            if rel.isEmpty { truncated = false }
            walk(from: [rel], ignore: ignore, cancelled: cancelled)
            return
        }
        guard var d = list(rel, ignore: ignore) else { dropSubtree(rel); return }
        let old = dirs[rel]
        fileCount -= old?.files.count ?? 0
        let room = limit - fileCount
        if d.files.count > room { d.files.removeLast(d.files.count - room); truncated = true }
        fileCount += d.files.count
        // The listing's names by their bytes (a `Set<String>` folds canonical twins).
        let oldSubs = Set((old?.subdirs ?? []).map { FolderTree.PathKey($0) }), newSubs = Set(d.subdirs.map { FolderTree.PathKey($0) })
        dirs[rel] = d
        for s in oldSubs.subtracting(newSubs) { dropSubtree(rel.isEmpty ? s.string : rel + "/" + s.string) }
        let added = d.subdirs.filter { !oldSubs.contains(FolderTree.PathKey($0)) }.map { rel.isEmpty ? $0 : rel + "/" + $0 }
        if !added.isEmpty, fileCount < limit { walk(from: added, ignore: ignore, cancelled: cancelled) }
    }
}

/// File paths prepared once (off the main thread, after each index
/// change) and ranked on each keystroke.
public struct FileMatchIndex: Sendable {
    /// Relative paths, shallowest first, then by path.
    public let paths: [String]
    /// Where each path's file name starts.
    let nameStart: [Int]
    let names: [CommandMatcher.Prepared]
    let full: [CommandMatcher.Prepared]

    public init(paths: [String]) {
        var keyed: [(path: String, depth: Int)] = []
        keyed.reserveCapacity(paths.count)
        for p in paths {
            var depth = 0
            for c in p.utf8 where c == UInt8(ascii: "/") { depth += 1 }
            keyed.append((p, depth))
        }
        keyed.sort { a, b in
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        let sorted = keyed.map(\.path)
        self.paths = sorted
        var starts: [Int] = [], ns: [CommandMatcher.Prepared] = [], fs: [CommandMatcher.Prepared] = []
        starts.reserveCapacity(sorted.count); ns.reserveCapacity(sorted.count); fs.reserveCapacity(sorted.count)
        for p in sorted {
            let name = p.split(separator: "/").last.map(String.init) ?? p
            starts.append(p.count - name.count)
            ns.append(CommandMatcher.Prepared(name))
            fs.append(CommandMatcher.Prepared(p))
        }
        nameStart = starts
        names = ns
        full = fs
    }

    public var count: Int { paths.count }

    /// The file name of path `i`.
    public func name(_ i: Int) -> String { String(paths[i].dropFirst(nameStart[i])) }

    /// The score of `query` against path `i`, or nil (no match).
    public func score(_ query: String, _ i: Int) -> Int? { score(CommandMatcher.fold(query), slash: query.contains("/"), i) }

    func score(_ q: [UInt32], slash: Bool, _ i: Int) -> Int? {
        if q.isEmpty { return 0 }
        if !slash, let s = CommandMatcher.score(q, in: names[i]) {
            return s + CommandMatcher.titleBonus + (Self.isAcronym(q, names[i]) ? Self.acronymBonus : 0)
        }
        return CommandMatcher.score(q, in: full[i])
    }

    /// The query is the name's word starts ("fs" for FolderSidebar.swift,
    /// "ad" for app_delegate.py), as Xcode and VS Code rank them: above a
    /// name that merely contains it ("offsets.txt").
    static let acronymBonus = 40

    static func isAcronym(_ q: [UInt32], _ p: CommandMatcher.Prepared) -> Bool {
        var k = 0
        for j in p.folded.indices where k < q.count && p.bonus[j] > CommandMatcher.matchPoint && p.folded[j] == q[k] { k += 1 }
        return k == q.count
    }

    /// The paths to show for `query`, as indices into `paths`, best first,
    /// at most `limit`. An empty query: the first `limit`, shallowest first.
    public func rank(_ query: String, limit: Int = QuickOpen.shownLimit) -> [Int] {
        let q = CommandMatcher.fold(query)
        if q.isEmpty { return Array(paths.indices.prefix(limit)) }
        let slash = query.contains("/")
        var hits: [(index: Int, score: Int, nameLength: Int)] = []
        for i in paths.indices {
            guard let s = score(q, slash: slash, i) else { continue }
            hits.append((i, s, paths[i].count - nameStart[i]))
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.nameLength != b.nameLength { return a.nameLength < b.nameLength }
            return a.index < b.index
        }
        return hits.prefix(limit).map(\.index)
    }
}
