import Foundation

/// Obsidian-style tags in notes (0.6): inline `#tag` and `#nested/tag`,
/// and front matter `tags:` (a YAML list or an inline value). Pure and
/// Foundation only: the line parser, a note's tags with their lines (for
/// the Tags pane, read by `BacklinkScan` in the same pass as the links),
/// and the folder's tag tree with counts.
///
/// Inline rules, one line at a time: a `#` starts a tag only at the start
/// of the line or after white space (so a URL's or a link's `#anchor`,
/// `a#b` and `&#123;` are not tags; `# Heading` and `## Heading` are
/// headings, not tags); `\#` is text; code spans are skipped (fenced code
/// is skipped by `refs`). The name runs over letters, marks, digits,
/// emoji, `_`, `-` and `/`; it needs one character that is not a digit
/// (`#123` and `#2024/11` are not tags). `/` nests (`#a/b`); empty parts
/// are dropped (`#a//b/` is `a/b`). Names compare ignoring case.
public enum Tags {
    /// The longest tag name looked at (UTF-16 units).
    public static let maxLength = 256

    static let hash: UInt16 = 35, slash: UInt16 = 47, bs: UInt16 = 92, tick: UInt16 = 96

    /// A tag in one line: its name (as written, normalized) and the range of `#name` in the line.
    public struct Found: Equatable, Sendable {
        public var name: String
        public var range: NSRange
    }

    @inline(__always)
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 0xA0 || c == 0x3000 || (c >= 0x2000 && c <= 0x200A) }

    /// Whether `s` can be in a tag name.
    static func isTagScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x5F, 0x2D, 0x2F: return true // _ - /
        case 0x200D, 0xFE0F: return true // emoji joiner, emoji presentation
        default: break
        }
        if s.value < 0x80 {
            return (s.value >= 0x30 && s.value <= 0x39) || (s.value | 0x20 >= 0x61 && s.value | 0x20 <= 0x7A)
        }
        let p = s.properties
        switch p.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return true
        case .otherSymbol, .modifierSymbol:
            // Emoji, and their skin tones.
            return p.isEmoji
        default:
            return false
        }
    }

    /// The tag name starting at `start` (just past the `#`): where it ends.
    @inline(__always)
    static func nameEnd(_ b: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        let n = b.count
        var j = start
        while j < n, j - start < maxLength {
            let c = b[j]
            if c < 0x80 {
                guard isTagScalar(Unicode.Scalar(UInt8(c))) else { break }
                j += 1
                continue
            }
            if UTF16.isLeadSurrogate(c) {
                guard j + 1 < n, UTF16.isTrailSurrogate(b[j + 1]) else { break }
                let v = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(b[j + 1]) - 0xDC00)
                guard let s = Unicode.Scalar(v), isTagScalar(s) else { break }
                j += 2
                continue
            }
            guard let s = Unicode.Scalar(c), isTagScalar(s) else { break }
            j += 1
        }
        return j
    }

    /// `raw` as a tag name: empty parts dropped; nil when nothing is left
    /// or it is only digits (and slashes).
    public static func normalize<S: StringProtocol>(_ raw: S) -> String? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        let name = parts.joined(separator: "/")
        guard name.unicodeScalars.contains(where: { !($0.value >= 0x30 && $0.value <= 0x39) && $0 != "/" }) else { return nil }
        return name
    }

    /// The inline tags in one line (no line break), outside code spans.
    public static func tags(inLine b: UnsafeBufferPointer<UInt16>) -> [Found] {
        var out: [Found] = []
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c == bs { i += 2; continue }
            if c == tick {
                let (runEnd, span) = WikiLinks.codeSpanEnd(b, at: i)
                i = span ?? runEnd
                continue
            }
            if c == hash, i == 0 || isSpace(b[i - 1]) {
                let e = nameEnd(b, from: i + 1)
                if e > i + 1 {
                    let raw = String(decoding: UnsafeBufferPointer(rebasing: b[(i + 1)..<e]), as: UTF16.self)
                    if let name = normalize(raw) { out.append(Found(name: name, range: NSRange(location: i, length: e - i))) }
                }
                i = max(e, i + 1)
                continue
            }
            i += 1
        }
        return out
    }

    public static func tags(inLine s: String) -> [Found] {
        let u = Array(s.utf16)
        return u.withUnsafeBufferPointer { tags(inLine: $0) }
    }

    /// A tag found in a note, for the Tags pane.
    public struct Ref: Equatable, Sendable {
        public var name: String
        /// 0-based line.
        public var line: Int
        /// The line, trimmed and shortened (as Backlinks' snippets).
        public var snippet: String

        public init(name: String, line: Int, snippet: String) {
            self.name = name
            self.line = line
            self.snippet = snippet
        }
    }

    /// The tags in `text`: front matter `tags:` first, then inline tags
    /// outside fenced code, each tag once (its first place; names compare
    /// ignoring case), in order.
    public static func refs(in text: String) -> [Ref] {
        var out: [Ref] = []
        var seen = Set<String>()
        func add(_ name: String, _ line: Int, _ l: String) {
            if seen.insert(name.lowercased()).inserted { out.append(Ref(name: name, line: line, snippet: WikiLinks.snippet(l))) }
        }
        var fence: (UInt16, Int)?
        var line = 0
        // Front matter: from a first line `---` to the next `---` or `...`.
        var front: FrontMatter? = nil
        text.enumerateLines { l, stop in
            defer { line += 1 }
            if line == 0 {
                var first = l
                if first.hasPrefix("\u{FEFF}") { first.removeFirst() }
                if first.trimmingCharacters(in: .whitespaces) == "---" { front = FrontMatter(); return }
            }
            if front != nil {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { front = nil; return }
                for name in front!.feed(l) { add(name, line, l) }
                return
            }
            let u = Array(l.utf16)
            if WikiLinks.fenceLine(u, fence: &fence) { return }
            guard u.count >= 2, u.contains(hash) else { return }
            for f in u.withUnsafeBufferPointer({ tags(inLine: $0) }) { add(f.name, line, l) }
        }
        return out
    }

    /// Reads front matter one line at a time, for its `tags:` (or `tag:`).
    struct FrontMatter {
        /// In a `tags:` with nothing after it: the list items that follow.
        var inList = false

        mutating func feed(_ l: String) -> [String] {
            let first = l.first
            if inList {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") || t == "-" {
                    return Tags.item(t.dropFirst()).map { [$0] } ?? []
                }
                // Blank lines and comments keep the list; another key ends it.
                if t.isEmpty || t.hasPrefix("#") { return [] }
                if first == " " || first == "\t" { return [] }
                inList = false
            }
            guard let colon = l.firstIndex(of: ":"), first != " ", first != "\t" else { return [] }
            let key = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "tags" || key == "tag" else { return [] }
            var value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A flow list (its items may be written `#tag`), up to its `]`.
            if value.hasPrefix("[") {
                var inner = value.dropFirst()
                if let close = inner.firstIndex(of: "]") { inner = inner[..<close] }
                return inner.split(separator: ",").compactMap { Tags.item($0) }
            }
            // A YAML comment after the value.
            if let r = value.range(of: " #") { value = String(value[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if value.hasPrefix("#") { value = "" }
            if value.isEmpty { inList = true; return [] }
            // Inline: separated by commas or spaces.
            return value.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).compactMap { Tags.item($0) }
        }
    }

    /// One front-matter value as a tag: quotes and a leading `#` taken off.
    static func item<S: StringProtocol>(_ raw: S) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if t.hasPrefix("#") { t.removeFirst() }
        guard !t.isEmpty, t.utf16.count <= maxLength, t.unicodeScalars.allSatisfy(isTagScalar) else { return nil }
        return normalize(t)
    }
}

/// The folder's tags as a tree, with the notes that have each: made from
/// each note's `Tags.Ref`s (`BacklinkScan`'s cache), off the main thread.
///
/// A tag's count is the notes that have it or a tag nested under it
/// (`#a/b` counts for `a` too). Siblings go by count, most first, then by
/// name. A name is shown as first written (by note path, then line);
/// names compare ignoring case.
public struct TagTree: Sendable {
    public struct Node: Equatable, Sendable {
        /// The last part of the name (`b` for `a/b`).
        public var name: String
        /// The whole name (`a/b`).
        public var path: String
        public var count: Int
        public var children: [Node]
    }

    /// A note with a tag: where it is first in that note.
    public struct Hit: Equatable, Sendable {
        /// The note (relative path).
        public var source: String
        public var tag: String
        public var line: Int
        public var snippet: String
    }

    public let roots: [Node]
    /// Distinct tags (nested ones and the tags above them each count).
    public let tagCount: Int
    /// Lowercased tag path → its notes (its own and those under it), by path.
    let hits: [String: [Hit]]

    public init(files: [String: [Tags.Ref]]) {
        // Lowercased path → (shown path, note → its first hit).
        var shown: [String: String] = [:]
        var byKey: [String: [String: Hit]] = [:]
        for src in files.keys.sorted() {
            for r in files[src] ?? [] {
                let parts = r.name.split(separator: "/").map(String.init)
                var lower = ""
                var display = ""
                for (k, p) in parts.enumerated() {
                    lower += (k == 0 ? "" : "/") + p.lowercased()
                    display += (k == 0 ? "" : "/") + p
                    if shown[lower] == nil { shown[lower] = display }
                    let hit = Hit(source: src, tag: r.name, line: r.line, snippet: r.snippet)
                    if let old = byKey[lower]?[src], old.line <= r.line { continue }
                    byKey[lower, default: [:]][src] = hit
                }
            }
        }
        var hits: [String: [Hit]] = [:]
        for (k, v) in byKey { hits[k] = v.values.sorted { $0.source < $1.source } }
        self.hits = hits
        tagCount = hits.count
        // Children by parent key.
        var kids: [String: [String]] = [:]
        for k in hits.keys {
            let parent = (k as NSString).deletingLastPathComponent
            kids[k.contains("/") ? parent : "", default: []].append(k)
        }
        func build(_ parent: String) -> [Node] {
            (kids[parent] ?? []).map { k in
                let path = shown[k] ?? k
                return Node(name: (path as NSString).lastPathComponent, path: path, count: hits[k]?.count ?? 0, children: build(k))
            }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                return c != .orderedSame ? c == .orderedAscending : a.name < b.name
            }
        }
        roots = build("")
    }

    /// The notes with `tag` or a tag under it, by path, each once at its first such line.
    public func notes(for tag: String) -> [Hit] { hits[tag.lowercased()] ?? [] }

    /// The node for `tag` (ignoring case), if any.
    public func node(_ tag: String) -> Node? {
        let want = tag.lowercased()
        var level = roots
        var found: Node?
        for part in want.split(separator: "/") {
            guard let n = level.first(where: { $0.name.lowercased() == part }) else { return nil }
            found = n
            level = n.children
        }
        return found
    }
}
