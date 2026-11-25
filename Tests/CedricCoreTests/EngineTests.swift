import Foundation
import Testing
@testable import CedricCore

@Suite struct LineIndexTests {
    @Test func buildsStarts() {
        let idx = LineIndex("ab\ncd\n\nlast" as NSString)
        #expect(idx.starts == [0, 3, 6, 7])
        #expect(idx.lineCount == 4)
        #expect(idx.line(containing: 0) == 0)
        #expect(idx.line(containing: 4) == 1)
        #expect(idx.line(containing: 11) == 3)
        #expect(idx.contentRange(ofLine: 1) == NSRange(location: 3, length: 2))
        #expect(idx.contentRange(ofLine: 2) == NSRange(location: 6, length: 0))
    }

    @Test func emptyDocumentHasOneLine() {
        let idx = LineIndex("" as NSString)
        #expect(idx.lineCount == 1)
        #expect(idx.contentRange(ofLine: 0) == NSRange(location: 0, length: 0))
    }

    /// Random edits: the incremental index always equals a fresh one.
    @Test(.offPool) func incrementalMatchesRebuild() {
        var rng = SystemRandomNumberGenerator()
        let text = NSMutableString(string: "one\ntwo\nthree\n\nfour five\nsix")
        var idx = LineIndex(text)
        let pieces = ["", "x", "\n", "ab\ncd", "\n\n", "long line here", "\nz\n"]
        for _ in 0..<500 {
            let loc = Int.random(in: 0...text.length, using: &rng)
            let len = Int.random(in: 0...min(6, text.length - loc), using: &rng)
            let piece = pieces.randomElement(using: &rng)!
            text.replaceCharacters(in: NSRange(location: loc, length: len), with: piece)
            idx.replace(NSRange(location: loc, length: len), newLength: (piece as NSString).length, in: text)
            let fresh = LineIndex(text)
            #expect(idx.starts == fresh.starts)
            #expect(idx.length == fresh.length)
            if idx.starts != fresh.starts { break }
        }
    }

    /// The scratch buffer is sized to the range: empty ranges report
    /// nothing, and every range (inside one chunk, across chunk edges,
    /// at the end) reports the newlines a character walk finds.
    @Test func scanNewlinesOverAnyRange() {
        let s = String(repeating: "ab\ncd\n\n", count: 30_000) + "é\n😀x"
        let text = s as NSString
        let units = Array(s.utf16)
        let expected: (NSRange) -> [Int] = { r in (r.location..<(r.location + r.length)).filter { units[$0] == 10 }.map { $0 + 1 } }
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 5, length: 0), NSRange(location: text.length, length: 0),
                      NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 3, length: 3),
                      NSRange(location: 65_530, length: 12), NSRange(location: 1, length: 65_536), NSRange(location: 0, length: 65_537),
                      NSRange(location: 7, length: 131_100), NSRange(location: text.length - 4, length: 4),
                      NSRange(location: 0, length: text.length)]
        for r in ranges {
            var got: [Int] = []
            LineIndex.scanNewlines(text, in: r) { got.append($0) }
            #expect(got == expected(r), "range \(r)")
        }
    }
}


@Suite struct HighlightEngineTests {
    @Test func absoluteOffsetsForRequestedLines() {
        let text = "let a = 1\n// c\nvar b" as NSString
        let idx = LineIndex(text)
        let engine = HighlightEngine(language: .swift)
        let t = engine.tokens(forLines: 1..<3, in: text, index: idx)
        #expect(t.map { text.substring(with: NSRange(location: $0.start, length: $0.length)) } == ["// c", "var"])
    }

    @Test func stateCarriedFromLinesAboveTheViewport() {
        let text = "/* open\nstill\nclosed */ let x" as NSString
        let idx = LineIndex(text)
        let engine = HighlightEngine(language: .swift)
        let t = engine.tokens(forLines: 2..<3, in: text, index: idx)
        #expect(t.first?.kind == .comment)
        #expect(t.last?.kind == .keyword)
    }

    @Test func invalidationAfterEditReTokenizes() {
        let text = NSMutableString(string: "let a\nlet b\nlet c")
        var idx = LineIndex(text)
        let engine = HighlightEngine(language: .swift)
        _ = engine.tokens(forLines: 0..<3, in: text, index: idx)
        #expect(engine.validStateCount == 3)
        // Open a block comment on line 0: lines 1–2 become comment.
        text.insert("/* ", at: 0)
        let line = idx.replace(NSRange(location: 0, length: 0), newLength: 3, in: text)
        engine.invalidate(fromLine: line)
        #expect(engine.validStateCount == 1)
        let t = engine.tokens(forLines: 2..<3, in: text, index: idx)
        #expect(t.map(\.kind) == [.comment])
    }

    @Test func statelessLanguagesNeverScanAbove() {
        let text = String(repeating: "{\"k\": 1}\n", count: 1000) as NSString
        let idx = LineIndex(text)
        let engine = HighlightEngine(language: .json)
        let t = engine.tokens(forLines: 990..<991, in: text, index: idx)
        #expect(t.map(\.kind) == [.key, .number])
        #expect(engine.validStateCount == 1)
    }

    /// A 10 MB JSON file: colouring a screenful at the end must be fast
    /// (no full-file scan). Generous bound; the app's perf numbers are in perf.md.
    @Test(.offPool) func bigJSONViewportIsFast() {
        var s = "[\n"
        let row = "  {\"id\": 123456, \"name\": \"Cedric the editor\", \"tags\": [\"a\", \"b\"], \"ok\": true},\n"
        while s.utf8.count < 10_000_000 { s += row }
        s += "  {}\n]\n"
        let text = s as NSString
        let idx = LineIndex(text)
        let engine = HighlightEngine(language: .json)
        // Best of 5 in this thread's CPU time, scaled by how slow the machine
        // is right now (see `Timing`): the wall clock also counts waiting for
        // a core, and a slow runner slows every try. A full-file scan of 10 MB
        // is far slower than 50 ms on every try. The wall clock keeps a wide
        // bound against a blow-up.
        let r = Timing.best(of: 5) {
            let t = engine.tokens(forLines: (idx.lineCount - 60)..<idx.lineCount, in: text, index: idx)
            #expect(!t.isEmpty)
        }
        #expect(r.scaled < 0.05, "best of 5: \(r.description)")
        #expect(r.wall < 2, "best of 5: \(r.description)")
    }
}
