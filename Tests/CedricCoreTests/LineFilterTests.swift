import Foundation
import Testing
@testable import CedricCore

@Suite struct LineFilterTests {
    func run(_ text: String, _ pattern: String, regex: Bool = false, caseSensitive: Bool = true, keep: Bool) throws -> String? {
        try LineFilter.filter(text as NSString, pattern: pattern, regex: regex, caseSensitive: caseSensitive, keepMatching: keep)?
            .edit.applied(to: text)
    }

    @Test func deleteAndKeepPlain() throws {
        let t = "error: a\ninfo: b\nERROR: c\ninfo: d\n"
        #expect(try run(t, "error", keep: false) == "info: b\nERROR: c\ninfo: d\n")
        #expect(try run(t, "error", caseSensitive: false, keep: false) == "info: b\ninfo: d\n")
        #expect(try run(t, "info", keep: true) == "info: b\ninfo: d\n")
        // Nothing to remove: nil (the command beeps).
        #expect(try run(t, "info", keep: false).map { _ in true } == true)
        #expect(try run(t, "zzz", keep: false) == nil)
        #expect(try run(t, ":", keep: true) == nil)
    }

    @Test func regexAnchorsPerLine() throws {
        let t = "  a1\nb2\n  c3\nd\n"
        #expect(try run(t, #"^\s+"#, regex: true, keep: false) == "b2\nd\n")
        #expect(try run(t, #"\d$"#, regex: true, keep: true) == "  a1\nb2\n  c3\n")
        #expect(throws: LineFilter.FilterError.invalidPattern) { try run(t, "(", regex: true, keep: true) }
        #expect(throws: LineFilter.FilterError.emptyPattern) { try run(t, "", keep: true) }
    }

    @Test func caseInsensitiveUnicodeFilterPreservesSurvivingLines() throws {
        let text = "😀 keep\nDROP\né keep\ndrop"
        let result = try #require(try LineFilter.filter(text as NSString, pattern: "^drop$", regex: true,
                                                        caseSensitive: false, keepMatching: false))
        #expect(result.removed == [1, 3])
        #expect(result.edit.applied(to: text) == "😀 keep\né keep")
    }

    @Test func lastLineWithoutNewline() throws {
        #expect(try run("a\nb\nx", "x", keep: false) == "a\nb")
        #expect(try run("x\na", "x", keep: false) == "a")
        #expect(try run("a\nx\nx", "x", keep: false) == "a")
        #expect(try run("x\nx", "x", keep: false) == "")
        #expect(try run("a\nx\nb", "x", keep: false) == "a\nb")
    }

    @Test func editSpansOnlyTheRemovedLines() throws {
        let t = "keep\nkeep\ndrop\nkeep\ndrop\nkeep\n" as NSString
        let r = try #require(try LineFilter.filter(t, pattern: "drop", regex: false, caseSensitive: true, keepMatching: false))
        #expect(r.edit.range == NSRange(location: 10, length: 15))
        #expect(r.edit.replacement == "keep\n")
        #expect(r.removed == [2, 4])
        #expect(r.edit.selection == NSRange(location: 10, length: 0))
    }

    @Test func copyAndDeleteGivenLines() {
        let t = "l0\nl1\nl2\nl3" as NSString
        #expect(LineFilter.copying(lines: [3, 1], in: t) == "l1\nl3\n")
        #expect(LineFilter.copying(lines: [9], in: t) == "")
        let r = LineFilter.removing(in: t) { line, _ in [1, 3].contains(line) }
        #expect(r?.edit.applied(to: t as String) == "l0\nl2")
        #expect(r?.removed == [1, 3])
    }

    @Test func renumberFollowsRemovals() {
        let removed = [2, 4, 5]
        #expect(LineFilter.renumber(0, removed: removed) == 0)
        #expect(LineFilter.renumber(2, removed: removed) == nil)
        #expect(LineFilter.renumber(3, removed: removed) == 2)
        #expect(LineFilter.renumber(6, removed: removed) == 3)
    }

    @Test func cancelledFilterThrows() async {
        let text = String(repeating: "line\n", count: 50_000) as NSString
        let task = Task.detached { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try LineFilter.filter(text, pattern: "line", regex: false, caseSensitive: true, keepMatching: false); return false }
            catch is CancellationError { return true } catch { return false }
        }
        task.cancel()
        #expect(await task.value)
    }
}
