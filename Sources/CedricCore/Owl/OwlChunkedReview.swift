import Foundation

/// Line-aligned planning and merging for whole-document reviews. Every
/// line of the document is planned into some part, however many parts
/// that takes: a whole-document question is never cut short to a window
/// of parts (0.5.2 kept 8 around the caret, so a 282-line file on Apple
/// Intelligence's budget stopped at line 236).
public enum OwlChunkedReview {
    public static let overlapLines = 2

    public struct Part: Sendable, Equatable {
        public let first: Int
        public let last: Int
        public let numbered: String
        /// False when even this window (usually one oversize line) exceeds the budget.
        public let fits: Bool
    }

    public struct Plan: Sendable {
        public let parts: [Part]
        public let totalLines: Int
        /// Lines in parts that don't fit the budget (an oversize line): never reviewed.
        public var tooLong: [Part] { parts.filter { !$0.fits } }
        public var isComplete: Bool {
            var covered = IndexSet()
            for part in parts where part.fits { covered.insert(integersIn: part.first...part.last) }
            return totalLines > 0 && covered.contains(integersIn: 1...totalLines)
        }
    }

    public static func plan(_ snapshot: OwlDocumentSnapshot, budget: Int) -> Plan {
        let total = snapshot.countedLines
        var all: [Part] = []
        var first = 1
        while first <= total {
            var last = first
            var used = 0
            for line in first...total {
                let length = snapshot.lines.contentRange(ofLine: line - 1).length + String(line).count + 2
                    + (line == first ? 0 : 1)
                if line > first && used + length > budget { break }
                used += length
                last = line
            }
            let numbered = snapshot.numbered(lines: first, last)
            all.append(Part(first: first, last: last, numbered: numbered, fits: used <= budget))
            if last == total { break }
            // When the budget cannot hold overlap plus a new line, progress takes priority.
            var next = max(first + 1, last - overlapLines + 1)
            while next <= last {
                let candidate = snapshot.numbered(lines: next, last + 1)
                if (candidate as NSString).length <= budget { break }
                next += 1
            }
            first = next
        }
        return Plan(parts: all, totalLines: total)
    }

    /// The scope chip for a planned whole-document question: it covers
    /// every line, so nothing says "trimmed" or "rest not reviewed"; only
    /// lines too long for the model are named.
    public static func label(_ plan: Plan) -> String {
        let skipped = plan.tooLong.reduce(0) { $0 + $1.last - $1.first + 1 }
        if skipped == 0 { return String(localized: "Whole document (\(plan.totalLines) lines)") }
        return skipped == 1
            ? String(localized: "Whole document (\(plan.totalLines) lines; 1 too long to read)")
            : String(localized: "Whole document (\(plan.totalLines) lines; \(skipped) too long to read)")
    }

    /// The note put before a whole-document answer for lines too long for
    /// the model: they were not reviewed.
    public static func tooLongNote(first: Int, last: Int) -> String {
        first == last
            ? String(localized: "Line \(first) was too long for this model and was not reviewed.")
            : String(localized: "Lines \(first)–\(last) were too long for this model and were not reviewed.")
    }

    /// The note put before a whole-document answer cut short.
    public static func partialNote(first: Int, last: Int, total: Int) -> String {
        String(localized: "Reviewed lines \(first)–\(last) of \(total); the rest was not reviewed.")
    }

    /// `text` with each row that is one of the notes above
    /// (`tooLongNote`, `partialNote`) blanked out, its length kept: what
    /// the review says about its own coverage, not about what a line
    /// says. "Line 3 was too long for this model and was not reviewed."
    /// is no evidence that line 3 was read, and a later answer may not
    /// cite it on the strength of that (`OwlPrompts.historyCitations`).
    public static func withoutStatusNotes(_ text: String) -> String {
        let ns = text as NSString
        let out = NSMutableString(string: text)
        var start = 0
        while start <= ns.length {
            let nl = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
            let end = nl == NSNotFound ? ns.length : nl
            let range = NSRange(location: start, length: end - start)
            if isStatusNote(ns.substring(with: range)) {
                out.replaceCharacters(in: range, with: String(repeating: "_", count: range.length))
            }
            if nl == NSNotFound { break }
            start = nl + 1
        }
        return out as String
    }

    private static let integer = try! NSRegularExpression(pattern: #"\d+"#)

    static func isStatusNote(_ row: String) -> Bool {
        let row = row.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = row as NSString
        let numbers = integer.matches(in: row, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range)) }
        guard (1...3).contains(numbers.count) else { return false }
        // Every order: a translation may put them differently.
        func orders(_ a: [Int]) -> [[Int]] {
            a.count <= 1 ? [a] : a.indices.flatMap { i in
                orders(Array(a[..<i] + a[(i + 1)...])).map { [a[i]] + $0 }
            }
        }
        return orders(numbers).contains { n in
            switch n.count {
            case 1: return row == tooLongNote(first: n[0], last: n[0])
            case 2: return row == tooLongNote(first: n[0], last: n[1])
            default: return row == partialNote(first: n[0], last: n[1], total: n[2])
            }
        }
    }

    public static func forcedVerdict(scanHasHigh: Bool, scanTruncated: Bool, covered: IndexSet,
                                     totalLines: Int) -> ScriptVerdict.Reason? {
        ScriptVerdict.forcedReason(scanHasHigh: scanHasHigh,
                                   truncated: scanTruncated || !covered.contains(integersIn: 1...totalLines))
    }

    private static let findingCite = try! NSRegularExpression(pattern:
        #"(?i)\b(?:lines?\s*|l\.?\s*|#)(\d+)\b|^\s*(?:[-*]\s*)?(?:\*\*)?\[?(\d+)(?:\]|\||:)"#)

    /// Keep each cited finding once, without manufacturing citations. A
    /// finding from a later part is left out only when every line it cites
    /// was cited by an earlier part and an earlier finding on one of those
    /// lines already says everything it says, in the same order
    /// (`says`, numbers included, and a "not" if it has one): "missing
    /// signature" and "missing checksum" on line 40 are two findings, not
    /// one, and so are "client trusts server" and "server trusts client".
    public static func mergeFindings(_ answers: [String]) -> String {
        let regex = findingCite
        var seen = Set<Int>()
        var earlier: [(lines: Set<Int>, words: [String], negated: Bool)] = []
        var output: [String] = []
        for answer in answers {
            var group: [String] = []
            var cited: [Int] = []
            var thisAnswer: [(lines: Set<Int>, words: [String], negated: Bool)] = []
            func flush() {
                guard !group.isEmpty else { return }
                let text = group.joined(separator: "\n")
                let lines = Set(cited)
                let words = substanceInOrder(text)
                let negated = negates(text)
                // Dedupe only against earlier answers, so two distinct findings
                // on the same line in one part are both kept.
                let repeated = !lines.isEmpty && lines.isSubset(of: seen) && earlier.contains {
                    !$0.lines.isDisjoint(with: lines) && says(words, in: $0.words) && $0.negated == negated
                }
                if !repeated { output.append(text) }
                thisAnswer.append((lines, words, negated))
                group = []
                cited = []
            }
            var newlySeen = Set<Int>()
            for line in answer.components(separatedBy: "\n") {
                let ns = line as NSString
                let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
                let numbers = matches.compactMap { match -> Int? in
                    let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                    return Int(ns.substring(with: range))
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !numbers.isEmpty || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.isEmpty { flush() }
                group.append(line)
                cited.append(contentsOf: numbers)
                newlySeen.formUnion(numbers)
            }
            flush()
            seen.formUnion(newlySeen)
            earlier += thisAnswer
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let filler: Set<String> = [
        "line", "lines", "this", "that", "with", "from", "which", "there", "their", "then", "than", "have", "does",
        "will", "into", "these", "those", "also", "when", "where", "here", "what", "were", "been", "being", "about",
        "some", "more", "very", "should", "could", "would", "uses", "used", "using", "high", "medium", "critical",
        "severity", "issue", "issues", "problem", "problems", "finding", "findings", "note", "notes", "first",
        "just", "really", "actually", "again", "still",
    ]

    private static let negations: Set<String> = [
        "not", "no", "nor", "never", "none", "nothing", "without", "cannot", "neither", "nowhere",
    ]

    /// Whether `text` says no ("not", "never", "without", "doesn't").
    public static func negates(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if lower.contains("n't") { return true }
        return lower.split { !$0.isLetter }.contains { negations.contains(String($0)) }
    }

    /// What a finding says, roughly: its words of four letters or more, not
    /// filler, cut to five letters ("downloads" and "download" match;
    /// "signed" and "unsigned" don't), and every number or word with a
    /// digit in it, whole ("90 days" and "30 days" differ; "sha256" and
    /// "sha512" too, and "L2" and "L3"), a decimal number with its point
    /// ("1.25" is not "25.1"). The numbers of its citations ("line 12",
    /// "lines 4–9", "#12", a leading "12:") are where it is, not what it
    /// says, and are left out. "L12" is kept whole too: it may be a term
    /// like "L2", so "- L12: x" and "- Line 12: x" are both kept (a
    /// finding repeated is better than one dropped). As a set: whether
    /// two findings say the same thing also takes their order (`says`).
    public static func substance(_ text: String) -> Set<String> { Set(substanceInOrder(text)) }

    /// `substance`, in the order the text says it.
    public static func substanceInOrder(_ text: String) -> [String] {
        let blanked = NSMutableString(string: text)
        let all = NSRange(location: 0, length: blanked.length)
        var cites = OwlCitations.find(text).map(\.range)
        for m in findingCite.matches(in: text, range: all) {
            let number = m.range(at: m.range(at: 1).location == NSNotFound ? 2 : 1)
            // "L2", "L3": a term, kept whole ("L2 regularization"), though
            // "line12" is still a citation.
            var start = number.location
            while start > 0, let u = UnicodeScalar(blanked.character(at: start - 1)), CharacterSet.letters.contains(u) {
                start -= 1
            }
            let word = blanked.substring(with: NSRange(location: start, length: number.location - start)).lowercased()
            if !word.isEmpty, word != "line", word != "lines" { continue }
            cites.append(number)
        }
        for r in cites { blanked.replaceCharacters(in: r, with: String(repeating: " ", count: r.length)) }
        let lower = (blanked as String).lowercased()
        let ns = lower as NSString
        return token.matches(in: lower, range: NSRange(location: 0, length: ns.length)).compactMap { m -> String? in
            let word = ns.substring(with: m.range)
            if word.contains(where: \.isNumber) { return word }
            guard word.count >= 4, !filler.contains(word) else { return nil }
            return String(word.prefix(5))
        }
    }

    // A word, or a number with its decimal point or thousands comma
    // ("1.25", "1,000", "v1.2.3"): "1.25" and "25.1" are different numbers.
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]*\p{N}(?:[.,]\p{N}+)+[\p{L}\p{N}]*|[\p{L}\p{N}]+"#)

    /// Whether a passage whose substance (`substanceInOrder`) is `passage`
    /// says all that `finding` says, in the same order: "server trusts
    /// client" doesn't say "client trusts server", though its words are
    /// the same. Words around them may differ ("downloads the unsigned
    /// code" says "downloads unsigned code"); a reordering ("downloads
    /// code that is unsigned") is taken as saying something else, and the
    /// finding is kept (a finding repeated is better than one dropped).
    /// A finding that says a word again is read from where it first says
    /// it ("Pipes curl to sh. Pipes curl to sh." says "pipes curl").
    public static func says(_ finding: [String], in passage: [String]) -> Bool {
        var rest = passage[...]
        var said = Set<String>()
        for word in finding where said.insert(word).inserted {
            guard let at = rest.firstIndex(of: word) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        return true
    }
}
