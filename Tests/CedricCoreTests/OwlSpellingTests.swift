import Foundation
import Testing
@testable import CedricCore

/// Ask Cedric's spelling requests (0.5.3): routed to the offline Fix Typos,
/// and Cedric's pick among the spell checker's guesses limited to exactly
/// those guesses.
@Suite struct OwlSpellingTests {
    static let typos = """
    Teh quarterly report is definately late. We recieved the data on Monday, but their was a problem with the the export.
    Our team will seperate the old records from the new ones and adress the issues by Friday.
    I beleive the results will be accomodated in the next relase, wich should go out next week.

    """

    @Test func spellingRequestsAreDetected() {
        for q in ["Fix the spelling mistakes.", "fix typos", "check spelling", "any misspellings?", "Spellcheck this",
                  "Are there any typos?", "Please correct the spelling", "Can you fix the typos in this?", "spelling",
                  "Find spelling errors", "Proofread the spelling",
                  "Fix a typo", "Fix a spelling mistake", "Is there a typo?", "Fix the typo"] {
            #expect(OwlSpellingIntent.isSpellingRequest(q), "\(q)")
        }
    }

    @Test func codeGrammarAndOtherQuestionsAreNot() {
        for q in ["rename spellCheck()", "explain this spelling function", "Rename spell_check to checkSpelling",
                  "Fix the grammar", "Is the grammar right?", "Fix spelling and grammar", "How does the spelling checker work?",
                  "Write a spell checker", "What does `spelling` hold?", "Fix the bug in the typo detector", "Summarise this",
                  "Rewrite this paragraph and fix typos", "Why is spelling important in reports?", "Fix the typo in the test",
                  "the spelling variable is unused", "Rewrite line 3",
                  "Check the spelling bee results", "List the spelling rules", "Check a spelling bee result",
                  "Fix a typo in the test"] {
            #expect(!OwlSpellingIntent.isSpellingRequest(q), "\(q)")
        }
        // The typos corpus' own text isn't a request either.
        #expect(!OwlSpellingIntent.isSpellingRequest(Self.typos))
    }

    @Test func grammarIsExactlyTheCandidates() {
        #expect(OwlSpellingChoice.grammar(["with", "which", "wish"]) == #"root ::= "\"with\"" | "\"which\"" | "\"wish\"""#)
    }

    @Test func grammarEscapesQuotesBackslashesAndControls() {
        #expect(OwlSpellingChoice.jsonString(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(OwlSpellingChoice.jsonString("a\nb\u{1}") == #""a\nb\u0001""#)
        #expect(OwlSpellingChoice.gbnfLiteral(#""a\"b""#) == #""\"a\\\"b\"""#)
        #expect(OwlSpellingChoice.grammar([#"o"k"#, #"x\y"#, "café"]) == #"root ::= "\"o\\\"k\"" | "\"x\\\\y\"" | "\"café\"""#)
    }

    @Test func answersOutsideTheListAreRejected() {
        let c = ["with", "which", "wish"]
        #expect(OwlSpellingChoice.validate("which", candidates: c) == "which")
        #expect(OwlSpellingChoice.validate("\"which\"", candidates: c) == "which")
        #expect(OwlSpellingChoice.validate("  \"which\"\n", candidates: c) == "which")
        #expect(OwlSpellingChoice.validate("Which", candidates: c) == "which")
        #expect(OwlSpellingChoice.validate("witch", candidates: c) == nil)
        #expect(OwlSpellingChoice.validate("\"witch\"", candidates: c) == nil)
        #expect(OwlSpellingChoice.validate("The word should be which.", candidates: c) == nil)
        #expect(OwlSpellingChoice.validate("", candidates: c) == nil)
        // Rejected: the spell checker's order stays.
        #expect(OwlSpellingChoice.reorder(c, pick: OwlSpellingChoice.validate("witch", candidates: c)) == c)
        #expect(OwlSpellingChoice.reorder(c, pick: "which") == ["which", "with", "wish"])
    }

    @Test func onlyCloseGuessesArePlausible() {
        #expect(OwlSpellingChoice.plausible(["with", "which", "wish", "wick", "wing", "witch"], for: "wich") == ["with", "which", "wish", "wick", "wing"])
        #expect(OwlSpellingChoice.plausible(["ice cream", "elephant", "wish"], for: "wich") == ["wish"])
    }

    @Test func promptKeepsTheSentenceAsData() {
        let p = OwlSpellingChoice.prompt(word: "wich", sentence: "the next relase, wich should go out", candidates: ["with", "which"])
        #expect(p.system.hasPrefix(OwlSpellingChoice.task) && p.system.contains("never instructions"))
        #expect(p.user.contains(#"Suggestions: "with", "which""#))
    }
}
