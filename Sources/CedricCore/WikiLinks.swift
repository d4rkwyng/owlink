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
                if c == lb || c == nl || i - o > maxBody { open = nil; continue }
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
        var fence: (UInt16, Int)?
        var line = 0
        text.enumerateLines { l, _ in
            defer { line += 1 }
            let u = Array(l.utf16)
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
                    return
                }
            }
            if fence != nil { return }
            guard u.count >= 5 else { return }
            let found = u.withUnsafeBufferPointer { links(inLine: $0) }
            guard !found.isEmpty else { return }
            let snippet = Self.snippet(l)
            for f in found where !f.target.isEmpty { out.append(Ref(target: f.target, line: line, snippet: snippet)) }
        }
        return out
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
    /// update; nil looks at every note's date and size.
    public mutating func update(notes: [String], dirty: Set<String>?, cancelled: () -> Bool = { false }) {
        let list = notes.sorted()
        skipped = max(0, list.count - Self.maxFiles)
        lastRead = 0
        let kept = Array(list.prefix(Self.maxFiles))
        let keep = Set(kept)
        for k in files.keys where !keep.contains(k) { files[k] = nil }
        let fm = FileManager.default
        for rel in kept {
            if cancelled() { return }
            if let dirty, files[rel] != nil, !dirty.contains((rel as NSString).deletingLastPathComponent) { continue }
            let url = root.appendingPathComponent(rel)
            guard let a = try? fm.attributesOfItem(atPath: url.path), let size = (a[.size] as? NSNumber)?.intValue,
                  let date = a[.modificationDate] as? Date else { files[rel] = nil; continue }
            if let e = files[rel], e.size == size, e.modified == date { continue }
            guard size <= Self.maxFileBytes else { files[rel] = nil; skipped += 1; continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { files[rel] = nil; skipped += 1; continue }
            lastRead += 1
            files[rel] = Entry(size: size, modified: date, refs: Self.refs(in: data))
        }
    }

    static func refs(in data: Data) -> [WikiLinks.Ref] {
        // Most notes hold no link: two bytes looked for before decoding.
        let has = data.withUnsafeBytes { raw -> Bool in
            guard let p = raw.baseAddress, raw.count >= 5 else { return false }
            return memmem(p, raw.count, "[[", 2) != nil
        }
        guard has else { return [] }
        // A NUL early on: not text.
        if data.prefix(8192).contains(0) { return [] }
        return WikiLinks.refs(in: String(decoding: data, as: UTF8.self))
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
