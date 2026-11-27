import Foundation

/// The second batch of non-AI rules (see `RulesHintProvider.check` for the
/// order they are offered in). Each one is a pure function of the context
/// text (≤ 8 KB) and the document facts, one or two linear passes, no
/// allocation proportional to anything but the window.
extension RulesHintProvider {
    public static let conflictID = "rules.merge-conflict"
    public static let secretID = "rules.secret"
    public static let jsonInvalidID = "rules.json-invalid"
    public static let bracketsID = "rules.brackets"
    public static let smartQuotesID = "rules.smart-quotes-in-code"
    public static let yamlTabsID = "rules.yaml-tabs"
    public static let invisibleID = "rules.invisible-characters"
    public static let todoListID = "rules.todo-list"
    /// Followed by `.markdown`, `.html` or `.json`: one id per language.
    public static let languageGuessPrefix = "rules.language-guess."
    public static let duplicateWordID = "rules.duplicate-word"
    public static let doubleSpaceID = "rules.double-space"
    public static let finalNewlineID = "rules.final-newline"
    public static let mixedEndingsID = "rules.mixed-line-endings"
    public static let certificateExpiryID = "rules.certificate-expiry"

    /// The language a `language-guess` hint offers, from its id.
    public static func guessedLanguage(_ hint: OwlHint) -> Language? {
        guard hint.id.hasPrefix(languageGuessPrefix) else { return nil }
        return Language(rawValue: String(hint.id.dropFirst(languageGuessPrefix.count)))
    }

    static let proseLanguages: Set<String> = ["plain", "markdown"]
    static let codeLanguages: Set<String> = ["swift", "python", "javascript", "typescript", "json", "yaml", "css", "shell", "c", "ruby", "html",
                                             "powershell", "batch"]

    /// 1-based line of `offset` in `s`.
    static func lineNumber(_ s: NSString, at offset: Int) -> Int {
        var n = 1
        for i in 0..<min(offset, s.length) where s.character(at: i) == 10 { n += 1 }
        return n
    }

    /// "on line 12" for a whole document; "near here" for a window, whose
    /// line numbers aren't the document's.
    static func whereText(_ s: NSString, _ offset: Int, whole: Bool) -> String {
        whole ? String(localized: "on line \(lineNumber(s, at: offset))") : String(localized: "near here")
    }

    // MARK: Merge conflict markers

    /// The first `<<<<<<<` line followed (in order) by `=======` and
    /// `>>>>>>>` lines: the range of the `<<<<<<<` line.
    static func conflictMarker(_ s: NSString, lines: [NSRange]) -> NSRange? {
        var start: NSRange?, sawMiddle = false
        for r in lines {
            let line = s.substring(with: r)
            if line == "<<<<<<<" || line.hasPrefix("<<<<<<< ") { start = r; sawMiddle = false }
            else if start != nil, line == "=======" { sawMiddle = true }
            else if let st = start, sawMiddle, line == ">>>>>>>" || line.hasPrefix(">>>>>>> ") { return st }
        }
        return nil
    }

    // MARK: Secrets

    /// Shapes that are almost never anything but a credential. Built in
    /// pieces so this file doesn't look like one to a scanner.
    static let secretPatterns: [(String, NSRegularExpression)] = {
        let dash = String(repeating: "-", count: 5)
        let raw: [(String, String)] = [
            (String(localized: "a private key"), dash + "BEGIN ([A-Z]+ )?PRIVATE" + " KEY" + dash),
            (String(localized: "an AWS access key"), "\\b(AK" + "IA|AS" + "IA)[0-9A-Z]{16}\\b"),
            (String(localized: "a GitHub token"), "\\bgh[pousr]" + "_[A-Za-z0-9]{36,}\\b"),
            (String(localized: "a GitHub token"), "\\bgithub" + "_pat_[A-Za-z0-9_]{60,}"),
            (String(localized: "a Slack token"), "\\bxox[baprs]" + "-[0-9]{6,}-[0-9A-Za-z-]{10,}"),
            (String(localized: "a Stripe live key"), "\\b[sr]k" + "_live_[0-9A-Za-z]{20,}"),
            // sk-ant-…, sk-proj-… (hyphens and underscores in the key), or
            // a plain sk- and letters and digits only; either way checked
            // for a random-looking mix below (not "sk-learn-model-…").
            (Self.apiKeyKind, "\\bsk-(ant|proj|svcacct|admin)-[A-Za-z0-9_-]{32,}"),
            (Self.apiKeyKind, "\\bsk-[A-Za-z0-9]{32,}\\b"),
            // 0.3.0, from gitleaks' default rules: a fixed prefix and length.
            (String(localized: "a Google API key"), "\\bAI" + "za[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])"),
            (String(localized: "a GitLab token"), "\\bgl" + "pat-[0-9A-Za-z_-]{20,}(?![0-9A-Za-z_-])"),
            (String(localized: "an npm token"), "\\bnp" + "m_[A-Za-z0-9]{36}\\b"),
            (String(localized: "a Slack webhook"), "https://hooks\\.sl" + "ack\\.com/(services|workflows|triggers)/[A-Za-z0-9+/_-]{30,}"),
            (Self.urlPasswordKind, "\\b[A-Za-z][A-Za-z0-9+.-]{1,20}://([^\\s:/?#@'\"`<>]{1,64}):([^\\s/?#@'\"`<>]{1,128})@[A-Za-z0-9_.-]+"),
        ]
        return raw.compactMap { name, p in (try? NSRegularExpression(pattern: p)).map { (name, $0) } }
    }()

    static let apiKeyKind = String(localized: "an OpenAI or Anthropic API key")
    static let urlPasswordKind = String(localized: "a password in a URL")

    /// Placeholder passwords in docs and samples: `user:password@`,
    /// `${DB_PASS}`, `<pass>`, `****`, `%s`, `changeme`; or the user name
    /// again (`postgres:postgres@`, a local default).
    static let placeholderPasswords: Set<String> = ["password", "passwd", "pass", "pw", "pwd", "secret", "changeme", "change_me", "example",
                                                    "xxx", "xxxx", "xxxxx", "xxxxxx", "test", "testing", "foo", "bar", "baz", "token", "apikey",
                                                    "api_key", "your_password", "yourpassword", "mypassword", "my_password", "<password>",
                                                    "redacted", "hidden", "dummy", "fake", "sample", "placeholder", "admin", "root", "guest",
                                                    "anonymous", "user", "username", "secretpassword", "p@ssw0rd", "s3cret", "pa55word"]

    static func isRealURLPassword(user: String, password: String) -> Bool {
        let p = password.lowercased()
        if p.count < 4 || p == user.lowercased() || placeholderPasswords.contains(p) { return false }
        if p.contains("$") || p.contains("{") || p.contains("%") || p.contains("*") || p.contains("<") || p.contains("[") || p.contains("…") { return false }
        if Set(p).count <= 2 { return false }   // xxxx, ****, 1111
        if p.hasPrefix("your") || p.hasPrefix("my") || p.hasSuffix("password") || p.hasSuffix("pass") || p.hasSuffix("secret") { return false }
        if ["user", "username", "login", "name", "u", "x"].contains(user.lowercased()) { return false }
        return true
    }

    /// A generated key mixes upper case, lower case and digits; a slug or
    /// a sentence of words doesn't.
    static func looksRandom(_ s: Substring) -> Bool {
        var upper = 0, lower = 0, digit = 0
        for u in s.unicodeScalars {
            if ("A"..."Z").contains(u) { upper += 1 } else if ("a"..."z").contains(u) { lower += 1 } else if ("0"..."9").contains(u) { digit += 1 }
        }
        return upper >= 2 && lower >= 2 && digit >= 2
    }

    static func secret(_ s: String) -> (kind: String, range: NSRange)? {
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        var best: (String, NSRange)?
        for (name, re) in secretPatterns {
            for m in re.matches(in: s, range: all) {
                if name == apiKeyKind, !looksRandom(ns.substring(with: m.range).dropFirst(3)) { continue }
                if name == urlPasswordKind {
                    guard isRealURLPassword(user: ns.substring(with: m.range(at: 1)), password: ns.substring(with: m.range(at: 2))) else { continue }
                    // Only the password is the secret.
                    if best == nil || m.range.location < best!.1.location { best = (name, m.range(at: 2)) }
                    break
                }
                if best == nil || m.range.location < best!.1.location { best = (name, m.range) }
                break
            }
        }
        return best
    }

    /// Fix it for a secret (0.3.0): the secret replaced with a placeholder,
    /// one undo step. A private key goes from its BEGIN line to its END
    /// line (nil when the END isn't in the text); a password in a URL is
    /// only the password.
    static func secretPlaceholder(_ s: NSString, kind: String, range: NSRange) -> (range: NSRange, replacement: String)? {
        if kind == String(localized: "a private key") {
            let after = NSRange(location: NSMaxRange(range), length: s.length - NSMaxRange(range))
            let end = s.range(of: PEM.dashes + "END ", options: [], range: after)
            guard end.location != NSNotFound else { return nil }
            let close = s.range(of: PEM.dashes, options: [], range: NSRange(location: NSMaxRange(end), length: s.length - NSMaxRange(end)))
            guard close.location != NSNotFound, s.substring(with: NSRange(location: end.location, length: NSMaxRange(close) - end.location)).contains("PRIVATE") else { return nil }
            return (NSRange(location: range.location, length: NSMaxRange(close) - range.location), "<private key removed>")
        }
        if kind == urlPasswordKind { return (range, "<password>") }
        return (range, "<REDACTED>")
    }

    // MARK: Certificates about to expire

    /// The first certificate in the window that has expired or expires
    /// within 30 days (only whole PEM blocks inside the window are read).
    static func certificateExpiry(_ s: String, now: Date) -> (title: String, detail: String, range: NSRange)? {
        guard s.contains(PEM.begin + "CERTIFICATE" + PEM.dashes) || s.contains(PEM.begin + "PKCS7" + PEM.dashes) else { return nil }
        for (range, item) in Certificates.items(inText: s) {
            guard let cert = item.certificate, cert.needsAttention(at: now), let end = cert.notAfter else { continue }
            let name = cert.summary.isEmpty ? String(localized: "This certificate") : "“\(cert.summary)”"
            let date = end.formatted(date: .abbreviated, time: .omitted)
            switch cert.validity(at: now) {
            case .expired(let d)?:
                let ago = d == 0 ? String(localized: "today") : d == 1 ? String(localized: "yesterday") : String(localized: "\(d) days ago")
                return (String(localized: "This certificate expired \(ago)."),
                        String(localized: "\(name) was valid until \(date). Anything still using it will be refused."), range)
            case .valid(let d)?:
                let when = d == 0 ? String(localized: "today") : d == 1 ? String(localized: "tomorrow") : String(localized: "in \(d) days")
                return (String(localized: "This certificate expires \(when)."),
                        String(localized: "\(name) is valid until \(date). Time to renew it."), range)
            default: continue
            }
        }
        return nil
    }

    // MARK: JSON that doesn't parse

    /// Names and extensions whose "JSON" allows comments.
    static func allowsComments(_ fileName: String?) -> Bool {
        guard let n = fileName?.lowercased() else { return false }
        return n.hasSuffix(".jsonc") || n.hasSuffix(".json5") || n.hasPrefix("tsconfig") || n.hasPrefix("jsconfig")
            || n.hasPrefix(".eslintrc") || n.hasPrefix(".babelrc") || n == "settings.json" || n == "keybindings.json"
            || n.hasSuffix(".code-workspace")
    }

    /// The error and its UTF-16 offset, or nil when it parses (or is empty).
    static func jsonError(_ s: String) -> (message: String, offset: Int)? {
        guard s.contains(where: { !$0.isWhitespace }) else { return nil }
        let bytes = Array(s.utf8)
        var p = JSONFormatter.Parser(bytes)
        var out: [UInt8] = []
        do {
            p.skipSpace()
            try p.value(&out, pretty: false, indent: [], depth: 0)
            p.skipSpace()
            if p.i < bytes.count { throw p.error(String(localized: "unexpected text after the value")) }
            return nil
        } catch TextToolError.invalidJSON(let msg) {
            let utf8 = s.utf8
            let idx = utf8.index(utf8.startIndex, offsetBy: min(p.i, bytes.count))
            return (msg, s.utf16.distance(from: s.utf16.startIndex, to: idx.samePosition(in: s.utf16) ?? s.utf16.endIndex))
        } catch {
            return nil
        }
    }

    /// Where the parser stopped is a closing `}` or `]` (after spaces) and
    /// the last thing before it is a comma: that comma's offset.
    static func trailingComma(_ s: NSString, before offset: Int) -> Int? {
        var i = min(offset, s.length)
        while i < s.length, [32, 9, 10, 13].contains(s.character(at: i)) { i += 1 }
        guard i < s.length, s.character(at: i) == 125 || s.character(at: i) == 93 else { return nil } // } ]
        var j = i - 1
        while j >= 0, [32, 9, 10, 13].contains(s.character(at: j)) { j -= 1 }
        return j >= 0 && s.character(at: j) == 44 ? j : nil
    }

    static func nextNonSpace(_ s: NSString, after offset: Int) -> Int? {
        var i = offset + 1
        while i < s.length, [32, 9, 10, 13].contains(s.character(at: i)) { i += 1 }
        return i < s.length ? i : nil
    }

    // MARK: Brackets and curly quotes in code

    struct CodeScan {
        enum Problem: Equatable {
            case unexpected(Character, at: Int)
            case mismatched(Character, at: Int, opener: Character, openedAt: Int)
            case unclosed(Character, at: Int)
        }
        var problem: Problem?
        /// UTF-16 offsets of “ ” ‘ ’ used as quotes in code (not in strings or comments).
        var curly: [Int] = []
        /// Strings, comments and regex literals, in the order they end
        /// (an interpolation's strings come before the string around them).
        /// `CodeMask` sorts and merges them. With `splitInterpolations`, a
        /// string with interpolations is one span per literal segment: the
        /// code of a Swift `\( … )` or JS `${ … }`, its brackets included,
        /// is in no span, so the mask keeps it.
        var spans: [CodeMask.Span] = []
    }

    /// A small lexer: skips strings, comments (and JS regex literals), and
    /// tracks (), [] and {} in what's left. Swift `\( )` and JS `${ }`
    /// interpolations are scanned as code. Stops at the first problem.
    /// `forMask`: no bracket tracking, never stops: one pass for the
    /// strings and comments of a window (`CodeMask`).
    /// `splitInterpolations`: see `CodeScan.spans` (the edit validation's
    /// bracket count; the lint rules keep interpolations blanked).
    static func scanCode(_ s: NSString, language: String, forMask: Bool = false, splitInterpolations: Bool = false) -> CodeScan {
        var scan = CodeScan()
        let n = s.length
        let swift = language == "swift", python = language == "python", css = language == "css"
        let js = language == "javascript" || language == "typescript", c = language == "c"
        let slashComments = swift || js || c
        let blockComments = swift || js || c || css
        let singleQuoteStrings = js || c || python || css
        var stack: [(Character, Int)] = []
        var i = 0
        func ch(_ k: Int) -> unichar { k < n ? s.character(at: k) : 0 }

        /// Skips a quoted string starting at `i` (on the quote); handles escapes,
        /// Swift `#"…"#` raw strings, `"""` / `'''` blocks and interpolations.
        func skipString() {
            let start = i
            var segment = start   // where the current literal segment starts
            func endSegment(at end: Int) {
                guard end > segment else { return }
                scan.spans.append(.init(range: NSRange(location: segment, length: end - segment), kind: .string,
                                        prefix: python && segment == start ? pythonPrefix(s, start) : ""))
            }
            defer { endSegment(at: i) }
            var hashes = 0
            while ch(i) == 35 { hashes += 1; i += 1 }   // Swift raw: #"
            let q = ch(i)
            let triple = (swift || python) && ch(i + 1) == q && ch(i + 2) == q
            i += triple ? 3 : 1
            while i < n {
                let k = ch(i)
                if k == 92, hashes == 0 || (0..<hashes).allSatisfy({ ch(i + 1 + $0) == 35 }) {   // backslash
                    let after = i + 1 + hashes
                    if swift, ch(after) == 40 {   // \( … ): the segment ends at the "(", which is code
                        if splitInterpolations { endSegment(at: after) }
                        i = after + 1; code(until: 41)
                        if splitInterpolations { segment = i }
                        continue
                    }
                    i = after + 1; continue
                }
                if js, q == 96, k == 36, ch(i + 1) == 123 {   // ${ … }: likewise, from the "{"
                    if splitInterpolations { endSegment(at: i + 1) }
                    i += 2; code(until: 125)
                    if splitInterpolations { segment = i }
                    continue
                }
                if k == q {
                    if triple { if ch(i + 1) == q && ch(i + 2) == q { i += 3; break } }
                    else if (0..<hashes).allSatisfy({ ch(i + 1 + $0) == 35 }) { i += 1 + hashes; break }
                }
                if k == 10, !triple, q != 96 { break }   // unterminated: stop at the line end
                i += 1
            }
        }

        /// Code until the `closer` that balances the call (nil: the end).
        /// Brackets inside an interpolation are tracked on their own stack.
        func code(until closer: unichar?) {
            var depth = 0
            while i < n, scan.problem == nil {
                let k = ch(i)
                if let closer, k == closer, depth == 0 { i += 1; return }
                switch k {
                case 34: skipString(); continue
                case 39 where singleQuoteStrings: skipString(); continue
                case 96 where js: skipString(); continue
                case 35 where swift && swiftRegexHashes(at: i) > 0:   // #/ … /# (extended regex literal)
                    let hashes = swiftRegexHashes(at: i)
                    let start = i
                    defer { scan.spans.append(.init(range: NSRange(location: start, length: i - start), kind: .string)) }
                    i += hashes + 1
                    while i < n {
                        if ch(i) == 92 { i += 2; continue }
                        if ch(i) == 47, (0..<hashes).allSatisfy({ ch(i + 1 + $0) == 35 }) { i += 1 + hashes; break }
                        i += 1
                    }
                    continue
                case 35 where swift && (ch(i + 1) == 34 || ch(i + 1) == 35): skipString(); continue
                case 35 where python:
                    let start = i
                    while i < n, ch(i) != 10 { i += 1 }
                    scan.spans.append(.init(range: NSRange(location: start, length: i - start), kind: .comment))
                    continue
                case 47 where slashComments && ch(i + 1) == 47:
                    let start = i
                    while i < n, ch(i) != 10 { i += 1 }
                    scan.spans.append(.init(range: NSRange(location: start, length: i - start), kind: .comment))
                    continue
                case 47 where blockComments && ch(i + 1) == 42:
                    let start = i
                    defer { scan.spans.append(.init(range: NSRange(location: start, length: i - start), kind: .comment)) }
                    var nest = 0
                    i += 2
                    while i < n {
                        if ch(i) == 42, ch(i + 1) == 47 { i += 2; if nest == 0 { break }; nest -= 1; continue }
                        if swift, ch(i) == 47, ch(i + 1) == 42 { nest += 1; i += 2; continue }
                        i += 1
                    }
                    continue
                case 47 where swift && regexCanStart(at: i):
                    // A bare /…/ regex literal: no space after the opening
                    // slash and closed on the same line, else it's division.
                    if let end = swiftBareRegexEnd(from: i) {
                        scan.spans.append(.init(range: NSRange(location: i, length: end - i), kind: .string))
                        i = end; continue
                    }
                case 47 where js && regexCanStart(at: i):
                    let start = i
                    defer { scan.spans.append(.init(range: NSRange(location: start, length: i - start), kind: .string)) }
                    i += 1
                    var inClass = false
                    while i < n, ch(i) != 10 {
                        let r = ch(i)
                        if r == 92 { i += 2; continue }
                        if r == 91 { inClass = true } else if r == 93 { inClass = false } else if r == 47, !inClass { i += 1; break }
                        i += 1
                    }
                    continue
                case 0x201C, 0x2018:   // a curly quote opening a "string"
                    let close: unichar = k == 0x201C ? 0x201D : 0x2019
                    scan.curly.append(i)
                    i += 1
                    while i < n, ch(i) != 10, ch(i) != close { i += 1 }
                    if ch(i) == close { scan.curly.append(i); i += 1 }
                    continue
                case 0x201D, 0x2019:
                    scan.curly.append(i)
                case 40, 91, 123:
                    if closer != nil { depth += 1 }
                    if !forMask { stack.append((Character(UnicodeScalar(k)!), i)) }
                case 41, 93, 125:
                    if closer != nil { depth -= 1 }
                    if forMask { break }
                    let want: Character = k == 41 ? "(" : k == 93 ? "[" : "{"
                    let got = Character(UnicodeScalar(k)!)
                    guard let top = stack.popLast() else { scan.problem = .unexpected(got, at: i); return }
                    if top.0 != want { scan.problem = .mismatched(got, at: i, opener: top.0, openedAt: top.1); return }
                default: break
                }
                i += 1
            }
        }

        /// A `/` starts a regex after an operator or an opening bracket, not after a value.
        /// How many #s open a Swift `#/…/#` regex literal at `k`, or 0.
        func swiftRegexHashes(at k: Int) -> Int {
            var j = k
            while ch(j) == 35 { j += 1 }
            return ch(j) == 47 && j > k ? j - k : 0
        }

        /// Past the closing slash of a Swift bare regex literal starting at `k`.
        func swiftBareRegexEnd(from k: Int) -> Int? {
            let first = ch(k + 1)
            guard first != 32, first != 9, first != 10, first != 0, first != 61 else { return nil }   // not "/ ", "/="
            var j = k + 1, inClass = false
            while j < n, ch(j) != 10 {
                let r = ch(j)
                if r == 92 { j += 2; continue }
                if r == 91 { inClass = true } else if r == 93 { inClass = false } else if r == 47, !inClass {
                    return ch(j - 1) == 32 || ch(j - 1) == 9 ? nil : j + 1   // can't end with a space either
                }
                j += 1
            }
            return nil
        }

        func regexCanStart(at k: Int) -> Bool {
            var j = k - 1
            while j >= 0, ch(j) == 32 || ch(j) == 9 { j -= 1 }
            guard j >= 0, ch(j) != 10 else { return true }
            if let u = UnicodeScalar(ch(j)), "(,=:[!&|?{};+-*%<>~^".unicodeScalars.contains(u) { return true }
            // `return /x/`, `typeof /x/`
            var w = j
            while w >= 0, let u = UnicodeScalar(ch(w)), CharacterSet.letters.contains(u) { w -= 1 }
            let word = s.substring(with: NSRange(location: w + 1, length: j - w))
            return ["return", "typeof", "case", "in", "of", "yield", "await", "void", "delete"].contains(word)
        }

        code(until: nil)
        if scan.problem == nil, let open = stack.last { scan.problem = .unclosed(open.0, at: open.1) }
        return scan
    }

    /// PowerShell's own lexer for the bracket check: `#` and `<# … #>`
    /// comments, `'…'` (with `''`) and `"…"` strings (backtick escapes, `""`,
    /// `$( … )` scanned as code, to any depth), here-strings `@' … '@` /
    /// `@" … "@` skipped whole (they end only at a line starting `'@` /
    /// `"@`), `${any name}` variables and backtick-escaped characters in
    /// code. Typographic quotes are quotes in PowerShell, so none are
    /// reported as curly.
    static func scanPowerShell(_ s: NSString, forMask: Bool = false) -> CodeScan {
        var scan = CodeScan()
        let n = s.length
        var stack: [(Character, Int)] = []
        var i = 0
        func ch(_ k: Int) -> unichar { k >= 0 && k < n ? s.character(at: k) : 0 }
        func isDQ(_ c: unichar) -> Bool { c == 34 || c == 0x201C || c == 0x201D || c == 0x201E }
        func isSQ(_ c: unichar) -> Bool { c == 39 || c == 0x2018 || c == 0x2019 || c == 0x201A || c == 0x201B }
        func restOfLineBlank(_ k: Int) -> Bool {
            var j = k
            while j < n, ch(j) == 32 || ch(j) == 9 || ch(j) == 13 { j += 1 }
            return j >= n || ch(j) == 10
        }

        func span(_ start: Int, _ kind: CodeMask.Span.Kind) {
            if forMask { scan.spans.append(CodeMask.Span(range: NSRange(location: start, length: min(i, n) - start), kind: kind)) }
        }

        func expandable() {   // on the opening quote
            let start = i
            defer { span(start, .string) }
            i += 1
            while i < n, scan.problem == nil {
                let k = ch(i)
                if k == 96 { i += 2; continue }   // `x
                if isDQ(k) { if isDQ(ch(i + 1)) { i += 2; continue }; i += 1; return }
                if k == 36, ch(i + 1) == 40 { i += 2; code(until: 41); continue }   // $( … )
                if k == 36, ch(i + 1) == 123 { i += 2; while i < n, ch(i) != 125 { i += 1 }; i += 1; continue }
                i += 1
            }
        }

        func code(until closer: unichar?) {
            var depth = 0
            while i < n, scan.problem == nil {
                let k = ch(i)
                if let closer, k == closer, depth == 0 { i += 1; return }
                switch k {
                case 96: i += 2; continue   // backtick escape
                case 60 where ch(i + 1) == 35:   // <# … #>
                    let start = i
                    i += 2
                    while i < n, !(ch(i) == 35 && ch(i + 1) == 62) { i += 1 }
                    i += 2
                    span(start, .comment)
                    continue
                case 35 where i == 0 || [32, 9, 10, 13, 59, 40, 123, 125, 124, 44, 61].contains(ch(i - 1)):
                    let start = i
                    while i < n, ch(i) != 10 { i += 1 }
                    span(start, .comment)
                    continue
                case 64 where (isSQ(ch(i + 1)) || isDQ(ch(i + 1))) && restOfLineBlank(i + 2):   // here-string
                    let single = isSQ(ch(i + 1)), start = i
                    i += 2
                    while i < n {
                        if ch(i) == 10, single ? isSQ(ch(i + 1)) : isDQ(ch(i + 1)), ch(i + 2) == 64 { i += 3; break }
                        i += 1
                    }
                    span(start, .string)
                    continue
                case _ where isSQ(k):
                    let start = i
                    i += 1
                    while i < n { if isSQ(ch(i)) { if isSQ(ch(i + 1)) { i += 2; continue }; i += 1; break }; i += 1 }
                    span(start, .string)
                    continue
                case _ where isDQ(k):
                    expandable()
                    continue
                case 36 where ch(i + 1) == 123:   // ${any name}
                    i += 2
                    while i < n, ch(i) != 125, ch(i) != 10 { i += ch(i) == 96 ? 2 : 1 }
                    i += 1
                    continue
                case 40, 91, 123:
                    if closer != nil { depth += 1 }
                    if !forMask { stack.append((Character(UnicodeScalar(k)!), i)) }
                case 41, 93, 125:
                    if closer != nil { depth -= 1 }
                    if forMask { break }
                    let want: Character = k == 41 ? "(" : k == 93 ? "[" : "{"
                    let got = Character(UnicodeScalar(k)!)
                    guard let top = stack.popLast() else { scan.problem = .unexpected(got, at: i); return }
                    if top.0 != want { scan.problem = .mismatched(got, at: i, opener: top.0, openedAt: top.1); return }
                default: break
                }
                i += 1
            }
        }

        code(until: nil)
        if forMask { return scan }
        if scan.problem == nil, let open = stack.last { scan.problem = .unclosed(open.0, at: open.1) }
        return scan
    }

    static let preprocessorConditional = try! NSRegularExpression(pattern: #"(?m)^[ \t]*#[ \t]*(if|ifdef|ifndef|elif|else)\b"#)

    /// C, C++ or Objective-C with #if/#ifdef/#else: its branches can't be
    /// bracket-counted as one text.
    static func hasPreprocessorConditional(_ s: NSString) -> Bool {
        preprocessorConditional.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) != nil
    }

    // MARK: YAML tabs

    func yamlTabs(_ s: NSString, lines: [NSRange]) -> Rewrite? {
        Self.rewrite(s, lines) { r in
            var i = r.location, out = "", sawTab = false
            while i < NSMaxRange(r) {
                let c = s.character(at: i)
                if c == 9 { sawTab = true; out += "  " } else if c == 32 { out += " " } else { break }
                i += 1
            }
            guard sawTab else { return nil }
            return out + s.substring(with: NSRange(location: i, length: NSMaxRange(r) - i))
        }
    }

    // MARK: Invisible characters

    /// Zero-width spaces, word joiners and stray byte-order marks (and, in
    /// code, non-breaking spaces): the range spanning them and the text
    /// with them removed (a non-breaking space becomes a plain one).
    static func invisibles(_ s: NSString, code: Bool) -> (range: NSRange, replacement: String, count: Int)? {
        var first = -1, last = -1, count = 0
        for i in 0..<s.length {
            let c = s.character(at: i)
            if c == 0xFEFF || (code && (c == 0x200B || c == 0x2060 || c == 0x00A0)) {
                if first < 0 { first = i }
                last = i
                count += 1
            }
        }
        guard first >= 0 else { return nil }
        let r = NSRange(location: first, length: last - first + 1)
        var out = String.UnicodeScalarView()
        for u in s.substring(with: r).unicodeScalars {
            if u.value == 0xFEFF || (code && (u.value == 0x200B || u.value == 0x2060)) { continue }
            out.append(code && u.value == 0x00A0 ? " " : u)
        }
        return (r, String(out), count)
    }

    // MARK: To-do lists

    static let todoWords = ["todo", "to do", "to-do", "tasks", "checklist", "shopping", "groceries"]
    static let boxMarkers = ["[ ] ", "[] ", "[x] ", "[X] ", "☐ ", "☑ ", "☒ "]
    static let bulletMarkers = ["- ", "* ", "• "]

    /// The item's text and whether it's ticked, or nil if the line isn't an item.
    static func todoItem(_ line: String) -> (text: String, done: Bool, boxed: Bool)? {
        var t = Substring(line.drop { $0 == " " || $0 == "\t" })
        var boxed = false, done = false
        if t.hasPrefix("- [") || t.hasPrefix("* [") { return nil }   // already Markdown
        for b in bulletMarkers where t.hasPrefix(b) { t = t.dropFirst(b.count); break }
        for b in boxMarkers where t.hasPrefix(b) {
            boxed = true
            done = b.contains("x") || b.contains("X") || b.hasPrefix("☑") || b.hasPrefix("☒")
            t = t.dropFirst(b.count)
            break
        }
        guard boxed || t.count < Substring(line.drop { $0 == " " || $0 == "\t" }).count else { return nil }
        let text = t.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (text, done, boxed)
    }

    /// Three or more item lines in a row, with a to-do title above them or
    /// checkbox markers on them: the rewrite to `- [ ] item`.
    static func todoList(_ s: NSString, lines: [NSRange]) -> Rewrite? {
        let texts = lines.map { s.substring(with: $0) }
        guard let titleIndex = texts.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let title = texts[titleIndex].lowercased()
        let titled = title.count < 60 && todoWords.contains { title.contains($0) }
        var run: [Int] = [], best: [Int] = []
        for (i, t) in texts.enumerated() {
            if todoItem(t) != nil { run.append(i) } else { if run.count > best.count { best = run }; run = [] }
        }
        if run.count > best.count { best = run }
        guard best.count >= 3 else { return nil }
        let boxed = best.filter { todoItem(texts[$0])!.boxed }.count
        guard titled || boxed >= 2 else { return nil }
        let items = Set(best.map { lines[$0].location })
        let index = Dictionary(uniqueKeysWithValues: best.map { (lines[$0].location, $0) })
        return rewrite(s, lines) { r in
            guard items.contains(r.location), let i = index[r.location], let item = todoItem(texts[i]) else { return nil }
            return (item.done ? "- [x] " : "- [ ] ") + item.text
        }
    }

    // MARK: Prose

    /// Doubled words that are often meant: "that that", "had had", "bye bye".
    static let meantTwice: Set<String> = ["that", "had", "is", "do", "so", "no", "bye", "ha", "haha", "now", "very", "really",
                                          "knock", "chop", "tut", "aye", "yeah", "yes", "well", "far", "many", "more", "again",
                                          "blah", "there", "can", "boo", "choo", "ding", "dum", "hip", "la", "na", "oh", "ho",
                                          "mm", "hmm", "uh", "um", "ah", "go", "wait", "please", "come", "out", "on", "and",
                                          "round", "over", "bang", "tick", "tock", "hush", "night", "pom", "run", "too", "her", "him",
                                          // Grammatical in other languages: "die die …", "nous nous …".
                                          "die", "das", "der", "nous", "vous"]

    /// A word and one or more copies of it right after it (one space, or
    /// a line break inside a paragraph): "the the", "the the the".
    static let doubledWord = try! NSRegularExpression(pattern: #"\b(\p{L}+)(?:(?: | *\n *)\1\b)+"#, options: [.caseInsensitive])
    static let nextCopy = try! NSRegularExpression(pattern: #"\G( | *\n *)(\p{L}+)"#)

    /// Articles of Spanish, Italian, Portuguese and French that are also
    /// sung ("la la la"): typed twice only as exactly two copies after a
    /// word that takes an article ("por la la tarde").
    static let sungArticles: Set<String> = ["la"]
    static let beforeArticle: Set<String> = [
        // Spanish, Portuguese
        "a", "de", "en", "por", "para", "con", "sin", "sobre", "entre", "hacia", "desde", "hasta", "que", "y", "o",
        "es", "era", "como", "pero", "ver", "toda", "todo", "em", "com", "pela", "na", "da",
        // Italian ("tra" and "fra" left out: "tra la la")
        "di", "in", "su", "per", "e", "è", "sulla", "alla",
        // French
        "à", "dans", "sur", "pour", "avec", "sous", "chez", "vers", "et", "est", "c'est", "par",
    ]

    /// The word before `location` (lower case), skipping spaces.
    static func wordBefore(_ s: NSString, _ location: Int) -> String {
        var e = location
        while e > 0, s.character(at: e - 1) == 32 { e -= 1 }
        var b = e
        while b > 0, let u = UnicodeScalar(s.character(at: b - 1)), CharacterSet.letters.contains(u) || u == "'" { b -= 1 }
        return s.substring(with: NSRange(location: b, length: e - b)).lowercased()
    }

    /// One run of a doubled word: the first word, and each further copy's
    /// range (its separator and itself), if it counts as typed twice.
    static func doubledRun(_ s: NSString, _ m: NSTextCheckingResult, skip: [NSRange]) -> (first: NSRange, copies: [NSRange])? {
        let firstWord = m.range(at: 1)
        let w = s.substring(with: firstWord)
        var copies: [NSRange] = []
        var at = NSMaxRange(firstWord)
        while at < NSMaxRange(m.range), let c = nextCopy.firstMatch(in: s as String, range: NSRange(location: at, length: NSMaxRange(m.range) - at)) {
            copies.append(c.range)
            at = NSMaxRange(c.range)
        }
        guard !copies.isEmpty else { return nil }
        let lower = w.lowercased()
        // Meant twice ("that that", "ha ha ha"); an article that is also
        // sung counts only as exactly two copies after a word that takes it.
        if meantTwice.contains(lower) {
            guard sungArticles.contains(lower), copies.count == 1,
                  beforeArticle.contains(wordBefore(s, firstWord.location)) else { return nil }
        }
        // Each copy in lower case and the first the same or capitalised
        // ("The the", "the the"; not "Duran Duran" or "ERROR error").
        for c in copies {
            let second = s.substring(with: NSRange(location: NSMaxRange(c) - firstWord.length, length: firstWord.length))
            guard second == second.lowercased(), w == second || w == second.prefix(1).uppercased() + second.dropFirst() else { return nil }
        }
        guard !skip.contains(where: { NSLocationInRange(m.range.location, $0) }) else { return nil }
        // Across a line break only mid-prose (not a column of single words).
        if s.substring(with: m.range).contains("\n") {
            let before = m.range.location - 1, after = NSMaxRange(m.range)
            guard before >= 0, s.character(at: before) != 10, after < s.length, s.character(at: after) != 10 else { return nil }
        }
        return (firstWord, copies)
    }

    /// Doubled words outside Markdown code: the rewrite drops every copy
    /// after the first ("the the the" → "the").
    static func duplicateWords(_ s: NSString, lines: [NSRange], markdown: Bool) -> (range: NSRange, replacement: String, count: Int, word: String)? {
        let skip = markdown ? markdownCodeRanges(s, lines: lines) : []
        var hits: [NSRange] = [], word = ""
        Self.doubledWord.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
            guard let m, let run = doubledRun(s, m, skip: skip) else { return }
            if hits.isEmpty { word = s.substring(with: m.range) }
            // Drop the separators and the copies.
            hits.append(NSRange(location: NSMaxRange(run.first), length: NSMaxRange(run.copies.last!) - NSMaxRange(run.first)))
        }
        guard let first = hits.first, let last = hits.last else { return nil }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var out = "", at = span.location
        for h in hits {
            out += s.substring(with: NSRange(location: at, length: h.location - at))
            at = NSMaxRange(h)
        }
        out += s.substring(with: NSRange(location: at, length: NSMaxRange(span) - at))
        return (span, out, hits.count, word.replacingOccurrences(of: "\n", with: " "))
    }

    /// Show Me for the doubled-word hint: the first doubled run in it (the
    /// words, "the the"), from the hint's range (which starts right after
    /// the first word) in `s`, the document or the window the hint came from.
    public static func doubledWordFocus(_ s: NSString, hintRange: NSRange) -> NSRange? {
        guard hintRange.location <= s.length else { return nil }
        var b = hintRange.location
        while b > 0, let u = UnicodeScalar(s.character(at: b - 1)), CharacterSet.letters.contains(u) { b -= 1 }
        guard b < hintRange.location else { return nil }
        let limit = min(s.length - b, max(hintRange.length, 0) + 256)
        guard let m = doubledWord.firstMatch(in: s as String, options: .anchored, range: NSRange(location: b, length: limit)) else { return nil }
        return m.range
    }

    /// Fenced blocks and indented code spans' lines in Markdown.
    static func markdownCodeRanges(_ s: NSString, lines: [NSRange]) -> [NSRange] {
        var out: [NSRange] = [], open: Int?
        for r in lines {
            let t = s.substring(with: r).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                if let o = open { out.append(NSRange(location: o, length: NSMaxRange(r) - o)); open = nil } else { open = r.location }
            } else if t.contains("`") {
                out.append(r)
            }
        }
        if let o = open { out.append(NSRange(location: o, length: s.length - o)) }
        return out
    }

    static let sentenceGap = try! NSRegularExpression(pattern: #"(?<=\p{Ll}[.!?]) {1,2}(?=\p{Lu})"#)

    /// Sentences that end ". X" and ".  X" in the same text: the rewrite
    /// to one space. Nil unless both kinds appear at least twice.
    static func doubleSpaces(_ s: NSString, lines: [NSRange], markdown: Bool) -> (range: NSRange, replacement: String, count: Int)? {
        let skip = markdown ? markdownCodeRanges(s, lines: lines) : []
        var doubles: [NSRange] = [], singles = 0
        sentenceGap.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
            guard let r = m?.range, !skip.contains(where: { NSLocationInRange(r.location, $0) }) else { return }
            if r.length == 2 { doubles.append(r) } else { singles += 1 }
        }
        guard doubles.count >= 2, singles >= 2, let first = doubles.first, let last = doubles.last else { return nil }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var out = "", at = span.location
        for d in doubles {
            out += s.substring(with: NSRange(location: at, length: d.location - at)) + " "
            at = NSMaxRange(d)
        }
        out += s.substring(with: NSRange(location: at, length: NSMaxRange(span) - at))
        return (span, out, doubles.count)
    }

    // MARK: The checks, as hints

    /// The second batch, in order, appended by `check`.
    func moreHints(_ c: OwlContext, facts: OwlDocumentFacts, text: NSString, lines: [NSRange],
                   hint: (String, OwlHint.Kind, String, String?, NSRange?, String?) -> Void) {
        let lang = c.language
        let whole = facts.isWholeDocument

        if let r = Self.conflictMarker(text, lines: lines) {
            hint(Self.conflictID, .warning, String(localized: "Merge conflict markers left \(Self.whereText(text, r.location, whole: whole))."),
                 String(localized: "Git left <<<<<<<, ======= and >>>>>>> lines in the file. Keep the side you want and delete the markers."),
                 r, nil)
        }
        if let found = Self.secret(c.text) {
            let fix = Self.secretPlaceholder(text, kind: found.kind, range: found.range)
            hint(Self.secretID, .warning, String(localized: "That looks like a secret key. Careful where it goes."),
                 String(localized: "This looks like \(found.kind) \(Self.whereText(text, found.range.location, whole: whole)). Don’t share, paste or commit this file with it in.")
                    + (fix == nil ? "" : " " + String(localized: "Fix it replaces it with a placeholder (one undo).")),
                 fix?.range ?? found.range, fix?.replacement)
        }
        if let r = Self.certificateExpiry(c.text, now: facts.now ?? Date()) {
            hint(Self.certificateExpiryID, .warning, r.title, r.detail, r.range, nil)
        }
        if lang == "json", whole, !Self.allowsComments(c.fileName),
           !lines.contains(where: { let t = text.substring(with: $0).trimmingCharacters(in: .whitespaces); return t.hasPrefix("//") || t.hasPrefix("/*") }),
           let err = Self.jsonError(c.text) {
            if let comma = Self.trailingComma(text, before: err.offset) {
                // The usual mistake: a comma after the last item. Named
                // where it is, not where the parser noticed (the next line).
                let n = Self.lineNumber(text, at: comma)
                let closer = Self.nextNonSpace(text, after: comma)
                let atLineEnd = closer.map { Self.lineNumber(text, at: $0) > n } ?? true
                let title = atLineEnd ? String(localized: "Extra comma at the end of line \(n).")
                    : String(localized: "Extra comma before “\(text.substring(with: NSRange(location: closer!, length: 1)))” on line \(n).")
                hint(Self.jsonInvalidID, .warning, title,
                     String(localized: "JSON doesn’t allow a comma after the last item in a list or object. Delete it."),
                     NSRange(location: comma, length: 1), nil)
            } else {
                let line = text.lineRange(for: NSRange(location: min(err.offset, max(0, text.length - 1)), length: 0))
                let lineRange = NSRange(location: line.location, length: max(0, line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0)))
                hint(Self.jsonInvalidID, .warning, String(localized: "This JSON doesn’t parse (line \(Self.lineNumber(text, at: err.offset)))."),
                     String(localized: "The parser stopped: \(err.message)."), lineRange, nil)
            }
        }
        let scans = ["swift", "javascript", "typescript", "c", "css", "python", "powershell"].contains(lang)
        let scan = scans && whole ? (lang == "powershell" ? Self.scanPowerShell(text) : Self.scanCode(text, language: lang)) : nil
        if let p = scan?.problem {
            switch p {
            case .unexpected where lang == "c" && Self.hasPreprocessorConditional(text):
                // #if / #else branches each open or close their own copy of
                // a bracket: counted together they never balance.
                break
            case .unexpected(let ch, let at):
                hint(Self.bracketsID, .warning, String(localized: "An extra “\(String(ch))” \(Self.whereText(text, at, whole: true))."),
                     String(localized: "Nothing before it opens it."), NSRange(location: at, length: 1), nil)
            case .mismatched(let ch, let at, let opener, let openedAt):
                hint(Self.bracketsID, .warning, String(localized: "“\(String(opener))” closed by “\(String(ch))” \(Self.whereText(text, at, whole: true))."),
                     String(localized: "The “\(String(opener))” opens \(Self.whereText(text, openedAt, whole: true)); a bracket is missing or extra in between."),
                     NSRange(location: at, length: 1), nil)
            case .unclosed where lang == "c" && Self.hasPreprocessorConditional(text):
                break
            case .unclosed(let ch, let at) where facts.unsavedSince == nil:
                // Only for a saved file: while typing, an open bracket is normal.
                hint(Self.bracketsID, .warning, String(localized: "“\(String(ch))” \(Self.whereText(text, at, whole: true)) is never closed."),
                     nil, NSRange(location: at, length: 1), nil)
            default: break
            }
        }
        if let curly = scan?.curly, !curly.isEmpty {
            let first = curly.first!, last = curly.last!
            let span = NSRange(location: first, length: last - first + 1)
            var out = text.substring(with: span) as NSString
            for k in curly.reversed() {
                let q = text.character(at: k)
                out = out.replacingCharacters(in: NSRange(location: k - first, length: 1), with: q == 0x201C || q == 0x201D ? "\"" : "'") as NSString
            }
            hint(Self.smartQuotesID, .fix, String(localized: "Curly quotes in code won’t work. Straighten them?"),
                 String(localized: "\(curly.count) “smart” quotes, probably pasted from a document or a chat. Straight quotes are what the code needs."),
                 span, out as String)
        }
        if lang == "yaml", let r = yamlTabs(text, lines: lines) {
            hint(Self.yamlTabsID, .fix, String(localized: "YAML can’t indent with tabs. Use spaces?"),
                 String(localized: "Each tab at the start of \(r.count) lines becomes two spaces."), r.range, r.replacement)
        }
    }

    /// Lower in the list: tidy-ups and offers.
    func tidyHints(_ c: OwlContext, facts: OwlDocumentFacts, text: NSString, lines: [NSRange],
                   hint: (String, OwlHint.Kind, String, String?, NSRange?, String?) -> Void) {
        let lang = c.language
        let isCode = Self.codeLanguages.contains(lang) && lang != "html"
        if !Self.isPatch(c), let r = Self.invisibles(text, code: isCode) {
            hint(Self.invisibleID, .fix, String(localized: "Invisible characters in here. Remove them?"),
                 isCode ? String(localized: "\(r.count) zero-width or non-breaking spaces, easy to paste and hard to see. They break code and searches.")
                        : String(localized: "\(r.count) stray byte-order marks, easy to paste and hard to see."),
                 r.range, r.replacement)
        }
        if lang == "plain", facts.isWholeDocument, let r = Self.todoList(text, lines: lines) {
            hint(Self.todoListID, .fix, String(localized: "It looks like you’re writing a to-do list. Checkboxes?"),
                 String(localized: "Turns \(r.count) lines into Markdown checkboxes (- [ ]) and colours the tab as Markdown."),
                 r.range, r.replacement)
        }
        if lang == "plain", !facts.languageIsManual {
            let guess = LanguageDetector.sniff(c.text)
            if guess == .markdown || guess == .html || guess == .json {
                hint(Self.languageGuessPrefix + guess.rawValue, .tip,
                     String(localized: "This looks like \(guess.displayName). Colour it that way?"),
                     String(localized: "Only changes the colouring in Owlink, not the file. The language menu in the status bar changes it back."),
                     nil, nil)
            }
        }
        // A log or data file opened as Plain Text: its words are data.
        let data = Self.isWhitespaceSignificant(c)
        if Self.proseLanguages.contains(lang), !data, let r = Self.duplicateWords(text, lines: lines, markdown: lang == "markdown") {
            hint(Self.duplicateWordID, .fix,
                 r.count == 1 ? String(localized: "“\(String(r.word.prefix(24)))”? A word typed twice. Fix it?")
                              : String(localized: "\(r.count) words typed twice. Fix them?"),
                 String(localized: "Removes the second copy of each."), r.range, r.replacement)
        }
        if Self.proseLanguages.contains(lang), !data, let r = Self.doubleSpaces(text, lines: lines, markdown: lang == "markdown") {
            hint(Self.doubleSpaceID, .fix, String(localized: "Two spaces after some full stops. Make it one?"),
                 String(localized: "\(r.count) sentences start after two spaces, the rest after one."), r.range, r.replacement)
        }
    }

    /// Last: facts about the file as a whole.
    func fileHints(_ c: OwlContext, facts: OwlDocumentFacts, text: NSString,
                   hint: (String, OwlHint.Kind, String, String?, NSRange?, String?) -> Void) {
        let lang = c.language
        let isCode = Self.codeLanguages.contains(lang) && lang != "json" && lang != "html"
        let n = text.length
        // A saved code file whose last line has no newline, with the caret elsewhere.
        // .editorconfig: insert_final_newline = false turns it off; true asks for it in any saved file.
        let wantsNewline = facts.editorConfig?.insertFinalNewline
        if isCode || wantsNewline == true, wantsNewline != false, facts.isWholeDocument, c.fileName != nil, facts.unsavedSince == nil, n > 0, text.character(at: n - 1) != 10,
           c.selection.map({ NSMaxRange($0) < n }) ?? true {
            hint(Self.finalNewlineID, .tip, String(localized: "No newline at the end of the file. Add one?"),
                 String(localized: "Git and many tools expect the last line to end with one."), NSRange(location: n, length: 0), "\n")
        }
        if facts.mixedLineEndings {
            hint(Self.mixedEndingsID, .explain, String(localized: "This file mixes line endings."),
                 String(localized: "Saving keeps each line’s own ending (mostly \(facts.lineEnding.displayName)). To use one kind, pick it from the status bar."), nil, nil)
        }
    }
}
