import Foundation

/// A small reader for the YAML front matter the Markdown preview shows:
/// block maps and lists nested by indentation, `- key: value` items,
/// flow lists (`[a, b]`), quoted scalars and `|` / `>` block text. Not a
/// YAML parser (no anchors, tags or multi-document streams): what it
/// doesn't understand stays text, shown as is (escaped by the renderer).
public enum FrontMatter {
    public indirect enum Value: Equatable, Sendable {
        case scalar(String)
        case list([Value])
        case map([(String, Value)])

        public static func == (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case (.scalar(let x), .scalar(let y)): return x == y
            case (.list(let x), .list(let y)): return x == y
            case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: return false
            }
        }
    }

    /// Deeper than this, the rest of a value is shown as its text.
    static let maxDepth = 16

    private struct Line {
        var indent: Int
        var text: Substring
    }

    /// The front matter's lines (between the `---` fences).
    public static func parse<S: Sequence>(_ lines: S) -> Value where S.Element == String {
        var all: [Line] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var indent = 0
            for ch in raw { if ch == " " { indent += 1 } else if ch == "\t" { indent += 2 } else { break } }
            all.append(Line(indent: indent, text: Substring(trimmed)))
        }
        guard !all.isEmpty else { return .map([]) }
        var i = 0
        var parts: [Value] = []
        while i < all.count {
            let before = i
            parts.append(node(&all, &i, indent: all[i].indent, depth: 0))
            if i == before { i += 1 }
        }
        if parts.count == 1 { return parts[0] }
        // Top-level pieces at different indents: merged maps, else a list.
        if parts.allSatisfy({ if case .map = $0 { return true } else { return false } }) {
            return .map(parts.flatMap { if case .map(let p) = $0 { return p } else { return [] } })
        }
        return .list(parts)
    }

    /// The `title` key's value at the top, if it is plain text.
    public static func title(_ value: Value) -> String? {
        guard case .map(let pairs) = value,
              let pair = pairs.first(where: { $0.0.lowercased() == "title" }),
              case .scalar(let s) = pair.1 else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t.replacingOccurrences(of: "\n", with: " ")
    }

    private static func isListItem(_ t: Substring) -> Bool { t == "-" || t.hasPrefix("- ") }

    /// `key: rest` (the key unquoted), or nil.
    private static func keyValue(_ t: Substring) -> (String, Substring)? {
        if t.hasPrefix("- ") || t.hasPrefix("[") || t.hasPrefix("{") { return nil }
        var key: Substring
        var rest: Substring
        if let q = t.first, q == "\"" || q == "'" {
            guard let close = t.dropFirst().firstIndex(of: q) else { return nil }
            key = t[t.index(after: t.startIndex)..<close]
            rest = t[t.index(after: close)...]
            guard rest.first == ":" else { return nil }
            rest = rest.dropFirst()
        } else {
            guard let colon = t.firstIndex(where: { $0 == ":" }) else { return nil }
            let after = t.index(after: colon)
            guard after == t.endIndex || t[after] == " " || t[after] == "\t" else { return nil }
            key = t[..<colon]
            rest = t[after...]
            if key.contains(" #") { return nil }
        }
        return (String(key).trimmingCharacters(in: .whitespaces), rest.drop { $0 == " " || $0 == "\t" })
    }

    private static func node(_ lines: inout [Line], _ i: inout Int, indent: Int, depth: Int) -> Value {
        guard i < lines.count else { return .scalar("") }
        if depth > maxDepth { return .scalar(rest(lines, &i, above: indent - 1)) }
        let first = lines[i]
        if isListItem(first.text) { return list(&lines, &i, indent: first.indent, depth: depth) }
        if keyValue(first.text) != nil { return map(&lines, &i, indent: first.indent, depth: depth) }
        // Plain text, with its more-indented continuation lines.
        i += 1
        var text = String(first.text)
        while i < lines.count, lines[i].indent > indent { text += " " + lines[i].text; i += 1 }
        return .scalar(unquote(text))
    }

    /// Every following line indented more than `above`, as text.
    private static func rest(_ lines: [Line], _ i: inout Int, above: Int) -> String {
        var out: [String] = []
        while i < lines.count, lines[i].indent > above || out.isEmpty {
            out.append(String(repeating: " ", count: lines[i].indent) + lines[i].text)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func list(_ lines: inout [Line], _ i: inout Int, indent: Int, depth: Int) -> Value {
        var items: [Value] = []
        while i < lines.count, lines[i].indent == indent, isListItem(lines[i].text) {
            let text = lines[i].text
            let content = text.dropFirst().drop { $0 == " " }
            if content.isEmpty {
                i += 1
                if i < lines.count, lines[i].indent > indent {
                    items.append(node(&lines, &i, indent: lines[i].indent, depth: depth + 1))
                } else {
                    items.append(.scalar(""))
                }
                continue
            }
            // `- key: value` (a map), `- - x` (a list): the item starts at
            // its content's column; read it from there.
            let column = indent + (text.count - content.count)
            if keyValue(content) != nil || isListItem(content) {
                lines[i] = Line(indent: column, text: content)
                items.append(node(&lines, &i, indent: column, depth: depth + 1))
            } else {
                i += 1
                var s = String(content)
                while i < lines.count, lines[i].indent > indent, !isListItem(lines[i].text) || lines[i].indent > column {
                    s += " " + lines[i].text
                    i += 1
                }
                items.append(scalar(s))
            }
        }
        return .list(items)
    }

    private static func map(_ lines: inout [Line], _ i: inout Int, indent: Int, depth: Int) -> Value {
        var pairs: [(String, Value)] = []
        while i < lines.count, lines[i].indent == indent, let kv = keyValue(lines[i].text) {
            let (key, rest) = kv
            i += 1
            let value: Value
            if rest.isEmpty || rest.hasPrefix("#") {
                // A nested block: deeper, or a list at the key's own indent.
                if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && isListItem(lines[i].text)) {
                    value = node(&lines, &i, indent: lines[i].indent, depth: depth + 1)
                } else {
                    value = .scalar("")
                }
            } else if let style = rest.first, style == "|" || style == ">", rest.dropFirst().allSatisfy({ "+-0123456789 ".contains($0) }) {
                var block: [String] = []
                while i < lines.count, lines[i].indent > indent { block.append(String(lines[i].text)); i += 1 }
                value = .scalar(block.joined(separator: style == "|" ? "\n" : " "))
            } else {
                var s = String(rest)
                // A plain value continued on more-indented lines.
                while i < lines.count, lines[i].indent > indent { s += " " + lines[i].text; i += 1 }
                value = scalar(s)
            }
            pairs.append((key, value))
        }
        return .map(pairs)
    }

    /// A scalar, or a flow list `[a, b]` / flow map `{a: 1}` on one line.
    private static func scalar(_ s: String) -> Value {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), t.hasSuffix("]") {
            let inner = t.dropFirst().dropLast()
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .list([]) }
            if !inner.contains("[") && !inner.contains("{") {
                return .list(splitFlow(inner).map { .scalar(unquote($0)) })
            }
        }
        if t.hasPrefix("{"), t.hasSuffix("}") {
            let inner = t.dropFirst().dropLast()
            if !inner.contains("[") && !inner.contains("{") {
                var pairs: [(String, Value)] = []
                for part in splitFlow(inner) {
                    if let colon = part.firstIndex(of: ":") {
                        pairs.append((unquote(String(part[..<colon])), .scalar(unquote(String(part[part.index(after: colon)...])))))
                    } else {
                        return .scalar(unquote(t))
                    }
                }
                return .map(pairs)
            }
        }
        return .scalar(unquote(t))
    }

    /// Splits on commas outside quotes.
    private static func splitFlow(_ s: Substring) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch); continue }
            if ch == "," { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let q = t.first, q == "\"" || q == "'", t.last == q { return String(t.dropFirst().dropLast()) }
        return t
    }
}
