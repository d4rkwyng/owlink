import Foundation
import Testing
@testable import CedricCore

@Suite struct EncodingTests {
    @Test func utf8() {
        let d = TextCodec.decode(Data("héllo\nwörld".utf8))
        #expect(d?.encoding == .utf8)
        #expect(d?.text == "héllo\nwörld")
    }

    @Test func utf8BOM() {
        let d = TextCodec.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8))
        #expect(d?.encoding == .utf8BOM)
        #expect(d?.text == "hi")
    }

    @Test func utf16WithBOM() {
        let le = TextCodec.encode("ça va\n", encoding: .utf16LE, lineEnding: .lf)!
        #expect(Array(le.prefix(2)) == [0xFF, 0xFE])
        #expect(TextCodec.decode(le)?.encoding == .utf16LE)
        #expect(TextCodec.decode(le)?.text == "ça va\n")
        let be = TextCodec.encode("ça va", encoding: .utf16BE, lineEnding: .lf)!
        #expect(Array(be.prefix(2)) == [0xFE, 0xFF])
        #expect(TextCodec.decode(be)?.text == "ça va")
    }

    /// UTF-16 with an odd byte count (a BOM, then a half code unit at the
    /// end) isn't text in that encoding: Foundation decoded it without the
    /// last byte and ⌘S dropped it (ff fe 61 00 62 → ff fe 61 00). It is
    /// refused, as a lone surrogate is, detected or chosen.
    @Test func utf16WithAnOddByteCountIsRefused() {
        #expect(TextCodec.decode(Data([0xFF, 0xFE, 0x61, 0x00, 0x62])) == nil)
        #expect(TextCodec.decode(Data([0xFE, 0xFF, 0x00, 0x61, 0x00])) == nil)
        #expect(TextCodec.decode(Data([0xFF, 0xFE, 0x61])) == nil)
        #expect(TextCodec.decode(Data([0x61, 0x00, 0x62]), as: .utf16LE) == nil)
        #expect(TextCodec.decode(Data([0x00, 0x61, 0x00]), as: .utf16BE) == nil)
        // A lone surrogate, the case it matches.
        #expect(TextCodec.decode(Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00])) == nil)
        // Even counts still open, and their bytes round-trip.
        let even = Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00])
        let d = TextCodec.decode(even)
        #expect(d?.text == "ab")
        #expect(d?.encoding == .utf16LE)
        #expect(TextCodec.encode("ab", encoding: .utf16LE, lineEnding: .lf) == even)
        #expect(TextCodec.decode(Data([0xFF, 0xFE]))?.text == "")
        // Reopened as another encoding the bytes are text again.
        #expect(TextCodec.decode(Data([0xFF, 0xFE, 0x61, 0x00, 0x62]), as: .latin1)?.text.unicodeScalars.count == 5)
    }

    @Test func utf16WithoutBOMBySniffing() {
        let le = "plain ascii text\n".data(using: .utf16LittleEndian)!
        #expect(TextCodec.detectEncoding(le) == .utf16LE)
        let be = "plain ascii text\n".data(using: .utf16BigEndian)!
        #expect(TextCodec.detectEncoding(be) == .utf16BE)
        #expect(TextCodec.decode(be)?.text == "plain ascii text\n")
    }

    @Test func latin1Fallback() {
        let bytes = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1: invalid UTF-8
        let d = TextCodec.decode(bytes)
        #expect(d?.encoding == .latin1)
        #expect(d?.text == "café")
    }

    @Test func utf8Validation() {
        #expect(TextCodec.isValidUTF8(Data("plain ascii that is longer than eight bytes".utf8)))
        #expect(TextCodec.isValidUTF8(Data("emoji 😀 and ü".utf8)))
        #expect(!TextCodec.isValidUTF8(Data([0xC0, 0x80])))            // overlong
        #expect(!TextCodec.isValidUTF8(Data([0xED, 0xA0, 0x80])))      // surrogate
        #expect(!TextCodec.isValidUTF8(Data([0x61, 0xE2, 0x82])))      // truncated
        #expect(!TextCodec.isValidUTF8(Data([0xF5, 0x80, 0x80, 0x80])))
    }

    @Test func latin1RefusesUnrepresentable() {
        #expect(TextCodec.encode("snowman ☃", encoding: .latin1, lineEnding: .lf) == nil)
        #expect(!TextCodec.canEncode("☃", as: .latin1))
        #expect(TextCodec.canEncode("é", as: .latin1))
    }
}

@Suite struct LineEndingTests {
    @Test func detection() {
        #expect(TextCodec.detectLineEnding("a\nb\n") == (.lf, false))
        #expect(TextCodec.detectLineEnding("a\r\nb\r\n") == (.crlf, false))
        #expect(TextCodec.detectLineEnding("a\rb\r") == (.cr, false))
        #expect(TextCodec.detectLineEnding("no breaks") == (.lf, false))
        let mixed = TextCodec.detectLineEnding("a\r\nb\r\nc\n")
        #expect(mixed.0 == .crlf)
        #expect(mixed.mixed)
    }

    @Test func decodeNormalisesAndEncodeRestores() {
        let d = TextCodec.decode(Data("one\r\ntwo\r\n".utf8))!
        #expect(d.text == "one\ntwo\n")
        #expect(d.lineEnding == .crlf)
        #expect(!d.mixedLineEndings)
        let back = TextCodec.encode(d.text, encoding: d.encoding, lineEnding: d.lineEnding)!
        #expect(String(decoding: back, as: UTF8.self) == "one\r\ntwo\r\n")
    }

    @Test func classicMacCR() {
        let d = TextCodec.decode(Data("a\rb".utf8))!
        #expect(d.text == "a\nb")
        #expect(d.lineEnding == .cr)
    }

    @Test func roundTripAllCombinations() {
        let text = "line one ü\nline two\n"
        for enc in TextEncoding.allCases {
            for le in LineEnding.allCases {
                let data = TextCodec.encode(text, encoding: enc, lineEnding: le)!
                let d = TextCodec.decode(data)!
                #expect(d.text == text, "\(enc) \(le)")
                #expect(d.lineEnding == le, "\(enc) \(le)")
                // Latin-1 and UTF-8 look alike only when the text is ASCII; ü makes them differ.
                // Windows-1252 writes ü as Latin-1 does (0xFC): the same bytes read back as Latin-1.
                #expect(d.encoding == (enc == .windows1252 ? .latin1 : enc), "\(enc) \(le)")
            }
        }
    }
}

@Suite struct FindTests {
    let text = "Cat cat CAT concat\ncat123" as NSString

    @Test func literalCaseInsensitive() throws {
        let re = try FindEngine.regex("cat", FindOptions())
        #expect(FindEngine.matches(re, in: text).count == 5)
    }

    @Test func caseSensitiveWholeWord() throws {
        let re = try FindEngine.regex("cat", FindOptions(caseSensitive: true, wholeWord: true))
        #expect(FindEngine.matches(re, in: text).map(\.range) == [NSRange(location: 4, length: 3)])
    }

    @Test func literalEscapesRegexCharacters() throws {
        let re = try FindEngine.regex("a.b", FindOptions())
        #expect(FindEngine.matches(re, in: "axb a.b" as NSString).map(\.range.location) == [4])
    }

    @Test func regexAndGroups() throws {
        let (out, n) = try FindEngine.replaceAll(in: "x=1, y=22", pattern: #"(\w)=(\d+)"#, with: "$2:$1", options: FindOptions(regex: true))
        #expect(out == "1:x, 22:y")
        #expect(n == 2)
    }

    @Test func literalReplacementKeepsDollar() throws {
        let (out, _) = try FindEngine.replaceAll(in: "a a", pattern: "a", with: "$1", options: FindOptions())
        #expect(out == "$1 $1")
    }

    @Test func nextWrapsAndPrevious() throws {
        let re = try FindEngine.regex("cat", FindOptions(caseSensitive: true))
        #expect(FindEngine.next(re, in: text, from: 0)?.location == 4)
        #expect(FindEngine.next(re, in: text, from: 16)?.location == 19)
        #expect(FindEngine.next(re, in: text, from: 23)?.location == 4)          // wraps
        #expect(FindEngine.next(re, in: text, from: 23, wrap: false) == nil)
        #expect(FindEngine.next(re, in: text, from: 19, backwards: true)?.location == 15)
        #expect(FindEngine.next(re, in: text, from: 4, backwards: true)?.location == 19) // wraps back
    }

    @Test func anchorsMatchLines() throws {
        let re = try FindEngine.regex("^cat", FindOptions(regex: true, caseSensitive: true))
        #expect(FindEngine.matches(re, in: text).map(\.range.location) == [19])
    }

    @Test func invalidPattern() {
        #expect(throws: FindEngine.FindError.invalidPattern("(")) { try FindEngine.regex("(", FindOptions(regex: true)) }
        #expect(throws: FindEngine.FindError.emptyPattern) { try FindEngine.regex("", FindOptions()) }
    }
}

@Suite struct EightBitEncodingTests {
    @Test func windows1252SmartQuotesAndEuro() {
        // “It’s 5 €” — 0x93 0x92 0x94 0x80 are Windows-1252 punctuation.
        let bytes = Data([0x93, 0x49, 0x74, 0x92, 0x73, 0x20, 0x35, 0x20, 0x80, 0x94])
        let d = TextCodec.decode(bytes)
        #expect(d?.encoding == .windows1252)
        #expect(d?.text == "“It’s 5 €”")
    }

    @Test func macRomanAccentsAndQuotes() {
        // "café, don’t" in Mac Roman: é = 0x8E, ’ = 0xD5.
        let bytes = Data("caf".utf8) + Data([0x8E]) + Data(", don".utf8) + Data([0xD5]) + Data("t".utf8)
        let d = TextCodec.decode(bytes)
        #expect(d?.encoding == .macRoman)
        #expect(d?.text == "café, don’t")
        // Mac Roman curly quotes only (no 0x80–0x9F byte): still Mac Roman, not "donÕt".
        let quotes = Data("don".utf8) + Data([0xD5]) + Data("t say ".utf8) + Data([0xD2]) + Data("hi".utf8) + Data([0xD3])
        #expect(TextCodec.decode(quotes)?.text == "don’t say “hi”")
    }

    @Test func latin1KeptWithoutC1Bytes() {
        // Western text in 0xA0–0xFF only reads the same in Latin-1 and Windows-1252.
        let bytes = Data("na".utf8) + Data([0xEF]) + Data("ve r".utf8) + Data([0xE9, 0x73, 0x75, 0x6D, 0xE9])
        let d = TextCodec.decode(bytes)
        #expect(d?.encoding == .latin1)
        #expect(d?.text == "naïve résumé")
    }

    @Test func roundTripAndCanEncode() {
        for enc in [TextEncoding.windows1252, .macRoman] {
            let text = "naïve “quotes” – café\n"
            let data = TextCodec.encode(text, encoding: enc, lineEnding: .crlf)
            #expect(data != nil)
            #expect(TextCodec.decode(data!, as: enc)?.text == text)
            #expect(TextCodec.canEncode(text, as: enc))
            #expect(!TextCodec.canEncode("snowman ☃", as: enc))
            #expect(TextCodec.encode("☃", encoding: enc, lineEnding: .lf) == nil)
        }
        #expect(TextCodec.canEncode("€", as: .windows1252) && !TextCodec.canEncode("€", as: .latin1))
    }

    @Test func undecodableGuessFallsBackToLatin1() {
        // 0x93 early says Windows-1252; 0x81 (undefined there) past the 64 KB sample.
        var bytes = Data([0x93, 0x61, 0x94]) + Data(repeating: 0x61, count: 70_000)
        bytes.append(0x81)
        let d = TextCodec.decode(bytes)
        #expect(d?.encoding == .latin1)
        #expect(d?.text.count == 70_004)
    }

    @Test func sessionDecodesNewEncodings() throws {
        let tab = SessionTab(path: "/x", encoding: .macRoman)
        let back = try JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(tab))
        #expect(back.encoding == .macRoman)
    }
}
