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
    /// lines already says everything it says (`substance`, numbers
    /// included, and a "not" if it has one): "missing signature" and
    /// "missing checksum" on line 40 are two findings, not one.
    public static func mergeFindings(_ answers: [String]) -> String {
        let regex = findingCite
        var seen = Set<Int>()
        var earlier: [(lines: Set<Int>, words: Set<String>, negated: Bool)] = []
        var output: [String] = []
        for answer in answers {
            var group: [String] = []
            var cited: [Int] = []
            var thisAnswer: [(lines: Set<Int>, words: Set<String>, negated: Bool)] = []
            func flush() {
                guard !group.isEmpty else { return }
                let text = group.joined(separator: "\n")
                let lines = Set(cited)
                let words = substance(text)
                let negated = negates(text)
                // Dedupe only against earlier answers, so two distinct findings
                // on the same line in one part are both kept.
                let repeated = !lines.isEmpty && lines.isSubset(of: seen) && earlier.contains {
                    !$0.lines.isDisjoint(with: lines) && words.isSubset(of: $0.words) && $0.negated == negated
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
    /// "sha512" too, and "L2" and "L3"). The numbers of its citations
    /// ("line 12", "lines 4–9", "#12", a leading "12:") are where it is,
    /// not what it says, and are left out. "L12" is kept whole too: it may
    /// be a term like "L2", so "- L12: x" and "- Line 12: x" are both
    /// kept (a finding repeated is better than one dropped).
    public static func substance(_ text: String) -> Set<String> {
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
        return Set((blanked as String).lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap { word -> String? in
            if word.contains(where: \.isNumber) { return String(word) }
            guard word.count >= 4, !filler.contains(String(word)) else { return nil }
            return String(word.prefix(5))
        })
    }
}
