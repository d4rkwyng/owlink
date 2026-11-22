import Foundation

/// Line-aligned planning and merging for whole-document reviews.
public enum OwlChunkedReview {
    public static let maxChunks = 8
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
        public let uncappedCount: Int
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
        let anchor = min(total, snapshot.lineNumber(at: snapshot.selection.location + snapshot.selection.length / 2))
        let anchorIndex = all.firstIndex { $0.first <= anchor && anchor <= $0.last } ?? 0
        let start = min(max(0, anchorIndex - maxChunks / 2), max(0, all.count - maxChunks))
        return Plan(parts: Array(all.dropFirst(start).prefix(maxChunks)), totalLines: total, uncappedCount: all.count)
    }

    public static func forcedVerdict(scanHasHigh: Bool, scanTruncated: Bool, covered: IndexSet,
                                     totalLines: Int) -> ScriptVerdict.Reason? {
        ScriptVerdict.forcedReason(scanHasHigh: scanHasHigh,
                                   truncated: scanTruncated || !covered.contains(integersIn: 1...totalLines))
    }

    /// Keep each cited finding once, without manufacturing citations.
    public static func mergeFindings(_ answers: [String]) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?i)\b(?:lines?\s*|l\.?\s*|#)(\d+)\b|^\s*(?:[-*]\s*)?(?:\*\*)?\[?(\d+)(?:\]|\||:)"#)
        var seen = Set<Int>()
        var output: [String] = []
        for answer in answers {
            var group: [String] = []
            var cited: [Int] = []
            func flush() {
                guard !group.isEmpty else { return }
                // Dedupe only against earlier answers, so two distinct findings
                // on the same line in one part are both kept.
                if cited.isEmpty || !cited.allSatisfy({ seen.contains($0) }) {
                    output.append(group.joined(separator: "\n"))
                }
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
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
