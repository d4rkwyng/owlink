import Foundation
import Testing
@testable import CedricCore

@Suite struct TextCheckingOffsetTests {
    /// Measured on macOS 27 (CEDRIC_CHECK=spellopen): scrolled to the end
    /// of a 600-line file, AppKit checked {14875, 1215}; the results were
    /// an orthography result per line from 0 and "tpyo" at 15, 42, …
    @Test func aPassDownTheTextIsRelativeToItsRange() {
        let checked = NSRange(location: 14875, length: 1215)
        let results = [NSRange(location: 0, length: 27), NSRange(location: 15, length: 4),
                       NSRange(location: 27, length: 27), NSRange(location: 42, length: 4)]
        for expected in [TextCheckingOffset.Convention.relative, .document] {
            #expect(TextCheckingOffset.offset(checked: checked, results: results, expected: expected) == 14875)
            #expect(TextCheckingOffset.documentRanges(checked: checked, results: results, expected: expected)[1]
                    == NSRange(location: 14890, length: 4))
        }
    }

    /// Typing at the end: {16063, 33}, "tpyo" at 15 and "wrnog" at 27.
    @Test func aTypingPassIsRelativeToo() {
        let checked = NSRange(location: 16063, length: 33)
        let results = [NSRange(location: 0, length: 33), NSRange(location: 15, length: 4), NSRange(location: 27, length: 5)]
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: results, expected: .relative)
                == [NSRange(location: 16063, length: 33), NSRange(location: 16078, length: 4), NSRange(location: 16090, length: 5)])
    }

    @Test func fromTheTopNothingMoves() {
        let checked = NSRange(location: 0, length: 2899)
        let results = [NSRange(location: 0, length: 27), NSRange(location: 15, length: 4), NSRange(location: 2000, length: 4)]
        #expect(TextCheckingOffset.offset(checked: checked, results: results, expected: .relative) == 0)
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: results, expected: .relative) == results)
    }

    /// Document offsets (as TextKit 1 hands them over) are left alone when
    /// a result ends past the checked range's length, whatever the path.
    @Test func documentOffsetsAreLeftAlone() {
        let checked = NSRange(location: 14875, length: 1215)
        let results = [NSRange(location: 14875, length: 1215), NSRange(location: 14890, length: 4)]
        for expected in [TextCheckingOffset.Convention.relative, .document] {
            #expect(TextCheckingOffset.offset(checked: checked, results: results, expected: expected) == 0)
        }
    }

    /// {10, 1000} with one misspelling at {20, 3}: both readings fit.
    /// "abc" sits at 20 (document) in one text and at 30 (relative) in the
    /// other; the checked text settles it, whatever the path expects.
    static func text(wordAt at: Int) -> NSString {
        var s = Array(repeating: Character(" "), count: 1100)
        for (i, c) in "abc".enumerated() { s[at + i] = c }
        return String(s) as NSString
    }

    @Test func anAmbiguousBatchFollowsTheText() {
        let checked = NSRange(location: 10, length: 1000)
        let results = [NSRange(location: 20, length: 3)]
        let asDocument = Self.text(wordAt: 20), asRelative = Self.text(wordAt: 30)
        for expected in [TextCheckingOffset.Convention.relative, .document] {
            #expect(TextCheckingOffset.documentRanges(checked: checked, results: results, text: asDocument, expected: expected)
                    == [NSRange(location: 20, length: 3)])
            #expect(TextCheckingOffset.documentRanges(checked: checked, results: results, text: asRelative, expected: expected)
                    == [NSRange(location: 30, length: 3)])
        }
    }

    /// A word at both places: the text can't tell, so the callback path's
    /// convention decides (TextKit 2: relative, TextKit 1: document).
    @Test func anAmbiguousBatchTheTextCantSettleFollowsThePath() {
        let checked = NSRange(location: 10, length: 1000)
        let results = [NSRange(location: 20, length: 3)]
        let both = (String(repeating: " ", count: 20) + "abc" + String(repeating: " ", count: 7) + "def"
                    + String(repeating: " ", count: 1000)) as NSString
        let neither = String(repeating: " ", count: 1100) as NSString
        for text in [both, neither, nil] {
            #expect(TextCheckingOffset.offset(checked: checked, results: results, text: text, expected: .relative) == 10)
            #expect(TextCheckingOffset.offset(checked: checked, results: results, text: text, expected: .document) == 0)
        }
    }

    /// Only spelling results have to be words: an orthography result
    /// spans sentences and is no evidence either way.
    @Test func onlySpellingResultsAreCheckedAgainstTheText() {
        let checked = NSRange(location: 10, length: 1000)
        let results = [NSRange(location: 15, length: 400), NSRange(location: 20, length: 3)]
        let asRelative = Self.text(wordAt: 30)
        #expect(TextCheckingOffset.offset(checked: checked, results: results, spelling: [false, true], text: asRelative,
                                          expected: .document) == 10)
        // Counted as words, the orthography range covers neither reading.
        #expect(TextCheckingOffset.offset(checked: checked, results: results, text: asRelative, expected: .document) == 0)
    }

    /// Part of a word isn't the word: "xabcx" at 19 doesn't make {20, 3} a word.
    @Test func partOfAWordIsNotAWord() {
        let ns = "                   xabcx      abc   " as NSString
        #expect(!TextCheckingOffset.isWord(NSRange(location: 20, length: 3), in: ns))
        #expect(TextCheckingOffset.isWord(NSRange(location: 30, length: 3), in: ns))
        #expect(!TextCheckingOffset.isWord(NSRange(location: 33, length: 3), in: ns))
        #expect(!TextCheckingOffset.isWord(NSRange(location: 35, length: 5), in: ns))
        #expect(TextCheckingOffset.isWord(NSRange(location: 0, length: 3), in: "abc" as NSString))
        #expect(TextCheckingOffset.isWord(NSRange(location: 0, length: 5), in: "naïve!" as NSString))
    }

    @Test func noResultsNoOffsetNeeded() {
        #expect(TextCheckingOffset.documentRanges(checked: NSRange(location: 500, length: 10), results: [], expected: .relative) == [])
    }

    @Test func notFoundIsKept() {
        let r = NSRange(location: NSNotFound, length: 0)
        let checked = NSRange(location: 500, length: 10)
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: [r, NSRange(location: 2, length: 3)], expected: .document)
                == [r, NSRange(location: 502, length: 3)])
    }
}
