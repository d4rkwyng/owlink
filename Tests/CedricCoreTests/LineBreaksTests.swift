import Foundation
import Testing
@testable import CedricCore

/// Mixed line endings are kept on save (LineBreaks): decoding notes the
/// breaks that aren't the most common kind, every edit moves them with
/// their "\n" (or takes them, for undo to give back), and a save writes
/// each break as it was; a break the user types gets the most common kind.
@Suite struct LineBreaksTests {
    func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// The editor, in small: a text, its breaks, and undo, as the tab
    /// keeps them (EditorWindowController.trackLineBreaks: every storage
    /// change goes through `replace`; undo puts the old text back and
    /// gives back what `replace` took).
    struct Editor {
        var text: NSMutableString
        var breaks: LineBreaks
        var encoding: TextEncoding
        var undoStack: [(range: NSRange, old: String, removed: [Int])] = []

        init(_ bytes: [UInt8]) throws {
            let d = try #require(TextCodec.decode(Data(bytes)))
            text = NSMutableString(string: d.text)
            breaks = try #require(d.lineBreaks, "mixed files keep their breaks")
            encoding = d.encoding
        }

        mutating func replace(_ r: NSRange, with s: String) {
            let old = text.substring(with: r)
            text.replaceCharacters(in: r, with: s)
            let removed = breaks.replace(r, newLength: (s as NSString).length)
            undoStack.append((NSRange(location: r.location, length: (s as NSString).length), old, removed))
        }

        /// Replaces the first `find` (after `from`, UTF-16) with `with`.
        mutating func replace(_ find: String, with s: String, from: Int = 0) {
            let r = text.range(of: find, options: .literal, range: NSRange(location: from, length: text.length - from))
            precondition(r.location != NSNotFound, find)
            replace(r, with: s)
        }

        mutating func undo() {
            let u = undoStack.removeLast()
            text.replaceCharacters(in: u.range, with: u.old)
            let back = NSRange(location: u.range.location, length: (u.old as NSString).length)
            _ = breaks.replace(u.range, newLength: back.length)
            _ = breaks.restore(u.removed, at: back.location, within: back, in: text)
        }

        func saved() throws -> [UInt8] {
            [UInt8](try #require(TextCodec.encode(breaks.output(text as String), encoding: encoding, lineEnding: .lf)))
        }
    }

    func edited(_ bytes: [UInt8], _ edit: (inout Editor) -> Void) throws -> [UInt8] {
        var e = try Editor(bytes)
        edit(&e)
        return try e.saved()
    }

    // MARK: Detection

    @Test func mixedFilesNoteEachBreak() throws {
        let d = try #require(TextCodec.decode(Data(b("a\r\nb\nc\rd\n"))))
        #expect(d.text == "a\nb\nc\nd\n" && d.mixedLineEndings && d.lineEnding == .lf)
        let lb = try #require(d.lineBreaks)
        #expect(lb.endings(in: d.text) == [.crlf, .lf, .cr, .lf])
        #expect(lb.dominant == .lf && lb.isMixed)
        // Only the odd ones are kept: the CRLF at 1, the CR at 5.
        #expect(lb.others == [LineBreaks.entry(1, .crlf), LineBreaks.entry(5, .cr)])
        // Most common CRLF: what a typed break gets; the one LF is the only one kept.
        let crlf = try #require(TextCodec.decode(Data(b("a\r\nb\r\nc\n")))?.lineBreaks)
        #expect(crlf.dominant == .crlf && crlf.others == [LineBreaks.entry(5, .lf)])
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
        #expect(d.lineBreaks?.endings(in: d.text) == [.cr, .cr, .crlf, .lf, .cr, .cr])
    }

    /// Offsets are UTF-16, as the editor's text is: é (2 UTF-8 bytes, 1
    /// unit), 😀 (4 bytes, 2 units), € (3 bytes, 1 unit).
    @Test func offsetsAreUTF16() throws {
        let s = "é\r\n😀\n€\r😀é\n"
        let d = try #require(TextCodec.decode(Data(b(s))))
        let lb = try #require(d.lineBreaks)
        #expect(lb.endings(in: d.text) == [.crlf, .lf, .cr, .lf])
        #expect(lb.others == [LineBreaks.entry(1, .crlf), LineBreaks.entry(6, .cr)])
        #expect(lb.output(d.text) == s)
    }

    /// Not UTF-8 (Latin-1) and UTF-16: the same breaks, noted while
    /// normalising (the non-UTF-8 path).
    @Test func otherEncodings() throws {
        let latin = [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x78, 0x0A, 0x79, 0x0D] as [UInt8]
        let d = try #require(TextCodec.decode(Data(latin)))
        #expect(d.encoding == .latin1 && d.lineBreaks?.endings(in: d.text) == [.crlf, .lf, .cr])
        #expect(try edited(latin) { _ in } == latin)
        #expect(try edited(latin) { $0.replace("x", with: "xx") } == [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x78, 0x78, 0x0A, 0x79, 0x0D])
        let utf16 = [UInt8](TextCodec.encode("é\r\nb\nc\r", encoding: .utf16LE, lineEnding: .lf)!)
        let u = try #require(TextCodec.decode(Data(utf16)))
        #expect(u.lineBreaks?.endings(in: u.text) == [.crlf, .lf, .cr])
        #expect(try edited(utf16) { _ in } == utf16)
    }

    /// The large all-ASCII path (its own buffer, not a String) notes them too.
    @Test func largeASCIIPath() throws {
        let line = String(repeating: "x", count: 99)
        var s = ""
        let lines = TextCodec.sharedBytesMinimum / 100 + 10
        for i in 0..<lines { s += line + (i % 1000 == 7 ? "\r\n" : "\n") }
        let bytes = b(s)
        let d = try #require(TextCodec.decode(Data(bytes), shareBytes: true))
        #expect(d.mixedLineEndings && d.lineBreaks?.others.count == (lines + 992) / 1000)
        #expect(try #require(d.lineBreaks).output(d.text).utf8.elementsEqual(bytes), "a large mixed file saves byte for byte")
    }

    /// Mostly CRLF with one LF: one number kept, not one per line (a 1 GB
    /// CRLF file with a stray LF keeps one entry, not 4 GB of offsets).
    @Test func keepsOnlyTheOddOnes() throws {
        var s = String(repeating: "line\r\n", count: 200_000)
        s += "odd\n" + String(repeating: "line\r\n", count: 10)
        let d = try #require(TextCodec.decode(Data(b(s))))
        let lb = try #require(d.lineBreaks)
        #expect(lb.dominant == .crlf && lb.others.count == 1)
        #expect(lb.output(d.text).utf8.elementsEqual(b(s)))
        // Mostly CR with a few CRLF: the same.
        let cr = String(repeating: "a\r", count: 1_000) + "b\r\n" + String(repeating: "a\r", count: 5)
        let c = try #require(TextCodec.decode(Data(b(cr)))?.lineBreaks)
        #expect(c.dominant == .cr && c.others.count == 1)
    }

    // MARK: Saving through edits

    static let file = "one\r\ntwo\nthree\rfour\r\nfive\nsix"

    @Test func unchangedSavesByteForByte() throws {
        for s in [Self.file, Self.file + "\r", Self.file + "\n", "\r\n\n\r", "\r\r\n\n\r", "é\r\nü\n€\r", "a\r\nb\r\nc\nd\r\n"] {
            #expect(try edited(b(s)) { _ in } == b(s), "\(s.debugDescription)")
        }
    }

    @Test func editsInsideALineKeepEveryBreak() throws {
        let out = try edited(b(Self.file)) { $0.replace("three", with: "THREE and more") }
        #expect(out == b("one\r\ntwo\nTHREE and more\rfour\r\nfive\nsix"))
        // Every line edited, none added or removed.
        let all = try edited(b(Self.file)) { e in
            for w in ["one", "two", "three", "four", "five", "six"] { e.replace(w, with: w.uppercased()) }
        }
        #expect(all == b("ONE\r\nTWO\nTHREE\rFOUR\r\nFIVE\nSIX"))
    }

    /// Typing at a line's start (right after a CR) and at its end (right
    /// before a CRLF): the break stays where it was.
    @Test func editsAtLineBoundaries() throws {
        let start = try edited(b(Self.file)) { $0.replace(NSRange(location: 14, length: 0), with: ">") }
        #expect(start == b("one\r\ntwo\nthree\r>four\r\nfive\nsix"))
        let end = try edited(b(Self.file)) { $0.replace(NSRange(location: 3, length: 0), with: "!") }
        #expect(end == b("one!\r\ntwo\nthree\rfour\r\nfive\nsix"))
        // The last line, which has no break, grows one: the most common kind (LF here).
        let grown = try edited(b(Self.file)) { $0.replace(NSRange(location: $0.text.length, length: 0), with: "\nseven") }
        #expect(grown == b(Self.file + "\nseven"))
    }

    @Test func typedLinesGetTheMostCommonKind() throws {
        // A new line after "two" (CRLF 2, LF 2, CR 1: LF wins ties).
        let out = try edited(b(Self.file)) { $0.replace(NSRange(location: 7, length: 0), with: "\nnew") }
        #expect(out == b("one\r\ntwo\nnew\nthree\rfour\r\nfive\nsix"))
        // CRLF most common: a typed line is CRLF.
        let crlf = try edited(b("a\r\nb\r\nc\nd")) { $0.replace(NSRange(location: 3, length: 0), with: "\nB") }
        #expect(crlf == b("a\r\nb\r\nB\r\nc\nd"))
        // Several lines pasted between CR and CRLF neighbours.
        let pasted = try edited(b(Self.file)) { $0.replace(NSRange(location: 14, length: 0), with: "x\ny\nz\n") }
        #expect(pasted == b("one\r\ntwo\nthree\rx\ny\nz\nfour\r\nfive\nsix"))
    }

    /// Return in the middle of a CR line: the CR stays where it was (after
    /// the second half); the first half's break is the new one.
    @Test func splittingALine() throws {
        let out = try edited(b(Self.file)) { $0.replace(NSRange(location: 10, length: 0), with: "\n") }
        #expect(out == b("one\r\ntwo\nth\nree\rfour\r\nfive\nsix"))
    }

    /// Joining two lines (deleting a break): the joined line keeps the
    /// second line's break; the others are untouched.
    @Test func joiningAndDeletingLines() throws {
        let joined = try edited(b(Self.file)) { $0.replace(NSRange(location: 13, length: 1), with: "") }
        #expect(joined == b("one\r\ntwo\nthreefour\r\nfive\nsix"))
        let deleted = try edited(b(Self.file)) { $0.replace("three\n", with: "") }
        #expect(deleted == b("one\r\ntwo\nfour\r\nfive\nsix"))
        let first = try edited(b(Self.file)) { $0.replace(NSRange(location: 0, length: 4), with: "") }
        #expect(first == b("two\nthree\rfour\r\nfive\nsix"))
    }

    /// The review's cases. Same text on two lines: deleting the first
    /// line and its break keeps the second line's own break (LF), whatever
    /// the lines say.
    @Test func identityIsTheBreakNotTheLine() throws {
        #expect(try edited(b("x\r\nx\nz")) { $0.replace(NSRange(location: 0, length: 2), with: "") } == b("x\nz"))
        #expect(try edited(b("x\r\nx\nz")) { $0.replace(NSRange(location: 2, length: 2), with: "") } == b("x\r\nz"))
        // Lines of equal text, one break typed between two of them.
        let same = try edited(b("a\na\r\na\ra\n")) { $0.replace(NSRange(location: 3, length: 0), with: "\na") }
        #expect(same == b("a\na\na\r\na\ra\n"))
    }

    /// Deleting the line between a CR and an LF puts the CR straight
    /// before the LF; written as is, they would read back as one CRLF
    /// (one line lost). The CR is written as CRLF: two breaks still.
    @Test func aCRNeverMergesWithTheLFAfterIt() throws {
        let out = try edited(b("A\rB\nC")) { $0.replace(NSRange(location: 2, length: 1), with: "") }
        #expect(out == b("A\r\n\nC"))
        #expect(TextCodec.decode(Data(out))?.text == "A\n\nC", "reopened: still three lines")
        // Mostly CR, an LF after a CR line emptied.
        let cr = try edited(b("a\rb\rc\nd\re\r")) { $0.replace(NSRange(location: 4, length: 1), with: "") }
        #expect(TextCodec.decode(Data(cr))?.text == "a\nb\n\nd\ne\n", "\(String(decoding: cr, as: UTF8.self).debugDescription)")
        // A CR straight before a CRLF reads back as two breaks: written as it is.
        #expect(try edited(b("A\rB\r\nC\n")) { $0.replace(NSRange(location: 2, length: 1), with: "") } == b("A\r\r\nC\n"))
    }

    // MARK: Undo

    /// Edits and their undo (the text back as it was): the bytes are the
    /// file's again, every break back as it was.
    @Test func undoGivesTheFileBack() throws {
        let edits: [(inout Editor) -> Void] = [
            { $0.replace(NSRange(location: 13, length: 1), with: "") },                  // join three+four (CR)
            { $0.replace(NSRange(location: 0, length: $0.text.length), with: "all") },   // everything
            { $0.replace(NSRange(location: 7, length: 0), with: "\nnew\nlines") },
            { $0.replace("four\n", with: "") },                                           // a CRLF line
            { $0.replace(NSRange(location: 2, length: 10), with: "") },                   // across CRLF, LF and into three
        ]
        for (k, edit) in edits.enumerated() {
            var e = try Editor(b(Self.file))
            edit(&e)
            #expect(try e.saved() != b(Self.file), "edit \(k) changes the bytes")
            e.undo()
            #expect(e.text as String == "one\ntwo\nthree\nfour\nfive\nsix", "edit \(k) undone")
            #expect(try e.saved() == b(Self.file), "edit \(k) undone: the file's bytes")
        }
    }

    /// Deleting the only CRLF, saving, undoing and saving again: the CRLF
    /// is back (the breaks are kept across the save, not rebuilt from it).
    @Test func undoAfterASaveBringsTheBreakBack() throws {
        var e = try Editor(b("a\r\nb\nc\n"))
        e.replace(NSRange(location: 1, length: 1), with: "")
        #expect(try e.saved() == b("ab\nc\n"))
        #expect(!e.breaks.isMixed, "no odd break left after the delete")
        e.undo()
        #expect(try e.saved() == b("a\r\nb\nc\n"))
        #expect(e.breaks.isMixed)
    }

    /// Several edits around the same breaks, undone one by one: each step
    /// back is the bytes that step saved.
    @Test func undoStepByStep() throws {
        var e = try Editor(b(Self.file))
        var history = [try e.saved()]
        e.replace(NSRange(location: 3, length: 2), with: "")          // join one+two (CRLF)
        history.append(try e.saved())
        e.replace(NSRange(location: 6, length: 0), with: "\nX")       // a break typed
        history.append(try e.saved())
        e.replace("three\nfour\n", with: "")                          // CR and CRLF lines
        history.append(try e.saved())
        e.replace(NSRange(location: 0, length: e.text.length), with: "") // all of it
        history.append(try e.saved())
        #expect(history.last == [])
        for k in stride(from: history.count - 2, through: 0, by: -1) {
            e.undo()
            #expect(try e.saved() == history[k], "undone back to step \(k)")
        }
        #expect(try e.saved() == b(Self.file))
    }

    // MARK: Session buffers

    /// A session buffer holds the text with its breaks written in; read
    /// back against the same most common kind, it is the same text and
    /// breaks (never read from the file again).
    @Test func buffersReadBackTheirBreaks() throws {
        for s in [Self.file, "a\r\nb\r\nc\nd", "a\rb\rc\r\nd\n", "é\r\n😀\n€\r", "x\ny\r"] {
            let d = try #require(TextCodec.decode(Data(b(s))))
            var e = try Editor(b(s))
            e.replace(NSRange(location: 0, length: 0), with: "new\n")
            let written = e.breaks.output(e.text as String)
            let (text, breaks) = LineBreaks.read(written, dominant: d.lineEnding)
            #expect(text == e.text as String && breaks == e.breaks, "\(s.debugDescription)")
        }
        // Every odd break deleted, mostly CRLF: no CR left in the buffer but each LF is odd.
        var e = try Editor(b("a\r\nb\nc\nd\r\ne\r\n"))
        e.replace(NSRange(location: 0, length: 2), with: "")
        let (text, breaks) = LineBreaks.read(e.breaks.output(e.text as String), dominant: .crlf)
        #expect(text == e.text as String && breaks == e.breaks)
    }

    // MARK: Many and random

    /// Random mixed files and random edits (typed text with breaks,
    /// deletions across breaks, undo): every break the edits kept is as it
    /// was on disk, a typed one is the most common kind, the saved bytes
    /// read back as the same lines, and undoing everything gives the file.
    @Test func randomEdits() throws {
        var rng = SplitMix(seed: 0x5EED)
        let kinds: [LineEnding] = [.lf, .crlf, .cr]
        for round in 0..<300 {
            let count = Int(rng.next() % 40) + 2
            var file = ""
            // Each character of the LF text, with the kind of its break (nil: not a break, or typed).
            var shadow: [(Character, LineEnding?)] = []
            for i in 0..<count {
                let word = "w\(i)" + (rng.next() % 4 == 0 ? "é" : "")
                for c in word { shadow.append((c, nil)) }
                file += word
                if i < count - 1 || rng.next() % 2 == 0 {
                    let k = kinds[Int(rng.next() % 3)]
                    file += k.string
                    shadow.append(("\n", k))
                }
            }
            guard let d = TextCodec.decode(Data(b(file))), d.lineBreaks != nil else { continue }
            var e = try Editor(b(file))
            var shadows = [shadow]
            for _ in 0..<Int(rng.next() % 10) + 1 {
                let len = e.text.length
                let at = Int(rng.next() % UInt64(len + 1))
                let del = min(len - at, Int(rng.next() % 6))
                let insert = ["", "q", "\n", "x\ny", "\n\n"][Int(rng.next() % 5)]
                // Every character here is one UTF-16 unit (é precomposed).
                e.replace(NSRange(location: at, length: del), with: insert)
                shadow.replaceSubrange(at..<(at + del), with: insert.map { ($0, $0 == "\n" ? d.lineEnding : nil) })
                shadows.append(shadow)
                #expect(e.text as String == String(shadow.map(\.0)), "round \(round): text")
                let want = shadow.compactMap { $0.0 == "\n" ? ($0.1 ?? d.lineEnding) : nil }
                #expect(e.breaks.endings(in: e.text as String) == want, "round \(round): each break its own")
                let saved = try e.saved()
                #expect(TextCodec.decode(Data(saved))?.text == e.text as String, "round \(round): reads back as the same lines")
            }
            for k in stride(from: shadows.count - 2, through: 0, by: -1) {
                e.undo()
                let want = shadows[k].compactMap { $0.0 == "\n" ? ($0.1 ?? d.lineEnding) : nil }
                #expect(e.breaks.endings(in: e.text as String) == want, "round \(round): undo step \(k)")
            }
            #expect(try e.saved() == b(file), "round \(round): undone, the file's bytes")
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

/// 0.5.4 QA, should round 2 leftovers: breaks through edits that keep
/// every line, what the status says once kinds are gone, appends, and
/// noting odd breaks against a kind that isn't LF in text with no CR.
@Suite struct LineBreaksKeepTests {
    /// The tab's edit, as LineBreakTracking makes it: `kinds` read before
    /// it when it keeps every line, `replace`, then `place`.
    func edit(_ text: inout NSString, _ breaks: inout LineBreaks, _ range: NSRange, _ with: String) {
        let keeps = LineBreaks.keepsLines(text.substring(with: range) as NSString, with as NSString)
        let kinds = keeps ? breaks.kinds(in: range, of: text) : nil
        breaks.replace(range, newLength: (with as NSString).length)
        text = text.replacingCharacters(in: range, with: with) as NSString
        if let kinds { breaks.place(kinds, newlinesIn: NSRange(location: range.location, length: (with as NSString).length), of: text) }
    }

    /// Convert Indentation (and Indent, Outdent) rewrite whole lines'
    /// leading whitespace as one edit over all of them: every odd break in
    /// it went, and the next save wrote the whole file as the most common
    /// kind. A break is the one it was when its line is.
    @Test func convertIndentationKeepsEveryBreak() throws {
        let file = "a\r\n    b\n\tc\r\n        d\r\n".utf8
        let d = try #require(TextCodec.decode(Data(file)))
        var breaks = try #require(d.lineBreaks)
        var text = d.text as NSString
        let all = NSRange(location: 0, length: text.length)
        let converted = LineOperations.convertIndentation(text as String, from: Indentation(usesTabs: false, width: 4),
                                                          to: Indentation(usesTabs: true, width: 4))
        #expect(converted != text as String)
        edit(&text, &breaks, all, converted)
        let out = TextCodec.encode(breaks.output(text as String), encoding: .utf8, lineEnding: .lf)
        #expect(out == Data("a\r\n\tb\n\tc\r\n\t\td\r\n".utf8), "each line's break as it was")
        // Mostly CRLF: the one odd break is the LF after "b".
        #expect(breaks.counts == [1, 0, 0], "\(breaks.counts)")
        #expect(breaks.counts.reduce(0, +) == breaks.others.count)
    }

    /// Only whitespace at a line's ends may change; anything else (a
    /// sort, a line added or joined) is a rewrite, whose breaks become the
    /// most common kind, as before.
    @Test func onlyWhitespaceAtTheEndsKeepsLines() {
        #expect(LineBreaks.keepsLines("  a\nb  \n", "\ta\nb\n"))
        #expect(!LineBreaks.keepsLines("a\nb\n", "b\na\n"), "a sort moves lines")
        #expect(!LineBreaks.keepsLines("a\nb\n", "a b\n"), "a join removes a break")
        #expect(!LineBreaks.keepsLines("a\nb\n", "a\nx\nb\n"))
        #expect(!LineBreaks.keepsLines("a b\n", "ab\n"), "inside a line is a change")

        var text = "x\r\ny\nz\r\n" as NSString
        let d = TextCodec.decode(Data((text as String).utf8))!
        var breaks = d.lineBreaks!
        text = d.text as NSString
        edit(&text, &breaks, NSRange(location: 0, length: text.length), "y\nx\nz\n")
        #expect(TextCodec.encode(breaks.output(text as String), encoding: .utf8, lineEnding: .lf) == Data("y\r\nx\r\nz\r\n".utf8),
                "a sort's breaks are the most common kind")
    }

    /// The status and the mixed bar say what is left: all the dominant
    /// breaks deleted is one kind (the odd one), not "LF (mixed)"; the last
    /// odd break deleted is the dominant kind alone.
    @Test func summaryIsWhatIsLeft() {
        var b = LineBreaks(dominant: .lf, others: [LineBreaks.entry(3, .crlf), LineBreaks.entry(7, .crlf)])
        #expect(b.counts == [0, 2, 0])
        #expect(b.summary(newlines: 5) == (.lf, true))
        #expect(b.summary(newlines: 3) == (.crlf, true), "two CRLF and one LF: mostly CRLF")
        #expect(b.summary(newlines: 2) == (.crlf, false), "no LF left: CRLF, not mixed")
        #expect(b.isMixed)
        b.replace(NSRange(location: 3, length: 1), newLength: 0)
        b.replace(NSRange(location: 6, length: 1), newLength: 0)
        #expect(b.others.isEmpty && b.counts == [0, 0, 0])
        #expect(b.summary(newlines: 4) == (.lf, false))
        #expect(b.summary(newlines: 0) == (.lf, false), "no break at all: the file's own")
        // Ties go to the file's own kind.
        let tie = LineBreaks(dominant: .crlf, others: [LineBreaks.entry(1, .lf)])
        #expect(tie.summary(newlines: 2) == (.crlf, true))
        // Counts follow restore too.
        var r = LineBreaks(dominant: .lf, others: [LineBreaks.entry(1, .cr)])
        let gone = r.replace(NSRange(location: 0, length: 2), newLength: 0)
        #expect(r.counts == [0, 0, 0])
        _ = r.restore(gone, at: 0, within: NSRange(location: 0, length: 2), in: "a\n")
        #expect(r.counts == [0, 0, 1])
    }

    /// Follow File's appends: their odd breaks after the text's own.
    @Test func appendShiftsTheAddedBreaks() {
        var b = LineBreaks(dominant: .lf, others: [LineBreaks.entry(1, .crlf)])
        b.append(LineBreaks(dominant: .lf, others: [LineBreaks.entry(2, .crlf), LineBreaks.entry(5, .cr)]), at: 4)
        #expect(b.others == [LineBreaks.entry(1, .crlf), LineBreaks.entry(6, .crlf), LineBreaks.entry(9, .cr)])
        #expect(b.counts == [0, 2, 1])
    }

    /// Noting against CRLF in text with no CR at all (an append of LF
    /// lines to a CRLF file): each LF is odd. It returned the text early
    /// and noted none.
    @Test func lfOnlyTextNotesItsBreaksAgainstCRLF() {
        var rec: TextCodec.BreakRecorder? = TextCodec.BreakRecorder(dominant: .crlf, ascii: false)
        let out = TextCodec.normalizeLineEndings("é\nb\n", recording: &rec)
        #expect(out == "é\nb\n")
        #expect(rec?.others == [LineBreaks.entry(1, .lf), LineBreaks.entry(3, .lf)])
    }

    /// Offsets of odd breaks in non-ASCII text, counted as each run is
    /// written (no reading back over the text before each break).
    @Test func nonASCIIOffsetsCountedAsWritten() throws {
        var bytes = Data()
        var expected: [Int] = []
        var units = 0
        for i in 0..<2000 {
            let line = i % 3 == 0 ? "é😀 line \(i)" : "ascii \(i)"
            bytes.append(Data(line.utf8))
            units += (line as NSString).length
            if i % 7 == 0 { bytes.append(Data("\r\n".utf8)); expected.append(LineBreaks.entry(units, .crlf)) } else { bytes.append(0x0A) }
            units += 1
        }
        let d = try #require(TextCodec.decode(bytes))
        #expect(d.lineEnding == .lf)
        #expect(d.lineBreaks?.others == expected)
    }
}
