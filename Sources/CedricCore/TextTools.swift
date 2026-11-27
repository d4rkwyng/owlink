import Foundation

/// Text › Text Tools: pure String → String transforms. The app applies one
/// to the selection (or the whole document) as a single undoable change.
public enum TextTool: String, CaseIterable, Sendable {
    case sortAscending, sortDescending, sortNumeric
    case removeDuplicateLines, trimTrailingWhitespace
    case uppercase, lowercase, titleCase
    case jsonPrettyPrint, jsonMinify, xmlPrettyPrint
    case base64Encode, base64Decode, urlEncode, urlDecode
    case joinLines, reverseLines

    public var displayName: String {
        switch self {
        case .sortAscending: return String(localized: "Sort Lines A→Z")
        case .sortDescending: return String(localized: "Sort Lines Z→A")
        case .sortNumeric: return String(localized: "Sort Lines Numerically")
        case .removeDuplicateLines: return String(localized: "Remove Duplicate Lines")
        case .trimTrailingWhitespace: return String(localized: "Trim Trailing Whitespace")
        case .uppercase: return String(localized: "UPPERCASE")
        case .lowercase: return String(localized: "lowercase")
        case .titleCase: return String(localized: "Title Case")
        case .jsonPrettyPrint: return String(localized: "JSON Pretty Print")
        case .jsonMinify: return String(localized: "JSON Minify")
        case .xmlPrettyPrint: return String(localized: "XML Pretty Print")
        case .base64Encode: return String(localized: "Base64 Encode")
        case .base64Decode: return String(localized: "Base64 Decode")
        case .urlEncode: return String(localized: "URL Encode")
        case .urlDecode: return String(localized: "URL Decode")
        case .joinLines: return String(localized: "Join Lines")
        case .reverseLines: return String(localized: "Reverse Lines")
        }
    }

    /// Works on whole lines: a partial selection is widened to the lines it touches.
    public var isLineBased: Bool {
        switch self {
        case .sortAscending, .sortDescending, .sortNumeric, .removeDuplicateLines,
             .trimTrailingWhitespace, .joinLines, .reverseLines: return true
        default: return false
        }
    }
}

public enum TextToolError: Error, Equatable, LocalizedError {
    case invalidJSON(String)
    case invalidXML(String)
    case invalidBase64
    case notUTF8
    case invalidPercentEncoding

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let m): return String(localized: "Not valid JSON: \(m)")
        case .invalidXML(let m): return String(localized: "Not valid XML: \(m)")
        case .invalidBase64: return String(localized: "Not valid Base64.")
        case .notUTF8: return String(localized: "The decoded bytes aren’t UTF-8 text.")
        case .invalidPercentEncoding: return String(localized: "Not valid URL (percent) encoding.")
        }
    }
}

public enum TextTools {
    public static func apply(_ tool: TextTool, to text: String) throws -> String {
        switch tool {
        case .sortAscending: return mapLines(text) { $0.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending } }
        case .sortDescending: return mapLines(text) { $0.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedDescending } }
        case .sortNumeric: return mapLines(text, sortNumeric)
        case .removeDuplicateLines:
            return mapLines(text) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        case .trimTrailingWhitespace:
            return mapLines(text) { $0.map(trimTrailing) }
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return titleCase(text)
        case .jsonPrettyPrint: return try JSONFormatter.format(text, pretty: true)
        case .jsonMinify: return try JSONFormatter.format(text, pretty: false)
        case .xmlPrettyPrint: return try xmlPretty(text)
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let stripped = text.filter { !$0.isWhitespace }
            var padded = stripped
            while padded.count % 4 != 0 { padded += "=" }
            guard let d = Data(base64Encoded: padded) else { throw TextToolError.invalidBase64 }
            guard let s = String(data: d, encoding: .utf8) else { throw TextToolError.notUTF8 }
            return s
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        case .urlDecode:
            guard let s = text.removingPercentEncoding else { throw TextToolError.invalidPercentEncoding }
            return s
        case .joinLines:
            return mapLines(text) { lines in
                guard let first = lines.first else { return lines }
                let rest = lines.dropFirst().map { String($0.drop { $0 == " " || $0 == "\t" }) }.filter { !$0.isEmpty }
                return [([trimTrailing(first)] + rest.map(trimTrailing)).filter { !$0.isEmpty }.joined(separator: " ")]
            }
        case .reverseLines: return mapLines(text) { $0.reversed() }
        }
    }

    /// Splits on "\n", transforms the lines and joins them; a trailing
    /// newline stays a trailing newline.
    static func mapLines(_ text: String, _ f: ([String]) -> [String]) -> String {
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.count > 1 && lines.last == ""
        if trailing { lines.removeLast() }
        return f(lines).joined(separator: "\n") + (trailing ? "\n" : "")
    }

    static func trimTrailing(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let p = s.index(before: end)
            if s[p] == " " || s[p] == "\t" { end = p } else { break }
        }
        return String(s[..<end])
    }

    /// The number a line starts with (after leading whitespace), if any.
    static func leadingNumber(_ s: String) -> Double? {
        let t = s.drop { $0 == " " || $0 == "\t" }
        var end = t.startIndex
        var seenDigit = false, seenDot = false
        if end < t.endIndex, t[end] == "-" || t[end] == "+" { end = t.index(after: end) }
        while end < t.endIndex {
            let c = t[end]
            if c.isASCII, c.isNumber { seenDigit = true } else if c == "." && !seenDot { seenDot = true } else if c == "," || c == "_" { } else { break }
            end = t.index(after: end)
        }
        guard seenDigit else { return nil }
        return Double(t[t.startIndex..<end].filter { $0 != "," && $0 != "_" })
    }

    /// Lines with a leading number first, by value; then the rest, as they were.
    static func sortNumeric(_ lines: [String]) -> [String] {
        let keyed = lines.enumerated().map { ($0.offset, $0.element, leadingNumber($0.element)) }
        return keyed.sorted { a, b in
            switch (a.2, b.2) {
            case let (x?, y?): return x != y ? x < y : a.0 < b.0
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.0 < b.0
            }
        }.map(\.1)
    }

    /// First letter of every word upper case, the rest lower case; an
    /// apostrophe inside a word ("don't") doesn't start a new word.
    static func titleCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var inWord = false
        for ch in s {
            if ch.isLetter || ch.isNumber {
                out += inWord ? ch.lowercased() : ch.uppercased()
                inWord = true
            } else if (ch == "'" || ch == "’") && inWord {
                out.append(ch)
            } else {
                out.append(ch)
                inWord = false
            }
        }
        return out
    }

    static func xmlPretty(_ text: String) throws -> String {
        #if os(macOS)
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: text, options: [.nodePreserveCDATA, .nodePreserveEmptyElements,
                                                              .nodePreserveAttributeOrder, .nodePreserveNamespaceOrder])
        } catch {
            let ns = error as NSError
            let msg = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ns.localizedDescription
            throw TextToolError.invalidXML(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var out = doc.xmlString(options: [.nodePrettyPrint, .nodePreserveAttributeOrder, .nodeCompactEmptyElement])
        // XMLDocument adds a declaration the input didn't have.
        let hadDecl = text.drop { $0.isWhitespace }.hasPrefix("<?xml")
        if !hadDecl, out.hasPrefix("<?xml"), let end = out.range(of: "?>") {
            out = String(out[end.upperBound...]).drop { $0 == "\n" }.description
        }
        if text.hasSuffix("\n") && !out.hasSuffix("\n") { out += "\n" }
        return out
        #else
        // iOS Foundation has no XMLDocument.
        throw TextToolError.invalidXML("Formatting XML needs the Mac app.")
        #endif
    }
}

/// A small JSON validator and re-printer. Keeps key order and number
/// spelling exactly as written (JSONSerialization does neither).
public enum JSONFormatter {
    /// `limit`: the most output bytes (deeply nested JSON indents to many
    /// times its own size); past it, `TextToolError.invalidJSON`.
    public static func format(_ text: String, pretty: Bool, indent: String = "  ", limit: Int = .max) throws -> String {
        var p = Parser(Array(text.utf8))
        p.limit = limit
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        p.skipSpace()
        guard p.i < p.b.count else { throw TextToolError.invalidJSON(String(localized: "empty input")) }
        try p.value(&out, pretty: pretty, indent: Array(indent.utf8), depth: 0)
        p.skipSpace()
        if p.i < p.b.count { throw p.error(String(localized: "unexpected text after the value")) }
        if pretty && text.hasSuffix("\n") { out.append(10) }
        // The check inside stops early, before each member; the last value
        // and the closing lines come after it, so the whole output is
        // held to the limit here too.
        if out.count > limit { throw p.error(String(localized: "too long to format")) }
        return String(decoding: out, as: UTF8.self)
    }

    struct Parser {
        let b: [UInt8]
        var i = 0
        var limit = Int.max
        init(_ b: [UInt8]) { self.b = b }

        func error(_ what: String) -> TextToolError {
            var line = 1, col = 1
            for k in 0..<min(i, b.count) { if b[k] == 10 { line += 1; col = 1 } else if b[k] & 0xC0 != 0x80 { col += 1 } }
            return .invalidJSON(String(localized: "\(what) at line \(line), column \(col)"))
        }

        mutating func skipSpace() {
            while i < b.count, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 }
        }

        func newline(_ out: inout [UInt8], _ indent: [UInt8], _ depth: Int) {
            out.append(10)
            for _ in 0..<depth { out += indent }
        }

        mutating func value(_ out: inout [UInt8], pretty: Bool, indent: [UInt8], depth: Int) throws {
            guard depth < 512 else { throw error(String(localized: "nested too deeply")) }
            skipSpace()
            guard i < b.count else { throw error(String(localized: "unexpected end")) }
            switch b[i] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let obj = b[i] == UInt8(ascii: "{")
                let close = obj ? UInt8(ascii: "}") : UInt8(ascii: "]")
                out.append(b[i]); i += 1
                skipSpace()
                if i < b.count, b[i] == close { out.append(close); i += 1; return }
                while true {
                    if pretty { newline(&out, indent, depth + 1) }
                    if out.count > limit { throw error(String(localized: "too long to format")) }
                    if obj {
                        skipSpace()
                        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw error(String(localized: "expected a key string")) }
                        try string(&out)
                        skipSpace()
                        guard i < b.count, b[i] == UInt8(ascii: ":") else { throw error(String(localized: "expected ':'")) }
                        i += 1
                        out.append(UInt8(ascii: ":"))
                        if pretty { out.append(32) }
                    }
                    try value(&out, pretty: pretty, indent: indent, depth: depth + 1)
                    skipSpace()
                    guard i < b.count else { throw error(String(localized: "unexpected end")) }
                    if b[i] == UInt8(ascii: ",") { out.append(b[i]); i += 1; continue }
                    if b[i] == close {
                        if pretty { newline(&out, indent, depth) }
                        out.append(close); i += 1; return
                    }
                    throw error(obj ? String(localized: "expected ',' or '}'") : String(localized: "expected ',' or ']'"))
                }
            case UInt8(ascii: "\""): try string(&out)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number(&out)
            default:
                for lit in ["true", "false", "null"] {
                    let u = Array(lit.utf8)
                    if i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u {
                        out += u; i += u.count; return
                    }
                }
                throw error(String(localized: "unexpected character"))
            }
        }

        mutating func string(_ out: inout [UInt8]) throws {
            let start = i
            i += 1
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; out += b[start..<i]; return }
                if c < 0x20 { throw error(String(localized: "control character in string")) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { break }
                    switch b[i] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                         UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"): i += 1
                    case UInt8(ascii: "u"):
                        guard i + 4 < b.count, b[(i + 1)...(i + 4)].allSatisfy({ isHex($0) }) else { throw error(String(localized: "bad \\u escape")) }
                        i += 5
                    default: throw error(String(localized: "bad escape"))
                    }
                    continue
                }
                i += 1
            }
            i = start
            throw error(String(localized: "unterminated string"))
        }

        func isHex(_ c: UInt8) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
        }

        mutating func number(_ out: inout [UInt8]) throws {
            let start = i
            func digits() -> Int { let s = i; while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }; return i - s }
            if b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count else { throw error(String(localized: "bad number")) }
            if b[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw error(String(localized: "bad number")) }
            if i < b.count, b[i] == UInt8(ascii: ".") { i += 1; if digits() == 0 { throw error(String(localized: "bad number")) } }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                if digits() == 0 { throw error(String(localized: "bad number")) }
            }
            out += b[start..<i]
        }
    }
}
