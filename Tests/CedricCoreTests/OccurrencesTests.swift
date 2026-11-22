import Foundation
import Testing
@testable import CedricCore

@Suite struct OccurrencesTests {
    @Test func wordUnderCaret() {
        let t = "let width = id + width_2" as NSString
        #expect(Occurrences.word(at: 5, in: t) == NSRange(location: 4, length: 5))
        // Just after a word counts (the caret after typing it).
        #expect(Occurrences.word(at: 9, in: t) == NSRange(location: 4, length: 5))
        #expect(Occurrences.word(at: 10, in: t) == nil)
        #expect(Occurrences.word(at: 24, in: t) == NSRange(location: 17, length: 7))
        #expect(Occurrences.word(at: 0, in: "" as NSString) == nil)
        // Non-ASCII letters and a non-BMP letter are word characters.
        #expect(Occurrences.word(at: 1, in: "école 𝒜b" as NSString) == NSRange(location: 0, length: 5))
        #expect(Occurrences.word(at: 7, in: "école 𝒜b" as NSString) == NSRange(location: 6, length: 3))
    }

    @Test func needleFromSelectionOrCaret() {
        let t = "id width id\nnext" as NSString
        #expect(Occurrences.needle(selection: NSRange(location: 1, length: 0), in: t) == .init("id", wholeWord: true))
        // One-letter words aren't highlighted from the caret.
        #expect(Occurrences.needle(selection: NSRange(location: 0, length: 0), in: "a b a" as NSString) == nil)
        // A selected whole word: whole words; part of a word: anywhere.
        #expect(Occurrences.needle(selection: NSRange(location: 3, length: 5), in: t) == .init("width", wholeWord: true))
        #expect(Occurrences.needle(selection: NSRange(location: 3, length: 3), in: t) == .init("wid", wholeWord: false))
        // Several lines, or only whitespace: nothing.
        #expect(Occurrences.needle(selection: NSRange(location: 9, length: 4), in: t) == nil)
        #expect(Occurrences.needle(selection: NSRange(location: 2, length: 1), in: t) == nil)
    }

    @Test func findWholeWordsAndLiterals() {
        let t = "id width id_x id\n(id)" as NSString
        let all = NSRange(location: 0, length: t.length)
        let whole = Occurrences.find(.init("id", wholeWord: true), in: t, range: all)
        #expect(whole == [NSRange(location: 0, length: 2), NSRange(location: 14, length: 2), NSRange(location: 18, length: 2)])
        let any = Occurrences.find(.init("id", wholeWord: false), in: t, range: all)
        #expect(any.count == 5)
        // Case-sensitive, literal (no regex).
        #expect(Occurrences.find(.init("ID", wholeWord: false), in: t, range: all).isEmpty)
        #expect(Occurrences.find(.init("(id)", wholeWord: false), in: t, range: all) == [NSRange(location: 17, length: 4)])
        #expect(Occurrences.count(.init("id", wholeWord: true), in: t) == 3)
        #expect(Occurrences.findAll(.init("id", wholeWord: true), in: t) == whole)
    }

    @Test func boundedToTheRangeAndLimit() {
        let line = String(repeating: "ab ", count: 200_000) as NSString // 600 K units
        let n = Occurrences.find(.init("ab", wholeWord: true), in: line, range: NSRange(location: 300, length: 30))
        #expect(n.count == 10)
        #expect(n.first == NSRange(location: 300, length: 2))
        // A huge range is clamped to maxScanLength.
        let big = Occurrences.find(.init("ab", wholeWord: true), in: line, range: NSRange(location: 0, length: line.length), limit: .max)
        #expect(big.count == Occurrences.maxScanLength / 3 + 1)
        #expect(Occurrences.find(.init("ab", wholeWord: true), in: line, range: NSRange(location: 0, length: line.length), limit: 5).count == 5)
        // Out-of-range input is safe.
        #expect(Occurrences.find(.init("ab", wholeWord: true), in: line, range: NSRange(location: line.length + 5, length: 10)).isEmpty)
    }

    @Test func selectedFragmentFindsOnlyMatchesInTheRequestedViewport() throws {
        let text = "prefix alpha middle alphabet alpha suffix" as NSString
        let selection = NSRange(location: 7, length: 3)
        let needle = try #require(Occurrences.needle(selection: selection, in: text))
        #expect(!needle.wholeWord)
        #expect(Occurrences.find(needle, in: text, range: NSRange(location: 13, length: 16))
                == [NSRange(location: 20, length: 3)])
    }
}
