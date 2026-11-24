import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Cedric's pick among the spell checker's guesses: only one of them, only
/// with an engine already in use for the Ask, and the spell checker's order
/// whenever anything else comes back.
@Suite struct OwlSpellingPickerTests {
    static let sentence = "I beleive the results will be accomodated in the next relase, wich should go out next week."
    static let guesses = ["with", "which", "wish"]

    static func pick(_ answer: String?, inUse: Bool = true, timeout: TimeInterval = 2) async -> [String] {
        var e = FakeChatEngine(delay: 0.001, pieces: 1)
        e.spellingAnswer = answer
        return await OwlSpellingPicker.pick(word: "wich", sentence: sentence, guesses: guesses, engine: e,
                                            engineInUse: inUse, timeout: timeout)
    }

    @Test func aValidPickReorders() async {
        #expect(await Self.pick("which") == ["which", "with", "wish"])
        #expect(await Self.pick("\"which\"") == ["which", "with", "wish"])
        // The fake's default answer: the first suggestion, as JSON.
        #expect(await Self.pick(nil) == Self.guesses)
    }

    @Test func anythingElseKeepsTheSpellCheckersOrder() async {
        #expect(await Self.pick("witch") == Self.guesses)
        #expect(await Self.pick("I think the word is which.") == Self.guesses)
        #expect(await Self.pick("") == Self.guesses)
    }

    @Test func neverWithoutAnEngineInUseOrWithFewerThanTwoCandidates() async {
        #expect(await Self.pick("which", inUse: false) == Self.guesses)
        let one = await OwlSpellingPicker.pick(word: "wich", sentence: Self.sentence, guesses: ["which", "elephant"],
                                               engine: FakeChatEngine(delay: 0.001), engineInUse: true)
        #expect(one == ["which", "elephant"])
        let none = await OwlSpellingPicker.pick(word: "wich", sentence: Self.sentence, guesses: Self.guesses, engine: nil, engineInUse: true)
        #expect(none == Self.guesses)
    }

    @Test func aSlowEngineTimesOutSilently() async {
        var e = FakeChatEngine(delay: 5, pieces: 1)
        e.spellingAnswer = "which"
        let start = Date()
        let r = await OwlSpellingPicker.pick(word: "wich", sentence: Self.sentence, guesses: Self.guesses, engine: e,
                                             engineInUse: true, timeout: 0.1)
        #expect(r == Self.guesses)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func builtInGrammarIsTheCandidateList() {
        #expect(OwlSpellingChoice.grammar(OwlSpellingChoice.plausible(Self.guesses, for: "wich"))
                == #"root ::= "\"with\"" | "\"which\"" | "\"wish\"""#)
    }

    @Test func grammarAcceptsOnlyACandidateAsAJSONString() throws {
        let g = try GBNFMatcher(OwlSpellingChoice.grammar(Self.guesses))
        for w in Self.guesses { #expect(g.matches("\"\(w)\""), "\(w)") }
        for bad in ["which", "\"witch\"", "\"which\" ", "\"Which\"", "\"with\"\"which\""] { #expect(!g.matches(bad), "\(bad)") }
        // Quotes and backslashes inside a candidate survive the escaping.
        let odd = try GBNFMatcher(OwlSpellingChoice.grammar([#"o"k"#, #"x\y"#]))
        #expect(odd.matches(#""o\"k""#) && odd.matches(#""x\\y""#))
        #expect(!odd.matches(#""o"k""#))
    }
}
