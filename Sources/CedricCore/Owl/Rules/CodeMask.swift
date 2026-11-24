import Foundation

/// Where the strings and comments of a text are, so a rule's pattern only
/// ever matches code: `debugger` in a comment, `== None` in a docstring or
/// `rm $x` in an echoed string are not findings.
///
/// Built once per owl query from one lexer pass (the bracket lexer's
/// `scanCode` for Swift, JS, TS, C, CSS and Python; `scanShell` for shell),
/// and shared by every rule of that query. `code` is the text with every
/// comment and every string's inside blanked to spaces (newlines and
/// lengths kept, so offsets match the text; a string's first and last
/// characters stay, so `is "a"` still shows a quote after `is`).
public struct CodeMask {
    public struct Span: Sendable, Equatable {
        public enum Kind: Sendable { case string, comment }
        public var range: NSRange
        public var kind: Kind
        /// Python's string prefix letters, lower case ("r", "b", "f", "rb"…).
        public var prefix: String = ""
    }

    /// Sorted by location, not overlapping. A string with interpolations
    /// is one span per literal segment (the interpolated code is in none);
    /// a segment after an interpolation is blanked whole, closing quote too.
    public let spans: [Span]
    /// The text with comments and string insides blanked (see above), as
    /// an NSString made from UTF-16 units: fast `character(at:)` and
    /// regex matching (a bridged Swift string is slower for both).
    public let codeNS: NSString
    public var code: String { codeNS as String }

    public init(_ s: NSString, spans raw: [Span]) {
        var merged: [Span] = []
        // A lexer can step past the end on a trailing backslash: clamp.
        let n = s.length
        let raw = raw.compactMap { sp -> Span? in
            var c = sp
            let a = min(max(sp.range.location, 0), n)
            c.range = NSRange(location: a, length: min(NSMaxRange(sp.range), n) - a)
            return c
        }
        for sp in raw.sorted(by: { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.range.length > $1.range.length) })
        where sp.range.length > 0 {
            if let last = merged.last, sp.range.location < NSMaxRange(last.range) {
                if NSMaxRange(sp.range) > NSMaxRange(last.range) {
                    merged[merged.count - 1].range.length = NSMaxRange(sp.range) - last.range.location
                }
                continue
            }
            merged.append(sp)
        }
        spans = merged
        var units = Array(repeating: unichar(0), count: s.length)
        s.getCharacters(&units, range: NSRange(location: 0, length: s.length))
        for sp in merged {
            let a = sp.range.location, b = NSMaxRange(sp.range)
            // A string keeps its quotes (a here-document body, which has none, doesn't).
            let keepEnds = sp.kind == .string && [34, 39, 96, 47, 35].contains(units[a])
            let from = keepEnds ? a + 1 : a, to = keepEnds ? b - 1 : b
            var k = from
            while k < to { if units[k] != 10 { units[k] = 32 }; k += 1 }
        }
        codeNS = NSString(characters: units, length: units.count)
    }

    /// The span containing `offset`, if any (binary search).
    public func span(at offset: Int) -> Span? {
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = spans[mid].range
            if offset < r.location { hi = mid - 1 } else if offset >= NSMaxRange(r) { lo = mid + 1 } else { return spans[mid] }
        }
        return nil
    }

    /// `offset` is in code: not in a string or a comment.
    public func isCode(_ offset: Int) -> Bool { span(at: offset) == nil }

    /// The string that starts exactly at `offset`, if any.
    public func string(startingAt offset: Int) -> Span? {
        guard let sp = span(at: offset), sp.kind == .string, sp.range.location == offset else { return nil }
        return sp
    }

    /// The mask for a language the owl lexes, or nil. `window`: the text
    /// is a window that starts part-way into the file, so it may start
    /// inside a block comment or a docstring (see `startsInside`).
    public static func make(_ s: NSString, language: String, window: Bool = false) -> CodeMask? {
        switch language {
        case "swift", "javascript", "typescript", "c", "css", "python":
            if window, let end = startsInside(s, language: language) {
                // Lex what follows; the start up to `end` is comment or string.
                var units = Array(repeating: unichar(0), count: s.length)
                s.getCharacters(&units, range: NSRange(location: 0, length: s.length))
                for k in 0..<end where units[k] != 10 { units[k] = 32 }
                let rest = NSString(characters: units, length: units.count)
                let head = Span(range: NSRange(location: 0, length: end), kind: language == "python" ? .string : .comment)
                return CodeMask(s, spans: [head] + RulesHintProvider.scanCode(rest, language: language, forMask: true).spans)
            }
            return CodeMask(s, spans: RulesHintProvider.scanCode(s, language: language, forMask: true).spans)
        case "shell":
            if window, let end = startsInsideHeredoc(s) ?? firstBlankLineEnd(s) {
                var units = Array(repeating: unichar(0), count: s.length)
                s.getCharacters(&units, range: NSRange(location: 0, length: s.length))
                for k in 0..<end where units[k] != 10 { units[k] = 32 }
                let rest = NSString(characters: units, length: units.count)
                return CodeMask(s, spans: [Span(range: NSRange(location: 0, length: end), kind: .string)] + scanShell(rest))
            }
            return CodeMask(s, spans: scanShell(s))
        case "sql":
            if window, let end = startsInside(s, language: "c") {
                return CodeMask(s, spans: [Span(range: NSRange(location: 0, length: end), kind: .comment)] + scanSQL(s, from: end))
            }
            return CodeMask(s, spans: scanSQL(s))
        case "powershell":
            if window, let end = startsInsidePowerShell(s) {
                var units = Array(repeating: unichar(0), count: s.length)
                s.getCharacters(&units, range: NSRange(location: 0, length: s.length))
                for k in 0..<end where units[k] != 10 { units[k] = 32 }
                let rest = NSString(characters: units, length: units.count)
                return CodeMask(s, spans: [Span(range: NSRange(location: 0, length: end), kind: .string)]
                                + RulesHintProvider.scanPowerShell(rest, forMask: true).spans)
            }
            return CodeMask(s, spans: RulesHintProvider.scanPowerShell(s, forMask: true).spans)
        default:
            return nil
        }
    }

    /// Where a window that starts inside a block comment or a docstring
    /// leaves it (just past the closer), or nil if it doesn't seem to.
    /// C-like: a `*/` before any `/*`. Python: the first `"""` or `'''`
    /// reads as a closer: not after `=`, `(`, `,`, `[`, `return` or a
    /// string prefix, and not the first thing after a `def`/`class` line.
    static func startsInside(_ s: NSString, language: String) -> Int? {
        if language != "python" {
            let close = s.range(of: "*/"), open = s.range(of: "/*")
            guard close.location != NSNotFound, open.location == NSNotFound || close.location < open.location else { return nil }
            return NSMaxRange(close)
        }
        let d = s.range(of: "\"\"\""), q = s.range(of: "'''")
        let first = [d, q].filter { $0.location != NSNotFound }.min { $0.location < $1.location }
        guard let t = first else { return nil }
        let line = s.lineRange(for: NSRange(location: t.location, length: 0))
        let before = s.substring(with: NSRange(location: line.location, length: t.location - line.location)).trimmingCharacters(in: .whitespaces)
        // A docstring's opening: the line before is a `def`/`class` line or
        // the end of a signature (`):`, `) -> T:`), not prose ending in ":".
        func previousLineOpensABlock() -> Bool {
            guard line.location > 0 else { return false }   // the window's first line: unknown
            // The line before, skipping blank and comment lines (`# type: …`).
            var start = line.location
            var text = ""
            while start > 0 {
                let prev = s.lineRange(for: NSRange(location: start - 1, length: 0))
                text = s.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines)
                start = prev.location
                if !text.isEmpty, !text.hasPrefix("#") { break }
                if start == 0 { return false }
            }
            return blockOpener.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
        let opener = ["=", "(", ",", "[", "{", ":"].contains { before.hasSuffix($0) } || before.hasSuffix("return")
            || (before.count <= 2 && before.lowercased().allSatisfy { "rbfu".contains($0) } && !before.isEmpty)
        if opener { return nil }
        if before.isEmpty {
            // The first statement after `def …:` / `class …:` is a docstring's opening.
            if previousLineOpensABlock() { return nil }
            // A closing quote ends its line; an opening one usually has text
            // after it (unless it follows a def line, checked above).
            let after = s.substring(with: NSRange(location: NSMaxRange(t), length: NSMaxRange(line) - NSMaxRange(t))).trimmingCharacters(in: .whitespacesAndNewlines)
            // (`""" % params` or `""")` continues an expression: a closer.)
            if !after.isEmpty, !after.hasPrefix("#"), !"%),.]};+".contains(after.first!) { return nil }
        }
        // The same quotes closing again on the line: a one-line string, not a closer.
        let restOfLine = NSRange(location: NSMaxRange(t), length: NSMaxRange(line) - NSMaxRange(t))
        if s.range(of: s.substring(with: t), options: [], range: restOfLine).location != NSNotFound { return nil }
        return NSMaxRange(t)
    }

    static let blockOpener = try! NSRegularExpression(pattern: #"^(async\s+def|def|class)\b.*:$|\)\s*(->.*)?:$"#)
    static let heredocWord = try! NSRegularExpression(pattern: #"^_?[A-Z][A-Z0-9_]*$"#)

    /// A shell window that starts inside a here-document: a line that is
    /// only a terminator-like word (EOF, _ACEOF, PY…) before any `<<` in
    /// the window. Where the body ends (past that line), or nil.
    static func startsInsideHeredoc(_ s: NSString) -> Int? {
        let first = s.range(of: "<<")
        var at = 0
        while at < s.length {
            let r = s.lineRange(for: NSRange(location: at, length: 0))
            if first.location != NSNotFound, r.location > first.location { return nil }
            let t = s.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 2, heredocWord.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil { return NSMaxRange(r) }
            at = NSMaxRange(r)
        }
        return nil
    }

    /// A shell window may also start inside a multi-line quoted string,
    /// which turns its quoting inside out. Lexing from the first blank line
    /// (rare inside a string) is safer; the lines above it are skipped.
    static func firstBlankLineEnd(_ s: NSString) -> Int? {
        var at = 0, n = 0
        while at < s.length, n < 40 {
            let r = s.lineRange(for: NSRange(location: at, length: 0))
            if s.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return at == 0 ? nil : NSMaxRange(r) }
            at = NSMaxRange(r); n += 1
        }
        return nil
    }

    // MARK: Shell

    /// Shell's strings and comments: `'…'`, `$'…'` (backslash escapes),
    /// `"…"` (backslash escapes; `$(…)` inside is part of the string here),
    /// `#` comments where a word starts (not `$#`, `${#x}` or `a#b`), and
    /// here-document bodies (`<<EOF`, `<<-EOF`, `<<'EOF'`, `<<"EOF"`; the
    /// body ends at a line that is the word, after tabs for `<<-`). A
    /// backslash in code escapes the next character. `<<<` is a
    /// here-string, not a here-document.
    public static func scanShell(_ s: NSString) -> [Span] {
        let n = s.length
        var out: [Span] = []
        var i = 0
        func ch(_ k: Int) -> unichar { k >= 0 && k < n ? s.character(at: k) : 0 }
        var pendingHeredocs: [(word: String, dash: Bool)] = []

        func startsWord(_ k: Int) -> Bool {
            guard k > 0 else { return true }
            let p = ch(k - 1)
            return p == 32 || p == 9 || p == 10 || p == 59 || p == 38 || p == 124 || p == 40 || p == 41 || p == 13
        }

        func readHeredocBodies() {   // i is just past a newline
            for doc in pendingHeredocs {
                let start = i
                while i < n {
                    var e = i
                    while e < n, ch(e) != 10 { e += 1 }
                    var b = i
                    if doc.dash { while b < e, ch(b) == 9 { b += 1 } }
                    var lineEnd = e
                    if lineEnd > b, ch(lineEnd - 1) == 13 { lineEnd -= 1 }
                    let line = s.substring(with: NSRange(location: b, length: lineEnd - b))
                    i = min(e + 1, n)
                    if line == doc.word {
                        out.append(Span(range: NSRange(location: start, length: e - start), kind: .string))
                        break
                    }
                    if e >= n { out.append(Span(range: NSRange(location: start, length: n - start), kind: .string)) }
                }
            }
            pendingHeredocs = []
        }

        while i < n {
            let k = ch(i)
            switch k {
            case 92:   // \x in code
                i += 2
                continue
            case 10:
                i += 1
                if !pendingHeredocs.isEmpty { readHeredocBodies() }
                continue
            case 39:   // '…'
                let start = i, escapes = i > 0 && ch(i - 1) == 36   // $'…'
                i += 1
                while i < n, ch(i) != 39 { i += escapes && ch(i) == 92 ? 2 : 1 }
                i = min(i + 1, n)
                out.append(Span(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            case 34:   // "…"
                let start = i
                i += 1
                while i < n, ch(i) != 34 { i += ch(i) == 92 ? 2 : 1 }
                i = min(i + 1, n)
                out.append(Span(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            case 35 where startsWord(i):
                let start = i
                while i < n, ch(i) != 10 { i += 1 }
                out.append(Span(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            case 60 where ch(i + 1) == 60 && ch(i + 2) != 60 && ch(i - 1) != 60:   // << (not <<<)
                var j = i + 2
                let dash = ch(j) == 45
                if dash { j += 1 }
                while ch(j) == 32 || ch(j) == 9 { j += 1 }
                var q: unichar = 0
                if ch(j) == 39 || ch(j) == 34 { q = ch(j); j += 1 }
                let ws = j
                while j < n, let u = UnicodeScalar(ch(j)), q != 0 ? ch(j) != q && ch(j) != 10
                        : (CharacterSet.alphanumerics.contains(u) || u == "_" || u == "-" || u == "." || u == "\\") { j += 1 }
                var word = s.substring(with: NSRange(location: ws, length: j - ws))
                word.removeAll { $0 == "\\" }
                if q != 0, ch(j) == q { j += 1 }
                // Not `$((1 << 3))`: a here-document's word doesn't start with a digit.
                if let f = word.unicodeScalars.first, !CharacterSet.decimalDigits.contains(f) { pendingHeredocs.append((word, dash)) }
                i = max(j, i + 2)
                continue
            default:
                i += 1
            }
        }
        return out
    }

    // MARK: SQL

    /// SQL's strings and comments: `'…'` (`''` and `\'` escapes), `"…"`
    /// and `` `…` `` identifiers, `--` and `/* … */` comments, and
    /// PostgreSQL's dollar-quoted bodies (`$$ … $$`, `$tag$ … $tag$`).
    public static func scanSQL(_ s: NSString, from start: Int = 0) -> [Span] {
        let n = s.length
        var out: [Span] = []
        var i = start
        func ch(_ k: Int) -> unichar { k >= 0 && k < n ? s.character(at: k) : 0 }
        while i < n {
            let k = ch(i)
            switch k {
            case 39, 34, 96:   // ' " `
                let a = i
                i += 1
                while i < n {
                    let c = ch(i)
                    if k == 39, c == 92 { i += 2; continue }
                    if c == k { if ch(i + 1) == k { i += 2; continue }; i += 1; break }
                    i += 1
                }
                out.append(Span(range: NSRange(location: a, length: min(i, n) - a), kind: .string))
            case 45 where ch(i + 1) == 45:   // --
                let a = i
                while i < n, ch(i) != 10 { i += 1 }
                out.append(Span(range: NSRange(location: a, length: i - a), kind: .comment))
            case 47 where ch(i + 1) == 42:   // /*
                let a = i
                i += 2
                while i < n, !(ch(i) == 42 && ch(i + 1) == 47) { i += 1 }
                i = min(i + 2, n)
                out.append(Span(range: NSRange(location: a, length: i - a), kind: .comment))
            case 36:   // $tag$ … $tag$ (not $1, a parameter)
                var j = i + 1
                while j < n, let u = UnicodeScalar(ch(j)), CharacterSet.letters.contains(u) || u == "_" { j += 1 }
                guard ch(j) == 36, !(i > 0 && CharacterSet.alphanumerics.contains(UnicodeScalar(ch(i - 1)) ?? " ")) else { i += 1; continue }
                let tag = s.substring(with: NSRange(location: i, length: j - i + 1))
                let close = s.range(of: tag, options: [], range: NSRange(location: j + 1, length: n - j - 1))
                let end = close.location == NSNotFound ? n : NSMaxRange(close)
                out.append(Span(range: NSRange(location: i, length: end - i), kind: .string))
                i = end
            default:
                i += 1
            }
        }
        return out
    }

    // MARK: PowerShell

    /// A PowerShell window that starts inside a block comment (`#>` before
    /// any `<#`) or a here-string (a line starting `'@` or `"@` before any
    /// `@'`/`@"` opener): where it leaves it.
    static func startsInsidePowerShell(_ s: NSString) -> Int? {
        let close = s.range(of: "#>"), open = s.range(of: "<#")
        if close.location != NSNotFound, open.location == NSNotFound || close.location < open.location { return NSMaxRange(close) }
        for q in ["'@", "\"@"] {
            let c = s.range(of: "\n" + q)
            let o = s.range(of: q.hasPrefix("'") ? "@'" : "@\"")
            if c.location != NSNotFound, o.location == NSNotFound || c.location < o.location { return NSMaxRange(c) }
        }
        return nil
    }
}
