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
        #expect(TextCheckingOffset.offset(checked: checked, results: results) == 14875)
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: results)[1] == NSRange(location: 14890, length: 4))
    }

    /// Typing at the end: {16063, 33}, "tpyo" at 15 and "wrnog" at 27.
    @Test func aTypingPassIsRelativeToo() {
        let checked = NSRange(location: 16063, length: 33)
        let results = [NSRange(location: 0, length: 33), NSRange(location: 15, length: 4), NSRange(location: 27, length: 5)]
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: results)
                == [NSRange(location: 16063, length: 33), NSRange(location: 16078, length: 4), NSRange(location: 16090, length: 5)])
    }

    @Test func fromTheTopNothingMoves() {
        let checked = NSRange(location: 0, length: 2899)
        let results = [NSRange(location: 0, length: 27), NSRange(location: 15, length: 4), NSRange(location: 2000, length: 4)]
        #expect(TextCheckingOffset.offset(checked: checked, results: results) == 0)
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: results) == results)
    }

    /// Document offsets (as TextKit 1 hands them over) are left alone:
    /// the orthography result spans the checked range, past its length.
    @Test func documentOffsetsAreLeftAlone() {
        let checked = NSRange(location: 14875, length: 1215)
        let results = [NSRange(location: 14875, length: 1215), NSRange(location: 14890, length: 4)]
        #expect(TextCheckingOffset.offset(checked: checked, results: results) == 0)
        let near = NSRange(location: 10, length: 1000)
        #expect(TextCheckingOffset.offset(checked: near, results: [NSRange(location: 10, length: 1000), NSRange(location: 20, length: 3)]) == 0)
    }

    @Test func noResultsNoOffsetNeeded() {
        #expect(TextCheckingOffset.documentRanges(checked: NSRange(location: 500, length: 10), results: []) == [])
    }

    @Test func notFoundIsKept() {
        let r = NSRange(location: NSNotFound, length: 0)
        let checked = NSRange(location: 500, length: 10)
        #expect(TextCheckingOffset.documentRanges(checked: checked, results: [r, NSRange(location: 2, length: 3)])
                == [r, NSRange(location: 502, length: 3)])
    }
}
