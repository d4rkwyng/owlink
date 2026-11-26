import Foundation
import Testing
@testable import CedricCore

/// LineStarts (a LineIndex's starts, four bytes each while they fit):
/// the same Ints as an array would hold, through appends, shifts and
/// replacements, on both sides of UInt32.max.
@Suite struct LineStartsTests {
    @Test func narrowStartsReadBackAsInts() {
        var s: LineStarts = [0, 3, 6]
        s.append(Int(UInt32.max))
        #expect(Array(s) == [0, 3, 6, Int(UInt32.max)])
        #expect(!s.isWide, "UInt32.max still fits")
        #expect(s.count == 4 && s[3] == Int(UInt32.max))
    }

    @Test func aStartPastUInt32TurnsThemToInts() {
        var s: LineStarts = [0, 10]
        let big = Int(UInt32.max) + 5
        s.append(big)
        #expect(s.isWide)
        #expect(Array(s) == [0, 10, big])
        s.append(big + 1)
        #expect(Array(s) == [0, 10, big, big + 1])
    }

    @Test func shiftsMatchAnArray() {
        var s: LineStarts = [0, 4, 9, 20]
        var a = [0, 4, 9, 20]
        s.shift(from: 2, by: 7)
        for k in 2..<a.count { a[k] += 7 }
        #expect(Array(s) == a && !s.isWide)
        s.shift(from: 1, by: -3)
        for k in 1..<a.count { a[k] -= 3 }
        #expect(Array(s) == a && !s.isWide)
        s.shift(from: 4, by: 5) // past the end: nothing
        s.shift(from: 0, by: 0)
        #expect(Array(s) == a)
        // A shift that takes the last start past UInt32.max.
        let d = Int(UInt32.max)
        s.shift(from: 3, by: d)
        a[3] += d
        #expect(s.isWide && Array(s) == a)
        s.shift(from: 1, by: 2)
        for k in 1..<a.count { a[k] += 2 }
        #expect(Array(s) == a)
    }

    @Test func replacementsMatchAnArray() {
        var s: LineStarts = [0, 5, 10, 15]
        var a = [0, 5, 10, 15]
        s.replaceSubrange(1..<3, with: [6, 7, 8])
        a.replaceSubrange(1..<3, with: [6, 7, 8])
        #expect(Array(s) == a && !s.isWide)
        s.replaceSubrange(2..<2, with: [])
        #expect(Array(s) == a)
        let big = Int(UInt32.max) + 1
        s.replaceSubrange(4..<5, with: [big])
        a.replaceSubrange(4..<5, with: [big])
        #expect(s.isWide && Array(s) == a)
    }

    @Test func equalityIgnoresHowTheyAreKept() {
        var narrow: LineStarts = [0, 1]
        var wide: LineStarts = [0, 1, Int(UInt32.max) + 1]
        wide.replaceSubrange(2..<3, with: [])
        #expect(wide.isWide && !narrow.isWide)
        #expect(narrow == wide && wide == narrow)
        narrow.append(2)
        #expect(narrow != wide)
        #expect(LineStarts([0, 1, 2]) == narrow)
    }

    /// A LineIndex edited many times keeps the starts a fresh scan gives
    /// (as EngineTests' random edits, here with the starts' own checks).
    @Test func anEditedIndexMatchesAFreshOne() {
        let text = NSMutableString(string: String(repeating: "ab\ncd\n\nefg\n", count: 50))
        var idx = LineIndex(text)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let loc = Int.random(in: 0...text.length, using: &rng)
            let len = Int.random(in: 0...min(6, text.length - loc), using: &rng)
            let ins = ["", "\n", "x", "x\ny", "\n\n", "longer\ntext\n"].randomElement(using: &rng)!
            let old = NSRange(location: loc, length: len)
            text.replaceCharacters(in: old, with: ins)
            idx.replace(old, newLength: (ins as NSString).length, in: text)
            let fresh = LineIndex(text)
            #expect(idx.starts == fresh.starts && idx.length == fresh.length)
            if idx.starts != fresh.starts { break }
        }
    }
}
