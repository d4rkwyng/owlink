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

    // "line 12", "lines 3-5", "lines 3 to 5", "lines 3, 7 and 9-11",
    // "lines 3 and 31 describe". A number joined by "and" or "&" is always
    // listed; one after a bare comma must end the list or a clause ("line
    // 5, 2026 changed" and "line 3, 100 items" cite only 5 and 3).
    private static let listed = try! NSRegularExpression(pattern:
        #"(?i)\blines?\s+(\d+(?:\s*(?:[-–—]|to|through)\s*\d+)?(?:\s*(?:,\s*and|and|&)\s*\d+(?:\s*(?:[-–—]|to|through)\s*\d+)?\b|\s*,\s*\d+(?:\s*(?:[-–—]|to|through)\s*\d+)?(?=\s*(?:[,.;:)]|and\b|&|$)))*)\b"#,
        options: [.anchorsMatchLines])
    private static let number = try! NSRegularExpression(pattern: #"(?i)(\d+)(?:\s*(?:[-–—]|to|through)\s*(\d+))?"#)
    // A quoted numbered line: "31| text".
    private static let quoted = try! NSRegularExpression(pattern: #"^\s*(?:[-*•]\s*)?(\d+)\|"#, options: [.anchorsMatchLines])
    // A finding listed by its line: "- 31: text", "- 12-14: text" (a list
    // item only, and a colon then a space: not a time like "12:30").
    private static let item = try! NSRegularExpression(pattern: #"^\s*[-*•]\s*(\d+)(?:\s*[-–—]\s*(\d+))?:(?=\s|$)"#,
                                                       options: [.anchorsMatchLines])

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
        for m in item.matches(in: text, range: all) {
            let whole = NSRange(location: m.range(at: 1).location,
                                length: NSMaxRange(m.range(at: m.range(at: 2).location == NSNotFound ? 1 : 2)) - m.range(at: 1).location)
            if let c = make(m.range(at: 1), m.range(at: 2), whole: whole) { out.append(c) }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Every line number `text` cites.
    public static func lines(in text: String) -> IndexSet {
        var s = IndexSet()
        for c in find(text) where c.lines.lowerBound >= 1 { s.insert(integersIn: c.lines) }
        return s
    }

    /// The lines `text` vouches for: every citation in it except those
    /// already marked with `flag` (a note that cites a line it wasn't given
    /// is no evidence for that line).
    public static func evidence(in text: String) -> IndexSet {
        let ns = text as NSString
        var s = IndexSet()
        for c in find(text) where c.lines.lowerBound >= 1 {
            let end = NSMaxRange(c.range)
            let flagged = end + (flag as NSString).length <= ns.length
                && ns.substring(with: NSRange(location: end, length: (flag as NSString).length)) == flag
            if !flagged { s.insert(integersIn: c.lines) }
        }
        return s
    }

    /// The line numbers of quoted numbered lines ("12| text") in a tool's
    /// result: the lines a search or outline actually showed.
    public static func quotedLines(in text: String) -> IndexSet {
        let ns = text as NSString
        var s = IndexSet()
        for m in quoted.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))), n >= 1 { s.insert(n) }
        }
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

    /// Streamed text with a possible citation held from its first number
    /// until the list it starts has ended (the first word after it that
    /// isn't "and", "to" or "through", or the line's end), then checked
    /// (`filter`): a citation of a line the model wasn't given is shown
    /// flagged, never as written, even while the answer is still being
    /// written or after Stop. Text before a number, and numbers not after
    /// "line" or at a line's start or list marker, pass at once.
    public struct Stream: Sendable {
        /// The current line as the model wrote it, up to `held`.
        private var raw = ""
        /// The same, as shown (checked: flags in place).
        private var shown = ""
        /// Held: from a citation's first number on.
        private var held = ""
        private static let connectors: Set<String> = ["and", "to", "through"]

        public init() {}

        /// What of `text` can be shown now. `allowed` nil: no filter.
        public mutating func feed(_ text: String, allowed: IndexSet?) -> String {
            guard let allowed else {
                let out = held + text
                held = ""
                raw = out.components(separatedBy: "\n").last ?? ""
                shown = raw
                return out
            }
            var out = ""
            for ch in text {
                if held.isEmpty {
                    if ch.isASCII, ch.isNumber, Self.mayCite(raw) { held.append(ch); continue }
                    out.append(ch)
                    if ch == "\n" { raw = ""; shown = "" } else { raw.append(ch); shown.append(ch) }
                    continue
                }
                held.append(ch)
                if ch == "\n" || (!ch.isLetter && listEnded()) { out += release(allowed) }
            }
            return out
        }

        /// The held end, checked, once the text is complete.
        public mutating func finish(allowed: IndexSet?) -> String {
            guard !held.isEmpty else { return "" }
            guard let allowed else { defer { held = "" }; return held }
            return release(allowed)
        }

        /// A word after the last number in `held` that can't continue a list.
        private func listEnded() -> Bool {
            guard let lastDigit = held.lastIndex(where: { $0.isASCII && $0.isNumber }) else { return true }
            let after = held[held.index(after: lastDigit)...]
            let words = after.split { !$0.isLetter }.map { $0.lowercased() }
            // The last word is complete only if something follows it.
            let complete = after.last.map { !$0.isLetter } ?? false
            let checked = complete ? words : Array(words.dropLast())
            return checked.contains { !Self.connectors.contains($0) }
        }

        private mutating func release(_ allowed: IndexSet) -> String {
            let checked = OwlCitations.filter(raw + held, allowed: allowed).text
            // Flags go after a citation's number: what was shown stays a prefix.
            let out = checked.hasPrefix(shown) ? String(checked.dropFirst(shown.count))
                : OwlCitations.filter(held, allowed: allowed).text
            if held.hasSuffix("\n") {
                raw = ""; shown = ""
            } else {
                raw += held; shown += out
            }
            held = ""
            return out
        }

        static func mayCite(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t == "-" || t == "*" || t == "•" || line.range(of: "line", options: .caseInsensitive) != nil
        }
    }

    private static func flagOnly(_ text: String, allowed: IndexSet) -> Filtered {
        let bad = find(text).filter { !allowed.contains(integersIn: $0.lines) }
        let ns = NSMutableString(string: text)
        for c in bad.reversed() { ns.insert(flag, at: NSMaxRange(c.range)) }
        return Filtered(text: ns as String, dropped: [], flagged: bad.map(\.lines))
    }
}
