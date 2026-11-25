import Foundation

/// A file's own line breaks when they are mixed (some LF, some CRLF or
/// CR), so a save writes each one back as it was rather than all as the
/// most common kind. The editor's text has every break as LF; this keeps
/// the breaks that weren't the most common kind (`dominant`), by where
/// their "\n" is in that text, and follows them through every edit
/// (`replace`, called for each change to the text): a break stays with
/// its "\n" wherever text is typed or deleted around it, so its identity
/// never depends on what the lines say. A break the user types, or one a
/// tool rewrites, is `dominant`. A break an edit deletes goes; the editor
/// keeps what `replace` returns and gives it back (`restore`) when undo
/// puts the text back.
///
/// Made while decoding (TextCodec.lfOnly notes each break that isn't the
/// most common kind as it turns CR and CRLF into LF), so opening costs no
/// pass of its own, and a file with a handful of odd breaks keeps a
/// handful of numbers however large it is.
public struct LineBreaks: Sendable, Equatable {
    /// What every break not in `others` is: the file's most common kind,
    /// and what a break the user types gets.
    public let dominant: LineEnding
    /// Each break that isn't `dominant`: the UTF-16 offset of its "\n" in
    /// the text, shifted left 2, plus its kind (`code`); ascending.
    public private(set) var others: [Int] {
        didSet { if others.isEmpty { counts = [0, 0, 0] } }
    }
    /// How many of `others` are each kind (by `code`), kept with every
    /// change to `others`, so `summary` costs nothing per keystroke.
    public private(set) var counts: [Int] = [0, 0, 0]

    public init(dominant: LineEnding, others: [Int] = []) {
        self.dominant = dominant
        self.others = others
        for e in others { counts[e & 3] += 1 }
    }

    /// Some break isn't `dominant`. Not by itself "mixed": every break
    /// may be odd once the dominant ones are deleted (`summary`).
    public var isMixed: Bool { !others.isEmpty }

    /// What the text's `newlines` breaks are now: the most common kind,
    /// and whether more than one kind is left. All the dominant breaks
    /// deleted and only odd ones left is one kind, not mixed (the status
    /// said "LF (mixed)" for a file now all CRLF); the last odd break gone
    /// is the dominant kind alone.
    public func summary(newlines: Int) -> (ending: LineEnding, mixed: Bool) {
        var byKind = counts
        byKind[Self.code(dominant)] += max(0, newlines - others.count)
        let kinds = byKind.filter { $0 > 0 }.count
        guard kinds > 1 else {
            // One kind (or no break at all: the file's own).
            let only = byKind.firstIndex(where: { $0 > 0 }).map(Self.kind) ?? dominant
            return (only, false)
        }
        // Ties go to the file's own kind, then LF, CRLF, CR.
        var best = Self.code(dominant)
        for c in [0, 1, 2] where byKind[c] > byKind[best] { best = c }
        return (Self.kind(best), true)
    }

    static func code(_ le: LineEnding) -> Int {
        switch le { case .lf: return 0; case .crlf: return 1; case .cr: return 2 }
    }
    static func kind(_ code: Int) -> LineEnding { code == 1 ? .crlf : code == 2 ? .cr : .lf }

    /// One `others` entry: the "\n" at UTF-16 `offset`, written as `le`.
    public static func entry(_ offset: Int, _ le: LineEnding) -> Int { offset << 2 | code(le) }

    /// The first entry at or after UTF-16 `offset`.
    public func index(from offset: Int) -> Int {
        var lo = 0, hi = others.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if others[mid] >> 2 < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// How the "\n" at UTF-16 `offset` is written.
    public func ending(at offset: Int) -> LineEnding {
        let i = index(from: offset)
        return i < others.count && others[i] >> 2 == offset ? Self.kind(others[i] & 3) : dominant
    }

    /// Each break of `text` as written, in order (one per "\n").
    public func endings(in text: String) -> [LineEnding] {
        var out: [LineEnding] = []
        for (i, u) in text.utf16.enumerated() where u == 10 { out.append(ending(at: i)) }
        return out
    }

    /// The text changed: the UTF-16 range `old` (in the text before)
    /// became `newLength` units. Breaks in `old` go (they were deleted, or
    /// rewritten); those after it move with their "\n". Returns the ones
    /// that went, offsets relative to `old.location`, for `restore`.
    @discardableResult
    public mutating func replace(_ old: NSRange, newLength: Int) -> [Int] {
        let start = index(from: old.location)
        let end = index(from: NSMaxRange(old))
        let removed = others[start..<end].map { $0 - (old.location << 2) }
        for e in others[start..<end] { counts[e & 3] -= 1 }
        let delta = newLength - old.length
        if delta != 0 {
            let shift = delta << 2
            for i in end..<others.count { others[i] += shift }
        }
        if end > start { others.removeSubrange(start..<end) }
        return removed
    }

    /// Undo (or redo) put text back at `location`: the breaks `replace`
    /// took from it (`removed`) come back, those inside `within` that are
    /// a "\n" in `text` again. Returns the ones not given back.
    public mutating func restore(_ removed: [Int], at location: Int, within: NSRange, in text: NSString) -> [Int] {
        var left: [Int] = []
        for r in removed {
            let at = location + r >> 2
            guard NSLocationInRange(at, within), at < text.length, text.character(at: at) == 10 else { left.append(r); continue }
            let i = index(from: at)
            if i < others.count, others[i] >> 2 == at { continue }
            if Self.kind(r & 3) != dominant {
                others.insert(Self.entry(at, Self.kind(r & 3)), at: i)
                counts[r & 3] += 1
            }
        }
        return left
    }

    /// Where `others` is stored (tests: an append made in place keeps it).
    var othersAddress: UnsafeRawPointer? { others.withUnsafeBufferPointer { $0.baseAddress.map(UnsafeRawPointer.init) } }

    /// Text was added at the end (`offset`, its start: Follow File):
    /// `added`'s breaks, by offsets in that text, follow. Its own dominant
    /// kind must be this one's (only its odd breaks are kept).
    public mutating func append(_ added: LineBreaks, at offset: Int) {
        guard !added.others.isEmpty else { return }
        let shifted = added.others.map { $0 + (offset << 2) }
        if let last = others.last, last >> 2 >= offset { return }
        others.append(contentsOf: shifted)
        for e in shifted { counts[e & 3] += 1 }
    }

    /// Whether replacing `old` with `new` keeps every line, only changing
    /// the spaces and tabs at its start or end (Convert Indentation,
    /// Indent, Outdent, trimming trailing whitespace): the same number of
    /// breaks, and each line the same once those are set aside. Then each
    /// break is still the one it was (`kinds`, `place`), not a new one.
    public static func keepsLines(_ old: NSString, _ new: NSString) -> Bool {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        guard a.count == b.count else { return false }
        let blank = CharacterSet(charactersIn: " \t")
        for (x, y) in zip(a, b) where x != y {
            if x.trimmingCharacters(in: blank) != y.trimmingCharacters(in: blank) { return false }
        }
        return true
    }

    /// How each "\n" in `range` of `text` (the text before an edit) is
    /// written, in order.
    public func kinds(in range: NSRange, of text: NSString) -> [LineEnding] {
        var out: [LineEnding] = []
        var at = range.location
        let end = NSMaxRange(range)
        var i = index(from: at)
        while at < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: at, length: end - at))
            guard found.location != NSNotFound else { break }
            while i < others.count, others[i] >> 2 < found.location { i += 1 }
            out.append(i < others.count && others[i] >> 2 == found.location ? Self.kind(others[i] & 3) : dominant)
            at = found.location + 1
        }
        return out
    }

    /// An edit that kept every line (`keepsLines`) replaced the text in
    /// `range` (now, in `text`): its breaks, in order, are `kinds` again
    /// (what `kinds` read before the edit). `replace` took them out.
    public mutating func place(_ kinds: [LineEnding], newlinesIn range: NSRange, of text: NSString) {
        var at = range.location
        let end = NSMaxRange(range)
        var k = 0
        var added: [Int] = []
        while at < end, k < kinds.count {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: at, length: end - at))
            guard found.location != NSNotFound else { break }
            let le = kinds[k]
            k += 1
            at = found.location + 1
            if le != dominant { added.append(Self.entry(found.location, le)) }
        }
        guard !added.isEmpty else { return }
        // `replace` left none inside `range`: they go in as one block.
        let i = index(from: range.location)
        guard i == index(from: end) else { return }
        others.insert(contentsOf: added, at: i)
        for e in added { counts[e & 3] += 1 }
    }

    /// `text` (every break "\n") with each break as this file has it:
    /// `others` as they are, every other `dominant`. A CR straight before
    /// an LF would read back as one CRLF (two lines become one; only an
    /// edit can put them together): that CR is written as CRLF.
    public func output(_ text: String) -> String {
        if others.isEmpty, dominant == .lf { return text }
        let ns = text as NSString
        let length = ns.length
        let out = NSMutableString(capacity: length + (dominant == .crlf ? length / 16 : 0) + others.count)
        func plain(_ from: Int, _ to: Int) {
            guard to > from else { return }
            let piece = ns.substring(with: NSRange(location: from, length: to - from))
            if dominant == .lf { out.append(piece); return }
            let m = NSMutableString(string: piece)
            m.replaceOccurrences(of: "\n", with: dominant.string, options: .literal, range: NSRange(location: 0, length: m.length))
            out.append(m as String)
        }
        var prev = 0
        for (i, e) in others.enumerated() {
            let at = e >> 2
            // Stale (never, if every edit was passed to `replace`): ignored.
            guard at >= prev, at < length, ns.character(at: at) == 10 else { continue }
            plain(prev, at)
            var le = Self.kind(e & 3)
            if le == .cr, at + 1 < length, ns.character(at: at + 1) == 10 {
                let next = i + 1 < others.count && others[i + 1] >> 2 == at + 1 ? Self.kind(others[i + 1] & 3) : dominant
                if next == .lf { le = .crlf }
            }
            // A `dominant` CR just before this LF.
            if le == .lf, dominant == .cr, at > 0, ns.character(at: at - 1) == 10,
               i == 0 || others[i - 1] >> 2 != at - 1 {
                out.append("\n")
            }
            out.append(le.string)
            prev = at + 1
        }
        plain(prev, length)
        return out as String
    }

    /// Text written by `output` (a session buffer) read back: LF text, and
    /// its breaks against `dominant`.
    public static func read(_ written: String, dominant: LineEnding) -> (text: String, breaks: LineBreaks) {
        var copy = written
        var rec: TextCodec.BreakRecorder? = TextCodec.BreakRecorder(dominant: dominant, ascii: false)
        let text = copy.withUTF8 { b -> String in
            guard b.count > 0 else { return "" }
            return String(unsafeUninitializedCapacity: b.count) {
                TextCodec.lfOnly(UnsafeRawBufferPointer(b), into: $0.baseAddress!, capacity: b.count, recording: &rec) ?? b.count
            }
        }
        return (text, LineBreaks(dominant: dominant, others: rec?.others ?? []))
    }
}
