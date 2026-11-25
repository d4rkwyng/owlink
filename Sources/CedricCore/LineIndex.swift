import Foundation

/// The UTF-16 offset of the start of every line, kept up to date
/// incrementally as the text changes. Lines end in "\n" only: Cedric
/// normalises CRLF and CR on load and paste and writes the document's line
/// ending back on save.
public struct LineIndex: Sendable {
    /// `starts[i]` is where line i begins; `starts[0] == 0`. Always at
    /// least one line (an empty document has one empty line).
    public private(set) var starts: [Int] = [0]
    public private(set) var length: Int = 0

    public init() {}

    public init(_ text: NSString) {
        length = text.length
        starts = [0]
        starts.reserveCapacity(max(16, length / 40))
        Self.scanNewlines(text, in: NSRange(location: 0, length: length)) { starts.append($0) }
    }

    public var lineCount: Int { starts.count }

    /// The length of the longest line (newline included), O(lines).
    public var longestLine: Int {
        var best = 0
        for i in 0..<starts.count {
            let end = i + 1 < starts.count ? starts[i + 1] : length
            best = max(best, end - starts[i])
        }
        return best
    }

    /// Line `i`'s length, newline included.
    public func lineLength(_ i: Int) -> Int {
        (i + 1 < starts.count ? starts[i + 1] : length) - starts[i]
    }

    /// Calls `found` with the offset just after each "\n" in `range`.
    /// The scratch buffer is the size of the range, up to 64 K units: an
    /// edit of one character asks for 2 bytes, not 128 KB.
    static func scanNewlines(_ text: NSString, in range: NSRange, _ found: (Int) -> Void) {
        guard range.length > 0 else { return }
        let chunk = min(65536, range.length)
        var buffer = [UInt16](repeating: 0, count: chunk)
        var pos = range.location
        let end = range.location + range.length
        while pos < end {
            let len = min(chunk, end - pos)
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: pos, length: len))
                for k in 0..<len where p[k] == 10 { found(pos + k + 1) }
            }
            pos += len
        }
    }

    /// The line containing `offset` (the last line for offset == length).
    public func line(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Line `i`'s range without its "\n".
    public func contentRange(ofLine i: Int) -> NSRange {
        let start = starts[i]
        let end = i + 1 < starts.count ? starts[i + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Updates the index after `text` (already edited) had `oldRange`
    /// replaced by `newLength` characters. Returns the first line whose
    /// content changed, for the highlighter's invalidation.
    @discardableResult
    public mutating func replace(_ oldRange: NSRange, newLength: Int, in text: NSString) -> Int {
        let delta = newLength - oldRange.length
        let firstLine = line(containing: oldRange.location)
        // Lines whose starts fall inside the replaced range are gone.
        var removeEnd = firstLine + 1
        while removeEnd < starts.count, starts[removeEnd] <= oldRange.location + oldRange.length { removeEnd += 1 }
        var inserted: [Int] = []
        Self.scanNewlines(text, in: NSRange(location: oldRange.location, length: newLength)) { inserted.append($0) }
        if delta != 0 {
            for k in removeEnd..<starts.count { starts[k] += delta }
        }
        starts.replaceSubrange((firstLine + 1)..<removeEnd, with: inserted)
        length += delta
        return firstLine
    }
}
