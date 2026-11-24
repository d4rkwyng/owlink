import Foundation
import Testing
@testable import CedricCore

@Suite struct CommandMatcherTests {
    typealias C = CommandMatcher.Candidate

    static let menu: [C] = [
        C(id: "File › Save", title: "Save", path: "File"),
        C(id: "File › Save As…", title: "Save As…", path: "File"),
        C(id: "File › Page Setup…", title: "Page Setup…", path: "File"),
        C(id: "Format › Markdown › Bold", title: "Bold", path: "Format › Markdown"),
        C(id: "View › Folding › Fold All", title: "Fold All", path: "View › Folding"),
        C(id: "Format › Language › Swift", title: "Swift", path: "Format › Language"),
        C(id: "Edit › Text Tools › Uppercase", title: "Uppercase", path: "Edit › Text Tools"),
        C(id: "Edit › Text Tools › Lowercase", title: "Lowercase", path: "Edit › Text Tools"),
        C(id: "View › Next Difference", title: "Next Difference", path: "View", enabled: false),
    ]

    func titles(_ q: String, recent: [String] = [], _ list: [C] = menu) -> [String] {
        CommandMatcher.rank(list, query: q, recent: recent).map { list[$0].title }
    }

    @Test func subsequenceIgnoringCaseAndSpaces() {
        let bold = Self.menu[3]
        #expect(CommandMatcher.score("bold", bold) != nil)
        #expect(CommandMatcher.score("BLD", bold) != nil)
        #expect(CommandMatcher.score("md bold", bold) != nil) // through the path
        #expect(CommandMatcher.score("dlob", bold) == nil) // order matters
        #expect(CommandMatcher.score("boldx", bold) == nil)
        #expect(CommandMatcher.score("", bold) == 0)
        #expect(CommandMatcher.score("   ", bold) == 0)
    }

    @Test func diacriticsAndWidthFold() {
        let c = C(id: "x", title: "Résumé Ｗide", path: "")
        #expect(CommandMatcher.score("resume", c) != nil)
        #expect(CommandMatcher.score("RESUMEW", c) != nil)
    }

    @Test func titleMatchBeatsPathOnlyMatch() {
        // "save" is in File › Save's title; the other two only reach it through letters spread over the path.
        let list = [C(id: "a", title: "Show Avatar Very Early", path: "View"), C(id: "b", title: "Save", path: "File")]
        #expect(titles("save", list) == ["Save", "Show Avatar Very Early"])
        let pathOnly = [C(id: "p", title: "Swift", path: "Format › Language"), C(id: "t", title: "Language Swap", path: "X")]
        // "lang" is a title match only for the second.
        #expect(titles("lang", pathOnly) == ["Language Swap", "Swift"])
    }

    @Test func wordStartsAndRunsScoreHigher() {
        // "fa": the F and A of Fold All (two word starts) over the F and a of "Format".
        let list = [C(id: "1", title: "Format Table", path: ""), C(id: "2", title: "Fold All", path: "")]
        #expect(titles("fa", list) == ["Fold All", "Format Table"])
        // A prefix beats letters scattered later in the title.
        let pre = [C(id: "1", title: "Unsaved Changes", path: ""), C(id: "2", title: "Save", path: "")]
        #expect(titles("sav", pre).first == "Save")
        // camelCase steps count as word starts.
        let camel = [C(id: "1", title: "xmlformat", path: ""), C(id: "2", title: "xmlFormat", path: "")]
        #expect(titles("xf", camel).first == "xmlFormat")
    }

    @Test func aRunBeatsScatteredWordStarts() {
        // From the app's menu: "case" should find the case tools before an acronym-ish scatter.
        let list = [C(id: "1", title: "Cedric AI Settings…", path: "View"), C(id: "2", title: "UPPERCASE", path: "Edit › Text Tools"),
                    C(id: "3", title: "Title Case", path: "Edit › Text Tools")]
        #expect(titles("case", list) == ["Title Case", "UPPERCASE", "Cedric AI Settings…"])
    }

    @Test func bestAlignmentNotGreedy() {
        // Greedy left-to-right takes the first "a" of "Paste and Match"; the best alignment uses the word start.
        let c = C(id: "1", title: "Paste and Match Style", path: "")
        let greedy = CommandMatcher.score("pm", c)!
        let other = C(id: "2", title: "Pxxxxxm", path: "")
        #expect(greedy > CommandMatcher.score("pm", other)!)
    }

    @Test func emptyQueryRecentFirstThenMenuOrder() {
        let r = titles("", recent: ["Edit › Text Tools › Lowercase", "File › Save"])
        #expect(Array(r.prefix(2)) == ["Lowercase", "Save"])
        #expect(Array(r.dropFirst(2)) == ["Save As…", "Page Setup…", "Bold", "Fold All", "Swift", "Uppercase", "Next Difference"])
        #expect(r.count == Self.menu.count)
    }

    @Test func recentMatchesComeFirst() {
        // "case": Uppercase and Lowercase score the same; Lowercase was used recently, so it is first.
        #expect(titles("case") == ["Uppercase", "Lowercase"])
        #expect(titles("case", recent: ["Edit › Text Tools › Lowercase"]) == ["Lowercase", "Uppercase"])
        // A recent command that doesn't match isn't shown.
        #expect(titles("bold", recent: ["File › Save"]) == ["Bold"])
    }

    @Test func disabledKeptButAfterEnabledOnATie() {
        let list = [C(id: "1", title: "Next Thing", path: "", enabled: false), C(id: "2", title: "Next Thing", path: "", enabled: true)]
        let r = CommandMatcher.rank(list, query: "next", recent: [])
        #expect(r == [1, 0])
        #expect(titles("diff").contains("Next Difference"))
    }

    @Test func indexRanksTheSameAsTheConvenience() {
        let index = CommandIndex(Self.menu)
        for q in ["", "s", "sa", "fold", "md b", "tt", "zzz"] {
            #expect(index.rank(query: q) == CommandMatcher.rank(Self.menu, query: q), "\(q)")
        }
        #expect(index.rank(query: "zzz").isEmpty)
        let recent = ["View › Folding › Fold All", "nope", "File › Save"]
        #expect(CommandIndex.emptyQueryOrder(Self.menu, recent: recent) == index.rank(query: "", recent: recent))
        #expect(CommandIndex.emptyQueryOrder(Self.menu, recent: recent).prefix(2) == [4, 0])
    }

    @Test func recentsNewestFirstNoRepeatsCapped() {
        var r = CommandRecents()
        for id in ["a", "b", "c", "a", "d", "e", "f"] { r.note(id) }
        #expect(r.ids == ["f", "e", "d", "a", "c"])
        #expect(r.ids.count == CommandRecents.limit)
        #expect(CommandRecents(["1", "2", "3", "4", "5", "6"]).ids.count == 5)
    }

    @Test func rankingFourHundredItemsIsFast() {
        let list = (0..<400).map { C(id: "\($0)", title: "Command number \($0) Something", path: "Menu \($0 % 9) › Submenu") }
        // The palette's first keystroke: prepare the index, then rank. A release
        // build takes well under a millisecond, a debug build a few. Best of 5
        // in this thread's CPU time, scaled by how slow the machine is right
        // now (see `Timing`), with a wide wall-clock bound against a blow-up.
        let queries = ["c", "co", "com", "cmd 12", "sub 3"]
        var k = 0
        let r = Timing.best(of: queries.count) {
            let q = queries[k]
            k += 1
            let index = CommandIndex(list)
            #expect(!index.rank(query: q).isEmpty, "\(q)")
        }
        #expect(r.scaled < 0.15, "\(r.description)")
        #expect(r.wall < 3, "\(r.description)")
    }
}
