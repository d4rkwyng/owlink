import Foundation

/// Keep or delete the lines that match (plain text or a regular
/// expression), and copy or delete given lines (bookmarks): pure functions
/// from the text to one `TextEdit` covering only the span from the first
/// removed line to the last, plus which lines went.
public enum LineFilter {
    public enum FilterError: Error, Equatable { case emptyPattern, invalidPattern }

    /// What a line must contain. `regex`: ICU syntax, matched anywhere in
    /// the line (use ^ and $ to anchor).
    public static func matcher(_ pattern: String, regex: Bool, caseSensitive: Bool) throws -> (NSString, NSRange) -> Bool {
        guard !pattern.isEmpty else { throw FilterError.emptyPattern }
        if regex {
            let re: NSRegularExpression
            do {
                re = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
            } catch { throw FilterError.invalidPattern }
            return { text, line in re.firstMatch(in: text as String, options: [], range: line) != nil }
        }
        let opts: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        return { text, line in text.range(of: pattern, options: opts, range: line).location != NSNotFound }
    }

    /// The edit that removes every line for which `remove(lineNumber,
    /// contentRange)` is true, and the removed line numbers (0-based).
    /// Nil if none is removed. An empty last line after a final newline
    /// isn't a line. The caret goes to where the first removed line was.
    public static func removing(in text: NSString, where remove: (Int, NSRange) -> Bool) -> (edit: TextEdit, removed: [Int])? {
        let index = LineIndex(text)
        let count = index.lineCount > 1 && index.lineLength(index.lineCount - 1) == 0 ? index.lineCount - 1 : index.lineCount
        if text.length == 0 { return nil }
        var removed: [Int] = []
        for line in 0..<count where remove(line, index.contentRange(ofLine: line)) { removed.append(line) }
        guard let first = removed.first, let last = removed.last else { return nil }
        let removedSet = Set(removed)
        let spanStart = index.starts[first]
        let spanEnd = index.starts[last] + index.lineLength(last)
        // The kept lines inside the span, each with its own newline.
        let kept = NSMutableString()
        for line in first...last where !removedSet.contains(line) {
            kept.append(text.substring(with: NSRange(location: index.starts[line], length: index.lineLength(line))))
        }
        var range = NSRange(location: spanStart, length: spanEnd - spanStart)
        // The last line went and had no newline: the one before it gives up its own.
        let lastHadNewline = spanEnd > 0 && text.character(at: spanEnd - 1) == 10
        if !lastHadNewline, spanEnd == text.length {
            if kept.length > 0, kept.character(at: kept.length - 1) == 10 {
                kept.deleteCharacters(in: NSRange(location: kept.length - 1, length: 1))
            } else if range.location > 0 {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
        }
        let caret = min(range.location, text.length - range.length + kept.length)
        return (TextEdit(range: range, replacement: kept as String, selection: NSRange(location: caret, length: 0)), removed)
    }

    /// Keep (or delete) the lines matching.
    public static func filter(_ text: NSString, pattern: String, regex: Bool, caseSensitive: Bool,
                              keepMatching: Bool) throws -> (edit: TextEdit, removed: [Int])? {
        let matches = try matcher(pattern, regex: regex, caseSensitive: caseSensitive)
        // Long documents: stop early when the surrounding task is cancelled.
        var cancelled = false
        let result = removing(in: text) { line, r in
            if cancelled { return false }
            if line & 0xFF == 0, Task.isCancelled { cancelled = true; return false }
            return matches(text, r) != keepMatching
        }
        try Task.checkCancellation()
        return result
    }

    /// The given lines (0-based, in order), each ending in a newline.
    public static func copying(lines: [Int], in text: NSString) -> String {
        let index = LineIndex(text)
        var out = ""
        for line in lines.sorted() where line < index.lineCount {
            let r = index.contentRange(ofLine: line)
            if r.length == 0, line == index.lineCount - 1, line > 0 { continue } // the empty line after a final newline
            out += text.substring(with: r) + "\n"
        }
        return out
    }

    /// Line numbers after the `removed` lines are gone: nil for a removed
    /// line, else its new number (bookmarks follow their lines).
    public static func renumber(_ line: Int, removed: [Int]) -> Int? {
        // removed is sorted ascending.
        var lo = 0, hi = removed.count
        while lo < hi { let mid = (lo + hi) / 2; if removed[mid] < line { lo = mid + 1 } else { hi = mid } }
        if lo < removed.count, removed[lo] == line { return nil }
        return line - lo
    }
}
