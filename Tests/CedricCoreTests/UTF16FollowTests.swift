import Foundation
import Testing
@testable import CedricCore

/// 0.5.4 leftover 2: Follow File's UTF-16 appends were decoded by
/// Foundation (`String(data:encoding:)`), whose handling of a U+FEFF is up
/// to the macOS it runs on (its UTF-8 decoding drops a leading one on
/// macOS 26). They now go through TextCodec.decodeUTF16, the project's own:
/// every U+FEFF after the file's BOM is text, a surrogate not in a pair is
/// refused, an odd byte or a high surrogate at the end is held for the
/// next append. These pin that, LE and BE, including a whole Follow and an
/// unedited save written back byte for byte.
@Suite struct UTF16FollowTests {
    static func units(_ s: String, bigEndian: Bool) -> [UInt8] {
        s.utf16.flatMap { u -> [UInt8] in
            let hi = UInt8(u >> 8), lo = UInt8(u & 0xFF)
            return bigEndian ? [hi, lo] : [lo, hi]
        }
    }
    static func scalars(_ s: String?) -> [UInt32]? { s.map { $0.unicodeScalars.map(\.value) } }

    @Test(arguments: [false, true])
    func theDecoderKeepsEveryFEFFAndRefusesLoneSurrogates(bigEndian: Bool) {
        func d(_ b: [UInt8]) -> String? { TextCodec.decodeUTF16(Data(b), bigEndian: bigEndian) }
        func u(_ s: String) -> [UInt8] { Self.units(s, bigEndian: bigEndian) }
        func unit(_ v: UInt16) -> [UInt8] { bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)] }
        #expect(Self.scalars(d(u("\u{FEFF}x"))) == [0xFEFF, 0x78], "a U+FEFF that starts an append is text")
        #expect(Self.scalars(d(u("\u{FEFF}"))) == [0xFEFF], "on its own too")
        #expect(Self.scalars(d(u("a\u{FEFF}\u{FEFF}b"))) == [0x61, 0xFEFF, 0xFEFF, 0x62])
        #expect(Self.scalars(d(unit(0xFFFE) + u("a"))) == [0xFFFE, 0x61], "the other byte order's BOM is text too")
        #expect(d(u("😀")) == "😀", "a surrogate pair")
        #expect(d(unit(0xD83D)) == nil, "a high surrogate at the end: not yet text")
        #expect(d(unit(0xD83D) + u("a")) == nil, "a high surrogate before a non-surrogate")
        #expect(d(unit(0xDE00) + u("a")) == nil, "a low surrogate on its own")
        #expect(d(unit(0xD83D) + unit(0xD83D) + unit(0xDE00)) == nil, "two highs")
        #expect(d(u("a") + [0x00]) == nil, "an odd byte count")
        #expect(d([]) == "")
        // What Foundation gives on this Mac, for the record (not relied on).
        let enc: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        for b in [u("\u{FEFF}x"), u("a\u{FEFF}"), u("😀"), unit(0xFFFE)] {
            #expect(Self.scalars(String(data: Data(b), encoding: enc)) == Self.scalars(d(b)), "same as Foundation here: \(b)")
        }
    }

    /// FileTail's append path takes the decoder (not Foundation) for UTF-16,
    /// and cuts at whole characters (decodePrefix): a half pair is held.
    @Test(arguments: [TextEncoding.utf16LE, .utf16BE])
    func appendsCutAtWholeCharacters(enc: TextEncoding) throws {
        let be = enc == .utf16BE
        let pair = Self.units("😀", bigEndian: be)
        #expect(Self.scalars(FileTail.decodeAppended(Data(Self.units("\u{FEFF}", bigEndian: be)), enc)) == [0xFEFF])
        let (s, used) = try #require(FileTail.decodePrefix(Data(Self.units("a", bigEndian: be) + pair.prefix(2)), enc) {
            FileTail.decodeAppended($0, enc)
        })
        #expect(s == "a" && used == 2, "the high surrogate is held for the next append")
        let (s3, used3) = try #require(FileTail.decodePrefix(Data(Self.units("a", bigEndian: be) + pair.prefix(3)), enc) {
            FileTail.decodeAppended($0, enc)
        })
        #expect(s3 == "a" && used3 == 2, "and with half of the low one after it")
        // A lone low surrogate with text after it is never text (held
        // alone, it is all held: no whole character yet, as for any start).
        let lowAlone: [UInt8] = be ? [0xDE, 0x00] : [0x00, 0xDE]
        let held = try #require(FileTail.decodePrefix(Data(lowAlone), enc) { FileTail.decodeAppended($0, enc) })
        #expect(held.0 == "" && held.1 == 0, "alone: held, nothing shown")
        #expect(FileTail.decodePrefix(Data(lowAlone + Self.units("b", bigEndian: be)), enc) { FileTail.decodeAppended($0, enc) } == nil,
                "with text after it: not text")
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(FileTail.Event, FileTail.Shown)] = []
        func add(_ e: FileTail.Event, _ s: FileTail.Shown) { lock.lock(); list.append((e, s)); lock.unlock() }
        var all: [(FileTail.Event, FileTail.Shown)] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// A whole Follow: the file starts with its BOM (and maybe text), each
    /// write appended on its own, then Follow stopped and the tab saved
    /// unedited: the text shown, and the bytes written back, as the file.
    @Test(arguments: [TextEncoding.utf16LE, .utf16BE])
    func followedUTF16AppendsAreShownAndSavedByteForByte(enc: TextEncoding) throws {
        let be = enc == .utf16BE
        func u(_ s: String) -> [UInt8] { Self.units(s, bigEndian: be) }
        let bom = u("\u{FEFF}")
        let pair = u("😀")
        // (case, the file when Follow starts, the writes, the text shown after)
        let cases: [(String, [UInt8], [[UInt8]], String)] = [
            ("BOM, then a second BOM alone, then x", bom, [bom, u("x")], "\u{FEFF}x"),
            ("BOM+text, then BOM+x", bom + u("a\n"), [bom + u("x")], "a\n\u{FEFF}x"),
            ("BOM, then a BOM split 1+1", bom, [Array(bom.prefix(1)), Array(bom.suffix(1)) + u("x")], "\u{FEFF}x"),
            ("BOM, then a pair split 2+2", bom, [Array(pair.prefix(2)), Array(pair.suffix(2))], "😀"),
            ("BOM, then a pair split 1+3", bom, [Array(pair.prefix(1)), Array(pair.suffix(3))], "😀"),
            ("BOM, then a pair split 3+1, then a line", bom, [Array(pair.prefix(3)), Array(pair.suffix(1)), u("!\n")], "😀!\n"),
            ("BOM, then FFFE and text", bom, [u("\u{FFFE}b\n")], "\u{FFFE}b\n"),
            ("BOM, then CRLF split across writes", bom + u("a"), [u("\r"), u("\nb\n")], "a\nb\n"),
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-utf16-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (note, start, writes, shown) in cases {
            let url = dir.appendingPathComponent("u16.log")
            try Data(start).write(to: url)
            let (data, stamp) = try FileTail.readStamped(url)
            let (d, used) = try #require(FileTail.decodeWhole(data, as: enc))
            #expect(d.encoding == enc, "\(note): opened as \(enc)")
            var text = d.text
            var ending = d.lineEnding
            var breaks: LineBreaks? = d.mixedLineEndings ? d.lineBreaks : nil
            let events = Events()
            let callbacks = DispatchQueue(label: "utf16-follow")
            let tail = FileTail(url: url, encoding: enc, offset: UInt64(used), held: UInt64(data.count - used),
                                callbackQueue: callbacks, startedFrom: stamp, lineEnding: d.lineEnding,
                                stamped: { events.add($0, $1) })
            tail.start()
            var applied = 0
            var all = start
            func catchUp() {
                tail.poll()
                _ = tail.isWatching
                callbacks.sync {}
                let got = events.all
                for (e, s) in got[applied...] {
                    switch e {
                    case .appended(let a):
                        if let odd = s.lineBreaks { breaks = breaks ?? LineBreaks(dominant: ending); breaks?.append(odd, at: (text as NSString).length) }
                        text += a
                    case .reset(let r):
                        if let le = s.lineEnding { ending = le }
                        breaks = s.lineBreaks
                        text = r
                    }
                }
                applied = got.count
            }
            catchUp()
            for w in writes {
                let fh = try FileHandle(forWritingTo: url)
                try fh.seekToEnd()
                try fh.write(contentsOf: Data(w))
                try fh.close()
                all += w
                catchUp()
            }
            tail.stop()
            #expect(Self.scalars(text) == Self.scalars(shown), "\(note) [\(enc)]: text")
            #expect(events.all.last?.1.bytes == UInt64(all.count), "\(note) [\(enc)]: every byte shown")
            #expect(!events.all.contains { if case .reset = $0.0 { return true }; return false }, "\(note) [\(enc)]: appends only")
            let saved = try #require(DocumentFormat(encoding: enc, lineEnding: ending, lineBreaks: breaks).encoded(text))
            #expect([UInt8](saved) == all, "\(note) [\(enc)]: saved bytes")
        }
    }

    /// A lone surrogate appended isn't text: Follow skips it and stops
    /// claiming the file's size (lossy), rather than showing U+FFFD or
    /// dropping it while stamping the bytes as shown.
    @Test(arguments: [TextEncoding.utf16LE, .utf16BE])
    func aLoneSurrogateAppendedIsSkippedAndLossy(enc: TextEncoding) throws {
        let be = enc == .utf16BE
        func unit(_ v: UInt16) -> [UInt8] { be ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-utf16-lone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("u16.log")
        let start = unit(0xFEFF) + Self.units("a", bigEndian: be)
        try Data(start).write(to: url)
        let events = Events()
        let callbacks = DispatchQueue(label: "utf16-lone")
        let tail = FileTail(url: url, encoding: enc, offset: UInt64(start.count), callbackQueue: callbacks) { events.add($0, $1) }
        tail.start()
        defer { tail.stop() }
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(unit(0xDE00) + Self.units("b", bigEndian: be)))
        try fh.close()
        tail.poll()
        _ = tail.isWatching
        callbacks.sync {}
        #expect(!events.all.contains { if case .appended(let s) = $0.0 { return s.contains("\u{FFFD}") || s.contains("b") }; return false },
                "nothing shown for bytes that aren't text")
    }
}
