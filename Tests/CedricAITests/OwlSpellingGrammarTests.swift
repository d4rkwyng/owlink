import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The candidate grammar for a spelling pick (`OwlSpellingChoice`, Core):
/// only one of the spell checker's guesses, as a JSON string. The pick
/// itself (a model choosing among them) is for 0.6.
@Suite struct OwlSpellingGrammarTests {
    static let guesses = ["with", "which", "wish"]

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
