import Foundation

/// A file's own line breaks when they are mixed (some LF, some CRLF or
/// CR), so a save writes each one back as it was rather than all as the
/// most common kind. The editor's text has every break as LF; this keeps
/// which of them were CR or CRLF on disk, against the text they belong to
/// (as last read or saved).
///
/// A save (`write(_:)`) matches the lines of the text being saved to the
/// lines of that text: a line that is still there keeps its break, so
/// edits anywhere, and undoing them, leave every other break as it was;
/// undone all the way, the bytes are the file's again. A line break the
/// user typed gets the most common kind. Where lines were changed, each
/// changed line keeps the break of the old line it most resembles (same
/// start or, weighted higher, same end: the break follows the end), so
/// typing in a line, pressing Return in it (the second half keeps the
/// break, where it was) or joining two lines (the joined line keeps the
/// second's) keeps the breaks around it; lines left unpaired between
/// those take the old breaks by position from the end.
///
/// Made while decoding (TextCodec.lfOnly notes each CR and CRLF it turns
/// into LF), so opening costs no pass of its own; the matching runs only
/// on save.
public struct LineBreaks: Sendable {
    /// The LF-normalised text these breaks belong to.
    public let text: String
    /// Each break that wasn't LF on disk, by the UTF-8 offset of its "\n"
    /// in `text`, ascending: offset << 1, plus 1 for CRLF (0: CR).
    public let crBreaks: [Int]
    /// The most common kind: what a break the user types gets.
    public let dominant: LineEnding

    public init(text: String, crBreaks: [Int], dominant: LineEnding) {
        self.text = text
        self.crBreaks = crBreaks
        self.dominant = dominant
    }

    /// The breaks of `text` as written to disk, in order (one per "\n").
    public var endings: [LineEnding] {
        var copy = text
        return copy.withUTF8 { Self.lines(of: $0).breaks(crBreaks) }
    }

    /// The text that was saved and how its breaks were written: the next
    /// save's starting point, and whether they are still mixed.
    public struct Saved: Sendable {
        /// `text` with each break as it is written ("\r\n", "\r" or "\n").
        public let output: String
        public let breaks: LineBreaks
        public let mixed: Bool
        /// The most common kind among the breaks written.
        public let dominant: LineEnding
    }

    /// `newText` (LF-normalised) with each line break as this file had it
    /// where the line is still there, and `dominant` where it is new.
    public func write(_ newText: String) -> Saved {
        var old = text, new = newText
        return old.withUTF8 { ob in
            new.withUTF8 { nb in
                let o = Self.lines(of: ob), n = Self.lines(of: nb)
                let oldEnds = o.breaks(crBreaks)
                var newEnds = [LineEnding](repeating: dominant, count: n.count - 1)
                func give(_ oi: Int, _ ni: Int) {
                    // The last line has no break of its own.
                    guard ni < newEnds.count, oi < oldEnds.count else { return }
                    newEnds[ni] = oldEnds[oi]
                }
                for (oldRange, newRange, equal) in Self.match(o, ob, n, nb) {
                    if equal {
                        for k in 0..<oldRange.count { give(oldRange.lowerBound + k, newRange.lowerBound + k) }
                    } else {
                        for (oi, ni) in Self.align(oldRange, o, ob, newRange, n, nb) { give(oi, ni) }
                    }
                }
                var bytes = [UInt8]()
                bytes.reserveCapacity(nb.count + newEnds.count)
                var cr = [Int]()
                var lf = 0, crlf = 0, crs = 0
                for i in 0..<n.count {
                    let r = n.range(i)
                    bytes.append(contentsOf: UnsafeBufferPointer(rebasing: nb[r]))
                    guard i < newEnds.count else { break }
                    switch newEnds[i] {
                    case .lf: bytes.append(10); lf += 1
                    case .crlf: bytes += [13, 10]; crlf += 1; cr.append(r.upperBound << 1 | 1)
                    case .cr: bytes.append(13); crs += 1; cr.append(r.upperBound << 1)
                    }
                }
                let (kind, mixed) = TextCodec.lineEnding(lf: lf, crlf: crlf, cr: crs)
                return Saved(output: String(decoding: bytes, as: UTF8.self),
                             breaks: LineBreaks(text: newText, crBreaks: cr, dominant: kind), mixed: mixed, dominant: kind)
            }
        }
    }

    /// Changed blocks up to this many old × new lines are aligned by
    /// likeness (`align`); larger ones by position only.
    static let alignLimit = 40_000

    /// Old and new lines of a changed block paired up: by likeness (a
    /// common start and end, the end counting double, at least half the
    /// shorter line), the most in total, in order; the lines between two
    /// pairs (or before the first, after the last) by position from the end.
    static func align(_ old: Range<Int>, _ o: Lines, _ ob: UnsafeBufferPointer<UInt8>,
                      _ new: Range<Int>, _ n: Lines, _ nb: UnsafeBufferPointer<UInt8>) -> [(Int, Int)] {
        func byPosition(_ a: Range<Int>, _ b: Range<Int>) -> [(Int, Int)] {
            (0..<min(a.count, b.count)).map { (a.upperBound - 1 - $0, b.upperBound - 1 - $0) }
        }
        guard old.count * new.count <= alignLimit, !old.isEmpty, !new.isEmpty else { return byPosition(old, new) }
        func weight(_ i: Int, _ j: Int) -> Int {
            let a = o.range(i), b = n.range(j)
            let shorter = min(a.count, b.count)
            guard shorter > 0 else { return 0 }
            var p = 0
            while p < shorter, ob[a.lowerBound + p] == nb[b.lowerBound + p] { p += 1 }
            var q = 0
            while q < shorter - p, ob[a.upperBound - 1 - q] == nb[b.upperBound - 1 - q] { q += 1 }
            return (p + q) * 2 >= shorter ? p + 2 * q : 0
        }
        let w = new.count + 1
        var best = [Int](repeating: 0, count: (old.count + 1) * w)
        var weights = [Int](repeating: 0, count: old.count * new.count)
        for i in 1...old.count {
            for j in 1...new.count {
                let wt = weight(old.lowerBound + i - 1, new.lowerBound + j - 1)
                weights[(i - 1) * new.count + j - 1] = wt
                best[i * w + j] = max(best[(i - 1) * w + j], best[i * w + j - 1], wt > 0 ? best[(i - 1) * w + j - 1] + wt : 0)
            }
        }
        var pairs: [(Int, Int)] = []
        var i = old.count, j = new.count
        while i > 0, j > 0 {
            let wt = weights[(i - 1) * new.count + j - 1]
            if wt > 0, best[i * w + j] == best[(i - 1) * w + j - 1] + wt {
                pairs.append((old.lowerBound + i - 1, new.lowerBound + j - 1)); i -= 1; j -= 1
            } else if best[i * w + j] == best[(i - 1) * w + j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        pairs.reverse()
        var out: [(Int, Int)] = []
        var oi = old.lowerBound, ni = new.lowerBound
        for (a, b) in pairs {
            out += byPosition(oi..<a, ni..<b)
            out.append((a, b))
            oi = a + 1; ni = b + 1
        }
        out += byPosition(oi..<old.upperBound, ni..<new.upperBound)
        return out
    }

    /// Where each line of UTF-8 text starts; a line ends at the next "\n"
    /// (not included), the last at the end of the text.
    struct Lines {
        /// starts[i]: the first byte of line i; the last entry is the text's length + 1.
        var starts: [Int]
        var count: Int { starts.count - 1 }
        func range(_ i: Int) -> Range<Int> { starts[i]..<(starts[i + 1] - 1) }

        /// Each break's kind, from the CR/CRLF list (`crBreaks`).
        func breaks(_ crBreaks: [Int]) -> [LineEnding] {
            var out = [LineEnding](repeating: .lf, count: count - 1)
            var k = 0
            for i in 0..<(count - 1) {
                let at = starts[i + 1] - 1
                while k < crBreaks.count, crBreaks[k] >> 1 < at { k += 1 }
                if k < crBreaks.count, crBreaks[k] >> 1 == at { out[i] = crBreaks[k] & 1 == 1 ? .crlf : .cr; k += 1 }
            }
            return out
        }
    }

    static func lines(of b: UnsafeBufferPointer<UInt8>) -> Lines {
        var starts = [0]
        guard let base = b.baseAddress else { return Lines(starts: [0, 1]) }
        var i = 0
        while i < b.count, let p = memchr(base + i, 10, b.count - i) {
            i = UnsafeRawPointer(p) - UnsafeRawPointer(base) + 1
            starts.append(i)
        }
        starts.append(b.count + 1)
        return Lines(starts: starts)
    }

    /// The most line edits (insertions plus deletions) the line diff looks
    /// for, and its work budget ((old + new lines) × edits). Past either,
    /// the changed middle is taken as one replaced block.
    static let diffLimit = 1_000
    static let diffBudget = 60_000_000

    /// The old and new lines as runs: equal (kept) or replaced, in order.
    static func match(_ o: Lines, _ ob: UnsafeBufferPointer<UInt8>, _ n: Lines, _ nb: UnsafeBufferPointer<UInt8>)
        -> [(Range<Int>, Range<Int>, Bool)] {
        func same(_ i: Int, _ j: Int) -> Bool {
            let a = o.range(i), b = n.range(j)
            return a.count == b.count && (a.isEmpty || memcmp(ob.baseAddress! + a.lowerBound, nb.baseAddress! + b.lowerBound, a.count) == 0)
        }
        var head = 0
        while head < o.count, head < n.count, same(head, head) { head += 1 }
        var tail = 0
        while tail < o.count - head, tail < n.count - head, same(o.count - 1 - tail, n.count - 1 - tail) { tail += 1 }
        var runs: [(Range<Int>, Range<Int>, Bool)] = []
        if head > 0 { runs.append((0..<head, 0..<head, true)) }
        let oldMid = head..<(o.count - tail), newMid = head..<(n.count - tail)
        func hashes(_ lines: Lines, _ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> [Int] {
            r.map { i in
                var h = Hasher()
                h.combine(bytes: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(b)[lines.range(i)]))
                return h.finalize()
            }
        }
        if !oldMid.isEmpty, !newMid.isEmpty {
            let ha = hashes(o, ob, oldMid), hb = hashes(n, nb, newMid)
            let pairs = myers(oldMid.count, newMid.count) { i, j in ha[i] == hb[j] && same(head + i, head + j) }
            if let pairs {
                var i = 0, j = 0
                for (pi, pj) in pairs {
                    if pi > i || pj > j { runs.append(((head + i)..<(head + pi), (head + j)..<(head + pj), false)) }
                    runs.append(((head + pi)..<(head + pi + 1), (head + pj)..<(head + pj + 1), true))
                    i = pi + 1; j = pj + 1
                }
                if i < oldMid.count || j < newMid.count {
                    runs.append(((head + i)..<oldMid.upperBound, (head + j)..<newMid.upperBound, false))
                }
            } else {
                runs.append((oldMid, newMid, false))
            }
        } else if !oldMid.isEmpty || !newMid.isEmpty {
            runs.append((oldMid, newMid, false))
        }
        if tail > 0 { runs.append(((o.count - tail)..<o.count, (n.count - tail)..<n.count, true)) }
        return runs
    }

    /// The matched (old, new) line pairs of a shortest edit script
    /// (Myers' O((N+M)D) greedy), ascending; nil past `diffLimit` edits or
    /// `diffBudget` work.
    static func myers(_ n: Int, _ m: Int, _ eq: (Int, Int) -> Bool) -> [(Int, Int)]? {
        let maxD = min(n + m, diffLimit, diffBudget / max(1, n + m))
        let off = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        // trace[d]: v[-d-1 ... d+1] before step d.
        var trace: [[Int]] = []
        for d in 0...maxD {
            trace.append(Array(v[(off - d - 1)...(off + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) ? v[off + k + 1] : v[off + k - 1] + 1
                var y = x - k
                while x < n, y < m, eq(x, y) { x += 1; y += 1 }
                v[off + k] = x
                guard x >= n, y >= m else { continue }
                // Back from (n, m): the diagonal moves are the matches.
                var pairs: [(Int, Int)] = []
                var cx = n, cy = m
                for e in stride(from: d, to: 0, by: -1) {
                    let pv = trace[e]
                    func at(_ k: Int) -> Int { pv[k + e + 1] }
                    let ck = cx - cy
                    let pk = ck == -e || (ck != e && at(ck - 1) < at(ck + 1)) ? ck + 1 : ck - 1
                    let px = at(pk), py = px - pk
                    // The snake after the edit from (px, py).
                    let sx = pk == ck + 1 ? px : px + 1, sy = sx - ck
                    while cx > sx, cy > sy { cx -= 1; cy -= 1; pairs.append((cx, cy)) }
                    cx = px; cy = py
                }
                while cx > 0, cy > 0 { cx -= 1; cy -= 1; pairs.append((cx, cy)) }
                return pairs.reversed()
            }
        }
        return nil
    }
}
