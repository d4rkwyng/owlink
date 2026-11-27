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

    /// {10, 1000} with one misspelling at {20, 3}: both readings fit, so
    /// the callback path's convention decides (TextKit 2: relative, TextKit
    /// 1: document), whatever the text holds.
    @Test func anAmbiguousBatchFollowsThePath() {
        let checked = NSRange(location: 10, length: 1000)
        let results = [NSRange(location: 20, length: 3)]
        #expect(TextCheckingOffset.offset(checked: checked, results: results, expected: .relative) == 10)
        #expect(TextCheckingOffset.offset(checked: checked, results: results, expected: .document) == 0)
    }

    /// `cat` at 20 and `🙂err` with `err` at 30 (Astra's case): a word
    /// guess read the emoji's trailing surrogate as a letter, took `err`
    /// for part of a word and picked `cat` on TextKit 2. Its mirror,
    /// `🙂cat` with `cat` at 20 and `err` at 30, would pick `err` on
    /// TextKit 1. Both readings fit, so the path decides in both.
    static func text(_ parts: [(Int, String)]) -> NSString {
        let s = NSMutableString(string: String(repeating: " ", count: 1100))
        for (at, word) in parts {
            let w = word as NSString
            s.replaceCharacters(in: NSRange(location: at, length: w.length), with: word)
        }
        return s
    }

    @Test func anEmojiBeforeAWordDoesntOverruleThePath() {
        let checked = NSRange(location: 10, length: 1000)
        let results = [NSRange(location: 20, length: 3)]
        let emojiBeforeErr = Self.text([(20, "cat"), (28, "🙂err")])
        let emojiBeforeCat = Self.text([(18, "🙂cat"), (30, "err")])
        for text in [emojiBeforeErr, emojiBeforeCat] {
            #expect(text.substring(with: NSRange(location: 20, length: 3)) == "cat")
            #expect(text.substring(with: NSRange(location: 30, length: 3)) == "err")
            let relative = TextCheckingOffset.documentRanges(checked: checked, results: results, expected: .relative)
            #expect(relative == [NSRange(location: 30, length: 3)])
            #expect(text.substring(with: relative[0]) == "err")
            let document = TextCheckingOffset.documentRanges(checked: checked, results: results, expected: .document)
            #expect(document == [NSRange(location: 20, length: 3)])
            #expect(text.substring(with: document[0]) == "cat")
        }
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
