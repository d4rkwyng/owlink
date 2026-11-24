import Foundation
import Testing
@testable import CedricCore

/// Mixed line endings are kept on save (LineBreaks): decoding notes which
/// break was CR or CRLF, and a save writes each line's break back as it
/// was, wherever the edits were; a break the user typed gets the most
/// common kind.
@Suite struct LineBreaksTests {
    /// Decodes `bytes`, applies `edit` to the LF text, and saves as the
    /// document would (each line's own break, the file's encoding).
    func save(_ bytes: [UInt8], _ edit: (String) -> String = { $0 }) throws -> [UInt8] {
        let d = try #require(TextCodec.decode(Data(bytes)))
        let lb = try #require(d.lineBreaks, "mixed files keep their breaks")
        let saved = lb.write(edit(d.text))
        return [UInt8](try #require(TextCodec.encode(saved.output, encoding: d.encoding, lineEnding: .lf)))
    }

    func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: Detection

    @Test func mixedFilesNoteEachBreak() throws {
        let d = try #require(TextCodec.decode(Data(b("a\r\nb\nc\rd\n"))))
        #expect(d.text == "a\nb\nc\nd\n" && d.mixedLineEndings && d.lineEnding == .lf)
        let lb = try #require(d.lineBreaks)
        #expect(lb.endings == [.crlf, .lf, .cr, .lf])
        #expect(lb.dominant == .lf)
        // Most common CRLF: what a typed break gets.
        #expect(TextCodec.decode(Data(b("a\r\nb\r\nc\n")))?.lineBreaks?.dominant == .crlf)
    }

    @Test func uniformFilesKeepNothing() {
        for s in ["a\nb\n", "a\r\nb\r\n", "a\rb\r", "no break", ""] {
            let d = TextCodec.decode(Data(b(s)))
            #expect(d?.mixedLineEndings == false && d?.lineBreaks == nil, "\(s.debugDescription)")
        }
    }

    /// CR then CRLF ("\r\r\n"), LF then CR ("\n\r"), a CR at the very
    /// start and end: each break is its own.
    @Test func neighbouringBreaks() throws {
        let d = try #require(TextCodec.decode(Data(b("\rx\r\r\ny\n\rz\r"))))
        #expect(d.text == "\nx\n\ny\n\nz\n")
        #expect(d.lineBreaks?.endings == [.cr, .cr, .crlf, .lf, .cr, .cr])
    }

    /// Not UTF-8 (Latin-1) and UTF-16: the same breaks, noted while
    /// normalising (the non-UTF-8 path).
    @Test func otherEncodings() throws {
        let latin = [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x78, 0x0A, 0x79, 0x0D] as [UInt8]
        let d = try #require(TextCodec.decode(Data(latin)))
        #expect(d.encoding == .latin1 && d.lineBreaks?.endings == [.crlf, .lf, .cr])
        #expect(try save(latin) == latin)
        #expect(try save(latin) { $0.replacingOccurrences(of: "x", with: "xx") } == [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x78, 0x78, 0x0A, 0x79, 0x0D])
        let utf16 = [UInt8](TextCodec.encode("é\r\nb\nc\r", encoding: .utf16LE, lineEnding: .lf)!)
        #expect(TextCodec.decode(Data(utf16))?.lineBreaks?.endings == [.crlf, .lf, .cr])
        #expect(try save(utf16) == utf16)
    }

    /// The large all-ASCII path (its own buffer, not a String) notes them too.
    @Test func largeASCIIPath() throws {
        let line = String(repeating: "x", count: 99)
        var s = ""
        for i in 0..<(TextCodec.sharedBytesMinimum / 100 + 10) { s += line + (i % 1000 == 7 ? "\r\n" : "\n") }
        let bytes = b(s)
        let d = try #require(TextCodec.decode(Data(bytes), shareBytes: true))
        #expect(d.mixedLineEndings && d.lineBreaks?.crBreaks.count == (TextCodec.sharedBytesMinimum / 100 + 10 + 992) / 1000)
        let saved = try #require(d.lineBreaks).write(d.text)
        #expect(saved.output.utf8.elementsEqual(bytes), "a large mixed file saves byte for byte")
    }

    // MARK: Saving

    static let file = "one\r\ntwo\nthree\rfour\r\nfive\nsix"

    @Test func unchangedSavesByteForByte() throws {
        for s in [Self.file, Self.file + "\r", Self.file + "\n", "\r\n\n\r", "\r\r\n\n\r", "é\r\nü\n€\r"] {
            #expect(try save(b(s)) == b(s), "\(s.debugDescription)")
        }
    }

    @Test func editsInsideALineKeepEveryBreak() throws {
        let out = try save(b(Self.file)) { $0.replacingOccurrences(of: "three", with: "THREE and more") }
        #expect(out == b("one\r\ntwo\nTHREE and more\rfour\r\nfive\nsix"))
        // Every line edited, none added or removed.
        let all = try save(b(Self.file)) { $0.uppercased() }
        #expect(all == b("ONE\r\nTWO\nTHREE\rFOUR\r\nFIVE\nSIX"))
    }

    /// Typing at a line's start (right after a CR) and at its end (right
    /// before a CRLF): the break stays the line's.
    @Test func editsAtLineBoundaries() throws {
        let start = try save(b(Self.file)) { $0.replacingOccurrences(of: "\nfour", with: "\n>four") }
        #expect(start == b("one\r\ntwo\nthree\r>four\r\nfive\nsix"))
        let end = try save(b(Self.file)) { $0.replacingOccurrences(of: "one\n", with: "one!\n") }
        #expect(end == b("one!\r\ntwo\nthree\rfour\r\nfive\nsix"))
        // The last line, which has no break, grows one: the most common kind (LF here).
        #expect(try save(b(Self.file)) { $0 + "\nseven" } == b(Self.file + "\nseven"))
    }

    @Test func typedLinesGetTheMostCommonKind() throws {
        // A new line after "two" (LF most common... CRLF 2, LF 2, CR 1: LF wins ties).
        let out = try save(b(Self.file)) { $0.replacingOccurrences(of: "two\n", with: "two\nnew\n") }
        #expect(out == b("one\r\ntwo\nnew\nthree\rfour\r\nfive\nsix"))
        // CRLF most common: a typed line is CRLF.
        let crlf = "a\r\nb\r\nc\nd"
        #expect(try save(b(crlf)) { $0.replacingOccurrences(of: "b\n", with: "b\nB\n") } == b("a\r\nb\r\nB\r\nc\nd"))
        // Several lines pasted between CR and CRLF neighbours.
        let pasted = try save(b(Self.file)) { $0.replacingOccurrences(of: "three\n", with: "three\nx\ny\nz\n") }
        #expect(pasted == b("one\r\ntwo\nthree\rx\ny\nz\nfour\r\nfive\nsix"))
    }

    /// Several changes in one place (a typed line, a line typed in, two
    /// lines joined): each changed line keeps the break of the line it
    /// most resembles; the typed line gets the most common kind.
    @Test func changedBlocks() throws {
        let file = "one\r\ntwo\nthree\rfour\r\nfive\nsix\n"
        let out = try save(b(file)) { _ in "one\ntwo\nnew\nthree!\nfourfive\nsix\n" }
        #expect(out == b("one\r\ntwo\nnew\nthree!\rfourfive\nsix\n"))
        // A line typed in at its start and one at its end, around a new one.
        let around = try save(b(file)) { _ in "one\ntwo\n>three\nadded\nfour<\nfive\nsix\n" }
        #expect(around == b("one\r\ntwo\n>three\radded\nfour<\r\nfive\nsix\n"))
    }

    /// Return in the middle of a CR line: the CR stays after the second
    /// half (where it was); the first half's break is the new one.
    @Test func splittingALine() throws {
        let out = try save(b(Self.file)) { $0.replacingOccurrences(of: "three\n", with: "th\nree\n") }
        #expect(out == b("one\r\ntwo\nth\nree\rfour\r\nfive\nsix"))
    }

    /// Joining two lines (deleting a break): the joined line keeps the
    /// second line's break; the others are untouched.
    @Test func joiningAndDeletingLines() throws {
        let joined = try save(b(Self.file)) { $0.replacingOccurrences(of: "three\nfour", with: "threefour") }
        #expect(joined == b("one\r\ntwo\nthreefour\r\nfive\nsix"))
        let deleted = try save(b(Self.file)) { $0.replacingOccurrences(of: "three\n", with: "") }
        #expect(deleted == b("one\r\ntwo\nfour\r\nfive\nsix"))
        let first = try save(b(Self.file)) { String($0.dropFirst(4)) }
        #expect(first == b("two\nthree\rfour\r\nfive\nsix"))
    }

    /// An edit and its undo (the text back as it was): the bytes are the
    /// file's again, whatever the edit did to the breaks in between (the
    /// document keeps the breaks it read until it saves).
    @Test func undoGivesTheFileBack() throws {
        let edits: [(String) -> String] = [
            { $0.replacingOccurrences(of: "three\nfour", with: "threefour") },
            { $0.replacingOccurrences(of: "\n", with: "") },
            { $0.replacingOccurrences(of: "two\n", with: "two\nnew\nlines\n") },
            { $0.replacingOccurrences(of: "\nfour\n", with: "\n") },
            { _ in "" },
        ]
        let d = try #require(TextCodec.decode(Data(b(Self.file))))
        let lb = try #require(d.lineBreaks)
        for (k, edit) in edits.enumerated() {
            let edited = edit(d.text)
            #expect(edited != d.text, "edit \(k) changes the text")
            #expect(!lb.write(edited).output.utf8.elementsEqual(b(Self.file)), "edit \(k) changes the bytes")
            #expect(lb.write(d.text).output.utf8.elementsEqual(b(Self.file)), "edit \(k) undone: the file's bytes")
        }
        // Saved with the join, then undone and saved again: the CR it
        // joined is gone from disk, so the split gets the most common kind
        // (LF); every other line keeps its own.
        let joined = lb.write(edits[0](d.text))
        #expect(joined.output == "one\r\ntwo\nthreefour\r\nfive\nsix")
        #expect(joined.breaks.write(d.text).output == "one\r\ntwo\nthree\nfour\r\nfive\nsix")
    }

    /// Two saves in a row: the second starts from what the first wrote.
    @Test func savesChain() throws {
        let d = try #require(TextCodec.decode(Data(b(Self.file))))
        let first = try #require(d.lineBreaks).write(d.text.replacingOccurrences(of: "two\n", with: "two\nadded\n"))
        #expect(first.output == "one\r\ntwo\nadded\nthree\rfour\r\nfive\nsix" && first.mixed)
        let second = first.breaks.write(first.breaks.text.replacingOccurrences(of: "five", with: "5"))
        #expect(second.output == "one\r\ntwo\nadded\nthree\rfour\r\n5\nsix" && second.mixed)
        // Lines removed until one kind is left: no longer mixed.
        let uniform = first.breaks.write("one\nsix")
        #expect(uniform.output == "one\r\nsix" && !uniform.mixed && uniform.dominant == .crlf)
    }

    /// Many lines, edits far apart (the line diff), and a middle too big
    /// to diff (taken as one block): untouched lines keep their breaks.
    @Test func manyLines() throws {
        let kinds = ["\n", "\r\n", "\r"]
        let count = 50_000
        var s = ""
        for i in 0..<count { s += "line \(i)" + kinds[i % 3] }
        var lines = (0..<count).map { "line \($0)" } + [""]
        lines[10] = "edited 10"
        lines.insert("typed", at: 25_000)
        lines.remove(at: 40_000)    // "line 39999"
        var want = ""
        for i in 0..<count where i != 39_999 {
            if i == 25_000 { want += "typed\n" }   // LF: the most common (LF and CRLF tie)
            want += (i == 10 ? "edited 10" : "line \(i)") + kinds[i % 3]
        }
        #expect(try save(b(s)) { _ in lines.joined(separator: "\n") } == b(want))
        // Every middle line replaced (more than the diff limit): one block,
        // as many lines as before, so each keeps its break.
        var far = (0..<count).map { "line \($0)" } + [""]
        var wantFar = ""
        for i in 0..<count {
            if i >= 100, i < count - 100 { far[i] = "x\(i)" }
            wantFar += far[i] + kinds[i % 3]
        }
        #expect(count - 200 > LineBreaks.diffLimit)
        #expect(try save(b(s)) { _ in far.joined(separator: "\n") } == b(wantFar))
    }

    /// Random mixed files and random line edits (seeded): every line left
    /// as it was keeps its own break, and undoing gives the file back.
    @Test func randomEdits() throws {
        var rng = SplitMix(seed: 0x5EED)
        let kinds = ["\n", "\r\n", "\r"]
        for round in 0..<200 {
            let count = Int(rng.next() % 60) + 1
            // Unique lines (ids), each with a random break; the last maybe none.
            var lines: [(id: String, end: String)] = (0..<count).map { ("l\(round)-\($0)", kinds[Int(rng.next() % 3)]) }
            if rng.next() % 2 == 0 { lines[count - 1].end = "" }
            let file = lines.map { $0.id + $0.end }.joined()
            let d = try #require(TextCodec.decode(Data(file.utf8)))
            guard let lb = d.lineBreaks else { continue }   // happened to be uniform
            var edited = d.text.components(separatedBy: "\n")
            for e in 0..<Int(rng.next() % 8) + 1 {
                let at = Int(rng.next() % UInt64(edited.count))
                switch rng.next() % 3 {
                case 0: edited.insert("new\(e)", at: at)
                case 1: if edited.count > 1 { edited.remove(at: at) }
                default: edited[at] = edited[at] + "*\(e)"
                }
            }
            let out = lb.write(edited.joined(separator: "\n")).output
            // Lines left as they were (not one that is last now: no break after it): their own break.
            for l in lines.dropLast() where edited.dropLast().contains(l.id) {
                #expect(out.contains(l.id + l.end), "round \(round): \(l.id) keeps \(l.end.debugDescription)")
            }
            #expect(lb.write(d.text).output == file, "round \(round): undone, the file's bytes")
        }
    }
}

/// A small seeded generator (tests only).
struct SplitMix {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
