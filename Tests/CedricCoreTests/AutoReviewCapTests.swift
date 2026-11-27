import Foundation
import Testing
@testable import CedricCore

/// The auto-review cap: over 100 KB of UTF-8 or over 2,000 lines, Cedric
/// does nothing on his own. Separate from large mode (`LargeDocument`).
@Suite struct AutoReviewCapTests {
    /// `lines` lines of `width` ASCII characters each, newline-terminated.
    func text(lines: Int, width: Int) -> String {
        String(repeating: String(repeating: "x", count: width) + "\n", count: lines)
    }

    @Test func thresholdsAreStaticAndDistinctFromLargeMode() {
        #expect(AutoReviewCap.maxUTF8Bytes == 100_000)
        #expect(AutoReviewCap.maxLines == 2_000)
        // Far below large mode, which is about the editor keeping up.
        #expect(AutoReviewCap.maxUTF8Bytes < LargeDocument.sizeThreshold / 100)
        #expect(LargeDocument.sizeThreshold == 25_000_000)
        #expect(LargeDocument.lineThreshold == 20_000)
    }

    @Test func byteThresholdBelowAtAbove() {
        #expect(AutoReviewCap.reason(utf8Bytes: 99_999, lines: 10) == nil)
        #expect(AutoReviewCap.reason(utf8Bytes: 100_000, lines: 10) == nil)
        #expect(AutoReviewCap.reason(utf8Bytes: 100_001, lines: 10) == .bytes)
        // From text: 1,000 lines of 99 characters + newline is exactly 100,000 bytes.
        let at = text(lines: 1_000, width: 99)
        #expect(AutoReviewCap.size(of: at) == .init(utf8Bytes: 100_000, lines: 1_000))
        #expect(AutoReviewCap.reason(for: at) == nil)
        #expect(AutoReviewCap.reason(for: at + "x") == .bytes)
        #expect(AutoReviewCap.reason(for: String(at.dropLast())) == nil)
    }

    @Test func lineThresholdBelowAtAbove() {
        #expect(AutoReviewCap.reason(utf8Bytes: 10_000, lines: 1_999) == nil)
        #expect(AutoReviewCap.reason(utf8Bytes: 10_000, lines: 2_000) == nil)
        #expect(AutoReviewCap.reason(utf8Bytes: 10_000, lines: 2_001) == .lines)
        let at = text(lines: 2_000, width: 3)          // 8,000 bytes
        #expect(AutoReviewCap.size(of: at).lines == 2_000)
        #expect(AutoReviewCap.reason(for: at) == nil)
        #expect(AutoReviewCap.reason(for: at + "x") == .lines)            // a 2,001st line
        #expect(AutoReviewCap.reason(for: text(lines: 1_999, width: 3)) == nil)
    }

    @Test func eitherThresholdAloneCaps() {
        // Dense: 90 KB in 5,000 short lines.
        let dense = text(lines: 5_000, width: 17)
        #expect(AutoReviewCap.size(of: dense).utf8Bytes == 90_000)
        #expect(AutoReviewCap.reason(for: dense) == .lines)
        // Wide: 150 KB in 400 long lines.
        let wide = text(lines: 400, width: 374)
        #expect(AutoReviewCap.size(of: wide).utf8Bytes == 150_000)
        #expect(AutoReviewCap.reason(for: wide) == .bytes)
        // Derek's log: 730 KB, 6,132 lines of at most 255 characters.
        #expect(AutoReviewCap.reason(utf8Bytes: 730_000, lines: 6_132) != nil)
        // Ordinary files stay under.
        #expect(AutoReviewCap.reason(for: text(lines: 400, width: 60)) == nil)
    }

    @Test func linesCountedAsAUserCountsThem() {
        #expect(AutoReviewCap.lineCount("" as NSString) == 0)
        #expect(AutoReviewCap.lineCount("a" as NSString) == 1)
        #expect(AutoReviewCap.lineCount("a\n" as NSString) == 1)
        #expect(AutoReviewCap.lineCount("a\nb" as NSString) == 2)
        #expect(AutoReviewCap.lineCount("a\nb\n" as NSString) == 2)
        #expect(AutoReviewCap.lineCount("\n\n" as NSString) == 2)
    }

    @Test func utf8IsCountedNotUTF16() {
        // 40,000 "é" are 40,000 UTF-16 units but 80,000 bytes: under.
        // 60,000 are 120,000 bytes: over, though 60,000 units is not.
        let under = String(repeating: "é", count: 40_000)
        let over = String(repeating: "é", count: 60_000)
        #expect(AutoReviewCap.reason(for: under) == nil)
        #expect(AutoReviewCap.reason(for: over) == .bytes)
        #expect((over as NSString).length == 60_000)
    }

    @Test func cheapVerdictMatchesTheFullOne() {
        var counted = 0
        func cheap(_ s: String) -> AutoReviewCap.Reason? {
            let ns = s as NSString
            return AutoReviewCap.reason(utf16Length: ns.length, lines: AutoReviewCap.lineCount(ns)) {
                counted += 1
                return ns.lengthOfBytes(using: String.Encoding.utf8.rawValue)
            }
        }
        let samples = [text(lines: 10, width: 10), text(lines: 1_000, width: 99), text(lines: 1_000, width: 99) + "x",
                       String(repeating: "é", count: 40_000), String(repeating: "é", count: 60_000),
                       String(repeating: "😀", count: 30_000), text(lines: 2_001, width: 2), text(lines: 400, width: 374)]
        for s in samples { #expect(cheap(s) == AutoReviewCap.reason(for: s)) }
        // Small (under a third of the cap) and big (over the cap in UTF-16
        // units) documents never count UTF-8.
        counted = 0
        _ = cheap(text(lines: 10, width: 10))
        _ = cheap(text(lines: 400, width: 374))
        #expect(counted == 0)
    }

    @Test func wordingNamesSizeAndLimits() {
        let size = AutoReviewCap.Size(utf8Bytes: 730_000, lines: 6_132)
        let note = AutoReviewCap.note(size)
        #expect(note.contains("730 KB"))
        #expect(note.contains("6,132 lines"))
        #expect(note.contains("Auto-review is off"))
        let c = AutoReviewCap.confirmation(fileName: "pwnagotchi.log", size: size)
        #expect(c.message.contains("pwnagotchi.log"))
        #expect(c.message.contains("730 KB, 6,132 lines"))
        #expect(c.message.contains("100 KB or 2,000 lines"))
        #expect(c.message.contains("auto-review is off"))
    }
}
