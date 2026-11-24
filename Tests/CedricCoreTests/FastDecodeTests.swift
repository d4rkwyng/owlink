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

    /// BOMs (UTF-8, UTF-16 LE/BE), a second UTF-8 BOM, a BOM with "as
    /// UTF-8" (Foundation drops it), the empty file, a BOM alone, and every
    /// encoding chosen by hand.
    @Test func bomsEmptyAndChosenEncodings() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let all: [TextEncoding?] = [nil] + TextEncoding.allCases.map { $0 }
        same([], as: all, "empty")
        same(bom, as: all, "UTF-8 BOM alone")
        same(bom + Array("hi\r\nthere".utf8), as: all, "UTF-8 BOM, CRLF")
        same(bom + bom + Array("double".utf8), as: all, "two UTF-8 BOMs")
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
}
