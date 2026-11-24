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
    // listed; one after a bare comma only if it ends the list or a clause,
    // and after "line" only on the way to an "and" ("line 5, 2026" and
    // "line 3, 100 items" cite only 5 and 3). A citation may run onto the next row only after a word or
    // mark that joins it ("Line 4 through" / "9999"): never at "line" itself
    // or before "and", "to" or a dash, so a stream can tell at a row's end
    // whether the citation goes on (`Stream`). The one exception is a
    // listed finding's number ("- 4" / "–31: setup", `item`), which the
    // stream holds until the next row shows whether a dash comes.
    private static let span = #"(?:(?:[^\S\r\n]*[-–—]|[^\S\r\n]*(?:to|through))\s*\d+)?"#
    private static let joined = #"(?:[^\S\r\n]*(?:,[^\S\r\n]*and|and|&)\s*\d+"# + span + #"\b)"#
    private static let comma = #"(?:[^\S\r\n]*,\s*\d+"# + span + #"(?=[^\S\r\n]*(?:[,.;:)]|and\b|&|$)))"#
    // After "line", a bare comma lists a number only on the way to an "and"
    // ("line 3, 7 and 9").
    private static let commaBeforeAnd = #"(?:[^\S\r\n]*,\s*\d+"# + span + #"(?=(?:[^\S\r\n]*,\s*\d+"# + span
        + #")*[^\S\r\n]*(?:,[^\S\r\n]*)?(?:and|&)\s*\d))"#
    private static let listed = try! NSRegularExpression(pattern:
        #"(?i)\b(?:lines[^\S\r\n]+(\d+"# + span + #"(?:"# + joined + "|" + comma + #")*)|line[^\S\r\n]+(\d+"#
        + span + #"(?:"# + joined + "|" + commaBeforeAnd + #")*))\b"#,
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
            let group = m.range(at: m.range(at: 1).location == NSNotFound ? 2 : 1)
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

    /// The lines the start of `text` (its first `retained` UTF-16 units,
    /// as sent on in a conversation's history) vouches for, each citation
    /// judged by its own `flag` in the whole of `text`: one cut off right
    /// after its number is still unread if the whole says so, and a line
    /// cited again, unflagged, past the cut vouches for nothing the start
    /// flagged. A citation only the cut makes ("lines 5, 20" from "lines
    /// 5, 2026 changed") vouches for nothing.
    public static func evidence(in text: String, retained: Int) -> IndexSet {
        let ns = text as NSString
        let prefix = ns.substring(to: min(max(retained, 0), ns.length))
        let flagLength = (flag as NSString).length
        let whole = find(text)
        func flagged(_ c: Cite) -> Bool {
            let end = NSMaxRange(c.range)
            return end + flagLength <= ns.length && ns.substring(with: NSRange(location: end, length: flagLength)) == flag
        }
        var s = IndexSet()
        for p in find(prefix) where p.lines.lowerBound >= 1 {
            let same = whole.filter { $0.range.location == p.range.location }
            guard !same.isEmpty, !same.contains(where: flagged) else { continue }
            for f in same where f.lines.overlaps(p.lines) {
                let r = f.lines.clamped(to: p.lines)
                s.insert(integersIn: r.lowerBound...r.upperBound)
            }
        }
        return s
    }

    /// Where the citations in `text` already followed by `flag` start.
    private static func flaggedAlready(_ text: String) -> Set<Int> {
        let ns = text as NSString
        let flagLength = (flag as NSString).length
        return Set(find(text).filter {
            let end = NSMaxRange($0.range)
            return end + flagLength <= ns.length && ns.substring(with: NSRange(location: end, length: flagLength)) == flag
        }.map(\.range.location))
    }

    /// Where `text` must not be cut (UTF-16 offsets: a cut at `p` falls
    /// between `p - 1` and `p`): inside a citation, from its "line" or
    /// "lines" to its last number, from a quoted line's or listed
    /// finding's marker to its "|" or ":", and between a number and the
    /// `flag` after it. A piece holding "Line 4 through" is evidence for
    /// line 4 that the whole citation, read together, may not be.
    public static func uncuttable(in text: String) -> IndexSet {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let flagLength = (flag as NSString).length
        var spans = listed.matches(in: text, range: all).map(\.range)
        // A quoted "31| text" or a listed "- 31: text" is a citation only
        // with its marker and its "|" or ":": cut between them, neither
        // piece cites the line. Kept whole from the marker (or number) on.
        for m in quoted.matches(in: text, range: all) + item.matches(in: text, range: all) {
            var start = m.range.location
            while start < NSMaxRange(m.range), let u = UnicodeScalar(ns.character(at: start)),
                  CharacterSet.whitespacesAndNewlines.contains(u) { start += 1 }
            spans.append(NSRange(location: start, length: NSMaxRange(m.range) - start))
        }
        for c in find(text) {
            let end = NSMaxRange(c.range)
            let flagged = end + flagLength <= ns.length
                && ns.substring(with: NSRange(location: end, length: flagLength)) == flag
            spans.append(NSRange(location: c.range.location, length: c.range.length + (flagged ? flagLength : 0)))
        }
        var s = IndexSet()
        for r in spans where r.length > 1 { s.insert(integersIn: (r.location + 1)..<NSMaxRange(r)) }
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
        let all = find(text)
        guard !all.isEmpty else { return result }
        let marked = flaggedAlready(text)
        // A citation already flagged (an answer filtered twice) still
        // counts for whether its item touches the lines given ("Line 4
        // through 99 (flagged) and line 31" read again for lines 1–18 is
        // about line 4, so it stays), but is never flagged again.
        func outside(_ c: Cite) -> Bool { !allowed.contains(integersIn: c.lines) }
        func untouched(_ c: Cite) -> Bool { !c.lines.contains { allowed.contains($0) } }
        // Rows, joined where a citation runs across the break between them
        // ("Line 4 through" / "9999"): a citation is checked whole, never
        // a row at a time.
        let ns = text as NSString
        var units: [NSRange] = []
        var start = 0
        while start <= ns.length {
            let nl = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
            let end = nl == NSNotFound ? ns.length : nl
            if start > 0, let last = units.last, all.contains(where: { NSLocationInRange(start - 1, $0.range) }) {
                units[units.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                units.append(NSRange(location: start, length: end - start))
            }
            if nl == NSNotFound { break }
            start = nl + 1
        }
        // Units whose items are flagged rather than dropped: taking them
        // out would join the rows around them into a citation the text
        // never made ("Line 4 through" / "9999 describes" once the item
        // between them is gone).
        var keep = Set<Int>()
        while true {
            var kept: [String] = []
            // Where an item was taken out: the index in `kept` of the row
            // after it, and the unit that was dropped.
            var gaps: [(at: Int, unit: Int)] = []
            var dropping = false
            var dropped = false
            var dropStart = 0
            result = Filtered(text: text, dropped: [], flagged: [])
            for (index, unit) in units.enumerated() {
                let row = ns.substring(with: unit)
                let cites = all.filter { NSLocationInRange($0.range.location, unit) }
                    .map { Cite(range: NSRange(location: $0.range.location - unit.location, length: $0.range.length), lines: $0.lines) }
                let trimmed = row.trimmingCharacters(in: .whitespaces)
                if dropping, !trimmed.isEmpty, row.first == " " || row.first == "\t", cites.isEmpty { continue }
                // No doubled blank line where an item was taken out.
                if dropped, trimmed.isEmpty, kept.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
                if dropped { gaps.append((kept.count, dropStart)) }
                dropping = false
                dropped = false
                let bad = cites.filter(outside)
                if bad.isEmpty { kept.append(row); continue }
                let item = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                    || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
                if cites.allSatisfy(untouched), item, !keep.contains(index) {
                    result.dropped.append(contentsOf: bad.map(\.lines))
                    dropping = true
                    dropped = true
                    dropStart = index
                    continue
                }
                let fresh = bad.filter { !marked.contains($0.range.location + unit.location) }
                let flagged = NSMutableString(string: row)
                for c in fresh.reversed() { flagged.insert(flag, at: NSMaxRange(c.range)) }
                result.flagged.append(contentsOf: fresh.map(\.lines))
                kept.append(flagged as String)
            }
            guard result.changed else { return result }
            let joined = kept.joined(separator: "\n")
            if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Everything was about unseen lines: say so, rather than nothing.
                return flagOnly(text, allowed: allowed)
            }
            // A row break where an item was taken out must not fall inside
            // a citation (`uncuttable`): if it does, that item stays, flagged.
            let noCut = uncuttable(in: joined)
            var offset = 0
            var offsets: [Int] = []
            for row in kept { offsets.append(offset); offset += (row as NSString).length + 1 }
            let joins = gaps.filter { $0.at > 0 && $0.at < kept.count }.filter {
                let newline = offsets[$0.at] - 1
                return noCut.contains(newline) || noCut.contains(newline + 1)
            }
            if joins.isEmpty {
                result.text = joined
                return result
            }
            keep.formUnion(joins.map(\.unit))
        }
    }

    /// Streamed text with a possible citation held from its first number
    /// until the list it starts has ended (the first word after it that
    /// isn't "and", "to" or "through", or the line's end unless the line
    /// ends on a word or mark that joins the next number), then checked
    /// (`filter`): a citation of a line the model wasn't given is shown
    /// flagged, never as written, even while the answer is still being
    /// written or after Stop. A list item's number alone on its row
    /// ("- 4") is held until the next row shows whether a dash makes it a
    /// range. Text before a number, and numbers not after "line" or at a
    /// line's start or list marker, pass at once.
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
                // A list item's number held past its row ("- 4" / "–31:
                // setup") goes on only with a dash: anything else ends it.
                if !held.isEmpty, awaitingDash(), !ch.isWhitespace, !Self.dashes.contains(ch) { out += release(allowed) }
                if held.isEmpty {
                    if ch.isASCII, ch.isNumber, Self.mayCite(raw) { held.append(ch); continue }
                    out.append(ch)
                    // "\r\n" is one Character, and "\r" alone ends a line too.
                    // A row that is only a list marker stays: the item's
                    // number may come on the next row ("-" / "31: text").
                    if ch.isNewline, !Self.markerPending(raw) { raw = ""; shown = "" } else { raw.append(ch); shown.append(ch) }
                    continue
                }
                held.append(ch)
                if ch.isNewline ? !(continuesOnNextRow() || itemRunsOn()) : (!ch.isLetter && !flagComing() && listEnded()) {
                    out += release(allowed)
                }
            }
            return out
        }

        /// The held end, checked, once the text is complete.
        public mutating func finish(allowed: IndexSet?) -> String {
            guard !held.isEmpty else { return "" }
            guard let allowed else { defer { held = "" }; return held }
            return release(allowed)
        }

        /// Whether what follows the last number in `held` is the start of
        /// `flag`: text already checked (a section filtered before) keeps
        /// its flag, and is not flagged again, only if the whole flag is
        /// read with its citation.
        private func flagComing() -> Bool {
            guard let lastDigit = held.lastIndex(where: { $0.isASCII && $0.isNumber }) else { return false }
            let after = held[held.index(after: lastDigit)...]
            return after.count < OwlCitations.flag.count && OwlCitations.flag.hasPrefix(after)
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

        /// Whether the row just ended in `held` leaves its citation open:
        /// it ends with a word or mark that joins the next number ("Line 4
        /// through", "lines 3 and", "lines 4,", "Line 4 -"). Held on, the
        /// citation is checked whole once it ends.
        private func continuesOnNextRow() -> Bool {
            guard let lastDigit = held.lastIndex(where: { $0.isASCII && $0.isNumber }) else { return false }
            let tail = String(held[held.index(after: lastDigit)...].filter { !$0.isWhitespace }).lowercased()
            return ["and", "to", "through", ",", ",and", "&", "-", "–", "—"].contains(tail)
        }

        private static let dashes: Set<Character> = ["-", "–", "—"]

        /// Whether a list item's number is held at its row's end ("- 4"):
        /// a dash on the next row makes it a range ("- 4" / "–31: setup",
        /// as `find` reads it), so it is held until the next row shows
        /// whether one comes.
        private func itemRunsOn() -> Bool {
            Self.markerPending(raw) && held.drop(while: { $0.isASCII && $0.isNumber }).allSatisfy(\.isWhitespace)
        }

        /// Held at a row's end by `itemRunsOn`, nothing but spacing since.
        private func awaitingDash() -> Bool {
            guard let lastDigit = held.lastIndex(where: { $0.isASCII && $0.isNumber }) else { return false }
            let after = held[held.index(after: lastDigit)...]
            return after.contains(where: \.isNewline) && after.allSatisfy(\.isWhitespace)
        }

        private static func isMarker(_ row: Substring) -> Bool {
            ["-", "*", "•"].contains(row.trimmingCharacters(in: .whitespaces))
        }

        /// `raw`'s rows ("\r\n" is one Character).
        private static func rows(_ raw: String) -> [Substring] {
            raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        }

        /// Whether `raw`'s last row with anything on it is only a list
        /// marker: an item's number may still come ("-" / "31: text").
        private static func markerPending(_ raw: String) -> Bool {
            rows(raw).last { !$0.allSatisfy(\.isWhitespace) }.map(isMarker) ?? false
        }

        private mutating func release(_ allowed: IndexSet) -> String {
            // Flagged, never cut: a list item about unread lines is dropped
            // from the finished answer (`filter`), but what was shown of it
            // can't be taken back, and the rows held may be several.
            let checked = OwlCitations.flagOnly(raw + held, allowed: allowed).text
            // Flags go after a citation's number: what was shown stays a prefix.
            let out = checked.hasPrefix(shown) ? String(checked.dropFirst(shown.count))
                : OwlCitations.flagOnly(held, allowed: allowed).text
            // A row ended outside a citation starts afresh. Rows a citation
            // ran across stay, so the next check still reads it whole and
            // what was shown of them stays a prefix of what it gives. So
            // does a row that is only a list marker ("lines 3 and" / " - "
            // / "99: x"): the item's number may come on the next row, and
            // `filter` reads "- " / "99:" as citing line 99.
            if held.last?.isNewline ?? false, !Self.markerPending(raw + held) {
                raw = ""; shown = ""
            } else {
                raw += held; shown += out
            }
            held = ""
            return out
        }

        static func mayCite(_ line: String) -> Bool {
            // The row being written: rows kept before it as context don't
            // make its start any less a row's start.
            let row = rows(line).last ?? ""
            return row.allSatisfy(\.isWhitespace) || isMarker(row) || line.range(of: "line", options: .caseInsensitive) != nil
        }
    }

    private static func flagOnly(_ text: String, allowed: IndexSet) -> Filtered {
        let marked = flaggedAlready(text)
        let bad = find(text).filter { !allowed.contains(integersIn: $0.lines) && !marked.contains($0.range.location) }
        let ns = NSMutableString(string: text)
        for c in bad.reversed() { ns.insert(flag, at: NSMaxRange(c.range)) }
        return Filtered(text: ns as String, dropped: [], flagged: bad.map(\.lines))
    }
}
