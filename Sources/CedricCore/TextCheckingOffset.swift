import Foundation

/// Where a batch of text-checking results lies in the document.
///
/// NSTextView's continuous checking on TextKit 2 (NSTextCheckingController)
/// hands `handleTextCheckingResults(_:forRange:…)` result ranges relative
/// to the checked range: checking `{14875, 1215}` (scrolled to the end of
/// a file) gives a misspelling at `{15, 4}`, its offset in that range.
/// TextKit 1 hands them over as document offsets. Read as document
/// offsets, a later pass's results fell outside the spelling scope and
/// nothing scrolled to was ever marked (0.5.4).
///
/// The convention is the callback path's (`expected`: relative on
/// TextKit 2, document offsets on TextKit 1), unless the batch itself
/// rules that reading out: a result that starts before `checked.location`
/// can't be a document offset (results lie inside the checked range), one
/// that ends past `checked.length` can't be relative. When both readings
/// fit (`{10, 1000}` with one misspelling at `{20, 3}`), nothing in the
/// text is trusted to overrule the path: a word-boundary guess picked
/// wrong next to an emoji (its trailing surrogate read as a letter), and a
/// wrong pick can drop a valid underline through the spelling scope.
public enum TextCheckingOffset {
    public enum Convention: Equatable, Sendable {
        /// Ranges are relative to the checked range (TextKit 2).
        case relative
        /// Ranges are document offsets (TextKit 1).
        case document
    }

    /// What to add to each result's location to get a document offset.
    public static func offset(checked: NSRange, results: [NSRange], expected: Convention) -> Int {
        guard checked.location > 0 else { return 0 }
        switch convention(checked: checked, results: results, expected: expected) {
        case .relative: return checked.location
        case .document: return 0
        }
    }

    public static func convention(checked: NSRange, results: [NSRange], expected: Convention) -> Convention {
        let found = results.filter { $0.location != NSNotFound }
        if found.contains(where: { $0.location < checked.location }) { return .relative }
        if found.contains(where: { NSMaxRange($0) > checked.length }) { return .document }
        return expected
    }

    /// `results` as document ranges.
    public static func documentRanges(checked: NSRange, results: [NSRange], expected: Convention) -> [NSRange] {
        let o = offset(checked: checked, results: results, expected: expected)
        return results.map { $0.location == NSNotFound ? $0 : NSRange(location: $0.location + o, length: $0.length) }
    }
}
