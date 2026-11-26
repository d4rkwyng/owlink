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
/// The convention is settled, in order, by:
/// 1. the batch itself, when only one reading is possible: a result that
///    starts before `checked.location` can't be a document offset (results
///    lie inside the checked range), one that ends past `checked.length`
///    can't be relative;
/// 2. the checked text, when the batch fits both readings (`{10, 1000}`
///    with one misspelling at `{20, 3}`): each spelling result must cover a
///    whole word there (a letter at each end, no letter either side); if
///    exactly one reading does, it is that one;
/// 3. otherwise the callback path's convention (`expected`: relative on
///    TextKit 2, document offsets on TextKit 1).
public enum TextCheckingOffset {
    public enum Convention: Equatable, Sendable {
        /// Ranges are relative to the checked range (TextKit 2).
        case relative
        /// Ranges are document offsets (TextKit 1).
        case document
    }

    /// What to add to each result's location to get a document offset.
    /// `spelling`: which of `results` are spelling results (the ones that
    /// cover a word; nil: all of them). `text`: the checked document.
    public static func offset(checked: NSRange, results: [NSRange], spelling: [Bool]? = nil,
                              text: NSString? = nil, expected: Convention) -> Int {
        guard checked.location > 0 else { return 0 }
        switch convention(checked: checked, results: results, spelling: spelling, text: text, expected: expected) {
        case .relative: return checked.location
        case .document: return 0
        }
    }

    public static func convention(checked: NSRange, results: [NSRange], spelling: [Bool]? = nil,
                                  text: NSString? = nil, expected: Convention) -> Convention {
        let found = results.indices.filter { results[$0].location != NSNotFound }
        if found.contains(where: { results[$0].location < checked.location }) { return .relative }
        if found.contains(where: { NSMaxRange(results[$0]) > checked.length }) { return .document }
        guard let text else { return expected }
        let words = found.filter { spelling?[$0] ?? true }.map { results[$0] }
        guard !words.isEmpty else { return expected }
        let asRelative = words.allSatisfy { isWord(NSRange(location: $0.location + checked.location, length: $0.length), in: text) }
        let asDocument = words.allSatisfy { isWord($0, in: text) }
        if asRelative != asDocument { return asRelative ? .relative : .document }
        return expected
    }

    /// `results` as document ranges.
    public static func documentRanges(checked: NSRange, results: [NSRange], spelling: [Bool]? = nil,
                                      text: NSString? = nil, expected: Convention) -> [NSRange] {
        let o = offset(checked: checked, results: results, spelling: spelling, text: text, expected: expected)
        return results.map { $0.location == NSNotFound ? $0 : NSRange(location: $0.location + o, length: $0.length) }
    }

    /// `r` covers a whole word of `text`: inside it, a letter at each end,
    /// and no letter just before or just after.
    static func isWord(_ r: NSRange, in text: NSString) -> Bool {
        guard r.length > 0, NSMaxRange(r) <= text.length else { return false }
        func letter(_ i: Int) -> Bool {
            guard let u = UnicodeScalar(text.character(at: i)) else { return true } // a surrogate half: part of a word
            return CharacterSet.letters.contains(u)
        }
        guard letter(r.location), letter(NSMaxRange(r) - 1) else { return false }
        if r.location > 0, letter(r.location - 1) { return false }
        if NSMaxRange(r) < text.length, letter(NSMaxRange(r)) { return false }
        return true
    }
}
