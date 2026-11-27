import Foundation
import Testing
@testable import CedricCore

/// Open then save, with no edit, writes the file back byte for byte, BOM
/// included. The same path a tab takes: DocumentRead.read (snapshot,
/// TextCodec.decode), the document's format as EditorDocument.apply keeps
/// it (encoding, line ending, a mixed file's own breaks), the save's
/// encoding (TextCodec.encodeDocument, EditorDocument.encoded) and
/// DocumentWrite. Exactly one leading UTF-8 BOM is left out of the text,
/// on every macOS (a second one is text, U+FEFF), and the save writes it
/// back: detected, or the file reopened by hand as UTF-8.
@Suite struct BOMRoundTripTests {
    static let bom8: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// A file of `bytes` opened (as `encoding`, or detected) and saved as
    /// a tab would, unedited; returns what was decoded and the bytes the
    /// save left on disk.
    func openAndSave(_ bytes: [UInt8], as encoding: TextEncoding?, shareBytes: Bool,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> (DecodedText, [UInt8])? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bom-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("file.txt")
        try Data(bytes).write(to: url)
        let (d, stamp) = try DocumentRead.read(url, encoding: encoding, shareBytes: shareBytes)
        // EditorDocument.apply: a mixed file's breaks are kept, else only the ending.
        let breaks = d.mixedLineEndings ? d.lineBreaks : nil
        let data = try #require(TextCodec.encodeDocument(d.text, encoding: d.encoding, lineEnding: d.lineEnding,
                                                         lineBreaks: breaks), sourceLocation: sourceLocation)
        try DocumentWrite.write(data, to: url, expecting: stamp)
        return (d, [UInt8](try Data(contentsOf: url)))
    }

    /// `bytes` opened (each of `encodings`, both ways of sharing) and saved
    /// unedited come back the same bytes; `text`, when given, is the text
    /// a detected open shows.
    func roundTrips(_ bytes: [UInt8], as encodings: [TextEncoding?], _ note: String, text: String? = nil,
                    encoding: TextEncoding? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for enc in encodings {
            for share in [false, true] {
                let label = "\(note) as \(enc.map(\.rawValue) ?? "detected")\(share ? ", shared" : "")"
                guard let (d, saved) = try openAndSave(bytes, as: enc, shareBytes: share, sourceLocation: sourceLocation) else { continue }
                #expect(saved == bytes, "\(label): saved bytes", sourceLocation: sourceLocation)
                if enc == nil, let text {
                    #expect(d.text == text, "\(label): text", sourceLocation: sourceLocation)
                }
                if enc == nil, let encoding {
                    #expect(d.encoding == encoding, "\(label): encoding", sourceLocation: sourceLocation)
                }
            }
        }
    }

    @Test func utf8BOMFilesSaveAsTheyWere() throws {
        let b = Self.bom8
        // By hand: UTF-8 (the BOM kept, as the encoding with one), with a
        // BOM, and 8-bit encodings that read the BOM's bytes as letters.
        let byHand: [TextEncoding?] = [nil, .utf8, .utf8BOM, .latin1, .windows1252, .macRoman]
        try roundTrips(b + Array("one\ntwo\n".utf8), as: byHand, "UTF-8 BOM, LF", text: "one\ntwo\n", encoding: .utf8BOM)
        try roundTrips(b + Array("one\r\ntwo\r\n".utf8), as: byHand, "UTF-8 BOM, CRLF", text: "one\ntwo\n", encoding: .utf8BOM)
        try roundTrips(b + Array("one\r\ntwo\nthree\rfour\r\n".utf8), as: byHand, "UTF-8 BOM, mixed",
                       text: "one\ntwo\nthree\nfour\n", encoding: .utf8BOM)
        try roundTrips(b + b + Array("double\n".utf8), as: byHand, "two UTF-8 BOMs", text: "\u{FEFF}double\n", encoding: .utf8BOM)
        try roundTrips(b + b + b + Array("triple\r\n".utf8), as: byHand, "three UTF-8 BOMs, CRLF",
                       text: "\u{FEFF}\u{FEFF}triple\n", encoding: .utf8BOM)
        try roundTrips(b, as: byHand, "UTF-8 BOM alone", text: "", encoding: .utf8BOM)
        try roundTrips(b + b, as: byHand, "two UTF-8 BOMs alone", text: "\u{FEFF}", encoding: .utf8BOM)
        try roundTrips(b + Array("caf\u{E9} \u{2603}\r\n".utf8), as: [nil, .utf8, .utf8BOM], "UTF-8 BOM, non-ASCII",
                       text: "caf\u{E9} \u{2603}\n", encoding: .utf8BOM)
        // A BOM that isn't at the start is text, and so is the file without one.
        try roundTrips(Array("a".utf8) + b + Array("b\n".utf8), as: [nil, .utf8], "a BOM inside",
                       text: "a\u{FEFF}b\n", encoding: .utf8)
        try roundTrips(Array("plain\r\n".utf8), as: [nil, .utf8], "no BOM", text: "plain\n", encoding: .utf8)
    }

    @Test func utf16BOMFilesSaveAsTheyWere() throws {
        func le(_ s: String) -> [UInt8] { [UInt8](s.data(using: .utf16LittleEndian)!) }
        func be(_ s: String) -> [UInt8] { [UInt8](s.data(using: .utf16BigEndian)!) }
        let leBOM: [UInt8] = [0xFF, 0xFE], beBOM: [UInt8] = [0xFE, 0xFF]
        try roundTrips(leBOM + le("one\ntwo\n"), as: [nil, .utf16LE], "UTF-16 LE BOM, LF", text: "one\ntwo\n", encoding: .utf16LE)
        try roundTrips(leBOM + le("one\r\ntwo\r\n"), as: [nil, .utf16LE], "UTF-16 LE BOM, CRLF", text: "one\ntwo\n", encoding: .utf16LE)
        try roundTrips(leBOM + le("caf\u{E9}\r\n\u{1F600}\r\n"), as: [nil, .utf16LE], "UTF-16 LE BOM, non-BMP, CRLF",
                       text: "caf\u{E9}\n\u{1F600}\n", encoding: .utf16LE)
        try roundTrips(beBOM + be("one\ntwo\n"), as: [nil, .utf16BE], "UTF-16 BE BOM, LF", text: "one\ntwo\n", encoding: .utf16BE)
        try roundTrips(beBOM + be("one\r\ntwo\r\n"), as: [nil, .utf16BE], "UTF-16 BE BOM, CRLF", text: "one\ntwo\n", encoding: .utf16BE)
        try roundTrips(leBOM, as: [nil, .utf16LE], "UTF-16 LE BOM alone", text: "", encoding: .utf16LE)
        try roundTrips(beBOM, as: [nil, .utf16BE], "UTF-16 BE BOM alone", text: "", encoding: .utf16BE)
        // A second BOM is text (U+FEFF), as in UTF-8.
        try roundTrips(leBOM + le("\u{FEFF}two\n"), as: [nil, .utf16LE], "two UTF-16 LE BOMs",
                       text: "\u{FEFF}two\n", encoding: .utf16LE)
        try roundTrips(beBOM + be("\u{FEFF}two\n"), as: [nil, .utf16BE], "two UTF-16 BE BOMs",
                       text: "\u{FEFF}two\n", encoding: .utf16BE)
    }

    /// Past the size where a tab's text reads the file's bytes in place
    /// (`sharedBytesMinimum`: all ASCII after the BOM, no CR), and where
    /// CRLF is converted into a buffer of its own: still the same bytes.
    @Test func largeUTF8BOMFilesSaveAsTheyWere() throws {
        let line = Array("2026-11-24 INFO request id=12 status=200\n".utf8)
        let count = (TextCodec.sharedBytesMinimum / line.count + 1) * line.count
        let body = (0..<count).map { line[$0 % line.count] }
        let b = Self.bom8
        for (bytes, note, first) in [(b + body, "large, BOM, LF", "2026"), (b + b + body, "large, two BOMs, LF", "\u{FEFF}202")] {
            for enc: TextEncoding? in [nil, .utf8] {
                let (d, saved) = try #require(try openAndSave(bytes, as: enc, shareBytes: true))
                #expect(saved == bytes, "\(note) as \(enc?.rawValue ?? "detected"): saved bytes")
                #expect(d.encoding == .utf8BOM && d.text.hasPrefix(first), "\(note) as \(enc?.rawValue ?? "detected")")
            }
        }
        var crlf = [UInt8]()
        crlf.reserveCapacity(body.count + body.count / line.count)
        for c in body { if c == 10 { crlf.append(13) }; crlf.append(c) }
        let (d, saved) = try #require(try openAndSave(b + crlf, as: nil, shareBytes: true))
        #expect(saved == b + crlf, "large, BOM, CRLF: saved bytes")
        #expect(d.encoding == .utf8BOM && d.lineEnding == .crlf && d.text.hasPrefix("2026"))
    }
}
