import Foundation

/// JSON: strings (keys when followed by a colon), numbers, true/false/null.
/// No state: a JSON string can't span lines.
public struct JSONTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c == C.quote {
                var j = i + 1
                while j < n, b[j] != C.quote { j += b[j] == C.backslash ? 2 : 1 }
                j = min(n, j + 1)
                let after = b.skipSpaces(from: j)
                t.add(i, j, after < n && b[after] == C.colon ? .key : .string)
                i = j
            } else if C.isDigit(c) || c == C.minus {
                let end = b.scanNumber(from: c == C.minus ? i + 1 : i)
                t.add(i, end, .number)
                i = max(end, i + 1)
            } else if C.isAlpha(c) {
                var j = i
                while j < n, C.isAlpha(b[j]) { j += 1 }
                t.add(i, j, .constant)
                i = j
            } else {
                i += 1
            }
        }
    }
}

/// YAML: comments, keys, quoted strings, numbers and booleans, anchors and
/// aliases, document markers and list dashes. Block scalars (`|`, `>`) are
/// not tracked across lines, so a `key: value` line inside one is
/// coloured as a key (known v0 gap).
public struct YAMLTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { false }
    private static let constants = WordSet(["true", "false", "yes", "no", "on", "off", "null", "~"], caseInsensitive: true)

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var i = b.skipSpaces(from: 0)
        if b.has(Array("---".utf16), at: 0) || b.has(Array("...".utf16), at: 0), n == 3 || (n > 3 && C.isSpace(b[3])) {
            t.add(0, 3, .punctuation)
            i = 3
        }
        // List dashes: "- item", "- - nested".
        while i + 1 < n, b[i] == C.minus, C.isSpace(b[i + 1]) {
            t.add(i, i + 1, .punctuation)
            i = b.skipSpaces(from: i + 1)
        }
        if i < n, b[i] == C.minus, i + 1 == n { t.add(i, n, .punctuation); return }
        // A key: plain or quoted text up to ": " or ":" at the end.
        if i < n, b[i] != C.hash {
            var j = i
            if b[j] == C.quote || b[j] == C.apos {
                let q = b[j]
                j += 1
                while j < n, b[j] != q { j += 1 }
                j = min(n, j + 1)
            } else {
                while j < n, !(b[j] == C.colon && (j + 1 == n || C.isSpace(b[j + 1]))), b[j] != C.hash || (j > i && !C.isSpace(b[j - 1])) { j += 1 }
            }
            if j < n, b[j] == C.colon, j + 1 == n || C.isSpace(b[j + 1]) {
                t.add(i, j, .key)
                i = j + 1
            }
        }
        scalarRest(b, from: i, into: &t)
    }

    private func scalarRest(_ b: UnsafeBufferPointer<UInt16>, from start: Int, into t: inout [Token]) {
        let n = b.count
        var i = b.skipSpaces(from: start)
        while i < n {
            let c = b[i]
            if c == C.hash, i == 0 || C.isSpace(b[i - 1]) { t.add(i, n, .comment); return }
            if c == C.quote || c == C.apos {
                var j = i + 1
                while j < n, b[j] != c { j += (c == C.quote && b[j] == C.backslash) ? 2 : 1 }
                j = min(n, j + 1)
                t.add(i, j, .string)
                i = j
                continue
            }
            if c == C.amp || c == C.star, i + 1 < n, C.isIdent(b[i + 1]) {
                var j = i + 1
                while j < n, !C.isSpace(b[j]) { j += 1 }
                t.add(i, j, .variable)
                i = j
                continue
            }
            // A plain scalar: a number or a constant if it is the whole word.
            var j = i
            while j < n, !C.isSpace(b[j]), !(b[j] == C.hash && j > i && C.isSpace(b[j - 1])) { j += 1 }
            var wordEnd = j
            while wordEnd > i, b[wordEnd - 1] == C.comma || b[wordEnd - 1] == C.rbracket || b[wordEnd - 1] == C.rbrace { wordEnd -= 1 }
            var wordStart = i
            while wordStart < wordEnd, b[wordStart] == C.lbracket || b[wordStart] == C.lbrace { wordStart += 1 }
            if wordStart < wordEnd {
                let f = b[wordStart]
                if C.isDigit(f) || ((f == C.minus || f == C.plus || f == C.dot) && wordStart + 1 < wordEnd && C.isDigit(b[wordStart + 1])) {
                    let numEnd = b.scanNumber(from: C.isDigit(f) ? wordStart : wordStart + 1)
                    if numEnd == wordEnd { t.add(wordStart, wordEnd, .number) }
                } else if Self.constants.contains(b, wordStart, wordEnd) {
                    t.add(wordStart, wordEnd, .constant)
                }
            }
            i = b.skipSpaces(from: j)
        }
    }
}

/// Markdown: headings, fenced code, block quotes, list markers, code
/// spans, emphasis, strong, links and autolinks, and YAML frontmatter.
/// State: the low 4 bits are the mode (0 text, 1 inside a ``` fence, 2
/// inside a ~~~ fence, 3 inside frontmatter); bit 0x80 marks the top of
/// the file (`initialState`), where a `---` line opens frontmatter. In a
/// fence whose info string names a language (```` ```swift ````), bits
/// 8–12 hold that language (+1) and bits 13+ its tokenizer's own state, so
/// the code is coloured as that language, as HTMLTokenizer does for
/// <script>.
public struct MarkdownTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { true }
    public var initialState: UInt32 { Self.topOfFile }
    static let topOfFile: UInt32 = 0x80
    private static let backticks: [UInt16] = Array("```".utf16)
    private static let tildes: [UInt16] = Array("~~~".utf16)
    private static let yaml = YAMLTokenizer()
    private static let languages = Language.allCases
    private static let innerMask: UInt32 = (1 << 19) - 1

    /// Whether the line is `---` (or `...` with `orDots`), trailing spaces allowed.
    private static func isMarker(_ b: UnsafeBufferPointer<UInt16>, orDots: Bool) -> Bool {
        guard b.count >= 3, (b[0] == C.minus && b[1] == C.minus && b[2] == C.minus) || (orDots && b[0] == C.dot && b[1] == C.dot && b[2] == C.dot)
        else { return false }
        return b.skipSpaces(from: 3) == b.count
    }

    /// The fence's state: its mode, and the language its info string names.
    private static func openFence(_ b: UnsafeBufferPointer<UInt16>, at i: Int, mode: UInt32) -> UInt32 {
        var j = i
        while j < b.count, b[j] == b[i] { j += 1 }
        let info = String(decoding: b[j..<b.count], as: UTF16.self).trimmingCharacters(in: .whitespaces)
        guard let lang = Language(fenceInfo: info), lang.colorsFencedCode, let k = languages.firstIndex(of: lang) else { return mode }
        let tokenizer = Languages.tokenizer(for: lang)
        return mode | UInt32(k + 1) << 8 | (tokenizer.initialState & innerMask) << 13
    }

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        if state & Self.topOfFile != 0 {
            state &= ~Self.topOfFile
            if Self.isMarker(b, orDots: false) { t.add(0, n, .punctuation); state = 3; return }
        }
        if state & 0xf == 3 {
            if Self.isMarker(b, orDots: true) { t.add(0, n, .punctuation); state = 0; return }
            var inner: UInt32 = 0
            Self.yaml.tokenize(b, state: &inner, into: &t)
            return
        }
        let indent = b.skipSpaces(from: 0)
        let fence = state & 0xf == 1 ? Self.backticks : state & 0xf == 2 ? Self.tildes : nil
        if let fence {
            if indent <= 3, b.has(fence, at: indent), Self.onlyFence(b, from: indent) {
                t.add(0, n, .code)
                state = 0
                return
            }
            let lang = Int((state >> 8) & 0x1f)
            guard lang > 0, lang <= Self.languages.count else { t.add(0, n, .code); return }
            var inner = state >> 13
            var tokens: [Token] = []
            Languages.tokenizer(for: Self.languages[lang - 1]).tokenize(b, state: &inner, into: &tokens)
            // The gaps are code too (prose checks skip them), in the text colour.
            var at = 0
            for tok in tokens where tok.start >= at {
                t.add(at, tok.start, .embeddedCode)
                t.add(tok.start, tok.end, tok.kind)
                at = tok.end
            }
            t.add(at, n, .embeddedCode)
            state = (state & 0x1fff) | (inner & Self.innerMask) << 13
            return
        }
        if indent <= 3, b.has(Self.backticks, at: indent) { t.add(0, n, .code); state = Self.openFence(b, at: indent, mode: 1); return }
        if indent <= 3, b.has(Self.tildes, at: indent) { t.add(0, n, .code); state = Self.openFence(b, at: indent, mode: 2); return }
        if indent >= 4 && n > indent { t.add(0, n, .code); return }

        var i = indent
        if i < n, b[i] == C.hash {
            var j = i
            while j < n, b[j] == C.hash { j += 1 }
            if j - i <= 6, j == n || C.isSpace(b[j]) { t.add(0, n, .heading); return }
        }
        // Setext underline / thematic break.
        if i < n, b[i] == C.eq || b[i] == C.minus || b[i] == C.star || b[i] == C.underscore {
            let m = b[i]
            var j = i
            while j < n, b[j] == m || C.isSpace(b[j]) { j += 1 }
            if j == n, n - i >= 3 || m == C.eq { t.add(i, n, m == C.eq || m == C.minus ? .heading : .punctuation); return }
        }
        while i < n, b[i] == C.gt {
            t.add(i, i + 1, .punctuation)
            i = b.skipSpaces(from: i + 1)
        }
        // List marker: -, *, + or 1. / 1)
        if i + 1 < n, b[i] == C.minus || b[i] == C.star || b[i] == C.plus, C.isSpace(b[i + 1]) {
            t.add(i, i + 1, .punctuation)
            i += 2
        } else if i < n, C.isDigit(b[i]) {
            var j = i
            while j < n, C.isDigit(b[j]) { j += 1 }
            if j + 1 < n, b[j] == C.dot || b[j] == C.rparen, C.isSpace(b[j + 1]) {
                t.add(i, j + 1, .punctuation)
                i = j + 2
            }
        }
        inline(b, from: i, into: &t)
    }

    /// A closing fence: only fence characters, then spaces.
    private static func onlyFence(_ b: UnsafeBufferPointer<UInt16>, from i: Int) -> Bool {
        var j = i
        while j < b.count, b[j] == b[i] { j += 1 }
        return b.skipSpaces(from: j) == b.count
    }

    private func inline(_ b: UnsafeBufferPointer<UInt16>, from start: Int, into t: inout [Token]) {
        let n = b.count
        var i = start
        while i < n {
            let c = b[i]
            if c == C.backslash { i += 2; continue }
            if c == C.backtick {
                var run = 0
                while i + run < n, b[i + run] == C.backtick { run += 1 }
                let closer = [UInt16](repeating: C.backtick, count: run)
                if let close = b.find(closer, from: i + run) {
                    t.add(i, close + run, .code)
                    i = close + run
                } else {
                    i += run
                }
                continue
            }
            if c == C.star || c == C.underscore {
                let strong = i + 1 < n && b[i + 1] == c
                let delim = [UInt16](repeating: c, count: strong ? 2 : 1)
                let bodyStart = i + delim.count
                if bodyStart < n, !C.isSpace(b[bodyStart]),
                   c == C.star || i == 0 || !C.isIdent(b[i - 1]),
                   let close = b.find(delim, from: bodyStart + 1), !C.isSpace(b[close - 1]) {
                    t.add(i, close + delim.count, strong ? .strong : .emphasis)
                    i = close + delim.count
                    continue
                }
                i += delim.count
                continue
            }
            // A [[wiki link]] or ![[embed]] (WikiLinks: the same rules as Backlinks).
            if c == C.lbracket || c == C.bang, i + 2 < n, b[i + 1] == C.lbracket,
               let end = WikiLinks.end(in: b, open: c == C.bang ? i + 1 : i) {
                t.add(i, end, .link)
                i = end
                continue
            }
            if c == C.lbracket || (c == C.bang && i + 1 < n && b[i + 1] == C.lbracket) {
                let open = c == C.bang ? i + 1 : i
                if let closeBracket = b.find([C.rbracket], from: open + 1), closeBracket + 1 < n, b[closeBracket + 1] == C.lparen,
                   let closeParen = b.find([C.rparen], from: closeBracket + 2) {
                    t.add(i, closeParen + 1, .link)
                    i = closeParen + 1
                    continue
                }
            }
            if c == C.lt, let close = b.find([C.gt], from: i + 1), b.has(Array("http".utf16), at: i + 1) {
                t.add(i, close + 1, .link)
                i = close + 1
                continue
            }
            if c == C.lt, i + 1 < n, C.isAlpha(b[i + 1]) || b[i + 1] == C.slash, let close = b.find([C.gt], from: i + 1) {
                t.add(i, close + 1, .tag)
                i = close + 1
                continue
            }
            i += 1
        }
    }
}

/// CSS: comments (state 1), strings, at-rules, selectors outside braces,
/// property names inside them (state bit 0x100 = inside a block), numbers
/// with units, #hex colours and !important.
public struct CSSTokenizer: Tokenizer {
    public init() {}
    public var carriesState: Bool { true }

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var inBlock = state & 0x100 != 0
        var inComment = state & 1 != 0
        var depth = Int(state >> 16)
        var i = 0
        let commentClose: [UInt16] = [C.star, C.slash]
        while i < n {
            if inComment {
                if let close = b.find(commentClose, from: i) {
                    t.add(i, close + 2, .comment)
                    i = close + 2
                    inComment = false
                } else {
                    t.add(i, n, .comment)
                    i = n
                }
                continue
            }
            let c = b[i]
            if C.isSpace(c) { i += 1; continue }
            if c == C.slash, i + 1 < n, b[i + 1] == C.star { inComment = true; t.add(i, i + 2, .comment); i += 2; continue }
            if c == C.quote || c == C.apos {
                var j = i + 1
                while j < n, b[j] != c { j += b[j] == C.backslash ? 2 : 1 }
                j = min(n, j + 1)
                t.add(i, j, .string)
                i = j
                continue
            }
            if c == C.lbrace { depth += 1; inBlock = true; i += 1; continue }
            if c == C.rbrace { depth = max(0, depth - 1); inBlock = depth > 0; i += 1; continue }
            if c == C.at {
                var j = i + 1
                while j < n, C.isIdent(b[j]) || b[j] == C.minus { j += 1 }
                t.add(i, j, .keyword)
                i = j
                continue
            }
            if c == C.bang {
                var j = i + 1
                while j < n, C.isAlpha(b[j]) { j += 1 }
                t.add(i, j, .keyword)
                i = j
                continue
            }
            if inBlock {
                if c == C.hash {
                    var j = i + 1
                    while j < n, C.isIdent(b[j]) { j += 1 }
                    t.add(i, j, .number)
                    i = j
                    continue
                }
                if C.isDigit(c) || (c == C.dot && i + 1 < n && C.isDigit(b[i + 1])) || (c == C.minus && i + 1 < n && C.isDigit(b[i + 1])) {
                    var j = c == C.minus ? i + 1 : i
                    while j < n, C.isDigit(b[j]) || b[j] == C.dot { j += 1 }
                    while j < n, C.isAlpha(b[j]) || b[j] == C.percent { j += 1 }
                    t.add(i, j, .number)
                    i = j
                    continue
                }
                if C.isIdentStart(c) || c == C.minus {
                    var j = i
                    while j < n, C.isIdent(b[j]) || b[j] == C.minus { j += 1 }
                    let after = b.skipSpaces(from: j)
                    if after < n, b[after] == C.colon {
                        t.add(i, j, .key)
                    } else if after < n, b[after] == C.lparen {
                        t.add(i, j, .function)
                    }
                    i = j
                    continue
                }
                i += 1
            } else {
                // Selectors: everything up to "{" or a comma that isn't a comment or string.
                var j = i
                while j < n, b[j] != C.lbrace, b[j] != C.comma, !(b[j] == C.slash && j + 1 < n && b[j + 1] == C.star) { j += 1 }
                var end = j
                while end > i, C.isSpace(b[end - 1]) { end -= 1 }
                t.add(i, end, .tag)
                i = j < n && b[j] == C.comma ? j + 1 : j
            }
        }
        state = (inComment ? 1 : 0) | (inBlock ? 0x100 : 0) | UInt32(min(depth, 0xffff)) << 16
    }
}

/// HTML/XML: tags, attribute names and values, comments, entities, and
/// embedded <script> and <style> handed to the JavaScript and CSS
/// tokenizers. State: low 4 bits are the mode (0 text, 1 comment, 2 inside
/// a tag, 3 script body, 4 style body, 5 inside a <script tag, 6 inside a
/// <style tag); bits 8+ carry the embedded tokenizer's own state.
public struct HTMLTokenizer: Tokenizer {
    /// XML: no embedded <script>/<style> languages, and `<![CDATA[ … ]]>`
    /// sections are coloured as strings (state 7, across lines).
    public let xml: Bool
    public init(xml: Bool = false) { self.xml = xml }
    public var carriesState: Bool { true }
    private static let js = Languages.tokenizer(for: .javascript)
    private static let css = CSSTokenizer()
    private static let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
    private static let scriptClose = Array("</script".utf16), styleClose = Array("</style".utf16)
    private static let script = Array("script".utf16), style = Array("style".utf16)
    private static let cdataOpen = Array("<![CDATA[".utf16), cdataClose = Array("]]>".utf16)

    public func tokenize(_ b: UnsafeBufferPointer<UInt16>, state: inout UInt32, into t: inout [Token]) {
        let n = b.count
        var mode = state & 0xf
        var sub = state >> 8
        var i = 0
        while i < n {
            switch mode {
            case 1:
                if let close = b.find(Self.commentClose, from: i) {
                    t.add(i, close + 3, .comment); i = close + 3; mode = 0
                } else {
                    t.add(i, n, .comment); i = n
                }
            case 2, 5, 6:
                i = tagBody(b, from: i, into: &t, mode: &mode)
            case 7:
                if let close = b.find(Self.cdataClose, from: i) {
                    t.add(i, close + 3, .string); i = close + 3; mode = 0
                } else {
                    t.add(i, n, .string); i = n
                }
            case 3, 4:
                let closer = mode == 3 ? Self.scriptClose : Self.styleClose
                let end = b.find(closer, from: i, caseInsensitive: true) ?? n
                if end > i {
                    // Tokenize the embedded slice with its own tokenizer.
                    let slice = UnsafeBufferPointer(rebasing: b[i..<end])
                    var inner: [Token] = []
                    if mode == 3 { Self.js.tokenize(slice, state: &sub, into: &inner) } else { Self.css.tokenize(slice, state: &sub, into: &inner) }
                    for tok in inner { t.add(tok.start + i, tok.end + i, tok.kind) }
                }
                if end < n { mode = 0; sub = 0 }
                i = end
            default:
                let c = b[i]
                if c == C.lt {
                    if b.has(Self.commentOpen, at: i) { mode = 1; t.add(i, i + 4, .comment); i += 4; continue }
                    if xml, b.has(Self.cdataOpen, at: i) { mode = 7; t.add(i, i + 9, .string); i += 9; continue }
                    var j = i + 1
                    if j < n, b[j] == C.slash || b[j] == C.bang || b[j] == C.question { j += 1 }
                    let nameStart = j
                    while j < n, C.isIdent(b[j]) || b[j] == C.minus || b[j] == C.colon { j += 1 }
                    if j > nameStart {
                        t.add(i, j, .tag)
                        let closing = nameStart > i + 1 && b[i + 1] == C.slash
                        if xml { mode = 2 }
                        else if !closing, j - nameStart == 6, b.has(Self.script, at: nameStart, caseInsensitive: true) { mode = 5 }
                        else if !closing, j - nameStart == 5, b.has(Self.style, at: nameStart, caseInsensitive: true) { mode = 6 }
                        else { mode = 2 }
                        i = j
                        continue
                    }
                    i += 1
                } else if c == C.amp {
                    var j = i + 1
                    while j < n, C.isIdent(b[j]) || b[j] == C.hash { j += 1 }
                    if j < n, b[j] == C.semicolon, j > i + 1 { t.add(i, j + 1, .constant); i = j + 1 } else { i += 1 }
                } else {
                    i += 1
                }
            }
        }
        state = mode | sub << 8
    }

    /// Inside a tag: attribute names, values, and the closing ">" (which
    /// switches to script/style mode after <script>/<style>).
    private func tagBody(_ b: UnsafeBufferPointer<UInt16>, from start: Int, into t: inout [Token], mode: inout UInt32) -> Int {
        let n = b.count
        var i = start
        while i < n {
            let c = b[i]
            if c == C.gt {
                t.add(i, i + 1, .tag)
                mode = mode == 5 ? 3 : mode == 6 ? 4 : 0
                return i + 1
            }
            if c == C.slash || c == C.question, i + 1 < n, b[i + 1] == C.gt {
                t.add(i, i + 2, .tag)
                mode = 0
                return i + 2
            }
            if c == C.quote || c == C.apos {
                var j = i + 1
                while j < n, b[j] != c { j += 1 }
                j = min(n, j + 1)
                t.add(i, j, .string)
                i = j
                continue
            }
            if C.isIdentStart(c) {
                var j = i
                while j < n, C.isIdent(b[j]) || b[j] == C.minus || b[j] == C.colon || b[j] == C.dot { j += 1 }
                t.add(i, j, .attribute)
                i = j
                continue
            }
            i += 1
        }
        return n
    }
}
