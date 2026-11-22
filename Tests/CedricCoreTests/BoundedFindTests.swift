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
        let pathological = try FindEngine.regex("(a+)+$", FindOptions(regex: true))
        #expect(throws: FindEngine.FindError.timedOut) {
            try FindEngine.boundedMatches(pathological, in: String(repeating: "a", count: 1000) + "!", timeLimit: 0.02)
        }
        #expect(throws: FindEngine.FindError.invalidPattern("(")) {
            try FindEngine.regex("(", FindOptions(regex: true))
        }
    }
}
