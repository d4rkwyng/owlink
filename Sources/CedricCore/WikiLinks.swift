import Foundation

/// Obsidian-style `[[wiki links]]` in the editor (0.6): `[[Name]]`,
/// `[[Name|alias]]`, `[[Name#Heading]]`, `![[Name]]`. Pure and Foundation
/// only: the line parser (shared with the Markdown colouring), what is
/// being typed after a `[[`, the folder's note names and how a link
/// resolves to one, and the links each note holds (for Backlinks).
///
/// Rules, one line at a time: `\` escapes the next character (`\[[` is
/// text); a code span (a run of backticks closed by the same run on the
/// line) is skipped whole; `[[` opens a link whose body runs to the next
/// `]]` and may not hold `[`, `]` or a line break, nor be blank, nor be
/// longer than `maxBody` (so `[[[x]]]` is the link `[[x]]` inside
/// brackets, and `[[a]b]]` is no link). In a table, `\|` is the alias bar.
public enum WikiLinks {
    /// The file types that are notes: what Owlink edits as Markdown or plain text.
    public static let noteExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]
    /// The longest link body looked at (UTF-16 units).
    public static let maxBody = 999

    public static func isNote(_ path: String) -> Bool {
        noteExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public struct Link: Equatable, Sendable {
        /// The whole `[[…]]` (with a leading `!` for an embed), in the line.
        public var range: NSRange
        /// The note named (before `#` and `|`), trimmed; "" for `[[#Heading]]`.
        public var target: String
        public var heading: String?
        public var alias: String?
        public var embed: Bool

        public init(range: NSRange, target: String, heading: String? = nil, alias: String? = nil, embed: Bool = false) {
            self.range = range
            self.target = target
            self.heading = heading
            self.alias = alias
            self.embed = embed
        }
    }

    static let lb: UInt16 = 91, rb: UInt16 = 93, bs: UInt16 = 92, tick: UInt16 = 96, bang: UInt16 = 33, nl: UInt16 = 10, cr: UInt16 = 13

    /// Where the link opened by the `[[` at `open` ends (just past its
    /// `]]`), or nil when there is none there.
    @inline(__always)
    public static func end(in b: UnsafeBufferPointer<UInt16>, open: Int) -> Int? {
        let n = b.count
        guard open + 1 < n, b[open] == lb, b[open + 1] == lb else { return nil }
        var j = open + 2
        var blank = true
        while j < n, j - open - 2 <= maxBody {
            let c = b[j]
            if c == lb || c == nl || c == cr { return nil }
            if c == rb {
                guard j + 1 < n, b[j + 1] == rb, !blank else { return nil }
                return j + 2
            }
            if c != 32 && c != 9 { blank = false }
            j += 1
        }
        return nil
    }

    /// After the backtick run at `i`: past the code span it opens, or nil
    /// when the run isn't closed on the line.
    @inline(__always)
    static func codeSpanEnd(_ b: UnsafeBufferPointer<UInt16>, at i: Int) -> (runEnd: Int, spanEnd: Int?) {
        let n = b.count
        var run = 0
        while i + run < n, b[i + run] == tick { run += 1 }
        var j = i + run
        while j < n {
            if b[j] == tick {
                var k = 0
                while j + k < n, b[j + k] == tick { k += 1 }
                if k == run { return (i + run, j + k) }
                j += k
            } else {
                j += 1
            }
        }
        return (i + run, nil)
    }

    /// The links in one line (no line break), outside code spans.
    public static func links(inLine b: UnsafeBufferPointer<UInt16>) -> [Link] {
        var out: [Link] = []
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c == bs { i += 2; continue }
            if c == tick {
                let (runEnd, span) = codeSpanEnd(b, at: i)
                i = span ?? runEnd
                continue
            }
            if c == lb, let e = end(in: b, open: i) {
                let embed = i > 0 && b[i - 1] == bang && !(i > 1 && b[i - 2] == bs)
                let start = embed ? i - 1 : i
                out.append(parse(b, open: i, end: e, start: start, embed: embed))
                i = e
                continue
            }
            i += 1
        }
        return out
    }

    public static func links(inLine s: String) -> [Link] {
        let u = Array(s.utf16)
        return u.withUnsafeBufferPointer { links(inLine: $0) }
    }

    /// The link (outside code spans) whose `[[…]]` holds `offset`, if any.
    public static func link(at offset: Int, inLine b: UnsafeBufferPointer<UInt16>) -> Link? {
        links(inLine: b).first { offset >= $0.range.location && offset < NSMaxRange($0.range) }
    }

    static func parse(_ b: UnsafeBufferPointer<UInt16>, open: Int, end e: Int, start: Int, embed: Bool) -> Link {
        let body = String(decoding: UnsafeBufferPointer(rebasing: b[(open + 2)..<(e - 2)]), as: UTF16.self)
        var target = body
        var alias: String?
        if let bar = body.firstIndex(of: "|") {
            target = String(body[..<bar])
            // `\|` in a table cell: the bar is the alias bar.
            if target.hasSuffix("\\") { target.removeLast() }
            alias = String(body[body.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        }
        var heading: String?
        if let hash = target.firstIndex(of: "#") {
            let h = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            heading = h.isEmpty ? nil : h
            target = String(target[..<hash])
        }
        return Link(range: NSRange(location: start, length: e - start),
                    target: target.trimmingCharacters(in: .whitespaces), heading: heading, alias: alias, embed: embed)
    }

    /// A `[[` being typed: the note name typed so far after it, and where
    /// that name starts in the line. nil when `caret` isn't in an open
    /// `[[` on its line, is in a code span (one still being typed counts),
    /// or past a `|` or `#` (an alias or a heading, not a note name).
    public struct Typing: Equatable, Sendable {
        public var start: Int
        public var query: String
    }

    /// The longest line prefix looked at for `typing` (UTF-16 units).
    public static let maxTypingColumn = 4_000

    public static func typing(inLine b: UnsafeBufferPointer<UInt16>, caret: Int) -> Typing? {
        guard caret >= 2, caret <= b.count, caret <= maxTypingColumn else { return nil }
        var i = 0
        var open: Int?
        while i < caret {
            let c = b[i]
            if let o = open {
                // A `[`, or a backtick (a code span may start there), ends the name.
                if c == lb || c == tick || c == nl || i - o > maxBody { open = nil; continue }
                if c == rb {
                    open = nil
                    i += (i + 1 < caret && b[i + 1] == rb) ? 2 : 1
                    continue
                }
                i += 1
                continue
            }
            if c == bs { i += 2; continue }
            if c == tick {
                let (runEnd, span) = codeSpanEnd(UnsafeBufferPointer(rebasing: b[0..<caret]), at: i)
                // A span still open at the caret: code being typed.
                guard let span else { return nil }
                i = max(runEnd, span)
                continue
            }
            if c == lb, i + 1 < caret, b[i + 1] == lb {
                // `[[[`: the innermost pair opens it.
                if i + 2 < caret, b[i + 2] == lb { i += 1; continue }
                open = i + 2
                i += 2
                continue
            }
            i += 1
        }
        guard let o = open else { return nil }
        let q = String(decoding: UnsafeBufferPointer(rebasing: b[o..<caret]), as: UTF16.self)
        guard !q.contains("|"), !q.contains("#"), !q.hasPrefix(" ") else { return nil }
        return Typing(start: o, query: q)
    }

    public static func typing(inLine s: String, caret: Int) -> Typing? {
        let u = Array(s.utf16)
        return u.withUnsafeBufferPointer { typing(inLine: $0, caret: caret) }
    }

    /// A link found in a note's text, for Backlinks.
    public struct Ref: Equatable, Sendable {
        public var target: String
        /// 0-based line.
        public var line: Int
        /// The line, trimmed and shortened to `snippetLength`.
        public var snippet: String
    }

    public static let snippetLength = 160

    /// Every link in `text` outside code spans and fenced code (``` and
    /// ~~~), with its line. `[[#Heading]]` (the note itself) is left out.
    public static func refs(in text: String) -> [Ref] {
        var out: [Ref] = []
        forEachRef(in: text) { out.append($0); return true }
        return out
    }

    /// The links `refs(in:)` finds, handed to `body` one at a time as each
    /// line is parsed (nothing kept here); `body` returns false to stop.
    /// `cancelled` is asked before each line. False when stopped either way.
    @discardableResult
    public static func forEachRef(in text: String, cancelled: () -> Bool = { false }, _ body: (Ref) -> Bool) -> Bool {
        // `enumerateLines` takes an escaping closure; these don't outlive this call.
        withoutActuallyEscaping(cancelled) { cancelled in
            withoutActuallyEscaping(body) { body in eachRef(in: text, cancelled: cancelled, body) }
        }
    }

    private static func eachRef(in text: String, cancelled: @escaping () -> Bool, _ body: @escaping (Ref) -> Bool) -> Bool {
        var fence: (UInt16, Int)?
        var line = 0
        var finished = true
        text.enumerateLines { l, stop in
            defer { line += 1 }
            if cancelled() { finished = false; stop = true; return }
            let u = Array(l.utf16)
            if fenceLine(u, fence: &fence) { return }
            guard u.count >= 5 else { return }
            let found = u.withUnsafeBufferPointer { links(inLine: $0) }
            guard !found.isEmpty else { return }
            let snippet = Self.snippet(l)
            for f in found where !f.target.isEmpty {
                guard body(Ref(target: f.target, line: line, snippet: snippet)) else { finished = false; stop = true; return }
            }
        }
        return finished
    }

    /// Fenced code (``` and ~~~, up to three spaces in), one line at a time:
    /// true when `u` opens or closes a fence or is inside one. `fence` is
    /// the open fence's character and length, carried from line to line.
    static func fenceLine(_ u: [UInt16], fence: inout (UInt16, Int)?) -> Bool {
        var k = 0
        while k < u.count, k < 4, u[k] == 32 { k += 1 }
        if k <= 3, k < u.count, u[k] == tick || u[k] == 126 {
            var run = 0
            while k + run < u.count, u[k + run] == u[k] { run += 1 }
            if run >= 3 {
                if let f = fence {
                    if f.0 == u[k], run >= f.1, u[(k + run)...].allSatisfy({ $0 == 32 || $0 == 9 }) { fence = nil }
                } else {
                    fence = (u[k], run)
                }
                return true
            }
        }
        return fence != nil
    }

    static func snippet(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > snippetLength ? String(t.prefix(snippetLength)) + "…" : t
    }
}

/// The open folder's notes by name: what `[[` offers and where a link
/// goes. Made off the main thread from the folder's file index
/// (FileIndex, the one Open Quickly uses); ranking a query is
/// `FileMatchIndex` on the paths without their extensions.
///
/// Resolution: the exact name (or folder/name for a path), then the same
/// ignoring case; among several, the shortest path (fewest folders, then
/// fewest characters, then by path), so the same files always give the
/// same note.
public struct NoteIndex: Sendable {
    /// Note paths relative to the root, with their extensions.
    public let paths: [String]
    /// `paths[i]` without its extension.
    let stems: [String]
    let byName: [String: [Int]]
    let byLowerName: [String: [Int]]
    let matcher: FileMatchIndex
    /// A stem → the notes with it (a.md and a.txt share one).
    let byStem: [String: [Int]]

    public init(paths all: [String]) {
        let notes = all.filter(WikiLinks.isNote).sorted()
        paths = notes
        stems = notes.map { ($0 as NSString).deletingPathExtension }
        var name: [String: [Int]] = [:], lower: [String: [Int]] = [:]
        for (i, p) in notes.enumerated() {
            let file = (p as NSString).lastPathComponent
            let stem = (file as NSString).deletingPathExtension
            for key in Set([stem, file]) {
                name[key, default: []].append(i)
                lower[key.lowercased(), default: []].append(i)
            }
        }
        byName = name
        byLowerName = lower
        var st: [String: [Int]] = [:]
        for (i, s) in stems.enumerated() { st[s, default: []].append(i) }
        byStem = st
        // One entry per stem: the ranking sees each name once.
        matcher = FileMatchIndex(paths: Array(st.keys))
    }

    public var count: Int { paths.count }

    static func shortest(_ c: [Int], _ paths: [String]) -> Int? {
        c.min { a, b in
            let pa = paths[a], pb = paths[b]
            let da = pa.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }, db = pb.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }
            if da != db { return da < db }
            if pa.utf16.count != pb.utf16.count { return pa.utf16.count < pb.utf16.count }
            return pa < pb
        }
    }

    /// The note `target` names (a relative path), or nil.
    public func resolve(_ target: String) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("/") { t.removeFirst() }
        guard !t.isEmpty, !t.split(separator: "/").contains("..") else { return nil }
        let file = (t as NSString).lastPathComponent
        let folder = (t as NSString).deletingLastPathComponent
        func inFolder(_ c: [Int], caseless: Bool) -> [Int] {
            guard !folder.isEmpty else { return c }
            return c.filter { i in
                let dir = (paths[i] as NSString).deletingLastPathComponent
                let (d, f) = caseless ? (dir.lowercased(), folder.lowercased()) : (dir, folder)
                return d == f || d.hasSuffix("/" + f)
            }
        }
        let exact = inFolder(byName[file] ?? [], caseless: false)
        if let i = Self.shortest(exact, paths) { return paths[i] }
        let caseless = inFolder(byLowerName[file.lowercased()] ?? [], caseless: true)
        return Self.shortest(caseless, paths).map { paths[$0] }
    }

    /// What to type to link `path`: its name, or its path without the
    /// extension when another note has the same name (ignoring case).
    public func linkText(for path: String) -> String {
        let stem = (path as NSString).deletingPathExtension
        let name = (stem as NSString).lastPathComponent
        if resolve(name) == path { return name }
        return stem
    }

    public struct Suggestion: Equatable, Sendable {
        public var path: String
        /// The note's name (no folder, no extension).
        public var name: String
        /// Its folder ("" at the root).
        public var folder: String
        /// What `[[` gets.
        public var insert: String
    }

    /// The notes for `query`, best first: CommandMatcher's fuzzy scoring
    /// with name prefixes and word starts first, shallowest first for an
    /// empty query.
    public func suggestions(_ query: String, limit: Int = 50) -> [Suggestion] {
        var seen = Set<Int>()
        var out: [Suggestion] = []
        for m in matcher.rank(query, limit: limit) {
            // Two notes with one stem (a.md, a.txt): each is offered.
            let group = byStem[matcher.paths[m]] ?? []
            for g in group where seen.insert(g).inserted {
                let p = paths[g]
                let stem = stems[g]
                out.append(Suggestion(path: p, name: (stem as NSString).lastPathComponent,
                                      folder: (stem as NSString).deletingLastPathComponent,
                                      insert: group.count > 1 ? (p as NSString).lastPathComponent : linkText(for: p)))
            }
        }
        return Array(out.prefix(limit))
    }
}

/// The links every note in the folder holds, read from the files (no
/// database, nothing written), kept per file by modification date and
/// size, so an update reads only the notes that changed.
public struct BacklinkScan: Sendable {
    public struct Entry: Sendable {
        var size: Int
        var modified: Date
        public var refs: [WikiLinks.Ref]
        /// The note's tags (Tags.refs), or nil when they weren't read (the
        /// last update didn't ask for tags).
        public var tags: [Tags.Ref]?
    }

    public struct Backlink: Equatable, Sendable {
        /// The note linking (relative path).
        public var source: String
        public var line: Int
        public var snippet: String
    }

    /// Notes bigger than this are skipped (and the result is partial).
    public static let maxFileBytes = 5 * 1024 * 1024
    /// Notes read at most.
    public static let maxFiles = 10_000

    public let root: URL
    public private(set) var files: [String: Entry] = [:]
    /// Notes left out (too big, unreadable, past `maxFiles`) in the last update.
    public private(set) var skipped = 0
    /// Notes read (not taken from the cache) in the last update.
    public private(set) var lastRead = 0

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var isPartial: Bool { skipped > 0 }

    /// Brings the cache in line with `notes` (relative paths). `dirty`:
    /// the folders (relative, "" the root) that changed since the last
    /// update; nil looks at every note's date and size. `tags`: read each
    /// note's tags too (a note cached without them is read again); the
    /// links are always read, in the same pass.
    ///
    /// `dirty` (by the bytes: two canonically equivalent folders stay two)
    /// comes from watcher events, in their spelling; `notes` from
    /// the listing, in its own. A folder is matched by its bytes first; a
    /// changed folder no note's folder matches by bytes is matched by
    /// identity (device and inode, `identity` a seam for tests), so a case
    /// or normalization variant of a note folder still rescans it, and of
    /// two canonically equivalent folders only the one that changed. A
    /// miss alone never leaves a changed folder's notes unread.
    ///
    /// `read`: how each note is read (iOS: `readBeneath`, through the
    /// granted folder's descriptor). Nil reads by path, as the Mac always has.
    public mutating func update(notes: [String], dirty: Set<FolderTree.PathKey>?, tags: Bool = false, cancelled: () -> Bool = { false },
                                identity: (String) -> Beneath.FileID? = FolderTree.identity,
                                read: ((String) -> NoteRead)? = nil) {
        let list = notes.sorted()
        skipped = max(0, list.count - Self.maxFiles)
        lastRead = 0
        let kept = Array(list.prefix(Self.maxFiles))
        let keep = Set(kept)
        for k in files.keys where !keep.contains(k) { files[k] = nil }
        let fm = FileManager.default
        // The note's folder, split at its last "/" byte.
        func folder(_ rel: String) -> FolderTree.PathKey {
            let b = Array(rel.utf8)
            return FolderTree.PathKey(b.lastIndex(of: 0x2f).map { String(decoding: b[..<$0], as: UTF8.self) } ?? "")
        }
        // Built as bytes: a file URL decomposes an NFC name (to NFD), which would probe the other twin.
        let rootPath = root.path
        func path(_ k: FolderTree.PathKey) -> String { k.bytes.isEmpty ? rootPath : (rootPath == "/" ? "/" : rootPath + "/") + k.string }
        var changed: Set<FolderTree.PathKey>?
        if let dirty {
            var c = dirty
            let folders = Set(kept.map(folder))
            let unmatched = c.subtracting(folders)
            if !unmatched.isEmpty {
                let ids = Set(unmatched.compactMap { identity(path($0)) })
                if !ids.isEmpty {
                    for f in folders where !c.contains(f) {
                        if let id = identity(path(f)), ids.contains(id) { c.insert(f) }
                    }
                }
            }
            changed = c
        }
        for rel in kept {
            if cancelled() { return }
            let complete = files[rel].map { !tags || $0.tags != nil } ?? false
            if let changed, complete, !changed.contains(folder(rel)) { continue }
            if let read {
                switch read(rel) {
                case .gone: files[rel] = nil
                case .skipped: files[rel] = nil; skipped += 1
                case .read(let size, let date, let data):
                    if complete, let e = files[rel], e.size == size, e.modified == date { continue }
                    lastRead += 1
                    files[rel] = Entry(size: size, modified: date, refs: Self.refs(in: data), tags: tags ? Self.tags(in: data) : nil)
                }
                continue
            }
            let url = root.appendingPathComponent(rel)
            guard let a = try? fm.attributesOfItem(atPath: url.path), let size = (a[.size] as? NSNumber)?.intValue,
                  let date = a[.modificationDate] as? Date else { files[rel] = nil; continue }
            if complete, let e = files[rel], e.size == size, e.modified == date { continue }
            guard size <= Self.maxFileBytes else { files[rel] = nil; skipped += 1; continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { files[rel] = nil; skipped += 1; continue }
            lastRead += 1
            files[rel] = Entry(size: size, modified: date, refs: Self.refs(in: data), tags: tags ? Self.tags(in: data) : nil)
        }
    }

    /// One note as `update`'s `read` hands it over.
    public enum NoteRead: Sendable {
        /// Not there (or not a note any more): dropped, not counted.
        case gone
        /// Left out (a link, not a regular file, too big, unreadable, over a
        /// budget): dropped and counted, so the result is partial.
        case skipped
        case read(size: Int, modified: Date, data: Data)
    }

    /// The note at `rel` (a relative path) beneath the folder `root` has
    /// open, read through one descriptor (`Beneath.open`: never leaving
    /// the folder, the last component never followed) that must be a
    /// regular file of at most `maxBytes`. A note replaced by a symbolic
    /// link, or reached through one that leads out, is skipped: what was
    /// checked is what is read.
    public static func readBeneath(_ rel: String, root: Int32, maxBytes: Int = maxFileBytes) -> NoteRead {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fd = Beneath.open(parts, beneath: root, flags: O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .gone : .skipped }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .skipped }
        let size = Int(st.st_size)
        guard size <= maxBytes else { return .skipped }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        var data = Data(count: size)
        var off = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while off < size {
                let n = Darwin.read(fd, raw.baseAddress! + off, size - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { break }
                off += n
            }
            return true
        }
        guard ok else { return .skipped }
        if off < size { data.count = off }
        return .read(size: size, modified: modified, data: data)
    }

    static func refs(in data: Data) -> [WikiLinks.Ref] {
        guard mayHoldLinks(data) else { return [] }
        return WikiLinks.refs(in: String(decoding: data, as: UTF8.self))
    }

    /// Most notes hold no link: two bytes looked for before decoding. A
    /// NUL early on: not text.
    static func mayHoldLinks(_ data: Data) -> Bool {
        let has = data.withUnsafeBytes { raw -> Bool in
            guard let p = raw.baseAddress, raw.count >= 5 else { return false }
            return memmem(p, raw.count, "[[", 2) != nil
        }
        return has && !data.prefix(8192).contains(0)
    }

    static func tags(in data: Data) -> [Tags.Ref] {
        guard mayHoldTags(data) else { return [] }
        return Tags.refs(in: String(decoding: data, as: UTF8.self))
    }

    /// A note with no `#` holds no tag (front matter `tags:` needs none,
    /// so a note starting with `---` is read too).
    static func mayHoldTags(_ data: Data) -> Bool {
        let has = data.withUnsafeBytes { raw -> Bool in
            guard let p = raw.baseAddress, raw.count >= 2 else { return false }
            return memchr(p, 35, raw.count) != nil || (raw.count >= 3 && memcmp(p, "---", 3) == 0)
                || (raw.count >= 6 && memcmp(p, "\u{FEFF}---", 6) == 0)
        }
        return has && !data.prefix(8192).contains(0)
    }

    /// What `collect` found: at most its limits, in the order `backlinks(to:)`
    /// and `tagsByNote` (by note) give them.
    public struct Collected: Sendable {
        public var backlinks: [Backlink] = []
        public var tagsByNote: [String: [Tags.Ref]] = [:]
        /// Notes left out (too big, unreadable, past `maxFiles`).
        public var skipped = 0
        /// More backlinks or tags were there than the limits keep.
        public var truncated = false
        /// `cancelled` said stop: the rest is what was found until then.
        public var cancelled = false
        /// Links and tags parsed (tests).
        public var parsed = 0
    }

    /// One pass over `notes` (relative paths) for the backlinks to `note`
    /// and every note's tags, with the limits kept as they are collected:
    /// each link is resolved as it is parsed and kept only when it leads to
    /// `note`, up to `maxBacklinks`, and tags up to `maxTagRefs` in all;
    /// past both nothing more is parsed. Nothing is cached. `cancelled` is
    /// asked before each note and each line of one. `read` as `update`'s.
    public static func collect(notes: [String], to note: String, in index: NoteIndex, maxBacklinks: Int, maxTagRefs: Int,
                               cancelled: () -> Bool = { false }, read: (String) -> NoteRead) -> Collected {
        var out = Collected()
        let list = notes.sorted()
        out.skipped = max(0, list.count - maxFiles)
        var resolved: [String: String?] = [:]
        var linksFull = false, tagsFull = false
        var tagRoom = maxTagRefs
        for rel in list.prefix(maxFiles) {
            if cancelled() { out.cancelled = true; break }
            if linksFull && tagsFull { break }
            let data: Data
            switch read(rel) {
            case .gone: continue
            case .skipped: out.skipped += 1; continue
            case .read(_, _, let d): data = d
            }
            let wantLinks = !linksFull && rel != note && mayHoldLinks(data)
            let wantTags = !tagsFull && mayHoldTags(data)
            guard wantLinks || wantTags else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if wantLinks {
                WikiLinks.forEachRef(in: text, cancelled: cancelled) { r in
                    out.parsed += 1
                    let to: String?
                    if let c = resolved[r.target] { to = c } else {
                        to = index.resolve(r.target)
                        // Bounded too: a folder of distinct targets doesn't grow it past this.
                        if resolved.count >= 10_000 { resolved.removeAll(keepingCapacity: true) }
                        resolved[r.target] = to
                    }
                    guard to == note else { return true }
                    guard out.backlinks.count < maxBacklinks else { linksFull = true; return false }
                    out.backlinks.append(Backlink(source: rel, line: r.line, snippet: r.snippet))
                    return true
                }
            }
            if wantTags, !cancelled() {
                var kept: [Tags.Ref] = []
                Tags.forEachRef(in: text, cancelled: cancelled) { r in
                    out.parsed += 1
                    guard tagRoom > 0 else { tagsFull = true; return false }
                    kept.append(r)
                    tagRoom -= 1
                    return true
                }
                if !kept.isEmpty { out.tagsByNote[rel] = kept }
            }
            if cancelled() { out.cancelled = true; break }
        }
        out.truncated = linksFull || tagsFull
        return out
    }

    /// Each note's tags (the notes whose tags were read).
    public var tagsByNote: [String: [Tags.Ref]] {
        var out: [String: [Tags.Ref]] = [:]
        for (k, e) in files { if let t = e.tags, !t.isEmpty { out[k] = t } }
        return out
    }

    /// The notes linking to `path` (not itself), by source then line.
    public func backlinks(to path: String, in index: NoteIndex) -> [Backlink] {
        var out: [Backlink] = []
        var resolved: [String: String?] = [:]
        for (src, e) in files where src != path {
            for r in e.refs {
                let to: String?
                if let c = resolved[r.target] { to = c } else { to = index.resolve(r.target); resolved[r.target] = to }
                if to == path { out.append(Backlink(source: src, line: r.line, snippet: r.snippet)) }
            }
        }
        return out.sorted { $0.source != $1.source ? $0.source < $1.source : $0.line < $1.line }
    }
}
