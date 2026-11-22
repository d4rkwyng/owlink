import Foundation
import Testing
@testable import CedricCore

@Suite struct BoundedFindTests {
    @Test func matchesAndReplacementUseRegexOptions() throws {
        let options = FindOptions(regex: true, caseSensitive: false, wholeWord: true)
        let text = "cat CAT cats"
        let regex = try FindEngine.regex("(cat)", options)
        let matches = try FindEngine.boundedMatches(regex, in: text)
        #expect(matches.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
        #expect(FindEngine.replacement(for: matches[1], in: text as NSString, template: "<$1>", regex: regex, options: options) == "<CAT>")
        let sensitive = try FindEngine.regex("(cat)", FindOptions(regex: true, caseSensitive: true, wholeWord: true))
        #expect(try FindEngine.boundedMatches(sensitive, in: text).count == 1)
    }

    @Test func boundedSearchReportsLimitsAndCancellation() throws {
        let regex = try FindEngine.regex("a", FindOptions(regex: true))
        #expect(throws: FindEngine.FindError.tooManyMatches) {
            try FindEngine.boundedMatches(regex, in: "aaa", maxMatches: 1)
        }
        #expect(throws: FindEngine.FindError.cancelled) {
            try FindEngine.boundedMatches(regex, in: "aaa", isCancelled: { true })
        }
        // Deterministic: a clock that advances one second per reading.
        nonisolated(unsafe) var ticks = 0.0
        #expect(throws: FindEngine.FindError.timedOut) {
            try FindEngine.boundedMatches(regex, in: "aaaaaa", timeLimit: 2, now: { ticks += 1; return ticks })
        }
        // A real catastrophic pattern, with a short limit and a long input.
        let pathological = try FindEngine.regex("(a+)+$", FindOptions(regex: true))
        #expect(throws: FindEngine.FindError.timedOut) {
            try FindEngine.boundedMatches(pathological, in: String(repeating: "a", count: 4000) + "!", timeLimit: 0.01)
        }
        #expect(throws: FindEngine.FindError.invalidPattern("(")) {
            try FindEngine.regex("(", FindOptions(regex: true))
        }
    }

    @Test func replaceAllStyleSearchHasNoMatchCapAndLongerLimit() throws {
        let regex = try FindEngine.regex("a", FindOptions(regex: true))
        let text = String(repeating: "a", count: 20_000)
        #expect(throws: FindEngine.FindError.tooManyMatches) { try FindEngine.boundedMatches(regex, in: text) }
        #expect(try FindEngine.boundedMatches(regex, in: text, timeLimit: 30, maxMatches: .max).count == 20_000)
    }

    @Test func timeLimitScalesWithLength() {
        #expect(FindEngine.timeLimit(forLength: 0) == 0.5)
        #expect(FindEngine.timeLimit(forLength: 1_000_000) > FindEngine.timeLimit(forLength: 1_000))
        #expect(FindEngine.timeLimit(forLength: 100, interactive: false) > FindEngine.timeLimit(forLength: 100))
        #expect(FindEngine.timeLimit(forLength: .max) <= 10)
        #expect(FindEngine.timeLimit(forLength: .max, interactive: false) <= 60)
    }

    @Test func wordPrefixMatchesOnlyWordStarts() throws {
        let options = FindOptions(regex: true, wordPrefix: true)
        let regex = try FindEngine.regex("cat", options)
        let matches = try FindEngine.boundedMatches(regex, in: "cat cats concat")
        #expect(matches.map(\.range.location) == [0, 4])
        let whole = try FindEngine.regex("cat", FindOptions(regex: true, wholeWord: true, wordPrefix: true))
        #expect(try FindEngine.boundedMatches(whole, in: "cat cats").count == 1)
    }

    @Test func emojiRangesAreUTF16AndLineAnchorsHandleCRLF() throws {
        let text = "😀 cat\r\ncat 😀\r\n"
        let regex = try FindEngine.regex("^cat$", FindOptions(regex: true, caseSensitive: true))
        #expect(try FindEngine.boundedMatches(regex, in: text).isEmpty)
        let ends = try FindEngine.regex("cat$", FindOptions(regex: true))
        #expect(try FindEngine.boundedMatches(ends, in: text).map(\.range) == [NSRange(location: 3, length: 3)])
        let emoji = try FindEngine.regex("😀", FindOptions())
        #expect(try FindEngine.boundedMatches(emoji, in: text).map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 12, length: 2)])
    }
}
