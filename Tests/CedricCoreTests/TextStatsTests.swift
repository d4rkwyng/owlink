import Foundation
import Testing
@testable import CedricCore

@Suite struct TextStatsTests {
    func c(_ s: String, _ r: NSRange? = nil) -> TextCounts? {
        let ns = s as NSString
        return TextStats.count(ns, range: r ?? NSRange(location: 0, length: ns.length))
    }

    @Test func wordsLinesCharacters() {
        #expect(c("hello world\nsecond line") == TextCounts(words: 4, lines: 2, characters: 23))
        // A trailing newline doesn't start a counted line; an empty text is one line.
        #expect(c("a\nb\n") == TextCounts(words: 2, lines: 2, characters: 4))
        #expect(c("") == TextCounts(words: 0, lines: 1, characters: 0))
        // Punctuation splits words; "_" doesn't; non-ASCII letters are letters.
        #expect(c("don't snake_case école, 42")?.words == 5)
        // A surrogate pair is one character.
        #expect(c("a😀b")?.characters == 3)
    }

    @Test func selectionRangesAndTheLimit() {
        let t = "one two\nthree four\nfive"
        #expect(c(t, NSRange(location: 4, length: 9)) == TextCounts(words: 2, lines: 2, characters: 9))
        // Ranges past the end are clamped.
        #expect(c(t, NSRange(location: 19, length: 100)) == TextCounts(words: 1, lines: 1, characters: 4))
        let big = String(repeating: "word ", count: 10) as NSString
        #expect(TextStats.count(big, range: NSRange(location: 0, length: big.length), limit: 20) == nil)
        #expect(TextStats.count(big, range: NSRange(location: 0, length: 20), limit: 20)?.words == 4)
    }
}

@Suite struct WritingStatsTests {
    func c(_ s: String) -> TextCounts { TextStats.count(s as NSString, range: NSRange(location: 0, length: (s as NSString).length))! }

    @Test func cjkIdeographsAndKanaAreAWordEach() {
        // 7 Han/kana: one word each; the full stop is punctuation.
        #expect(c("日本語の文章です。").words == 8)
        #expect(c("我爱北京").words == 4)
        // Katakana with the prolonged sound mark: the mark lengthens, it isn't a word.
        #expect(c("コーヒー").words == 2)
        // Mixed with Latin: "Owlink" is one word, then two ideographs.
        #expect(c("Owlink日本").words == 3)
        // Hangul is written with spaces: words as in Latin.
        #expect(c("안녕하세요 세계").words == 2)
        #expect(c("日本").characters == 2)
    }

    @Test func emojiAreCharactersNotWords() {
        #expect(c("I 😀 you").words == 2)
        #expect(c("😀😀").words == 0)
        #expect(c("😀😀").characters == 2)
        // A ZWJ family is several scalars.
        #expect(c("👨‍👩‍👧").characters == 5)
        #expect(c("a😀b").words == 2)
        // Combining marks continue a word (e + ◌́).
        #expect(c("cafe\u{301} ok").words == 2)
    }

    @Test func crlfIsOneBreakAndOneCharacter() {
        #expect(c("one two\r\nthree\r\n") == TextCounts(words: 3, lines: 2, characters: 14))
        #expect(c("a\nb\n") == c("a\r\nb\r\n"))
        // A lone CR is an ordinary character, not a line break.
        #expect(c("a\rb") == TextCounts(words: 2, lines: 1, characters: 3))
    }

    @Test func markdownMarkersAreNotWords() {
        // Headings, emphasis, quotes, lists, rules, tables, checkboxes: only the words count.
        #expect(c("# Title\n\n**Bold** and _it_\n\n> quote\n\n- [ ] done\n\n___\n\n| a | b |\n|---|---|\n").words == 8)
        // A checked box's "x" is a letter: it counts (the one marker that does).
        #expect(c("- [x] done").words == 2)
        #expect(c("___").words == 0)
        #expect(c("snake_case _x_").words == 2)
        // Link targets and code count as written (documented: one scan, no parse).
        #expect(c("[Owlink](https://owlink.app)").words == 4)
        #expect(c("`let x = 1`").words == 3)
    }

    @Test func readingTimeAt238WordsPerMinute() {
        #expect(ReadingTime.wordsPerMinute == 238)
        #expect(ReadingTime.minutes(words: 0) == 0)
        #expect(ReadingTime.minutes(words: 1) == 1)
        #expect(ReadingTime.minutes(words: 238) == 1)
        #expect(ReadingTime.minutes(words: 600) == 3)    // 2.52 rounds to 3
        #expect(ReadingTime.minutes(words: 2380) == 10)
        #expect(c(String(repeating: "word ", count: 476)).readingMinutes == 2)
    }

    @Test func wordGoalParsingAndProgress() {
        #expect(WordGoal.parse("1000") == 1000)
        #expect(WordGoal.parse(" 1,500 ") == 1500)
        #expect(WordGoal.parse("2.000") == 2000)
        #expect(WordGoal.parse("0") == nil)
        #expect(WordGoal.parse("") == nil)
        #expect(WordGoal.parse("12a") == nil)
        #expect(WordGoal.parse("-5") == nil)
        #expect(WordGoal.progress(words: 250, goal: 1000) == 0.25)
        #expect(WordGoal.progress(words: 2000, goal: 1000) == 1)
        #expect(WordGoal.progress(words: 10, goal: 0) == 0)
        #expect(WordGoal.percent(words: 1120, goal: 1000) == 112)
        #expect(WordGoal.percent(words: 999, goal: 1000) == 99)
    }

    @Test func wordGoalClearsOnEmptyOrZero() {
        #expect(WordGoal.clears(""))
        #expect(WordGoal.clears(" 0 "))
        #expect(WordGoal.clears("000"))
        #expect(!WordGoal.clears("5"))
        #expect(!WordGoal.clears("abc"))
        #expect(!WordGoal.clears("-0"))
        #expect(!WordGoal.clears("10000001"))
    }

    @Test func fileWordGoalsSetMoveRemoveAndCap() {
        var list: [FileWordGoal] = []
        list = FileWordGoals.setting(500, for: "/a.md", in: list)
        list = FileWordGoals.setting(800, for: "/b.md", in: list)
        list = FileWordGoals.setting(900, for: "/a.md", in: list)
        #expect(list.map(\.path) == ["/b.md", "/a.md"])
        #expect(FileWordGoals.goal(for: "/a.md", in: list) == 900)
        list = FileWordGoals.setting(nil, for: "/b.md", in: list)
        #expect(FileWordGoals.goal(for: "/b.md", in: list) == nil)
        list = FileWordGoals.setting(0, for: "/a.md", in: list)
        #expect(list.isEmpty)
        for i in 0..<5 { list = FileWordGoals.setting(100 + i, for: "/\(i).md", in: list, limit: 3) }
        #expect(list.map(\.path) == ["/2.md", "/3.md", "/4.md"])
    }

    @Test func wordGoalsPersistInTheSessionNotTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        var untitled = SessionTab(untitledName: "Untitled", hasBuffer: true)
        untitled.wordGoal = 750
        untitled.writing = WritingModeState(typewriter: true, focus: false)
        let file = SessionTab(path: "/tmp/essay.md")
        let session = Session(windows: [SessionWindow(tabs: [untitled, file])],
                              wordGoals: FileWordGoals.setting(1200, for: "/tmp/essay.md", in: []))
        try store.save(session)
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back == session)
        #expect(back.windows[0].tabs[0].wordGoal == 750)
        #expect(back.windows[0].tabs[0].writing == WritingModeState(typewriter: true, focus: false))
        #expect(FileWordGoals.goal(for: "/tmp/essay.md", in: back.wordGoals ?? []) == 1200)
        // A session from before 0.4.0 (no keys) still loads, with no goals.
        let old = #"{"version":1,"windows":[{"tabs":[{"id":"\#(UUID().uuidString)","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0,"path":"/x.md"}],"selectedTab":0}],"untitledCounter":0}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("session.json"))
        let legacy = try #require(SessionStore(directory: dir).load())
        #expect(legacy.wordGoals == nil && legacy.windows[0].tabs[0].wordGoal == nil && legacy.windows[0].tabs[0].writing == nil)
    }
}
