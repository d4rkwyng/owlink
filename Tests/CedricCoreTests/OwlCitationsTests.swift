import Foundation
import Testing
@testable import CedricCore

/// Citations kept to the lines a model was given, the planner covering
/// every line at any size, and the section notes in an exported chat.
@Suite struct OwlCitationsTests {
    static let lines1to18 = IndexSet(integersIn: 1...18)

    @Test func unsentLinesAreDroppedAndSentOnesKept() {
        // What Summarise answered on iPad, shown lines 1–18 of 282.
        let answer = """
        - Line 3 names the trip.
        - Lines 12–14 describe the walk.
        - Lines 19–20 talk about the rain.
        - Lines 31-34 end the day.
        """
        let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
        #expect(f.text.contains("Line 3 names the trip."))
        #expect(f.text.contains("Lines 12–14 describe the walk."))
        #expect(!f.text.contains("rain") && !f.text.contains("end the day"))
        #expect(f.dropped == [19...20, 31...34] && f.flagged.isEmpty)
    }

    @Test func aSentenceThatAlsoCitesSentLinesIsFlaggedNotCut() {
        let one = "The opening (line 2) sets the scene and the ending on line 31 resolves it."
        let f = OwlCitations.filter(one, allowed: Self.lines1to18)
        #expect(f.text == "The opening (line 2) sets the scene and the ending on line 31\(OwlCitations.flag) resolves it.")
        #expect(f.flagged == [31...31] && f.dropped.isEmpty)
        // A range running past the lines given is flagged too.
        let over = OwlCitations.filter("Lines 17-20 repeat the list.", allowed: Self.lines1to18)
        #expect(over.text.contains("17-20\(OwlCitations.flag)"))
    }

    @Test func anAnswerThatIsOnlyAboutUnsentLinesIsFlaggedNotEmptied() {
        let f = OwlCitations.filter("- Lines 31–34 end the day.", allowed: Self.lines1to18)
        #expect(f.text == "- Lines 31–34\(OwlCitations.flag) end the day.")
    }

    @Test func formsItReads() {
        let cites = OwlCitations.find("See lines 3, 7 and 9-11, line 4 to 5.\n31| quoted text")
        #expect(cites.map(\.lines) == [3...3, 7...7, 9...11, 4...5, 31...31])
        // Not citations: a count of lines, a heading number, a time, L2/L1 terms.
        #expect(OwlCitations.find("It has 282 lines. ## 2 Plans at 12:30, #4. L2 regularization, an L1 cache.").isEmpty)
        // A list stops at a number that doesn't end a clause.
        #expect(OwlCitations.find("On line 5, 2026 changed it.").map(\.lines) == [5...5])
        #expect(OwlCitations.find("Line 3, 100 items are read.").map(\.lines) == [3...3])
        #expect(OwlCitations.filter("Nothing cited here.", allowed: IndexSet()).changed == false)
    }

    @Test func ordinaryProseIsNeverCutOnlyFlagged() {
        // Selection 40–60; paragraphs (not list items) about other lines keep their words.
        let allowed = IndexSet(integersIn: 40...60)
        let text = "This uses L2 regularization on line 45.\n\nThe setup on line 2 matters too.\n\n\n    indented code"
        let f = OwlCitations.filter(text, allowed: allowed)
        #expect(f.text == "This uses L2 regularization on line 45.\n\nThe setup on line 2\(OwlCitations.flag) matters too.\n\n\n    indented code")
        #expect(f.dropped.isEmpty && f.flagged == [2...2])
        // Nothing out of range: the text is returned exactly.
        let clean = "\n  code\n\n\n\nLine 45 is fine.\n"
        #expect(OwlCitations.filter(clean, allowed: allowed).text == clean)
    }

    @Test func zeroBasedOrShiftedCitationsAreCaught() {
        // A 0-based "line 0", or a citation shifted one past the last line given.
        let f = OwlCitations.filter("- Line 0 is the front matter.\n- Line 19 is the title.\n- Line 1 opens it.",
                                    allowed: Self.lines1to18)
        #expect(f.text == "- Line 1 opens it.")
        #expect(f.dropped == [0...0, 19...19])
    }

    @Test func numberingCountsFrontMatterSoCitationsAreNotOffset() {
        // Line numbers sent are the file's own: front matter is line 1, not skipped.
        let text = "---\ntitle: Field notes\n---\n# Day one\nWe walked.\n"
        let s = OwlDocumentSnapshot(text: text, generation: 1, fileName: "n.md", language: "markdown")
        #expect(s.countedLines == 5)
        #expect(s.numbered(lines: 1, 5).components(separatedBy: "\n") == ["1| ---", "2| title: Field notes", "3| ---", "4| # Day one", "5| We walked."])
        let part = OwlChatContext.reviewPart(s, first: 4, last: 5)
        #expect(part.numbered == "4| # Day one\n5| We walked.")
        #expect(OwlCitations.lines(in: part.numbered) == IndexSet(integersIn: 4...5))
        let whole = OwlChatContext.build(s, scope: .wholeDocument, budget: 10_000)!
        #expect(whole.firstLine == 1 && whole.lastLine == 5 && !whole.truncated)
    }

    @Test(arguments: [(2_000, 400), (5_000, 600), (5_000, 3_000)])
    func planCoversEveryLineAtBigSizes(lines n: Int, budget: Int) {
        let text = (1...n).map { "line \($0) " + String(repeating: "t", count: 10 + $0 % 40) }.joined(separator: "\n")
        let s = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: (text as NSString).length / 2, length: 0))
        let plan = OwlChunkedReview.plan(s, budget: budget)
        #expect(plan.totalLines == n && plan.isComplete)
        #expect(plan.parts.first?.first == 1 && plan.parts.last?.last == n)
        #expect(plan.parts.allSatisfy { $0.fits && ($0.numbered as NSString).length <= budget })
        for (a, b) in zip(plan.parts, plan.parts.dropFirst()) { #expect(b.first > a.first && b.first <= a.last + 1) }
        #expect(OwlChunkedReview.label(plan) == String(localized: "Whole document (\(n) lines)"))
    }

    @Test func sectionNotesExportUnderTheAnswer() {
        let entry = OwlChatEntry(role: .owl, text: "One answer.",
                                 sections: [OwlChatSection(first: 1, last: 40, text: "Notes A"), OwlChatSection(first: 39, last: 80, text: "Notes B")])
        let md = OwlChatEntry.markdown([entry], fileName: "n.md")
        #expect(md.contains("**Cedric:** One answer.\n"))
        #expect(md.contains("<summary>Section notes (2)</summary>"))
        #expect(md.contains("**Lines 1–40:** Notes A") && md.contains("**Lines 39–80:** Notes B"))
        #expect(md.range(of: "One answer.")!.lowerBound < md.range(of: "Notes A")!.lowerBound)
    }
}
