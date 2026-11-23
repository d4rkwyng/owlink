import Foundation
import Testing
@testable import CedricCore

@Suite struct FoldLinesTests {
    // Lines: 0 "a {", 1 "  b {", 2 "    c", 3 "  }", 4 "}", 5 "d", 6 "" (empty last line).
    let text = "a {\n  b {\n    c\n  }\n}\nd\n" as NSString
    var index: LineIndex { LineIndex(text) }

    @Test func regionHiddenRange() throws {
        let r = try #require(FoldRegion(header: 0, last: 3).hiddenRange(in: index))
        #expect(text.substring(with: r) == "  b {\n    c\n  }\n")
        #expect(FoldRegion(header: 1, last: 1).hiddenRange(in: index) == nil)
        #expect(FoldRegion(header: 5, last: 9).hiddenRange(in: index) == nil)
        // A last line without a newline: to the end of the text.
        let short = "a\nb\nc" as NSString
        let all = try #require(FoldRegion(header: 0, last: 2).hiddenRange(in: LineIndex(short)))
        #expect(short.substring(with: all) == "b\nc")
    }

    @Test func headersAndHiddenLines() throws {
        let outer = try #require(FoldRegion(header: 0, last: 3).hiddenRange(in: index))
        let inner = try #require(FoldRegion(header: 1, last: 2).hiddenRange(in: index))
        let s = FoldState([inner, outer])
        #expect(s.headerLines(index) == [0, 1])
        #expect(s.folds(header: 0, index) == [outer])
        #expect(s.folds(header: 1, index) == [inner])
        #expect(s.folds(header: 4, index).isEmpty)
        #expect((0..<index.lineCount).filter { s.isLineHidden($0, index) } == [1, 2, 3])
        #expect(s.visibleLine(2, index) == 0)
        #expect(s.visibleLine(4, index) == 4)
        #expect(s.folds(startingAt: outer.location) == [outer])
        #expect(FoldState.lineCount(of: outer, index) == 3)
        #expect(FoldState.lineCount(of: inner, index) == 1)
        #expect(!FoldState().isLineHidden(1, index))
    }

    @Test func scannerRegionsMatchHiddenLines() throws {
        let scanner = FoldScanner(language: .swift, text: text, index: index)
        let regions = scanner.allRegions()
        #expect(regions.map { $0.header...$0.last } == [0...3, 1...2])
        let s = FoldState(regions.compactMap { $0.hiddenRange(in: index) })
        // Only lines 0, 4, 5 and the empty last line stay.
        #expect((0..<index.lineCount).filter { !s.isLineHidden($0, index) } == [0, 4, 5, 6])
        // The text itself is untouched by folding.
        #expect(text as String == "a {\n  b {\n    c\n  }\n}\nd\n")
    }
}
