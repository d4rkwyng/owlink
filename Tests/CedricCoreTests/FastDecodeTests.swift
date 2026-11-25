import Foundation
import Testing
@testable import CedricCore

/// The one-pass UTF-8 decode (TextCodec.scanUTF8 / decodeUTF8) against the
/// decode it replaced (`Reference`, copied from TextCodec before 0.5.4):
/// the same text, encoding, line ending and mixed flag, or nil, for every
/// input, with the interesting byte at every position around the 8-byte
/// words the scan reads.
@Suite struct FastDecodeTests {
    /// TextCodec.decode as it was (Foundation decoding, then line endings).
    enum Reference {
        static func isValidUTF8(_ data: Data) -> Bool {
            let b = [UInt8](data)
            var i = 0
            let n = b.count
            while i < n {
                let c = b[i]
                if c < 0x80 { i += 1; continue }
                let len: Int
                if c & 0xE0 == 0xC0 { len = 2; if c < 0xC2 { return false } }
                else if c & 0xF0 == 0xE0 { len = 3 }
                else if c & 0xF8 == 0xF0 { len = 4; if c > 0xF4 { return false } }
                else { return false }
                if i + len > n { return false }
                for k in 1..<len where b[i + k] & 0xC0 != 0x80 { return false }
                if len == 3 {
                    if c == 0xE0 && b[i + 1] < 0xA0 { return false }
                    if c == 0xED && b[i + 1] >= 0xA0 { return false }
                }
                if len == 4 {
                    if c == 0xF0 && b[i + 1] < 0x90 { return false }
                    if c == 0xF4 && b[i + 1] >= 0x90 { return false }
                }
                i += len
            }
            return true
        }

        static func detectEncoding(_ data: Data) -> TextEncoding {
            let head = [UInt8](data.prefix(4))
            if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
            if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
            if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
            if let guess = TextCodec.guessUTF16(data) { return guess }
            if isValidUTF8(data) { return .utf8 }
            return TextCodec.guessEightBit(data)
        }

        static func detectLineEnding(_ text: String) -> (LineEnding, Bool) {
            var lf = 0, crlf = 0, cr = 0
            let b = Array(text.utf8)
            var i = 0
            while i < b.count {
                if b[i] == 13 {
                    if i + 1 < b.count, b[i + 1] == 10 { crlf += 1; i += 2; continue }
                    cr += 1
                } else if b[i] == 10 { lf += 1 }
                i += 1
            }
            let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
            let ending: LineEnding = crlf > lf && crlf >= cr ? .crlf : cr > lf && cr > crlf ? .cr : .lf
            return (ending, kinds > 1)
        }

        static func normalize(_ text: String) -> String {
            guard text.utf8.contains(13) else { return text }
            let m = NSMutableString(string: text)
            m.replaceOccurrences(of: "\r\n", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
            m.replaceOccurrences(of: "\r", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
            return m as String
        }

        static func decode(_ data: Data, as encoding: TextEncoding? = nil) -> DecodedText? {
            var enc = encoding ?? detectEncoding(data)
            var body = data
            if !enc.bom.isEmpty, data.starts(with: enc.bom) { body = data.dropFirst(enc.bom.count) }
            if enc == .utf16LE || enc == .utf16BE, body.count % 2 != 0 { return nil }
            var decoded = String(data: body, encoding: enc.foundation)
            if decoded == nil, encoding == nil, enc == .windows1252 || enc == .macRoman {
                enc = .latin1
                decoded = String(data: body, encoding: .isoLatin1)
            }
            guard let raw = decoded else { return nil }
            let (ending, mixed) = detectLineEnding(raw)
            return DecodedText(text: normalize(raw), encoding: enc, lineEnding: ending, mixedLineEndings: mixed,
                               looksBinary: TextCodec.looksBinary(data))
        }
    }

    /// Decodes `bytes` both ways (detected and as each encoding given) and
    /// expects the same result.
    func same(_ bytes: [UInt8], as encodings: [TextEncoding?] = [nil, .utf8], _ note: String,
              sourceLocation: SourceLocation = #_sourceLocation) {
        let data = Data(bytes)
        for enc in encodings {
            // A leading UTF-8 BOM read as UTF-8: as `oneBOMOut`, not Foundation.
            if Self.leadingBOMReadAsUTF8(bytes, as: enc) {
                let rest = Data(bytes.dropFirst(3))
                let raw = Reference.isValidUTF8(rest) ? String(decoding: rest, as: UTF8.self) : nil
                oneBOMOut(bytes, as: enc, note, text: raw.map(Reference.normalize),
                          ending: raw.map { Reference.detectLineEnding($0).0 } ?? .lf, sourceLocation: sourceLocation)
                continue
            }
            let new = TextCodec.decode(data, as: enc), old = Reference.decode(data, as: enc)
            let label = "\(note) as \(enc.map(\.rawValue) ?? "detected")"
            #expect((new == nil) == (old == nil), "\(label): nil-ness", sourceLocation: sourceLocation)
            guard let new, let old else { continue }
            #expect(new.text == old.text, "\(label): text", sourceLocation: sourceLocation)
            #expect(new.encoding == old.encoding, "\(label): encoding", sourceLocation: sourceLocation)
            #expect(new.lineEnding == old.lineEnding, "\(label): ending", sourceLocation: sourceLocation)
            #expect(new.mixedLineEndings == old.mixedLineEndings, "\(label): mixed", sourceLocation: sourceLocation)
            #expect(new.looksBinary == old.looksBinary, "\(label): binary", sourceLocation: sourceLocation)
        }
    }

    /// Valid sequences (2, 3, 4 bytes) and invalid ones (overlong,
    /// surrogate, past U+10FFFF, stray continuation, truncated, bad
    /// continuation), each placed at every offset 0..<24 in ASCII filler,
    /// with the sequence also cut off by the end of the input.
    @Test func utf8ValidityAtEveryWordPosition() {
        let valid: [[UInt8]] = [[0xC3, 0xA9], [0xE2, 0x82, 0xAC], [0xF0, 0x9F, 0x98, 0x80], [0xEF, 0xBF, 0xBF], [0xF4, 0x8F, 0xBF, 0xBF]]
        let invalid: [[UInt8]] = [[0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF0, 0x80, 0x80, 0x80],
                                  [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0x80], [0xBF], [0xFF],
                                  [0xE2, 0x82], [0xE2, 0x41, 0x82], [0xF0, 0x9F, 0x98]]
        for seq in valid + invalid {
            for at in 0..<24 {
                let filler = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
                let bytes = Array(filler.prefix(at)) + seq + Array(filler.prefix(17))
                same(bytes, "\(seq) at \(at)")
                let cut = Array(filler.prefix(at)) + seq
                same(cut, "\(seq) ending at \(at)")
                #expect(TextCodec.isValidUTF8(Data(bytes)) == Reference.isValidUTF8(Data(bytes)), "\(seq) at \(at)")
                #expect(TextCodec.isValidUTF8(Data(cut)) == Reference.isValidUTF8(Data(cut)), "\(seq) cut at \(at)")
            }
        }
    }

    /// CR, LF, CRLF and a CRLF split across two 8-byte words, at every
    /// offset, alone and mixed, with ASCII and non-ASCII around them.
    @Test func lineEndingsAtEveryWordPosition() {
        let breaks: [[UInt8]] = [[10], [13], [13, 10], [13, 13, 10], [10, 13], [13, 10, 10], [13, 13]]
        for brk in breaks {
            for at in 0..<24 {
                let head = Array(String(repeating: "x", count: at).utf8)
                same(head + brk + Array("tail line".utf8), "\(brk) at \(at)")
                same(head + brk, "\(brk) ending at \(at)")
                same(Array("é".utf8) + head + brk + Array("ü\r\nend\n".utf8), "\(brk) at \(at) among non-ASCII")
            }
        }
        for text in ["a\nb\n", "a\r\nb\r\n", "a\rb\r", "no breaks", "a\r\nb\r\nc\n", "a\rb\rc\r\nd\n", "a\r\rb\n\n\r\n",
                     "\r", "\n", "\r\n", "\r\n\r\n\n", String(repeating: "line\r\n", count: 1000) + "x\n"] {
            same(Array(text.utf8), text.debugDescription)
            #expect(TextCodec.detectLineEnding(text) == Reference.detectLineEnding(text), "\(text.debugDescription)")
            #expect(TextCodec.normalizeLineEndings(text) == Reference.normalize(text), "\(text.debugDescription)")
        }
    }

    /// A UTF-8 BOM case where the decode is meant to differ from
    /// `Reference`: Foundation's "as UTF-8" keeps a leading BOM on macOS 15
    /// and drops it on macOS 26, and the old decode then saved without it.
    /// Exactly one leading BOM is left out of the text, on every macOS (a
    /// second one is text, U+FEFF), and the encoding is UTF-8 with BOM, so
    /// a save writes it back. Expected outright for text and encoding; the
    /// rest (line ending, mixed, binary, nil-ness) still as `Reference`.
    /// `text` nil: the bytes after the BOM aren't UTF-8, so nil.
    func oneBOMOut(_ bytes: [UInt8], as enc: TextEncoding?, _ note: String, text: String?, ending: LineEnding,
                   sourceLocation: SourceLocation = #_sourceLocation) {
        let data = Data(bytes)
        let label = "\(note) as \(enc.map(\.rawValue) ?? "detected")"
        let new = TextCodec.decode(data, as: enc), old = Reference.decode(data, as: enc)
        #expect((new == nil) == (old == nil), "\(label): nil-ness", sourceLocation: sourceLocation)
        #expect((new == nil) == (text == nil), "\(label): nil-ness as expected", sourceLocation: sourceLocation)
        guard let new, text != nil else { return }
        #expect(new.text == text, "\(label): text", sourceLocation: sourceLocation)
        #expect(new.encoding == .utf8BOM, "\(label): encoding", sourceLocation: sourceLocation)
        #expect(new.lineEnding == ending, "\(label): ending", sourceLocation: sourceLocation)
        #expect(!new.encodingGuessed, "\(label): not a guess", sourceLocation: sourceLocation)
        #expect(TextCodec.encodeDocument(new.text, encoding: new.encoding, lineEnding: new.lineEnding,
                                         lineBreaks: new.mixedLineEndings ? new.lineBreaks : nil) == data,
                "\(label): saved as it was", sourceLocation: sourceLocation)
        guard let old else { return }
        #expect(new.lineEnding == old.lineEnding, "\(label): ending", sourceLocation: sourceLocation)
        #expect(new.mixedLineEndings == old.mixedLineEndings, "\(label): mixed", sourceLocation: sourceLocation)
        #expect(new.looksBinary == old.looksBinary, "\(label): binary", sourceLocation: sourceLocation)
    }

    /// A UTF-8 BOM at the start read as UTF-8 by Foundation in `Reference`
    /// (whose BOM handling there differs by macOS): asked for as UTF-8, or
    /// a second BOM after the one a UTF-8-with-BOM decode drops itself.
    static func leadingBOMReadAsUTF8(_ bytes: [UInt8], as enc: TextEncoding?) -> Bool {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        guard bytes.starts(with: bom) else { return false }
        if enc == .utf8 { return true }
        return (enc == nil || enc == .utf8BOM) && bytes.dropFirst(3).starts(with: bom)
    }

    /// BOMs (UTF-8, UTF-16 LE/BE), a second UTF-8 BOM, a BOM with "as
    /// UTF-8", the empty file, a BOM alone, and every encoding chosen by
    /// hand. A leading UTF-8 BOM read as UTF-8 (`oneBOMOut`) is expected
    /// outright, not as Foundation, which differs by macOS there.
    @Test func bomsEmptyAndChosenEncodings() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let all: [TextEncoding?] = [nil] + TextEncoding.allCases.map { $0 }
        same([], as: all, "empty")
        same(bom, as: all.filter { $0 != .utf8 }, "UTF-8 BOM alone")
        oneBOMOut(bom, as: .utf8, "UTF-8 BOM alone", text: "", ending: .lf)
        same(bom + Array("hi\r\nthere".utf8), as: all.filter { $0 != .utf8 }, "UTF-8 BOM, CRLF")
        oneBOMOut(bom + Array("hi\r\nthere".utf8), as: .utf8, "UTF-8 BOM, CRLF", text: "hi\nthere", ending: .crlf)
        same(bom + bom + Array("double".utf8), as: all.filter { $0 != nil && $0 != .utf8 && $0 != .utf8BOM }, "two UTF-8 BOMs")
        for enc: TextEncoding? in [nil, .utf8, .utf8BOM] {
            oneBOMOut(bom + bom + Array("double".utf8), as: enc, "two UTF-8 BOMs", text: "\u{FEFF}double", ending: .lf)
        }
        same(Array("a".utf8) + bom + Array("b".utf8), as: all, "a BOM inside")
        same([0xFF, 0xFE, 0x61, 0x00, 0x0D, 0x00, 0x0A, 0x00], as: all, "UTF-16 LE BOM, CRLF")
        same([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x0D], as: all, "UTF-16 BE BOM, CR")
        same([0xFF, 0xFE, 0x61, 0x00, 0x62], as: all, "UTF-16 odd byte count")
        same(Array("caf\u{E9}".utf8), as: all, "UTF-8 é")
        same([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A], as: all, "Latin-1 é, CRLF")
        same([0x93, 0x71, 0x94, 0x0D], as: all, "Windows-1252 quotes, CR")
        same([0x64, 0x6F, 0x6E, 0xD5, 0x74], as: all, "Mac Roman apostrophe")
        same(Array("plain ascii text\n".data(using: .utf16LittleEndian)!), as: all, "UTF-16 LE without BOM")
        same([0x00, 0x01, 0x02, 0x0A, 0x7F, 0x1B], as: all, "binary-looking")
    }

    /// Malformed and truncated UTF-8 after one and after two leading
    /// BOMs (the BOM branch of the decode, which random inputs rarely
    /// reach with a bad payload): never text as any UTF-8, detected or
    /// picked, whatever the BOMs; the 8-bit encodings still read them as
    /// Foundation does (`same`), and so does every case's nil-ness.
    /// Expected outright: nil as UTF-8 (`oneBOMOut` with no text), and
    /// DocumentRead says it isn't text.
    @Test func malformedAndTruncatedAfterBOMs() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let all: [TextEncoding?] = [nil] + TextEncoding.allCases.map { $0 }
        let payloads: [([UInt8], String)] = [
            ([0x80] + Array("abc\n".utf8), "stray continuation first"),
            (Array("ab".utf8) + [0xC3], "a 2-byte character cut at the end"),
            (Array("ab".utf8) + [0xE2, 0x82], "a 3-byte character cut at the end"),
            (Array("ab".utf8) + [0xF0, 0x9F, 0x98], "a 4-byte character cut at the end"),
            ([0xE2, 0x82] + Array("\r\nx".utf8), "a 3-byte character cut before CRLF"),
            ([0xC0, 0x80], "overlong NUL"),
            (Array("a".utf8) + [0xED, 0xA0, 0x80] + Array("b".utf8), "a surrogate"),
            ([0xF4, 0x90, 0x80, 0x80], "past U+10FFFF"),
            ([0xFF, 0xFE] + Array("x".utf8), "FF FE after the BOM"),
            ([0xEF, 0xBB], "a BOM cut short after the BOM"),
            (Array("ok\r\n".utf8) + [0xE9] + Array("\n".utf8), "Latin-1 é in UTF-8 lines"),
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fastdecode-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (payload, what) in payloads {
            for (lead, n) in [(bom, "one BOM"), (bom + bom, "two BOMs")] {
                let bytes = lead + payload, note = "\(what) after \(n)"
                #expect(!Reference.isValidUTF8(Data(bytes.dropFirst(3))), "\(note): not UTF-8 after the first BOM")
                // Detected (the BOM says UTF-8 with BOM), UTF-8 and UTF-8 with BOM picked.
                for enc: TextEncoding? in [nil, .utf8, .utf8BOM] {
                    #expect(TextCodec.decode(Data(bytes), as: enc) == nil, "\(note) as \(enc?.rawValue ?? "detected"): nil")
                    #expect(TextCodec.decode(Data(bytes), as: enc, shareBytes: true) == nil,
                            "\(note) as \(enc?.rawValue ?? "detected"), shared: nil")
                    if Self.leadingBOMReadAsUTF8(bytes, as: enc) {
                        oneBOMOut(bytes, as: enc, note, text: nil, ending: .lf)
                    }
                    let url = dir.appendingPathComponent("bad.txt")
                    try Data(bytes).write(to: url)
                    #expect(throws: DocumentRead.LoadError.self, "\(note) as \(enc?.rawValue ?? "detected"): not text") {
                        try DocumentRead.read(url, encoding: enc)
                    }
                }
                same(bytes, as: all, note)
            }
        }
    }

    /// One long line (no break at all) and a long line split by CRLF, past
    /// the size where the text reads the file's bytes in place.
    @Test func hugeLines() {
        let n = TextCodec.sharedBytesMinimum + 13
        var line = [UInt8](repeating: 0x61, count: n)
        let d = TextCodec.decode(Data(line))!
        #expect(d.encoding == .utf8 && d.lineEnding == .lf && !d.mixedLineEndings)
        #expect((d.text as NSString).length == n)
        #expect(d.text.utf8.count == n && d.text.utf8.allSatisfy { $0 == 0x61 })
        line[n / 2] = 13
        line[n / 2 + 1] = 10
        line[n - 1] = 13
        let e = TextCodec.decode(Data(line))!
        let ns = e.text as NSString
        #expect(ns.length == n - 1)
        #expect(ns.character(at: n / 2) == 10 && ns.character(at: n / 2 + 1) == 0x61 && ns.character(at: n - 2) == 10)
        #expect(e.lineEnding == .crlf && e.mixedLineEndings)
        line[7] = 0xE9   // Latin-1 é: not UTF-8 any more
        let f = TextCodec.decode(Data(line))!
        #expect(f.encoding == .latin1 && (f.text as NSString).length == n - 1)
    }

    /// A large all-ASCII file with no CR, asked to (`shareBytes`), reads
    /// its bytes in place (no copy of the text); otherwise a copy. Seen by
    /// when the bytes are let go, never by changing them under a string:
    /// shared, they live as long as the text; copied, they go with `data`.
    @Test func largeASCIIReadsInPlace() {
        let line = Array("2026-11-24 INFO request id=12 status=200\n".utf8)
        let count = (TextCodec.sharedBytesMinimum / line.count + 1) * line.count
        func lines(_ n: Int) -> [UInt8] { (0..<n).map { line[$0 % line.count] } }
        /// Decodes `bytes` from a buffer of their own and reports whether the
        /// text still held that buffer once the data was let go.
        func decode(_ bytes: [UInt8], shareBytes: Bool) -> (text: NSString, shared: Bool) {
            final class Freed: @unchecked Sendable { var done = false }
            let freed = Freed()
            var text: NSString!
            autoreleasepool {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
                buffer.initialize(from: bytes, count: bytes.count)
                let data = Data(bytesNoCopy: buffer, count: bytes.count, deallocator: .custom { p, _ in
                    freed.done = true
                    p.deallocate()
                })
                text = TextCodec.decode(data, shareBytes: shareBytes)!.text as NSString
            }
            let shared = !freed.done
            #expect(text.length > 0)
            return (text, shared)
        }
        let big = lines(count)
        let shared = decode(big, shareBytes: true)
        #expect(shared.shared, "asked to, a large ASCII file is read in place")
        #expect(shared.text.length == count && shared.text.character(at: 11) == 0x49)   // "I" of INFO
        #expect(shared.text as String == String(decoding: big, as: UTF8.self))
        let copy = decode(big, shareBytes: false)
        #expect(!copy.shared, "not unless asked: a copy")
        #expect(copy.text as String == shared.text as String)
        // Not in place when it would need changing (CRLF), or when small.
        var crlf = big
        crlf[39] = 0x0D                       // "...200\r\n": byte 39 is the first line's last "0"
        let c = decode(crlf, shareBytes: true)
        #expect(!c.shared && c.text.length == count - 1 && c.text.character(at: 39) == 0x0A)
        let small = decode(lines(64), shareBytes: true)
        #expect(!small.shared && small.text.length == 64 && small.text.character(at: 13) == 0x46)
    }

    /// TextCodec.snapshot: the file's bytes in memory of their own, so the
    /// text read in place is the bytes read, whatever the file does next.
    @Test func snapshotIsNotTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fastdecode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.log")
        let line = Array("2026-11-24 INFO request id=12 status=200\n".utf8)
        let count = (TextCodec.sharedBytesMinimum / line.count + 1) * line.count
        let bytes = (0..<count).map { line[$0 % line.count] }
        try Data(bytes).write(to: url)
        let data = try TextCodec.snapshot(of: url)
        #expect(data == Data(bytes))
        let text = TextCodec.decode(data, shareBytes: true)!.text as NSString
        #expect(text.length == count && text.character(at: 11) == 0x49)
        // The file rewritten in place, same length: the text is what was read.
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: 11)
        try h.write(contentsOf: Data("W".utf8))
        try h.synchronize()
        try h.close()
        #expect(text.character(at: 11) == 0x49, "a write to the file doesn't show through the text")
        #expect(data[11] == 0x49)
        // Growing while read and empty files read whole; a missing one throws.
        #expect(try TextCodec.snapshot(of: url).count == count)
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try TextCodec.snapshot(of: empty).isEmpty)
        #expect(throws: CocoaError.self) { try TextCodec.snapshot(of: dir.appendingPathComponent("missing")) }
    }

    /// Random bytes biased towards the interesting ones: the new decode
    /// always agrees with the old.
    @Test func randomInputsAgree() {
        var rng = SystemRandomNumberGenerator()
        let pool: [UInt8] = [0x61, 0x62, 0x0A, 0x0D, 0x09, 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, 0x80, 0xBF, 0xED, 0xA0, 0x00, 0xFF, 0xFE, 0xEF, 0xBB]
        for k in 0..<3000 {
            let len = Int.random(in: 0..<40, using: &rng)
            let bytes = (0..<len).map { _ in pool.randomElement(using: &rng)! }
            same(bytes, "random #\(k) \(bytes)")
        }
    }

    /// Reload and Find in Files decode a mapped file: one rewritten in
    /// place between the scan and the CRLF conversion can have fewer CRLF
    /// pairs than the scan counted, so the conversion needs more room than
    /// it was given. It never writes past that room (the bytes after it
    /// keep their guard value), and the text comes from the bytes as they
    /// are now (0.5.4 QA, Codex review).
    @Test func crlfConversionNeverWritesPastItsRoom() {
        let raw = Array("ab\r\ncd\r\nef\rgh\n".utf8)   // 1 CR, CRLF pairs since gone
        let room = raw.count - 3                         // as if the scan counted 3 CRLF
        let guardBytes = 64
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: room + guardBytes)
        defer { out.deallocate() }
        out.initialize(repeating: 0xA5, count: room + guardBytes)
        var rec: TextCodec.BreakRecorder? = TextCodec.BreakRecorder(dominant: .crlf, ascii: true)
        let written = raw.withUnsafeBytes { TextCodec.lfOnly($0, into: out, capacity: room, recording: &rec) }
        #expect(written == nil, "too small: says so")
        #expect((0..<guardBytes).allSatisfy { out[room + $0] == 0xA5 }, "nothing written past the room")
        // Room enough: the whole conversion, as before.
        let fits = raw.withUnsafeBytes { TextCodec.lfOnly($0, into: out, capacity: raw.count) }
        #expect(fits == raw.count - 2 && String(decoding: UnsafeBufferPointer(start: out, count: fits ?? 0), as: UTF8.self) == "ab\ncd\nef\ngh\n")

        // A scan made before the rewrite (3 CRLF), the bytes after it (2 CRLF, a CR).
        let now = Data("one\r\ntwo\r\nthree\rfour\nfive".utf8)
        var stale = TextCodec.UTF8Scan()
        stale.crlf = 3
        stale.cr = 1
        stale.lf = 0
        let d = TextCodec.decodeUTF8(now, scan: stale, encoding: .utf8, looksBinary: false, shareBytes: false)
        #expect(d?.text == "one\ntwo\nthree\nfour\nfive", "the text of the bytes as they are now")
        #expect(d?.lineEnding == .crlf && d?.mixedLineEndings == true)
    }

    /// A path checked as a file and swapped for a FIFO before the
    /// snapshot opens it: opening it waited for a writer that never came,
    /// blocking the large-open queue (or a synchronous restore) forever.
    /// Now it is refused at once. A watchdog unblocks the read (opening
    /// the FIFO for writing) so the old code fails here instead of hanging.
    @Test func snapshotRefusesAFIFOWithoutWaiting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("swapped.log")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        final class Outcome: @unchecked Sendable { var result: Result<Data, Error>? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Thread {
            outcome.result = Result { try TextCodec.snapshot(of: fifo) }
            done.signal()
        }.start()
        let inTime = done.wait(timeout: .now() + 3) == .success
        #expect(inTime, "the snapshot of a FIFO came back without a writer")
        var finished = inTime
        if !inTime {
            // Let the stuck open (then read) finish: a writer that writes nothing.
            let w = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if w >= 0 { close(w) }
            finished = done.wait(timeout: .now() + 5) == .success
        }
        // Read only once the thread has signalled it's done with it.
        if finished {
            switch outcome.result {
            case .success?: Issue.record("a FIFO read as a file")
            case .failure(let error)?:
                let underlying = (error as? CocoaError)?.userInfo[NSUnderlyingErrorKey] as? POSIXError
                #expect(underlying?.code == .EFTYPE, "refused as not a regular file: \(error)")
            case nil: Issue.record("no outcome")
            }
        } else {
            Issue.record("the snapshot of a FIFO never came back")
        }
        // A regular file still reads, blocking reads and all.
        let file = dir.appendingPathComponent("plain.log")
        try Data("ok\n".utf8).write(to: file)
        #expect(try TextCodec.snapshot(of: file) == Data("ok\n".utf8))
    }

    /// Reload, reopening and Find in Files read a file's bytes into memory
    /// of their own before they're scanned and converted. Mapped, a
    /// same-size rewrite in place in between (the CRLF count kept, a lone
    /// CR added) gave the new bytes' text with the old scan's line-ending
    /// notes, which a later save wrote back; and a truncation faulted
    /// (0.5.4 QA, Codex review round 2). The rewrite here lands after the
    /// read: the text, the line endings and the search hit are all the
    /// bytes as read.
    @Test func readTextAndFindInFilesDecodeTheBytesAsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("log.txt")
        // 1 MiB, every line CRLF: big enough that Foundation would map it.
        var bytes = Data("needle\r\n".utf8)
        bytes.append(Data(String(repeating: "abcdef\r\n", count: 128 * 1024).utf8))
        try bytes.write(to: file)
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        // Same size, one CRLF still there, a lone CR added, the needle gone.
        let rewrite = Data("zzzzz\r\r\n".utf8)
        #expect(rewrite.count == 8)
        // Each rewrite must really happen: one that failed silently would
        // let the assertions below pass on the old bytes.
        final class Rewrites: @unchecked Sendable {
            let lock = NSLock()
            var done = 0
            var failures: [String] = []
            func note(_ error: Error?) {
                lock.lock(); defer { lock.unlock() }
                if let error { failures.append("\(error)") } else { done += 1 }
            }
            var count: Int { lock.lock(); defer { lock.unlock() }; return done }
            var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
        }
        let rewrites = Rewrites()
        let rewriteInPlace: @Sendable (URL) -> Void = { url in
            guard url.standardizedFileURL.resolvingSymlinksInPath().path == path else { return }
            do {
                let h = try FileHandle(forUpdating: file)
                try h.seek(toOffset: 0)
                try h.write(contentsOf: rewrite)
                try h.synchronize()
                try h.close()
                rewrites.note(nil)
            } catch {
                rewrites.note(error)
            }
        }
        func rewritten() throws -> Bool { try Data(contentsOf: file).prefix(8) == rewrite }
        let after = TextCodec.ReadHooks(after: rewriteInPlace)

        let d = try TextCodec.readText(at: file, hooks: after)
        #expect(rewrites.count == 1 && rewrites.errors.isEmpty, "rewritten after the read: \(rewrites.errors)")
        #expect(try rewritten(), "the file on disk changed")
        #expect(d?.text.hasPrefix("needle\nabcdef\n") == true, "the text of the bytes as read")
        #expect(d?.lineEnding == .crlf)
        #expect(d?.mixedLineEndings == false, "no lone CR noted that the bytes read don't have")
        #expect(d?.lineBreaks == nil)

        // The way a tab reads a file (open, Reload): the same.
        try bytes.write(to: file)
        let (doc, stamp) = try DocumentRead.read(file, hooks: after)
        #expect(rewrites.count == 2 && rewrites.errors.isEmpty, "rewritten after the document's read: \(rewrites.errors)")
        #expect(try rewritten(), "the file on disk changed")
        #expect(doc.text.hasPrefix("needle\nabcdef\n"), "the document's text is the bytes as read")
        #expect(doc.mixedLineEndings == false && doc.lineBreaks == nil, "no lone CR noted from the rewrite")
        #expect(stamp?.size == bytes.count)

        try bytes.write(to: file)
        final class Hits: @unchecked Sendable { var lines: [Int] = [] }
        let hits = Hits()
        // Errors come out: a search that failed isn't "no hits".
        _ = try FileSearch(FileSearchOptions(root: dir, query: "needle"), readHooks: after).run { hits.lines.append($0.line) }
        #expect(rewrites.count == 3 && rewrites.errors.isEmpty, "rewritten after the search's read: \(rewrites.errors)")
        #expect(try rewritten(), "the file on disk changed")
        #expect(hits.lines == [1], "Find in Files searched the bytes as read")

        // Checked as a file, swapped for a FIFO just before the read: Reload
        // and the search come back (refused, skipped) instead of waiting
        // for a writer forever. A watchdog opens the FIFO for writing so
        // a stuck read ends and the test fails rather than hangs.
        let swapForFIFO = TextCodec.ReadHooks(before: { url in
            guard url.standardizedFileURL.resolvingSymlinksInPath().path == path else { return }
            try? FileManager.default.removeItem(at: file)
            _ = mkfifo(file.path, 0o600)
        })
        func comesBack(_ what: String, _ body: @escaping @Sendable () -> Void) -> Bool {
            let done = DispatchSemaphore(value: 0)
            Thread { body(); done.signal() }.start()
            if done.wait(timeout: .now() + 3) == .success { return true }
            Issue.record("\(what) waited on a FIFO")
            let w = Darwin.open(file.path, O_WRONLY | O_NONBLOCK)
            if w >= 0 { close(w) }
            _ = done.wait(timeout: .now() + 5)
            return false
        }
        final class Box: @unchecked Sendable { var error: Error?; var hits = -1; var searchError: Error? }
        let box = Box()
        try bytes.write(to: file)
        let readBack = comesBack("Reload") {
            do { _ = try TextCodec.readText(at: file, hooks: swapForFIFO) } catch { box.error = error }
        }
        if readBack {
            // Refused as what it is: Foundation's read said "you don't have
            // permission to view it" (EACCES) for a FIFO.
            let underlying = (box.error as? CocoaError)?.userInfo[NSUnderlyingErrorKey] as? POSIXError
            #expect(underlying?.code == .EFTYPE, "a FIFO is refused as not a regular file: \(String(describing: box.error))")
        }

        try? FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        let searchBack = comesBack("Find in Files") {
            var n = 0
            do {
                _ = try FileSearch(FileSearchOptions(root: dir, query: "needle"), readHooks: swapForFIFO).run { _ in n += 1 }
            } catch {
                box.searchError = error
            }
            box.hits = n
        }
        if searchBack {
            #expect(box.searchError == nil, "the search itself didn't fail: \(String(describing: box.searchError))")
            #expect(box.hits == 0)
        }
    }

    /// Find in Files' size limit holds for the file as opened and as read,
    /// not only the size its directory walk saw: a file that grew (or was
    /// replaced by a larger one) since was read whole, however large
    /// (0.5.4 QA, triage round 2).
    @Test func findInFilesSizeLimitHoldsOnTheFileAsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("grows.log")
        try Data("needle\n".utf8).write(to: file)
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let big = Data(("needle\n" + String(repeating: "x", count: 64 * 1024)).utf8)
        final class Grown: @unchecked Sendable { var count = 0 }
        let grown = Grown()
        let grow = TextCodec.ReadHooks(before: { url in
            guard url.standardizedFileURL.resolvingSymlinksInPath().path == path else { return }
            if (try? big.write(to: file)) != nil { grown.count += 1 }
        })
        var hits = 0
        let search = FileSearch(FileSearchOptions(root: dir, query: "needle", maxFileSize: 1024), readHooks: grow)
        let summary = try search.run { _ in hits += 1 }
        #expect(grown.count == 1, "the file grew after the walk, before the read")
        #expect(hits == 0, "the grown file wasn't searched")
        #expect(summary.skippedLarge == 1, "it counts as too large")
        #expect(summary.filesSearched == 0)

        // At open: the size by the opened descriptor.
        #expect(throws: CocoaError.self) { try TextCodec.snapshot(of: file, maxBytes: 1024) }
        do {
            _ = try TextCodec.snapshot(of: file, maxBytes: 1024)
        } catch {
            #expect(TextCodec.isTooLarge(error))
        }
        #expect(try TextCodec.snapshot(of: file, maxBytes: big.count) == big, "at the limit it reads")
        // While read: a size seen at open that is less than the bytes there
        // (the file grew in between) never lets more than limit + 1 in.
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        do {
            let data = try TextCodec.readAll(fd, url: file, sizeHint: 8, limit: 1024)
            Issue.record("read \(data.count) bytes past a 1024-byte limit")
        } catch {
            #expect(TextCodec.isTooLarge(error), "refused as too large: \(error)")
        }
        _ = lseek(fd, 0, SEEK_SET)
        #expect(try TextCodec.readAll(fd, url: file, sizeHint: 8, limit: nil) == big, "unlimited, it grows to fit")
    }

    /// `maxBytes: Int.max` means no real limit: the ceiling saturates
    /// instead of trapping on `limit + 1` (Find in Files with
    /// `maxFileSize: Int.max` read every file that way; Sol round 2).
    @Test func anIntMaxLimitReadsWithoutTrapping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-maxint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tiny.txt")
        try Data("needle\n".utf8).write(to: file)
        #expect(try TextCodec.snapshot(of: file, maxBytes: Int.max) == Data("needle\n".utf8))
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(try TextCodec.readAll(fd, url: file, sizeHint: 7, limit: Int.max) == Data("needle\n".utf8))
        var hits = 0
        let summary = try FileSearch(FileSearchOptions(root: dir, query: "needle", maxFileSize: Int.max)).run { _ in hits += 1 }
        #expect(hits == 1)
        #expect(summary.filesSearched == 1)
    }

    /// A tab's read takes the file's stamp from the descriptor its bytes
    /// come from. From the path, before the read, a file replaced in
    /// between (an atomic save by another app, a link retargeted) gave the
    /// old file's stamp with the new file's text, so the next check saw
    /// no change (0.5.4 QA, follow round 2).
    @Test func documentReadStampIsTheFileItRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.txt")
        try Data("old text\n".utf8).write(to: file)
        let oldStamp = try #require(DiskStamp.of(file))
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let replacement = Data("a different, longer text\n".utf8)
        final class Swapped: @unchecked Sendable { var ok = false }
        let swapped = Swapped()
        let replace = TextCodec.ReadHooks(before: { url in
            guard url.standardizedFileURL.resolvingSymlinksInPath().path == path else { return }
            let other = dir.appendingPathComponent("other.txt")
            // Another inode put in its place, as an atomic save does.
            swapped.ok = (try? replacement.write(to: other)) != nil && rename(other.path, file.path) == 0
        })
        let (d, stamp) = try DocumentRead.read(file, hooks: replace)
        #expect(swapped.ok, "the file was replaced before the read")
        let now = try #require(DiskStamp.of(file))
        #expect(d.text == "a different, longer text\n")
        #expect(now.identity != oldStamp.identity, "another file")
        #expect(stamp?.identity == now.identity, "the stamp is the file the text came from")
        #expect(stamp?.size == replacement.count)
        #expect(!DiskStamp.changed(known: stamp, current: now))
    }
}

/// DecodedText.newlineCount, the line index's reservation hint: the "\n"
/// count of the decoded text for UTF-8 (LF, CRLF and lone CR each one,
/// at every position around the scan's 8-byte words, shared bytes and
/// copies alike); nil for the encodings decoded by Foundation.
@Suite struct NewlineCountHintTests {
    @Test func countsTheDecodedNewlines() {
        var inputs: [[UInt8]] = [[], Array("x".utf8), Array("a\n".utf8), Array("a\r\nb\rc\n".utf8), Array("\r\r\n\n\r".utf8),
                                 Array("é\r\nü\n😀\r".utf8), [0xEF, 0xBB, 0xBF] + Array("bom\r\nline\n".utf8)]
        for brk in [[UInt8]([10]), [13, 10], [13]] {
            for at in 0..<20 {
                inputs.append(Array(repeating: 0x61, count: at) + brk + Array(repeating: 0x62, count: 19 - at) + brk)
            }
        }
        // Long enough to share its bytes / use the ASCII malloc path.
        let big = String(repeating: "line of text\n", count: TextCodec.sharedBytesMinimum / 13 + 1)
        inputs.append(Array(big.utf8))
        inputs.append(Array(big.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        for bytes in inputs {
            for share in [false, true] {
                guard let d = TextCodec.decode(Data(bytes), shareBytes: share) else { Issue.record("decodes"); continue }
                let actual = (d.text as NSString).components(separatedBy: "\n").count - 1
                #expect(d.newlineCount == actual, "\(bytes.prefix(24)) share \(share): \(d.newlineCount ?? -1) vs \(actual)")
                let hinted = LineIndex(d.text as NSString, expectedLineCount: d.newlineCount.map { $0 + 1 })
                #expect(hinted.starts == LineIndex(d.text as NSString).starts && hinted.lineCount == actual + 1)
            }
        }
        let utf16 = TextCodec.decode(Data([0xFF, 0xFE, 0x61, 0x00, 0x0A, 0x00]))
        #expect(utf16?.text == "a\n" && utf16?.newlineCount == nil)
        let latin1 = TextCodec.decode(Data([0x61, 0xE9, 0x0A]), as: .latin1)
        #expect(latin1?.text == "aé\n" && latin1?.newlineCount == nil)
    }
}
