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

    /// The UTF-16 loop's line starts, built the way `init` did before the
    /// ASCII fast path: the reference the fast path must equal.
    private static func loopStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        LineIndex.scanNewlines(text, in: NSRange(location: 0, length: text.length)) { starts.append($0) }
        return starts
    }

    /// The same text as a native Swift string, an 8-bit NSString copied
    /// from bytes, a mutable copy and (long enough for `Data` to keep its
    /// bytes on the heap, as the ≥ 16 MiB decodes that use it do) one
    /// reading the bytes in place.
    private static func asciiForms(_ s: String) -> [NSString] {
        let bytes = Array(s.utf8)
        var forms: [NSString] = [s as NSString, NSString(string: s), NSMutableString(string: s)]
        if let copied = NSString(bytes: bytes, length: bytes.count, encoding: String.Encoding.ascii.rawValue) { forms.append(copied) }
        if bytes.count >= 64, let shared = TextCodec.sharedASCII(Data(bytes)) { forms.append(shared as NSString) }
        return forms
    }

    /// The ASCII `memchr` paths (the bytes in place, and copies of them
    /// for text reading a file's bytes in place) give exactly the line
    /// starts of the UTF-16 loop: empty, no newline, a trailing newline,
    /// newlines only, dense, longer than the loop's 64 K chunk and the
    /// copy's 1 M chunk with newlines on their edges. Non-ASCII text
    /// takes the loop, with the same starts.
    @Test(.offPool) func asciiFastPathMatchesTheUTF16Loop() {
        func edged(_ chunk: Int) -> String {
            var s = String(repeating: "a", count: chunk - 1) + "\n"   // a newline last in the first chunk
            s += "\n" + String(repeating: "b", count: chunk - 2) + "\n"   // first, and last, in the next
            return s + String(repeating: "c\nd", count: 20_000) + "tail"
        }
        let ascii = ["", "x", "no newline here", "trailing\n", "\n", "\n\n\n", "a\nb\nc", "\nlead",
                     String(repeating: "\n", count: 200_000), String(repeating: "ab\n", count: 70_000),
                     String(repeating: "q", count: 3 * 65536 + 17), edged(65536), edged(LineIndex.asciiChunk),
                     String(repeating: "x", count: LineIndex.asciiChunk) + "\n",
                     "nul\u{0}byte\nand\tcontrol\u{1}\nescape\u{1B}[0m\n" + String(repeating: "pad ", count: 20)]
        var pointerSeen = 0, bytesSeen = 0
        for s in ascii {
            for text in Self.asciiForms(s) {
                let reference = Self.loopStarts(text)
                var viaPointer = [0]
                if LineIndex.scanASCIIPointer(text, { viaPointer.append($0) }) {
                    pointerSeen += 1
                    #expect(viaPointer == reference, "pointer path, \(text.length) units")
                } else {
                    #expect(viaPointer == [0], "no pointer: nothing reported")
                }
                var viaBytes = [0]
                let scanned = LineIndex.scanASCIIBytes(text) { viaBytes.append($0) }
                if text.length > 0 { bytesSeen += 1 }
                #expect(scanned == text.length && viaBytes == reference, "byte-copy path, \(scanned) of \(text.length) units")
                // Whether the fast path is taken here is Foundation's
                // storage choice; whatever it scans, it reports the
                // loop's starts for exactly those units.
                var viaPrefix = [0]
                let prefix = LineIndex.scanASCIIPrefix(text) { viaPrefix.append($0) }
                #expect((0...text.length).contains(prefix) && viaPrefix == reference.filter { $0 <= prefix },
                        "the fast path reports the loop's starts for what it scans, \(prefix) of \(text.length) units")
                let idx = LineIndex(text)
                #expect(idx.starts == reference, "init, \(text.length) units")
                #expect(idx.length == text.length)
                let newlines = reference.count - 1
                for hint in [0, 1, newlines + 1, newlines + 7] {
                    let hinted = LineIndex(text, expectedLineCount: hint)
                    #expect(hinted.starts == reference && hinted.length == text.length, "hint \(hint)")
                }
            }
        }
        // Which forms Foundation keeps as 8-bit with a C-string pointer is
        // its own choice: above, every form is held only to the loop's
        // starts. The pointer path itself on controlled 8-bit fixtures:
        _ = pointerSeen
        #expect(bytesSeen >= ascii.count - 1, "byte copies \(bytesSeen)")
        // the bytes and their NUL in a buffer of the test's own, read in
        // place (not copied; 16 bytes or more, as CF keeps shorter ones
        // as tagged pointers or constants): each short case after 16
        // bytes of padding too.
        let controlled = (ascii + ascii.map { String(repeating: "p", count: 16) + $0 })
            .filter { !$0.contains("\u{0}") && $0.utf8.count >= 16 }
        #expect(controlled.count >= ascii.count + 5)
        for s in controlled {
            let bytes = Array(s.utf8CString).map { UInt8(bitPattern: $0) }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            defer { buffer.deallocate() }
            buffer.initialize(from: bytes, count: bytes.count)
            let cf = CFStringCreateWithCStringNoCopy(nil, UnsafeRawPointer(buffer).assumingMemoryBound(to: CChar.self),
                                                     CFStringBuiltInEncodings.ASCII.rawValue, kCFAllocatorNull)!
            let text = cf as NSString
            #expect(CFStringGetCStringPtr(cf, CFStringBuiltInEncodings.ASCII.rawValue).map { UnsafeRawPointer($0) } == UnsafeRawPointer(buffer),
                    "an 8-bit C string read in place, \(text.length) units")
            var viaPointer = [0]
            #expect(LineIndex.scanASCIIPointer(text) { viaPointer.append($0) }, "the pointer path is taken, \(text.length) units")
            #expect(viaPointer == Self.loopStarts(text) && LineIndex(text).starts == viaPointer, "…with the loop's starts")
            var viaPrefix = [0]
            #expect(CFStringGetFastestEncoding(cf) == CFStringBuiltInEncodings.ASCII.rawValue, "stored as 8-bit ASCII, \(text.length) units")
            #expect(LineIndex.scanASCIIPrefix(text) { viaPrefix.append($0) } == text.length && viaPrefix == viaPointer,
                    "init's fast path scans it whole, \(text.length) units")
        }
        // A large decode's text (the bytes in place, no NUL after them):
        // no pointer, so the byte copies.
        let big = edged(LineIndex.asciiChunk)
        let shared = TextCodec.sharedASCII(Data(big.utf8))! as NSString
        #expect(!LineIndex.scanASCIIPointer(shared) { _ in })
        #expect(LineIndex.scanASCIIPrefix(shared) { _ in } == shared.length)

        // Not ASCII (UTF-16 storage, an attributed string's): not
        // scanned as bytes at all; the UTF-16 loop, the same starts.
        let wide = ["é\n", "naïve\nline\n", "😀\n😀", "a\nб\nc\n", String(repeating: "ü\n", count: 40_000) + "€",
                    "ascii first\n" + String(repeating: "x", count: 65536) + "\nthen é\n"]
        for s in wide {
            for text in [s as NSString, NSString(string: s), NSMutableString(string: s), NSMutableAttributedString(string: s).string as NSString, NSMutableAttributedString(string: s).mutableString] {
                var seen: [Int] = []
                #expect(LineIndex.scanASCIIPrefix(text) { seen.append($0) } == 0, "non-ASCII takes the loop")
                #expect(seen.isEmpty)
                let reference = Self.loopStarts(text)
                #expect(LineIndex(text).starts == reference)
                #expect(LineIndex(text, expectedLineCount: reference.count).starts == reference)
            }
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
