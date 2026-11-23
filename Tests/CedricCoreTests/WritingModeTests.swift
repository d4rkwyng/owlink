import Foundation
import Testing
@testable import CedricCore

@Suite struct TypewriterTests {
    @Test func caretLineGoesToTheMiddle() {
        // 600 pt visible, caret line's middle at 1000: the top goes to 700.
        #expect(Typewriter.scrollTarget(caretMidY: 1000, visibleHeight: 600, currentY: 0, documentHeight: 5000, bottomInset: 290) == 700)
        // Already there (within half a point): no scroll.
        #expect(Typewriter.scrollTarget(caretMidY: 1000, visibleHeight: 600, currentY: 700.3, documentHeight: 5000, bottomInset: 290) == nil)
        // Near the top: can't scroll above 0.
        #expect(Typewriter.scrollTarget(caretMidY: 100, visibleHeight: 600, currentY: 40, documentHeight: 5000, bottomInset: 290) == 0)
        #expect(Typewriter.scrollTarget(caretMidY: 100, visibleHeight: 600, currentY: 0, documentHeight: 5000, bottomInset: 290) == nil)
    }

    @Test func theBottomInsetLetsTheLastLineReachTheMiddle() {
        let inset = Typewriter.bottomInset(visibleHeight: 600, lineHeight: 20)
        #expect(inset == 290)
        // The last line (middle at 4990 of a 5000 pt text) can still be centred.
        #expect(Typewriter.scrollTarget(caretMidY: 4990, visibleHeight: 600, currentY: 0, documentHeight: 5000, bottomInset: inset) == 4690)
        // Without the inset it would stop short (only to the bottom of the text).
        #expect(Typewriter.scrollTarget(caretMidY: 4990, visibleHeight: 600, currentY: 0, documentHeight: 5000, bottomInset: 0) == 4400)
        // A short text: nothing to scroll.
        #expect(Typewriter.scrollTarget(caretMidY: 10, visibleHeight: 600, currentY: 0, documentHeight: 40, bottomInset: inset) == nil)
        #expect(Typewriter.bottomInset(visibleHeight: 10, lineHeight: 20) == 0)
    }

    @Test func oneScrollPerKeystroke() {
        // Typing on the same line: the caret's middle stays put, so after the first no scroll.
        var y = 0.0, scrolls = 0
        for _ in 0..<20 {
            if let t = Typewriter.scrollTarget(caretMidY: 1210, visibleHeight: 600, currentY: y, documentHeight: 5000, bottomInset: 290) {
                y = t
                scrolls += 1
            }
        }
        #expect(scrolls == 1 && y == 910)
        // Each Return moves the line down by one line height: one scroll each.
        scrolls = 0
        for line in 1...5 {
            if let t = Typewriter.scrollTarget(caretMidY: 1210 + Double(line) * 18, visibleHeight: 600, currentY: y,
                                               documentHeight: 5000 + Double(line) * 18, bottomInset: 290) {
                y = t
                scrolls += 1
            }
        }
        #expect(scrolls == 5 && y == 1000)
    }
}

@Suite struct FocusRangeTests {
    let text = "# Title\n\nFirst paragraph line one.\nLine two of it.\n\nSecond one. Dr. Smith said 3.5 is fine! Is it?\n\n\nLast" as NSString

    func sub(_ r: NSRange) -> String { text.substring(with: r) }
    func at(_ s: String, plus: Int = 0) -> Int { text.range(of: s).location + plus }

    @Test func paragraphIsTheLinesBetweenBlankLines() {
        #expect(sub(FocusRange.paragraph(in: text, caret: at("paragraph"))) == "First paragraph line one.\nLine two of it.")
        #expect(sub(FocusRange.paragraph(in: text, caret: at("two"))) == "First paragraph line one.\nLine two of it.")
        // The caret at a paragraph's very end (before its newline).
        #expect(sub(FocusRange.paragraph(in: text, caret: at("of it.", plus: 6))) == "First paragraph line one.\nLine two of it.")
        #expect(sub(FocusRange.paragraph(in: text, caret: 0)) == "# Title")
        #expect(sub(FocusRange.paragraph(in: text, caret: text.length)) == "Last")
        // On a blank line: that (empty) line, so everything else dims.
        let blank = FocusRange.paragraph(in: text, caret: at("\n\nFirst", plus: 1))
        #expect(blank.length == 0)
        // Whitespace-only lines count as blank.
        let ws = "a\n  \t\nb" as NSString
        #expect(ws.substring(with: FocusRange.paragraph(in: ws, caret: 6)) == "b")
        // CRLF text: the CR stays out of the range end.
        let crlf = "one\r\ntwo\r\n\r\nthree" as NSString
        #expect(crlf.substring(with: FocusRange.paragraph(in: crlf, caret: 1)) == "one\r\ntwo")
        #expect(crlf.substring(with: FocusRange.paragraph(in: crlf, caret: crlf.length)) == "three")
        #expect(FocusRange.paragraph(in: "" as NSString, caret: 0) == NSRange(location: 0, length: 0))
    }

    @Test func sentenceUsesTheNaturalLanguageTokenizer() {
        #expect(sub(FocusRange.sentence(in: text, caret: at("Second"))) == "Second one.")
        // "Dr." and "3.5" don't end a sentence.
        #expect(sub(FocusRange.sentence(in: text, caret: at("Smith"))) == "Dr. Smith said 3.5 is fine!")
        #expect(sub(FocusRange.sentence(in: text, caret: at("fine"))) == "Dr. Smith said 3.5 is fine!")
        // Just after the "!": still that sentence; past the space: the next.
        #expect(sub(FocusRange.sentence(in: text, caret: at("fine!", plus: 5))) == "Dr. Smith said 3.5 is fine!")
        #expect(sub(FocusRange.sentence(in: text, caret: at("Is it"))) == "Is it?")
        // Sentences don't cross paragraphs: the last line of one paragraph.
        #expect(sub(FocusRange.sentence(in: text, caret: at("two of"))) == "Line two of it.")
        // Typing at the end of an unfinished sentence.
        let typing = "Done here. Now I am typ" as NSString
        #expect(typing.substring(with: FocusRange.sentence(in: typing, caret: typing.length)) == "Now I am typ")
        // Range helper picks the unit.
        #expect(FocusRange.range(.paragraph, in: text, caret: at("Smith")) == FocusRange.paragraph(in: text, caret: at("Smith")))
        #expect(FocusRange.range(.sentence, in: text, caret: at("Smith")) == FocusRange.sentence(in: text, caret: at("Smith")))
    }

    @Test func dimmedIsTheVisibleTextOutsideTheFocus() {
        #expect(FocusRange.dimmed(visible: NSRange(location: 0, length: 100), focus: NSRange(location: 40, length: 10))
                == [NSRange(location: 0, length: 40), NSRange(location: 50, length: 50)])
        // Focus above the visible text: all of it dims, as one range.
        #expect(FocusRange.dimmed(visible: NSRange(location: 200, length: 100), focus: NSRange(location: 40, length: 10))
                == [NSRange(location: 200, length: 100)])
        // Focus covering it all: nothing dims.
        #expect(FocusRange.dimmed(visible: NSRange(location: 10, length: 20), focus: NSRange(location: 0, length: 100)).isEmpty)
    }

    @Test func aHugeLineIsScannedOnlyNearTheCaret() {
        let big = String(repeating: "word ", count: 200_000) as NSString   // one 1 M-character paragraph
        // Best of 5 in this thread's CPU time, scaled by how slow the machine
        // is right now (see `Timing`), with a wide wall-clock bound against a
        // blow-up. The length check below is the bound that holds on any machine.
        var r = NSRange()
        let time = Timing.best(of: 5) { r = FocusRange.paragraph(in: big, caret: 500_000) }
        #expect(time.scaled < 0.05, "best of 5: \(time.description)")
        #expect(time.wall < 2, "best of 5: \(time.description)")
        #expect(r.length <= 3 * FocusRange.scanLimit)
        #expect(NSLocationInRange(500_000, r))
        // Typing on in the same paragraph: the clipped window stays put
        // (on a grid), so Focus has nothing to redo for most keys.
        #expect(FocusRange.paragraph(in: big, caret: 500_001) == r)
        #expect(FocusRange.paragraph(in: big, caret: 500_000 + FocusRange.scanLimit).location > r.location)
    }
}
