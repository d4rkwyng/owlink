import Foundation
import Testing
@testable import CedricCore

/// 0.6.1 bug 2: a sidebar click on a binary file (a pcap, for example)
/// must not decode the whole file into text before the tab is shown.
/// `TextCodec.decodeForOpen` sniffs `looksBinary` on the first 8 KB and
/// returns empty text (Open Anyway decodes later with `decode`).
@Suite struct BinaryOpenDecodeTests {
    /// libpcap little-endian magic, then bytes with NULs so the first 8 KB
    /// look binary.
    static func pcapLike(_ bytes: Int, seed: UInt64 = 70) -> Data {
        var d = Data([0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0x7F, 0, 0, 0])
        var s = seed
        while d.count < bytes {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            var v = s
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0.prefix(min(8, bytes - d.count))) }
        }
        return d
    }

    @Test func looksBinaryOnAPcapPrefix() {
        let data = Self.pcapLike(5_000_000)
        #expect(TextCodec.looksBinary(data))
        #expect(TextCodec.looksBinary(data.prefix(TextCodec.binarySample)))
    }

    @Test func decodeForOpenDoesNotMaterializeTextForABinaryFile() {
        let data = Self.pcapLike(2_000_000)
        let opened = TextCodec.decodeForOpen(data)
        #expect(opened != nil)
        #expect(opened?.looksBinary == true)
        #expect(opened?.text.isEmpty == true,
                "a binary file is not decoded into text until Open Anyway (got \(opened?.text.count ?? -1) characters)")
    }

    @Test func decodeStillProducesTextForOpenAnyway() {
        let data = Self.pcapLike(8_192 * 2)
        let forced = TextCodec.decode(data)
        #expect(forced?.looksBinary == true)
        #expect((forced?.text.count ?? 0) > 1000, "Open Anyway still decodes the bytes as text")
    }

    @Test func decodeForOpenLeavesATextFileAlone() {
        let data = Data(String(repeating: "access point channel 6 rssi=-70\n", count: 200).utf8)
        let opened = TextCodec.decodeForOpen(data)
        let full = TextCodec.decode(data)
        #expect(opened?.looksBinary == false)
        #expect(opened?.text == full?.text)
        #expect(opened?.encoding == full?.encoding)
        #expect(opened?.lineEnding == full?.lineEnding)
    }

    /// TIMING SENSITIVE: decodeForOpen of a 5 MB pcap-like buffer must stay
    /// near a looksBinary sniff, not a full 8-bit decode. Generous margin
    /// (Timing.best, scaled CPU plus a wall-clock guard).
    @Test func decodeForOpenOfALargeBinaryFileStaysUnderBudget() {
        let data = Self.pcapLike(5_000_000)
        let r = Timing.best(of: 5) {
            let d = TextCodec.decodeForOpen(data)
            #expect(d?.looksBinary == true)
            #expect(d?.text.isEmpty == true)
        }
        // A sniff of 8 KB is well under 1 ms on an M-series Mac; 20 ms
        // scaled and a 2 s wall guard leave room for a loaded CI runner.
        #expect(r.scaled < 0.020, "5 MB binary decodeForOpen: \(r.description)")
        #expect(r.wall < 2, "5 MB binary decodeForOpen: \(r.description)")
    }

    // MARK: DocumentRead (the open path's own call)

    private func file(_ data: Data, _ name: String) throws -> (dir: URL, url: URL) {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return (dir, url)
    }

    /// The open path (`forOpen: true`, no encoding): a binary file is
    /// read and stamped but not decoded.
    @Test func documentReadForOpenSkipsTheDecodeOfABinaryFile() throws {
        let data = Self.pcapLike(64_000)
        let f = try file(data, "capture.pcap")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (d, stamp) = try DocumentRead.read(f.url, forOpen: true)
        #expect(d.looksBinary)
        #expect(d.text.isEmpty)
        #expect(stamp != nil)
        // Open Anyway's read (no forOpen): the same file, decoded.
        let (full, _) = try DocumentRead.read(f.url)
        #expect(full.looksBinary)
        #expect(full.text.utf16.count > 30_000, "Open Anyway decodes it (got \(full.text.utf16.count) UTF-16 units)")
    }

    /// An encoding asked for (Reload, Revert, an encoding reopen, a
    /// restored tab) is always decoded, `forOpen` or not: the skip is
    /// only for a first open that detects the encoding.
    @Test func documentReadWithAnExplicitEncodingDecodesABinaryFileEvenForOpen() throws {
        let data = Self.pcapLike(64_000)
        let f = try file(data, "capture.pcap")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        for enc in [TextEncoding.macRoman, .latin1] {
            let (d, _) = try DocumentRead.read(f.url, encoding: enc, forOpen: true)
            let plain = try DocumentRead.read(f.url, encoding: enc).0
            #expect(d.encoding == enc)
            #expect(d.text.utf16.count > 30_000, "\(enc): decoded, not skipped (got \(d.text.utf16.count) UTF-16 units)")
            #expect(d.text == plain.text, "\(enc): the same text with and without forOpen")
            #expect(d.lineEnding == plain.lineEnding && d.mixedLineEndings == plain.mixedLineEndings)
        }
        // Bytes the encoding asked for has no characters for (Windows-1252
        // leaves 0x81 and four more undefined): the decode is tried and
        // says "not text", forOpen or not. A skipped decode returned
        // empty text and no error.
        let undefined = Data([0x00, 0x81, 0x8D, 0x0A]) + data
        let h = try file(undefined, "undefined.bin")
        defer { try? FileManager.default.removeItem(at: h.dir) }
        #expect(TextCodec.decode(undefined, as: .windows1252) == nil)
        for forOpen in [true, false] {
            #expect(performing: { _ = try DocumentRead.read(h.url, encoding: .windows1252, forOpen: forOpen) },
                    throws: { if case DocumentRead.LoadError.notText = $0 { return true } else { return false } })
        }
        // Valid UTF-8 with NUL bytes: binary by the sniff, text when asked for as UTF-8.
        let nul = Data("a\u{0}b\r\nc\u{0}\r\n".utf8)
        #expect(TextCodec.looksBinary(nul))
        let g = try file(nul, "nul.bin")
        defer { try? FileManager.default.removeItem(at: g.dir) }
        #expect(try DocumentRead.read(g.url, forOpen: true).0.text.isEmpty)
        for enc in [TextEncoding.utf8, .utf8BOM] {
            let (d, _) = try DocumentRead.read(g.url, encoding: enc, forOpen: true)
            #expect(d.text == "a\u{0}b\nc\u{0}\n", "\(enc): \(d.text.debugDescription)")
            #expect(d.lineEnding == .crlf)
        }
    }

    /// Text that isn't UTF-8 opens as text through the open path: UTF-16
    /// (with a BOM, detected; without, asked for) and an 8-bit file.
    @Test func documentReadForOpenDecodesUTF16AndEightBitText() throws {
        let text = "Hello from UTF-16\nsecond line: caf\u{E9}\n"
        let le = text.data(using: .utf16LittleEndian)!
        let be = text.data(using: .utf16BigEndian)!
        let cases: [(name: String, data: Data, ask: TextEncoding?, want: TextEncoding)] = [
            ("UTF-16 LE with a BOM, detected", Data([0xFF, 0xFE]) + le, nil, .utf16LE),
            ("UTF-16 BE with a BOM, detected", Data([0xFE, 0xFF]) + be, nil, .utf16BE),
            ("UTF-16 LE with a BOM, asked for", Data([0xFF, 0xFE]) + le, .utf16LE, .utf16LE),
            ("UTF-16 LE without a BOM, asked for", le, .utf16LE, .utf16LE),
            ("UTF-16 BE without a BOM, asked for", be, .utf16BE, .utf16BE),
            ("Latin-1, asked for", text.data(using: .isoLatin1)!, .latin1, .latin1),
        ]
        for c in cases {
            let f = try file(c.data, "text.txt")
            defer { try? FileManager.default.removeItem(at: f.dir) }
            let (d, _) = try DocumentRead.read(f.url, encoding: c.ask, forOpen: true)
            #expect(d.text == text, "\(c.name): \(d.text.debugDescription)")
            #expect(d.encoding == c.want, "\(c.name): \(d.encoding)")
            #expect(!d.looksBinary, "\(c.name): not held as binary")
        }
    }
}
