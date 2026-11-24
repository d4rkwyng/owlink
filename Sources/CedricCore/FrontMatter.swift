import Foundation

/// A small reader for the YAML front matter the Markdown preview shows:
/// block maps and lists nested by indentation, `- key: value` items,
/// flow lists and maps (`[a, {b: [c]}]`, nested), quoted scalars and `|`
/// / `>` block text (with its blank and `#` lines). Not a
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
        /// Blank: text in a block scalar (`|`, `>`), skipped elsewhere.
        var blank = false
        /// Starts with `#`: text in a block scalar, a comment elsewhere.
        var comment = false
        var ignorable: Bool { blank || comment }
    }

    /// The line at `i`, past blank and comment lines (`i` moves to it), or
    /// nil at the end. Blank and `#` lines are kept until it's known
    /// whether they are a block scalar's text (Codex review of 0.5.2 (17),
    /// should-fix 1: dropped up front, a `description: |` lost its
    /// `# Heading` line and the blank line after it).
    private static func at(_ lines: [Line], _ i: inout Int) -> Line? {
        while i < lines.count, lines[i].ignorable { i += 1 }
        return i < lines.count ? lines[i] : nil
    }

    /// The front matter's lines (between the `---` fences).
    public static func parse<S: Sequence>(_ lines: S) -> Value where S.Element == String {
        var all: [Line] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            var indent = 0
            for ch in raw { if ch == " " { indent += 1 } else if ch == "\t" { indent += 2 } else { break } }
            all.append(Line(indent: indent, text: Substring(trimmed), blank: trimmed.isEmpty, comment: trimmed.hasPrefix("#")))
        }
        var i = 0
        var parts: [Value] = []
        while let line = at(all, &i) {
            let before = i
            parts.append(node(&all, &i, indent: line.indent, depth: 0))
            if i == before { i += 1 }
        }
        if parts.isEmpty { return .map([]) }
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
        guard let first = at(lines, &i) else { return .scalar("") }
        if depth > maxDepth { return .scalar(rest(lines, &i, above: indent - 1)) }
        if isListItem(first.text) { return list(&lines, &i, indent: first.indent, depth: depth) }
        if keyValue(first.text) != nil { return map(&lines, &i, indent: first.indent, depth: depth) }
        // Plain text, with its more-indented continuation lines; a flow
        // map or list on its own (`{title: Owls}` at the root: Codex review
        // of the 0.5.2 (17) fixes) is read as one.
        i += 1
        var text = String(first.text)
        while let next = at(lines, &i), next.indent > indent { text += " " + next.text; i += 1 }
        return scalar(text, depth: depth)
    }

    /// Every following line indented more than `above`, as text.
    private static func rest(_ lines: [Line], _ i: inout Int, above: Int) -> String {
        var out: [String] = []
        while let line = at(lines, &i), line.indent > above || out.isEmpty {
            out.append(String(repeating: " ", count: line.indent) + line.text)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func list(_ lines: inout [Line], _ i: inout Int, indent: Int, depth: Int) -> Value {
        var items: [Value] = []
        while let line = at(lines, &i), line.indent == indent, isListItem(line.text) {
            let text = line.text
            let content = text.dropFirst().drop { $0 == " " }
            if content.isEmpty {
                i += 1
                if let next = at(lines, &i), next.indent > indent {
                    items.append(node(&lines, &i, indent: next.indent, depth: depth + 1))
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
                while let next = at(lines, &i), next.indent > indent, !isListItem(next.text) || next.indent > column {
                    s += " " + next.text
                    i += 1
                }
                items.append(scalar(s, depth: depth + 1))
            }
        }
        return .list(items)
    }

    private static func map(_ lines: inout [Line], _ i: inout Int, indent: Int, depth: Int) -> Value {
        var pairs: [(String, Value)] = []
        while let line = at(lines, &i), line.indent == indent, let kv = keyValue(line.text) {
            let (key, rest) = kv
            i += 1
            let value: Value
            if rest.isEmpty || rest.hasPrefix("#") {
                // A nested block: deeper, or a list at the key's own indent.
                if let next = at(lines, &i), next.indent > indent || (next.indent == indent && isListItem(next.text)) {
                    value = node(&lines, &i, indent: next.indent, depth: depth + 1)
                } else {
                    value = .scalar("")
                }
            } else if let style = rest.first, style == "|" || style == ">",
                      rest.dropFirst().prefix { $0 != "#" }.allSatisfy({ "+-0123456789 ".contains($0) }) {
                value = .scalar(blockScalar(lines, &i, above: indent, folded: style == ">"))
            } else {
                var s = String(rest)
                // A plain value continued on more-indented lines.
                while let next = at(lines, &i), next.indent > indent { s += " " + next.text; i += 1 }
                value = scalar(s, depth: depth + 1)
            }
            pairs.append((key, value))
        }
        return .map(pairs)
    }

    /// A `|` (literal) or `>` (folded) block's text: the lines after its
    /// key indented more than the key, and the blank lines among them; a
    /// `#` line in it is text. Indentation beyond the block's first line is
    /// kept; trailing blank lines go (YAML's default "clip").
    private static func blockScalar(_ lines: [Line], _ i: inout Int, above indent: Int, folded: Bool) -> String {
        var block: [String] = []
        var base: Int?
        while i < lines.count {
            let line = lines[i]
            if line.blank { block.append(""); i += 1; continue }
            guard line.indent > indent else { break }
            let b = base ?? line.indent
            base = b
            block.append(String(repeating: " ", count: max(0, line.indent - b)) + line.text)
            i += 1
        }
        while block.last == "" { block.removeLast() }
        guard folded else { return block.joined(separator: "\n") }
        // Folded: lines join with a space; a blank line is a line break.
        var out = ""
        var lineStart = true
        for line in block {
            if line.isEmpty { out += "\n"; lineStart = true; continue }
            if !lineStart { out += " " }
            out += line
            lineStart = false
        }
        return out
    }

    /// A scalar, or a flow list `[a, b]` / flow map `{a: 1}` on one line,
    /// nested (`{links: [home, about]}`); unbalanced or too deep: its text.
    private static func scalar(_ s: String, depth: Int = 0) -> Value {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard depth <= maxDepth else { return .scalar(unquote(t)) }
        if t.hasPrefix("["), t.hasSuffix("]"), let parts = splitFlow(t.dropFirst().dropLast()) {
            if parts == [""] { return .list([]) }
            return .list(parts.map { scalar($0, depth: depth + 1) })
        }
        if t.hasPrefix("{"), t.hasSuffix("}"), let parts = splitFlow(t.dropFirst().dropLast()) {
            if parts == [""] { return .map([]) }
            var pairs: [(String, Value)] = []
            for part in parts {
                guard let colon = flowColon(part) else { return .scalar(unquote(t)) }
                pairs.append((unquote(String(part[..<colon])), scalar(String(part[part.index(after: colon)...]), depth: depth + 1)))
            }
            return .map(pairs)
        }
        return .scalar(unquote(t))
    }

    /// Splits on commas outside quotes and nested brackets, a trailing
    /// comma dropped; nil when the brackets don't balance.
    private static func splitFlow(_ s: Substring) -> [String]? {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var nesting = 0
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            switch ch {
            case "\"", "'": quote = ch
            case "[", "{": nesting += 1
            case "]", "}":
                nesting -= 1
                if nesting < 0 { return nil }
            case "," where nesting == 0:
                out.append(cur)
                cur = ""
                continue
            default: break
            }
            cur.append(ch)
        }
        guard nesting == 0, quote == nil else { return nil }
        out.append(cur)
        var parts = out.map { $0.trimmingCharacters(in: .whitespaces) }
        // One trailing comma is allowed (`{icon: owl.png,}`), as in YAML.
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts
    }

    /// A flow map entry's `:` (outside quotes and brackets).
    private static func flowColon(_ s: String) -> String.Index? {
        var quote: Character?
        var nesting = 0
        for idx in s.indices {
            let ch = s[idx]
            if let q = quote { if ch == q { quote = nil }; continue }
            switch ch {
            case "\"", "'": quote = ch
            case "[", "{": nesting += 1
            case "]", "}": nesting -= 1
            case ":" where nesting == 0: return idx
            default: break
            }
        }
        return nil
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let q = t.first, q == "\"" || q == "'", t.last == q { return String(t.dropFirst().dropLast()) }
        return t
    }
}
