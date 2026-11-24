import Foundation

/// Line citations in a model's answer ("line 12", "lines 19–20", a quoted
/// "31| text"), and the filter that keeps an answer to the lines
/// it was actually given. A small model shown lines 1–18 of 282 still
/// wrote about "lines 19–20" and "31–34" (Apple Intelligence, Summarise,
/// 0.5.2): the numbering it was shown is the file's own (`numbered`,
/// 1-based, front matter included), so those were invented, not offset.
///
/// Not `mergeFindings`'s pattern: that one also reads "#12" and a bare
/// "12:" at a line's start, fine for grouping findings but too loose to
/// delete text on (a heading "#2", a time "12:30"). "L12" isn't read
/// either: "L2 regularization" and "an L1 cache" aren't citations.
public enum OwlCitations {
    public struct Cite: Sendable, Equatable {
        /// Where the number (or range) is, in the text searched.
        public let range: NSRange
        public let lines: ClosedRange<Int>
    }

    public struct Filtered: Sendable, Equatable {
        public var text: String
        /// Citations removed with the list item or line that made them.
        public var dropped: [ClosedRange<Int>]
        /// Citations kept but marked (`flag`) because the sentence also
        /// says something about lines that were given.
        public var flagged: [ClosedRange<Int>]
        public var changed: Bool { !dropped.isEmpty || !flagged.isEmpty }
    }

    /// Put after a citation of a line the model was not given.
    public static let flag = String(localized: " (not among the lines read)")

    // "line 12", "lines 3-5", "lines 3 to 5", "lines 3, 7 and 9-11". A
    // listed number after the first must end the list or a clause ("line
    // 5, 2026 changed" and "line 3, 100 items" cite only 5 and 3).
    private static let listed = try! NSRegularExpression(pattern:
        #"(?i)\blines?\s+(\d+(?:\s*(?:[-–—]|to|through)\s*\d+)?(?:\s*(?:,\s*and|,|and|&)\s*\d+(?:\s*(?:[-–—]|to|through)\s*\d+)?(?=\s*(?:[,.;:)]|and\b|&|$)))*)\b"#,
        options: [.anchorsMatchLines])
    private static let number = try! NSRegularExpression(pattern: #"(?i)(\d+)(?:\s*(?:[-–—]|to|through)\s*(\d+))?"#)
    // A quoted numbered line: "31| text".
    private static let quoted = try! NSRegularExpression(pattern: #"^\s*(?:[-*•]\s*)?(\d+)\|"#, options: [.anchorsMatchLines])

    /// Every citation in `text`, in order.
    public static func find(_ text: String) -> [Cite] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [Cite] = []
        func make(_ a: NSRange, _ b: NSRange, whole: NSRange) -> Cite? {
            guard let x = Int(ns.substring(with: a)) else { return nil }
            let y = b.location == NSNotFound ? x : (Int(ns.substring(with: b)) ?? x)
            return Cite(range: whole, lines: min(x, y)...max(x, y))
        }
        for m in listed.matches(in: text, range: all) {
            let group = m.range(at: 1)
            for n in number.matches(in: text, range: group) {
                if let c = make(n.range(at: 1), n.range(at: 2), whole: n.range) { out.append(c) }
            }
        }
        for m in quoted.matches(in: text, range: all) {
            if let c = make(m.range(at: 1), NSRange(location: NSNotFound, length: 0), whole: m.range(at: 1)) { out.append(c) }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Every line number `text` cites.
    public static func lines(in text: String) -> IndexSet {
        var s = IndexSet()
        for c in find(text) where c.lines.lowerBound >= 1 { s.insert(integersIn: c.lines) }
        return s
    }

    /// Keeps `text` to the lines in `allowed`. A list item whose every
    /// citation lies outside `allowed` is removed, with its indented
    /// continuation lines: it is about text the model never saw. Anything
    /// else (a paragraph, an item that also cites given lines, an answer
    /// that would be left empty) keeps its words and gets `flag` after
    /// each citation that isn't wholly inside `allowed`. Nothing else in
    /// the text changes.
    public static func filter(_ text: String, allowed: IndexSet) -> Filtered {
        var result = Filtered(text: text, dropped: [], flagged: [])
        let rows = text.components(separatedBy: "\n")
        guard !find(text).isEmpty else { return result }
        func outside(_ c: Cite) -> Bool { !allowed.contains(integersIn: c.lines) }
        func untouched(_ c: Cite) -> Bool { !c.lines.contains { allowed.contains($0) } }
        var kept: [String] = []
        var dropping = false
        var dropped = false
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if dropping, !trimmed.isEmpty, row.first == " " || row.first == "\t", find(row).isEmpty { continue }
            // No doubled blank line where an item was taken out.
            if dropped, trimmed.isEmpty, kept.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            dropping = false
            dropped = false
            let cites = find(row)
            let bad = cites.filter(outside)
            if bad.isEmpty { kept.append(row); continue }
            let item = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
            if cites.allSatisfy(untouched), item {
                result.dropped.append(contentsOf: bad.map(\.lines))
                dropping = true
                dropped = true
                continue
            }
            let ns = NSMutableString(string: row)
            for c in bad.reversed() { ns.insert(flag, at: NSMaxRange(c.range)) }
            result.flagged.append(contentsOf: bad.map(\.lines))
            kept.append(ns as String)
        }
        guard result.changed else { return result }
        let joined = kept.joined(separator: "\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Everything was about unseen lines: say so, rather than nothing.
            return flagOnly(text, allowed: allowed)
        }
        result.text = joined
        return result
    }

    private static func flagOnly(_ text: String, allowed: IndexSet) -> Filtered {
        let bad = find(text).filter { !allowed.contains(integersIn: $0.lines) }
        let ns = NSMutableString(string: text)
        for c in bad.reversed() { ns.insert(flag, at: NSMaxRange(c.range)) }
        return Filtered(text: ns as String, dropped: [], flagged: bad.map(\.lines))
    }
}
