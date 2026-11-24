import Foundation

/// The encodings Cedric reads and writes.
public enum TextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case latin1
    case windows1252
    case macRoman

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return String(localized: "UTF-8 with BOM")
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return String(localized: "Latin-1 (ISO 8859-1)")
        case .windows1252: return String(localized: "Windows-1252 (Western)")
        case .macRoman: return String(localized: "Mac Roman")
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        case .utf8, .latin1, .windows1252, .macRoman: return []
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .latin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        case .macRoman: return .macOSRoman
        }
    }
}

public enum LineEnding: String, CaseIterable, Codable, Sendable {
    case lf, crlf, cr

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    public var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// A file's text as Cedric edits it: decoded, with line endings
/// normalised to "\n", plus what to write back.
public struct DecodedText: Sendable {
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// The file mixed line endings; saving writes them all as `lineEnding`.
    public var mixedLineEndings: Bool
    /// The bytes look like a binary file (`TextCodec.looksBinary`).
    public var looksBinary = false
}

public enum TextCodec {
    /// Detects the encoding: a BOM, else valid UTF-8, else UTF-16 by its
    /// pattern of zero bytes, else one of the 8-bit Western encodings
    /// (`guessEightBit`).
    public static func detectEncoding(_ data: Data) -> TextEncoding {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        if let guess = guessUTF16(data) { return guess }
        if isValidUTF8(data) { return .utf8 }
        return guessEightBit(data)
    }

    /// How much of a file `looksBinary` reads.
    public static let binarySample = 8_192

    /// Whether `data` looks like a binary file rather than text: in its
    /// first 8 KB, a NUL byte, or more than 10% control characters (other
    /// than tab, line breaks, form feed, backspace and escape, which logs
    /// and terminal output use). Text Cedric reads is never binary: a
    /// UTF-8 or UTF-16 byte-order mark, or UTF-16 without one (its zero
    /// bytes fall in one parity, `guessUTF16`).
    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(binarySample)
        guard !sample.isEmpty else { return false }
        let head = [UInt8](sample.prefix(3))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
        if guessUTF16(sample) != nil { return false }
        var controls = 0
        for b in sample {
            if b == 0 { return true }
            if (b < 0x20 && b != 9 && b != 10 && b != 13 && b != 12 && b != 8 && b != 0x1B) || b == 0x7F { controls += 1 }
        }
        return controls * 10 > sample.count
    }

    /// Not UTF-8: Windows-1252, Mac Roman or Latin-1, from the bytes over
    /// 0x7F in the first 64 KB. Each candidate is scored on what those
    /// bytes decode to: lowercase letters and common punctuation (curly
    /// quotes, dashes, …, €) count for it; control characters, symbols
    /// (√, ◊, ‡) and a capital letter straight after a lowercase one
    /// ("donÕt", "cafÈ") count against. Ties go to Windows-1252, which
    /// reads like Latin-1 for 0xA0–0xFF; Latin-1 is kept when no byte is
    /// in 0x80–0x9F (where the two differ), as before.
    static func guessEightBit(_ data: Data) -> TextEncoding {
        var win = 0, mac = 0
        var c1 = false
        var prev: UInt8 = 0
        for b in data.prefix(65536) {
            if b >= 0x80 {
                if b < 0xA0 { c1 = true }
                let lowerBefore = prev >= 0x61 && prev <= 0x7A
                win += EightBit.score(EightBit.windows[Int(b) - 0x80], lowerBefore: lowerBefore)
                mac += EightBit.score(EightBit.mac[Int(b) - 0x80], lowerBefore: lowerBefore)
            }
            prev = b
        }
        if mac > win { return .macRoman }
        return c1 ? .windows1252 : .latin1
    }

    /// Mostly-ASCII UTF-16 without a BOM: zero bytes in one parity.
    static func guessUTF16(_ data: Data) -> TextEncoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (k, byte) in sample.enumerated() where byte == 0 {
            if k % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros * 10 > half * 6, evenZeros * 10 < half { return .utf16LE }
        if evenZeros * 10 > half * 6, oddZeros * 10 < half { return .utf16BE }
        return nil
    }

    static func isValidUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = b.count
            while i < n {
                // Fast path: 8 ASCII bytes at a time.
                if i + 8 <= n {
                    let word = UnsafeRawPointer(b.baseAddress! + i).loadUnaligned(as: UInt64.self)
                    if word & 0x8080808080808080 == 0 { i += 8; continue }
                }
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
                    let c1 = b[i + 1]
                    if c == 0xE0 && c1 < 0xA0 { return false }    // overlong
                    if c == 0xED && c1 >= 0xA0 { return false }   // surrogates
                }
                if len == 4 {
                    let c1 = b[i + 1]
                    if c == 0xF0 && c1 < 0x90 { return false }
                    if c == 0xF4 && c1 >= 0x90 { return false }
                }
                i += len
            }
            return true
        }
    }

    /// Decodes `data` (as `encoding`, or the detected one) and normalises
    /// its line endings. Nil if the bytes aren't valid in that encoding.
    /// UTF-16 with an odd number of bytes after the BOM (a truncated
    /// download) is nil too, as a lone surrogate is: Foundation decoded it
    /// without the last byte, so ⌘S dropped that byte with no notice.
    public static func decode(_ data: Data, as encoding: TextEncoding? = nil) -> DecodedText? {
        var enc = encoding ?? detectEncoding(data)
        var body = data
        if !enc.bom.isEmpty, data.starts(with: enc.bom) { body = data.dropFirst(enc.bom.count) }
        if enc == .utf16LE || enc == .utf16BE, body.count % 2 != 0 { return nil }
        var decoded = String(data: body, encoding: enc.foundation)
        // A guessed 8-bit encoding that can't decode a byte past the sample
        // (0x81 in Windows-1252): Latin-1 decodes any bytes.
        if decoded == nil, encoding == nil, enc == .windows1252 || enc == .macRoman {
            enc = .latin1
            decoded = String(data: body, encoding: .isoLatin1)
        }
        guard let raw = decoded else { return nil }
        let (ending, mixed) = detectLineEnding(raw)
        return DecodedText(text: normalizeLineEndings(raw), encoding: enc, lineEnding: ending, mixedLineEndings: mixed,
                           looksBinary: looksBinary(data))
    }

    /// The most common line ending, and whether more than one kind occurs.
    /// A file with no line breaks counts as LF.
    public static func detectLineEnding(_ text: String) -> (LineEnding, mixed: Bool) {
        var lf = 0, crlf = 0, cr = 0
        var copy = text
        copy.withUTF8 { b in
            var i = 0
            while i < b.count {
                let c = b[i]
                if c == 13 {
                    if i + 1 < b.count, b[i + 1] == 10 { crlf += 1; i += 2; continue }
                    cr += 1
                } else if c == 10 {
                    lf += 1
                }
                i += 1
            }
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let ending: LineEnding = crlf > lf && crlf >= cr ? .crlf : cr > lf && cr > crlf ? .cr : .lf
        return (ending, kinds > 1)
    }

    /// CRLF and CR → LF.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        let m = NSMutableString(string: text)
        m.replaceOccurrences(of: "\r\n", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
        m.replaceOccurrences(of: "\r", with: "\n", options: .literal, range: NSRange(location: 0, length: m.length))
        return m as String
    }

    /// Encodes LF-normalised text for saving: line endings converted, BOM
    /// added. Nil if a character can't be represented (Latin-1).
    public static func encode(_ text: String, encoding: TextEncoding, lineEnding: LineEnding) -> Data? {
        var s = text
        if lineEnding != .lf {
            let m = NSMutableString(string: text)
            m.replaceOccurrences(of: "\n", with: lineEnding.string, options: .literal, range: NSRange(location: 0, length: m.length))
            s = m as String
        }
        guard let body = s.data(using: encoding.foundation, allowLossyConversion: false) else { return nil }
        // Foundation's .utf16LittleEndian/BigEndian write no BOM; add ours.
        return encoding.bom.isEmpty ? body : Data(encoding.bom) + body
    }

    /// Whether `text` can be saved in `encoding` without loss.
    public static func canEncode(_ text: String, as encoding: TextEncoding) -> Bool {
        switch encoding {
        case .latin1: return text.unicodeScalars.allSatisfy { $0.value < 256 }
        case .windows1252, .macRoman: return text.canBeConverted(to: encoding.foundation)
        default: return true
        }
    }
}

/// What bytes 0x80–0xFF decode to in the 8-bit encodings, for the guess.
enum EightBit {
    static let windows = table(.windowsCP1252)
    static let mac = table(.macOSRoman)

    static func table(_ enc: String.Encoding) -> [Unicode.Scalar?] {
        (0x80...0xFF).map { b in String(data: Data([UInt8(b)]), encoding: enc)?.unicodeScalars.first }
    }

    static let rareCapitals = Set("ŠŒŽŸ".unicodeScalars)
    static let punctuation = Set("‘’“”‚„–—…€•«»‹›¡¿°·©®™§¶\u{A0}".unicodeScalars)

    static func score(_ s: Unicode.Scalar?, lowerBefore: Bool) -> Int {
        guard let s else { return -3 }
        let p = s.properties
        if p.generalCategory == .control { return -3 }
        if p.isLowercase { return 1 }
        // Windows-1252's Š Œ Ž Ÿ are rare in real text: no evidence either way.
        if p.isUppercase { return lowerBefore ? -2 : rareCapitals.contains(s) ? 0 : 1 }
        if punctuation.contains(s) { return 1 }
        return -1
    }
}
