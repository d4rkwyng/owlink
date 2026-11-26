import Foundation

/// Where a batch of text-checking results lies in the document.
///
/// NSTextView's continuous checking on TextKit 2 (NSTextCheckingController)
/// hands `handleTextCheckingResults(_:forRange:…)` result ranges relative
/// to the checked range: checking `{14875, 1215}` (scrolled to the end of
/// a file) gives a misspelling at `{15, 4}`, its offset in that range.
/// A pass from the top of the text (location 0) can't tell the two apart.
/// Read as document offsets, a later pass's results fell outside the
/// spelling scope and nothing scrolled to was ever marked (0.5.4).
public enum TextCheckingOffset {
    /// What to add to each result's location to get a document offset:
    /// `checked.location` when every result lies within the checked range's
    /// length (relative, as TextKit 2 hands them over), 0 when they are
    /// document offsets (one ends past that length: a pass's orthography
    /// result spans the whole checked range, so with `checked.location > 0`
    /// document offsets always do).
    public static func offset(checked: NSRange, results: [NSRange]) -> Int {
        guard checked.location > 0 else { return 0 }
        let found = results.filter { $0.location != NSNotFound }
        let relative = found.allSatisfy { NSMaxRange($0) <= checked.length }
        return relative ? checked.location : 0
    }

    /// `results` as document ranges.
    public static func documentRanges(checked: NSRange, results: [NSRange]) -> [NSRange] {
        let o = offset(checked: checked, results: results)
        return results.map { $0.location == NSNotFound ? $0 : NSRange(location: $0.location + o, length: $0.length) }
    }
}
