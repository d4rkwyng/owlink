import Foundation

/// When a document is "large": big enough, or with a line long enough, that
/// the normal editing extras (colouring, the owl, spell check) cost more
/// than they give. In large mode the editor shows a slim info bar, cuts
/// long lines into chunks for TextKit (ChunkedContentStorage in the app),
/// pauses colouring and spell check, and the owl stays idle: no rules, no
/// AI, unless the user clicks him.
///
/// Thresholds, from measurements on an M4 Pro (Scripts/perf-check.sh,
/// docs/architecture.md › Large documents): TextKit 2 lays out a paragraph
/// as a whole, so a keystroke on one long line costs ~0.16 µs per
/// character of that line: 5 ms at 20,000 characters, 9 ms at 40,000,
/// 24 ms at 80,000 and 100–140 ms at 636,000 (Derek's file). 20,000 keeps
/// a keystroke well under a frame on slower Macs too. Many-line files stay
/// fast to far larger sizes (a 50 MB log types in 3 ms), so the size
/// threshold is only for the extras' sake.
public enum LargeDocument {
    /// Any line longer than this (UTF-16 code units) turns large mode on.
    public static let lineThreshold = 20_000
    /// So does a document longer than this (UTF-16 code units, ≈ 25 MB of ASCII).
    /// Raised from 5 M (T3-M4, 2026-11-18): many-line files stay fast far past
    /// that, and a 10 MB JSON or code file should keep its colouring.
    public static let sizeThreshold = 25_000_000
    /// The chunk length TextKit sees for lines longer than this.
    public static let chunkLength = 2_048

    public enum Reason: String, Sendable, Equatable {
        case longLine, size
    }

    /// Why `index`'s document is large, or nil.
    public static func reason(for index: LineIndex) -> Reason? {
        if index.length > sizeThreshold { return .size }
        // A line can only be that long if the document is.
        if index.length > lineThreshold, index.longestLine > lineThreshold { return .longLine }
        return nil
    }

    /// After an edit: lines `lines` changed. Cheap (the edited lines only),
    /// for typing and pasting into a document that wasn't large.
    public static func reason(afterEditOf lines: Range<Int>, in index: LineIndex) -> Reason? {
        if index.length > sizeThreshold { return .size }
        guard index.length > lineThreshold else { return nil }
        for i in lines where i < index.lineCount && index.lineLength(i) > lineThreshold { return .longLine }
        return nil
    }

    // MARK: Chunks

    /// TextKit gets chunks (ChunkedContentStorage) only when a line is
    /// over `lineThreshold`: a long line is what it can't lay out quickly.
    /// A large file of ordinary lines (a 55 MB log) keeps TextKit's own
    /// paragraphs, as it has below `sizeThreshold`. Handing those out one
    /// by one through the chunking storage crashed on macOS 26 (0.5.2: an
    /// NSCountableTextLocation compare: exception in layout, every log
    /// past 25 M characters, the first size that turned large mode on).
    public static func needsChunks(_ index: LineIndex) -> Bool {
        index.length > lineThreshold && index.longestLine > lineThreshold
    }

    /// After an edit of lines `lines`: one of them is now over `lineThreshold`.
    public static func needsChunks(afterEditOf lines: Range<Int>, in index: LineIndex) -> Bool {
        guard index.length > lineThreshold else { return false }
        return lines.contains { $0 < index.lineCount && index.lineLength($0) > lineThreshold }
    }

    /// Where chunk `k` of `line` starts: `k × limit` from the line start,
    /// moved back to the start of a composed character sequence (surrogate
    /// pair, combining marks, CRLF) it would cut. Depends only on the text
    /// there: O(1), and an edit only moves the chunks from the edit on.
    public static func boundary(_ k: Int, of line: NSRange, in text: NSString, limit: Int) -> Int {
        let nominal = line.location + k * limit
        guard k > 0, nominal < NSMaxRange(line) else { return min(nominal, NSMaxRange(line)) }
        let seq = text.rangeOfComposedCharacterSequence(at: nominal)
        return seq.location < nominal && seq.location > nominal - limit ? seq.location : nominal
    }

    /// The chunks of `line` (newline included): the line itself if it fits.
    public static func chunks(of line: NSRange, in text: NSString, limit: Int) -> [NSRange] {
        guard line.length > limit else { return [line] }
        let n = (line.length + limit - 1) / limit
        return (0..<n).map { k in
            let s = boundary(k, of: line, in: text, limit: limit), e = boundary(k + 1, of: line, in: text, limit: limit)
            return NSRange(location: s, length: e - s)
        }
    }

    /// The chunk of `line` holding `offset` (the line's end: the last chunk).
    public static func chunk(containing offset: Int, line: NSRange, in text: NSString, limit: Int) -> NSRange {
        guard line.length > limit else { return line }
        let n = (line.length + limit - 1) / limit
        var k = min(max(0, offset - line.location) / limit, n - 1)
        // Chunk k starts at or before offset (boundaries only move back).
        // Chunk k+1's start moves back, never by a whole chunk, for a
        // composed sequence it would cut: if offset is that sequence's
        // start or inside it, offset is in chunk k+1. Picking chunk k
        // there handed TextKit a chunk ending at offset, and its forward
        // enumeration asked from offset again, forever: a hang on a long
        // line with an emoji or an accent at a chunk boundary.
        if k + 1 < n, boundary(k + 1, of: line, in: text, limit: limit) <= offset { k += 1 }
        let s = boundary(k, of: line, in: text, limit: limit)
        return NSRange(location: s, length: boundary(k + 1, of: line, in: text, limit: limit) - s)
    }

    /// A forward walk over chunks (the chunking content storage's
    /// enumeration): where it goes after handing out `chunk`, asked for
    /// from `offset`. Nil when `chunk` doesn't hold `offset`: the walk
    /// would hand out an element that ends at or before where it was
    /// asked from, or ask from the same offset again, so it stops.
    public static func forwardStep(from offset: Int, chunk: NSRange) -> Int? {
        NSLocationInRange(offset, chunk) ? NSMaxRange(chunk) : nil
    }

    /// A backward walk's step: the offset before `chunk`, asked for from
    /// `offset`; nil when `chunk` doesn't hold `offset`.
    public static func backwardStep(from offset: Int, chunk: NSRange) -> Int? {
        NSLocationInRange(offset, chunk) ? chunk.location - 1 : nil
    }
}
