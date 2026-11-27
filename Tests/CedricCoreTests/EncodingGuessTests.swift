import Foundation
import Testing
@testable import CedricCore

/// Not valid UTF-8: the 8-bit encoding is marked as Owlink's guess.
@Suite struct EncodingGuessTests {
    @Test func invalidUTF8IsAGuess() {
        // "café" in Latin-1, then ÿþ: the QA's invalid-utf8.txt.
        let d = TextCodec.decode(Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF, 0xFE, 0x0A]))
        #expect(d?.encoding == .latin1 && d?.encodingGuessed == true)
        // Windows-1252 and Mac Roman guesses too.
        #expect(TextCodec.decode(Data([0x93, 0x68, 0x69, 0x94]))?.encodingGuessed == true)
        let mac = TextCodec.decode(Data("caf".utf8) + Data([0x8E]) + Data(", don".utf8) + Data([0xD5]) + Data("t\n".utf8))
        #expect(mac?.encoding == .macRoman && mac?.encodingGuessed == true)
        // Windows-1252 guessed from the sample, Latin-1 after a byte it can't decode: still a guess.
        var bytes = [UInt8](repeating: 0x61, count: 70_000)
        bytes[5] = 0x93; bytes[69_000] = 0x81
        let fallback = TextCodec.decode(Data(bytes))
        #expect(fallback?.encoding == .latin1 && fallback?.encodingGuessed == true)
    }

    @Test func knownEncodingsAreNot() {
        #expect(TextCodec.decode(Data("plain ascii\n".utf8))?.encodingGuessed == false)
        #expect(TextCodec.decode(Data("héllo".utf8))?.encodingGuessed == false)
        #expect(TextCodec.decode(Data())?.encodingGuessed == false)
        #expect(TextCodec.decode(Data([0xEF, 0xBB, 0xBF, 0xE9]), as: .latin1)?.encodingGuessed == false)
        #expect(TextCodec.decode(TextCodec.encode("é", encoding: .utf16LE, lineEnding: .lf)!)?.encodingGuessed == false)
        #expect(TextCodec.decode(TextCodec.encode("é", encoding: .utf16BE, lineEnding: .lf)!)?.encodingGuessed == false)
        // Asked for by name (Reopen with Encoding, a session's encoding): never a guess.
        #expect(TextCodec.decode(Data([0x63, 0xE9]), as: .latin1)?.encodingGuessed == false)
        #expect(TextCodec.decode(Data([0x63, 0xE9]), as: .macRoman)?.encodingGuessed == false)
    }

    @Test func shortNames() {
        #expect(TextEncoding.latin1.shortName == "Latin-1" && TextEncoding.windows1252.shortName == "Windows-1252")
        #expect(TextEncoding.macRoman.shortName == "Mac Roman" && TextEncoding.utf8.shortName == "UTF-8")
    }
}
