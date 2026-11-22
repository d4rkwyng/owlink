import Foundation
import Testing
@testable import CedricCore

/// Ask Cedric's scope: the whole document by default
/// the model's context, and get_outline's counts for "how many" questions
/// about a file shown only in part.
@Suite struct OwlAskScopeTests {
    /// A games list: three systems, list items under each (one nested), a
    /// table, and a fenced block whose "- " lines aren't items.
    static let games: String = {
        var s = "Intro\n- loose item\n\n# Games\n\n## NES\n"
        for i in 1...5 { s += "- NES game \(i)\n" }
        s += "  - a note under game 5\n\n## SNES\n"
        for i in 1...3 { s += "1. SNES game \(i)\n" }
        s += "\n```\n- not an item\n| not | a row |\n```\n\n## Genesis\n\n| Title | Year |\n|---|---|\n| Sonic | 1991 |\n| Streets | 1991 |\n"
        return s
    }()
    func snap(_ text: String = Self.games, sel: NSRange = NSRange(location: 0, length: 0)) -> OwlDocumentSnapshot {
        OwlDocumentSnapshot(text: text, generation: 1, selection: sel, visible: NSRange(location: 0, length: 20),
                            fileName: "games.md", language: "markdown")
    }

    @Test func defaultIsWholeDocumentUnlessSelected() throws {
        #expect(OwlChatContext.defaultScope(for: snap(), budget: 5_000) == .wholeDocument)
        #expect(OwlChatContext.defaultScope(for: snap(), budget: 50) == .wholeDocument)
        // A selection still wins.
        #expect(OwlChatContext.defaultScope(for: snap(sel: NSRange(location: 0, length: 5)), budget: 5_000) == .selection)
        // The default always builds at the same budget.
        let big = String(repeating: "a line of text\n", count: 600)
        let s = snap(big)
        let scope = OwlChatContext.defaultScope(for: s, budget: 5_000)
        #expect(scope == .wholeDocument)
        let context = try #require(OwlChatContext.build(s, scope: scope, budget: 5_000))
        #expect(context.truncated && context.firstLine == 1)
        #expect(context.label == "Lines \(context.firstLine)–\(context.lastLine) of 600 (trimmed to fit)")
        #expect(context.firstLine <= s.lineNumber(at: s.selection.location) && context.lastLine >= s.lineNumber(at: s.selection.location))
    }

    @Test func sectionCountsListItemsNestedAndTableRowsOutsideCode() {
        let c = OwlTools.sectionCounts(snap())
        #expect(c.map { $0.heading?.title } == [nil, "Games", "NES", "SNES", "Genesis"])
        #expect(c.map(\.listItems) == [1, 0, 6, 3, 0])
        #expect(c.map(\.nestedItems) == [0, 0, 1, 0, 0])
        #expect(c.map(\.tableRows) == [0, 0, 0, 0, 2])
        #expect(c[0].first == 1 && c[0].last == 3)
        #expect(c[2].first == 6 && c[2].last == 13)
    }

    @Test func getOutlineGivesCountsAndTotalsFirst() {
        let out = OwlTools.run(OwlToolCall(name: "get_outline"), on: snap()).text
        let lines = out.components(separatedBy: "\n")
        #expect(lines.first == "Total in all 29 lines: 10 list items, 2 table rows")
        #expect(lines.contains("(before the first heading: 1 list item)"))
        #expect(lines.contains("6| ## NES [6 list items (1 nested)]"))
        #expect(lines.contains("14| ## SNES [3 list items]"))
        #expect(lines.contains { $0.hasSuffix("## Genesis [2 table rows]") })
        #expect(lines.contains("4| # Games"))
    }

    @Test func getOutlineTotalsSurviveTheOutputCap() {
        var s = ""
        for i in 1...80 { s += "## System \(i) with a fairly long heading title\n- game a\n- game b\n" }
        let out = OwlTools.run(OwlToolCall(name: "get_outline"), on: snap(s)).text
        #expect(out.hasPrefix("Total in all 240 lines: 160 list items, 0 table rows; more headings than listed"))
        #expect(out.hasSuffix("[… cut]"))
    }

    @Test func csvOutlineCountsDataRows() {
        let s = OwlDocumentSnapshot(text: "name,system\nMario,NES\nSonic,Genesis\n\n", generation: 1, fileName: "g.csv", language: "csv")
        #expect(OwlTools.run(OwlToolCall(name: "get_outline"), on: s).text == "2 data rows; header: name,system")
    }

    @Test func getLinesReportsTheLinesItShowed() {
        let r = OwlTools.run(OwlToolCall(name: "get_lines", arguments: .object(["start": .number(6), "end": .number(9)])), on: snap())
        #expect(r.lines == 6...9)
        // Capped output: only whole lines that arrived count.
        let long = String(repeating: String(repeating: "x", count: 100) + "\n", count: 100)
        let c = OwlTools.run(OwlToolCall(name: "get_lines", arguments: .object(["start": .number(1), "end": .number(100)])), on: snap(long))
        let shown = c.text.components(separatedBy: "\n").filter { $0.contains("| ") }.count
        #expect(c.lines.map { $0.count } ?? 0 <= shown && (c.lines?.count ?? 0) >= shown - 1)
        #expect(OwlTools.run(OwlToolCall(name: "get_outline"), on: snap()).lines == nil)
    }

    /// The coverage note is on for a question about the open document, and
    /// also when that is only doubtful. It is off for a pure sum and for
    /// an explicit translation whose source text is not in the file.
    @Test func coverageQuestionIsAboutTheDocument() {
        let s = snap()
        let yes = [
            "How many games per system?",
            "What is in the Genesis section?",
            "List the NES games",
            "Summarise this document",
            "Which lines mention Sonic?",
            "Find Sonic",
            "How many headings are there?",
            "What does this file say about Genesis?",
            "Any errors?",
            "What's on line 12?",
            "What's this about?",
            "Explain this.",
            // Not a sum, and not a translation: "how many" can be about the file.
            "How many feet are in a mile?",
            // Not one of the forms that suppress the note.
            "Check the weather tomorrow",
            // A definition or a who-wrote question about the open document.
            "Who wrote the first section?",
            "Define the selected term",
            "Define photosynthesis",
            "Who wrote Hamlet?",
            "What is the capital of France?",
        ]
        let no = [
            "What is 12 times 7?",
            "3+4*2",
            "Translate hello into French",
            "What is 2 plus 2?",
        ]
        for q in yes { #expect(OwlTools.coverageNoteApplies(q, snapshot: s), "\(q) keeps the coverage note") }
        for q in no { #expect(!OwlTools.coverageNoteApplies(q, snapshot: s), "\(q) is clearly unrelated") }
    }

    /// Cursor's cases: the file's own words need not be the question's.
    /// General knowledge keeps the note even when the subject is absent.
    /// A translation keeps it when its source text is in the file.
    @Test func coverageNoteStaysWhenTheWordingIsNotInTheFile() {
        let titles = """
        # Catalogue

        ## Platforms
        - title one
        - title two

        The list is titles and platforms.
        """
        #expect(!titles.localizedCaseInsensitiveContains("games"))
        #expect(!titles.localizedCaseInsensitiveContains("system"))
        #expect(OwlTools.coverageNoteApplies("How many games per system?", snapshot: snap(titles)))

        let players = "The cabinet supports two-player mode on the same screen.\n"
        #expect(!players.localizedCaseInsensitiveContains("multiplayer"))
        #expect(OwlTools.coverageNoteApplies("What does it say about multiplayer?", snapshot: snap(players)))

        let s = snap()
        #expect(OwlTools.coverageNoteApplies("What's this about?", snapshot: s))
        #expect(OwlTools.coverageNoteApplies("Explain this.", snapshot: s))

        let trip = "We spent a week in France and ate too much bread.\n"
        // "capital of" is not a suppression: the note stays with France in the file and without it.
        #expect(OwlTools.coverageNoteApplies("What is the capital of France?", snapshot: snap(trip)))
        #expect(OwlTools.coverageNoteApplies("What is the capital of France?", snapshot: s))
        // A pure sum still suppresses it.
        #expect(!OwlTools.coverageNoteApplies("What is 12 times 7?", snapshot: s))
        let hello = "She wrote hello on the board and left the room.\n"
        #expect(OwlTools.coverageNoteApplies("Translate hello into French", snapshot: snap(hello)))
        #expect(!OwlTools.coverageNoteApplies("Translate hello into French", snapshot: s))
    }
}
