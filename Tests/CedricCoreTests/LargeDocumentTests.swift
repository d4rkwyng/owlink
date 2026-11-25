import Foundation
import Testing
@testable import CedricCore

@Suite(.offPool) struct LargeDocumentTests {
    static func line(_ n: Int, _ c: Character = "A") -> String { String(repeating: c, count: n) }

    @Test func shortLinesAreNotLarge() {
        let text = (0..<2000).map { "line \($0) " + Self.line(80) }.joined(separator: "\n")
        #expect(LargeDocument.reason(for: LineIndex(text as NSString)) == nil)
    }

    @Test func oneLongLineIsLarge() {
        // Derek's kind of file: one base64-like line, no newline.
        let derek = Self.line(636_293)
        #expect(LargeDocument.reason(for: LineIndex(derek as NSString)) == .longLine)
        // Just over and just at the threshold, among short lines.
        let over = "a\n" + Self.line(LargeDocument.lineThreshold + 1) + "\nb\n"
        #expect(LargeDocument.reason(for: LineIndex(over as NSString)) == .longLine)
        let at = "a\n" + Self.line(LargeDocument.lineThreshold - 1) + "\nb\n"   // + "\n" = threshold
        #expect(LargeDocument.reason(for: LineIndex(at as NSString)) == nil)
    }

    @Test func sizeAloneIsLarge() {
        let row = Self.line(99) + "\n"
        let text = String(repeating: row, count: LargeDocument.sizeThreshold / 100 + 1)
        let index = LineIndex(text as NSString)
        #expect(index.longestLine == 100)
        #expect(LargeDocument.reason(for: index) == .size)
    }

    /// The setup decision is exactly `reason(for:)` and `needsChunks(_:)`:
    /// empty, short, at and one past each threshold, a long line in a
    /// short or size-large document, and size-large with short lines.
    @Test func setupDecisionMatchesReasonAndNeedsChunks() {
        let t = LargeDocument.lineThreshold, big = LargeDocument.sizeThreshold
        var texts = ["", "a", "a\nb\n", Self.line(t), Self.line(t + 1), Self.line(t - 1) + "\n", Self.line(t) + "\n",
                     "a\n" + Self.line(t - 1) + "\nb\n", "a\n" + Self.line(t + 1) + "\nb\n",
                     String(repeating: "x\n", count: t / 2 + 1), Self.line(636_293)]
        let row = Self.line(99) + "\n"
        let rows = String(repeating: row, count: big / 100)
        texts += [rows, rows + Self.line(big - rows.utf16.count), rows + Self.line(big - rows.utf16.count + 1),
                  rows + "a" + Self.line(t + 1), rows + Self.line(t)]
        var seen = Set<String>()
        for text in texts {
            let index = LineIndex(text as NSString)
            let d = LargeDocument.setupDecision(for: index)
            #expect(d.reason == LargeDocument.reason(for: index) && d.needsChunks == LargeDocument.needsChunks(index),
                    "\(index.length) units, longest \(index.longestLine)")
            seen.insert("\(d.reason?.rawValue ?? "none") \(d.needsChunks)")
        }
        #expect(seen == ["none false", "longLine true", "size false", "size true"], "\(seen)")
    }

    @Test func anEditCanMakeItLarge() {
        // A paste of a long line into a small document: only the edited
        // lines are looked at.
        var index = LineIndex("one\ntwo\n" as NSString)
        let after = "one\n" + Self.line(30_000) + "two\n" as NSString
        let first = index.replace(NSRange(location: 4, length: 0), newLength: 30_000, in: after)
        #expect(LargeDocument.reason(afterEditOf: first..<(first + 1), in: index) == .longLine)
        #expect(LargeDocument.reason(afterEditOf: 0..<1, in: index) == nil)
    }

    @Test func longestLineAndLineLength() {
        let index = LineIndex("ab\ncdef\n\ng" as NSString)
        #expect(index.longestLine == 5)
        #expect(index.lineLength(0) == 3)
        #expect(index.lineLength(3) == 1)
    }

    @Test func chunksTileTheLine() {
        let text = (Self.line(10_000) + "\n") as NSString
        let line = NSRange(location: 0, length: text.length)
        let chunks = LargeDocument.chunks(of: line, in: text, limit: 2048)
        #expect(chunks.count == 5)
        #expect(chunks.first?.location == 0)
        #expect(chunks.last.map(NSMaxRange) == text.length)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        // Every offset maps to the chunk that holds it.
        for off in [0, 1, 2047, 2048, 4095, 4096, 9_999, 10_000] {
            let c = LargeDocument.chunk(containing: off, line: line, in: text, limit: 2048)
            #expect(NSLocationInRange(off, c))
            #expect(chunks.contains(c))
        }
        // A short line is one chunk.
        let short = NSRange(location: 0, length: 100)
        #expect(LargeDocument.chunks(of: short, in: text, limit: 2048) == [short])
    }

    @Test func chunksNeverSplitAComposedCharacter() {
        // An emoji (surrogate pair) straddling the nominal boundary at 2048.
        let s = Self.line(2047) + "😀" + Self.line(3000) as NSString
        let line = NSRange(location: 0, length: s.length)
        let chunks = LargeDocument.chunks(of: line, in: s, limit: 2048)
        #expect(chunks[1].location == 2047)   // moved back to the pair's start
        for c in chunks.dropFirst() { #expect(!CFStringIsSurrogateLowCharacter(s.character(at: c.location))) }
        #expect(NSLocationInRange(2048, LargeDocument.chunk(containing: 2048, line: line, in: s, limit: 2048)))
        #expect(LargeDocument.chunk(containing: 2046, line: line, in: s, limit: 2048).location == 0)
    }

    @Test func chunksStartAtTheirLine() {
        let s = "short\n" + Self.line(5000) + "\nend" as NSString
        let line = NSRange(location: 6, length: 5001)
        let chunks = LargeDocument.chunks(of: line, in: s, limit: 2048)
        #expect(chunks.map(\.location) == [6, 6 + 2048, 6 + 4096])
        #expect(NSMaxRange(chunks.last!) == 6 + 5001)
    }

    @Test func owlWindowStaysCappedOnAHugeLine() {
        // The owl's rules see the window only, never the whole document.
        let text = Self.line(636_293) as NSString
        let w = OwlContextWindow(text: text, visible: NSRange(location: 300_000, length: 4000), selection: nil,
                                 fileName: "big-guide.txt", language: "plain", documentID: UUID(), editGeneration: 1)
        #expect((w.context.text as NSString).length <= OwlContextWindow.byteCap)
        #expect(!w.isWholeDocument)
    }
}
