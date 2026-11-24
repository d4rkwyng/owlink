import Foundation

// Edit validation (0.5.3): before a proposed edit's card can offer Apply,
// the document is changed in memory (a copy; the editor is never touched)
// and checked. A hard problem turns Apply off; a warning is shown on the
// card with Apply on. Only problems the edit adds count: a check that
// already failed on the document before the edit can't fail the edit
// (unless it measurably gets worse, like more unbalanced brackets).
//
// Nothing here runs the document: JSON, property lists and XML are only
// parsed (XML without resolving external entities), and JavaScript is
// only syntax-checked by an injected checker (CedricAI's JavaScriptCore
// syntax check; this target is Foundation-only).

/// A parser's complaint: its message and the 1-based line, when it says.
public struct OwlSyntaxError: Sendable, Equatable {
    public var message: String
    public var line: Int?
    /// UTF-16 offset in the checked text, when the parser says exactly where.
    public var offset: Int?

    public init(message: String, line: Int? = nil, offset: Int? = nil) {
        self.message = message; self.line = line; self.offset = offset
    }
}

/// Checks a script's syntax without running it (CedricAI implements it
/// with JavaScriptCore's syntax check).
public protocol OwlScriptSyntaxChecker: Sendable {
    /// nil when the script parses.
    func syntaxError(in script: String) -> OwlSyntaxError?
}

/// One problem the validation found in a proposed edit.
public struct OwlEditIssue: Sendable, Equatable {
    public enum Severity: String, Sendable { case hard, warning }
    public enum Check: String, Sendable {
        case json, plist, xml, script, brackets
        case selfInitialization, selfAssignment, swiftLetMutation, negation
    }

    public var check: Check
    public var severity: Severity
    /// What is wrong, for the card and the model.
    public var message: String
    /// 1-based document line after the edit, when known.
    public var line: Int?

    public init(check: Check, severity: Severity, message: String, line: Int? = nil) {
        self.check = check; self.severity = severity; self.message = message; self.line = line
    }

    /// A parser or bracket problem: the text doesn't parse.
    public var isParseFailure: Bool { [.json, .plist, .xml, .script, .brackets].contains(check) }

    /// "message (line N)".
    public var described: String { line.map { "\(message) (line \($0))" } ?? message }
}

/// The validation's verdict on one proposal. Stored on the proposal; a
/// clean report shows nothing on the card (there is no "verified" badge).
public struct OwlEditCheck: Sendable, Equatable {
    public var issues: [OwlEditIssue]

    public init(issues: [OwlEditIssue] = []) { self.issues = issues }

    public static let clean = OwlEditCheck()

    /// The first hard problem: Apply stays off while there is one.
    public var hardIssue: OwlEditIssue? { issues.first { $0.severity == .hard } }
    public var warnings: [OwlEditIssue] { issues.filter { $0.severity == .warning } }
    public var failsValidation: Bool { hardIssue != nil }

    /// The card's heading for a hard problem: "Doesn't parse" (parsers,
    /// brackets) or "Won't run" (a variable initialised from itself).
    public var failureTitle: String? {
        guard let h = hardIssue else { return nil }
        return h.isParseFailure ? String(localized: "Doesn’t parse") : String(localized: "Won’t run")
    }

    /// "Doesn't parse: <reason> (line N)", for the card and its accessibility label.
    public var failureText: String? {
        guard let h = hardIssue, let title = failureTitle else { return nil }
        return title + ": " + h.described
    }

    /// The warnings, one per line, for the card.
    public var warningText: String? {
        let w = warnings
        return w.isEmpty ? nil : w.map(\.described).joined(separator: "\n")
    }

    /// What the model is told when its edit fails a hard check the first time.
    public var retryFeedback: String? {
        guard let h = hardIssue else { return nil }
        let what = h.isParseFailure ? "the change doesn't parse" : "the change won't run"
        return "\(what): \(h.described); fix it and call propose_edit again"
    }
}

public enum OwlEditValidation {
    /// Documents longer than this (UTF-16 units) are not validated.
    public static let maxDocumentLength = 2_000_000

    /// Languages whose brackets are balanced-checked, and whether an
    /// unbalanced bracket the edit adds is hard (Apply off) or a warning.
    /// Strings, comments and regex literals (JS/TS `/…/`, Swift `/…/` and
    /// `#/…/#`) are blanked over the whole text by the owl's lexer
    /// (`CodeMask`, from `RulesHintProvider.scanCode`) before counting.
    ///
    /// - Swift, C, Python: HARD.
    /// - CSS: WARNING. An escape makes a bracket part of a name
    ///   (`.\(` is a class called `(`), and the lexer doesn't read escapes.
    /// - JavaScript: HARD only when the syntax checker also rejects the
    ///   edited text as a classic script. Accepted: the parser wins and
    ///   the brackets aren't reported. Possibly a module (see
    ///   `mentionsImportOrExport`; the checker can't judge one): a
    ///   WARNING. No checker given: HARD, as the lexer is then the only
    ///   check (the app always gives one).
    /// - TypeScript: WARNING. Nothing parses it, and the lexer can't
    ///   always tell a regex from a division (`if (ok) /\(/.test(s);`).
    /// - Ruby: WARNING, Apply on. Only the highlighter's tokens can blank
    ///   its strings, and they miss `%q{…}`-style literals, regexes and
    ///   anything past the highlighter's per-line limit, so a count there
    ///   is a hint, not a verdict.
    static let bracketLanguages: [String: OwlEditIssue.Severity] = [
        "swift": .hard, "javascript": .hard, "c": .hard, "css": .warning, "python": .hard,
        "typescript": .warning, "ruby": .warning,
    ]

    /// A statement-start `import` (not a dynamic `import(…)`) or `export`,
    /// or `import.meta` anywhere, outside strings and comments: module
    /// syntax, which JavaScriptCore's classic-script check rejects even
    /// when it is valid. Not what `validate` uses (that is the looser
    /// `mentionsImportOrExport`); kept for its existing tests.
    static let moduleSyntax = try! NSRegularExpression(
        pattern: #"(?:^|[;{}])[ \t]*(?:import\b(?!\s*\()|export\b)|(?<![\w$.])import\s*\.\s*meta\b"#,
        options: [.anchorsMatchLines])

    static func usesModuleSyntax(_ text: String) -> Bool {
        let code = code(text, language: "javascript")
        return moduleSyntax.firstMatch(in: code as String, range: NSRange(location: 0, length: code.length)) != nil
    }

    static let importOrExport = try! NSRegularExpression(pattern: #"\b(import|export)\b"#)

    /// The word `import` or `export` anywhere outside comments, strings
    /// and template interpolations included. The fail-open test for
    /// JavaScript: a text that has one may be a module (`${import.meta.url}`,
    /// `f(...import.meta.url)`, `export`), which JavaScriptCore's
    /// classic-script check rejects even when it is valid, so its
    /// rejection is only a warning. Deliberately looser than
    /// `usesModuleSyntax`: no attempt to model module syntax.
    static func mentionsImportOrExport(_ text: String) -> Bool {
        let ns = text as NSString
        guard ns.range(of: "import").location != NSNotFound || ns.range(of: "export").location != NSNotFound else { return false }
        let code: NSString
        if let mask = CodeMask.make(ns, language: "javascript") {
            // Blank only the comments.
            code = CodeMask(ns, spans: mask.spans.filter { $0.kind == .comment }).codeNS
        } else {
            code = ns
        }
        return importOrExport.firstMatch(in: code as String, range: NSRange(location: 0, length: code.length)) != nil
    }

    // MARK: Entry points

    /// `p` applied to a copy of the snapshot's text, then checked.
    public static func validate(_ p: OwlEditProposal, in s: OwlDocumentSnapshot,
                                script: (any OwlScriptSyntaxChecker)?) -> OwlEditCheck {
        let ns = s.text as NSString
        guard NSMaxRange(p.range) <= ns.length else { return .clean }
        let after = ns.replacingCharacters(in: p.range, with: p.replacement)
        return validate(language: s.language, fileName: s.fileName, before: s.text, after: after,
                        original: p.original, replacement: p.replacement, firstLine: p.firstLine, script: script)
    }

    /// The whole document before and after, and the edited fragment
    /// (`original` → `replacement`, starting on `firstLine`).
    public static func validate(language: String, fileName: String?, before: String, after: String,
                                original: String, replacement: String, firstLine: Int = 1,
                                script: (any OwlScriptSyntaxChecker)?) -> OwlEditCheck {
        guard (after as NSString).length <= maxDocumentLength, (before as NSString).length <= maxDocumentLength else { return .clean }
        var issues: [OwlEditIssue] = []
        let ext = ((fileName ?? "") as NSString).pathExtension.lowercased()

        // Single-verdict parsers. HARD only when the document parsed
        // before the edit (or was empty). When it already failed, a parser
        // stops at its first error, so a partial fix uncovers an old error
        // and nothing can say for sure that the edit caused it: a WARNING
        // ("may not parse"), Apply on, and only when the error looks like
        // the edit's (in the edit, see `isInEdit`, and a different
        // complaint, numbers aside, or the before error wasn't in the
        // replaced text). `advisory`: the parser's rejection is never hard
        // (JavaScript module syntax).
        let region = changedRegions(before, after)
        func parser(_ check: OwlEditIssue.Check, advisory: Bool = false, _ run: (String) -> OwlSyntaxError?) -> OwlSyntaxError? {
            guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let e = run(after) else { return nil }
            if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || run(before) == nil {
                issues.append(advisory
                    ? OwlEditIssue(check: check, severity: .warning, message: mayNotParse(e.message), line: e.line)
                    : OwlEditIssue(check: check, severity: .hard, message: e.message, line: e.line))
            } else if let b = run(before) {
                let inEdit = isInEdit(e, text: after, region: region.after, fragment: replacement, firstLine: firstLine)
                let beforeInEdit = isInEdit(b, text: before, region: region.before, fragment: original, firstLine: firstLine)
                if inEdit && (comparable(e.message) != comparable(b.message) || !beforeInEdit) {
                    issues.append(OwlEditIssue(check: check, severity: .warning, message: mayNotParse(e.message), line: e.line))
                }
            }
            return e
        }
        if language == "json" {
            _ = parser(.json, jsonError)
        } else if ext == "plist", language == "xml" || language == "plain" {
            _ = parser(.plist, plistError)
        } else if language == "xml" || ext == "svg" {
            _ = parser(.xml, xmlError)
        }
        var scriptAccepts = false
        var bracketSeverity = bracketLanguages[language]
        if language == "javascript", let script {
            // Possibly a module (a .mjs file, or `import`/`export` anywhere
            // outside comments, before or after): the checker's classic-script
            // rejection is only a warning there.
            let module = ext == "mjs" || mentionsImportOrExport(before) || mentionsImportOrExport(after)
            scriptAccepts = parser(.script, advisory: module, script.syntaxError(in:)) == nil
            if module { bracketSeverity = .warning }
        }

        // Brackets: may fail an already-unbalanced document only if it gets worse.
        // JavaScript the syntax checker accepts is balanced (see `bracketLanguages`).
        if let severity = bracketSeverity, !scriptAccepts, let lang = Language(rawValue: language) {
            let a = bracketProblems(after, language: lang)
            if a.count > 0 {
                let b = bracketProblems(before, language: lang)
                if a.count > b.count, let first = a.first {
                    issues.append(OwlEditIssue(check: .brackets, severity: severity, message: first.message, line: first.line))
                }
            }
        }

        issues += ruleIssues(language: language, original: original, replacement: replacement, firstLine: firstLine)
        if language == "javascript" || language == "typescript" {
            issues += selfInitializationIssues(language: language, before: before, after: after, changed: region.after)
        }
        // Hard problems first.
        return OwlEditCheck(issues: issues.filter { $0.severity == .hard } + issues.filter { $0.severity == .warning })
    }

    // MARK: Where an error is

    /// The lines a fragment starting on `firstLine` covers. A final newline
    /// ends the fragment's last line; it doesn't start another one.
    static func lines(_ fragment: String, firstLine: Int) -> ClosedRange<Int> {
        var newlines = fragment.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        if newlines > 0, fragment.utf16.last == 10 { newlines -= 1 }
        return firstLine...(firstLine + newlines)
    }

    /// What differs between `before` and `after` (UTF-16; past the common
    /// prefix and before the common suffix), in each text. Always inside
    /// the edit's replacement, so it never claims more than the edit did.
    static func changedRegions(_ before: String, _ after: String) -> (before: NSRange, after: NSRange) {
        let a = Array(before.utf16), b = Array(after.utf16)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (NSRange(location: p, length: a.count - p - s), NSRange(location: p, length: b.count - p - s))
    }

    /// The error is in the edit: its offset falls in the changed region
    /// (or on the first character after it, past white space: a parser
    /// reports a deletion at the next token); without an offset, its line
    /// is one the fragment covers. Neither known: not in the edit.
    static func isInEdit(_ e: OwlSyntaxError, text: String, region: NSRange, fragment: String, firstLine: Int) -> Bool {
        if let o = e.offset {
            let u = text.utf16
            var end = NSMaxRange(region)
            var k = u.index(u.startIndex, offsetBy: min(end, u.count))
            while k < u.endIndex, [32, 9, 10, 13].contains(u[k]) { end += 1; k = u.index(after: k) }
            return o >= region.location && o <= end
        }
        guard let line = e.line else { return false }
        return lines(fragment, firstLine: firstLine).contains(line)
    }

    // MARK: Parsers

    /// JSONSerialization's complaint, or nil when `text` is JSON. Newer
    /// systems' JSONSerialization accepts a trailing comma (`[1, 2,]`),
    /// which strict JSON doesn't: that is checked after it.
    public static func jsonError(_ text: String) -> OwlSyntaxError? {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            return syntaxError(from: error, fallback: String(localized: "not valid JSON"), in: text)
        }
        return trailingComma(text)
    }

    /// The first comma followed (after white space) by `]` or `}`, outside strings.
    static func trailingComma(_ text: String) -> OwlSyntaxError? {
        let u = Array(text.utf16)
        var i = 0, line = 1
        var inString = false
        while i < u.count {
            let c = u[i]
            if c == 10 { line += 1 }
            if inString {
                if c == 92 { i += 2; continue }   // backslash escape
                if c == 34 { inString = false }
            } else if c == 34 {
                inString = true
            } else if c == 44 {   // ,
                var j = i + 1, l = line
                while j < u.count, [32, 9, 10, 13].contains(u[j]) { if u[j] == 10 { l += 1 }; j += 1 }
                if j < u.count, u[j] == 93 || u[j] == 125 {
                    let closer = u[j] == 93 ? "]" : "}"
                    return OwlSyntaxError(message: String(localized: "trailing comma before “\(closer)”"), line: line, offset: i)
                }
            }
            i += 1
        }
        return nil
    }

    /// PropertyListSerialization's complaint, or nil when `text` is a property list.
    public static func plistError(_ text: String) -> OwlSyntaxError? {
        do {
            _ = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
            return nil
        } catch {
            return syntaxError(from: error, fallback: String(localized: "not a valid property list"), in: text)
        }
    }

    /// The XML parser the validation uses: external entities are never
    /// resolved (nothing is fetched or read from disk).
    public static func xmlParser(for data: Data) -> XMLParser {
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        p.shouldProcessNamespaces = false
        p.shouldReportNamespacePrefixes = false
        return p
    }

    /// XMLParser's complaint (its first), or nil when `text` is well-formed XML.
    public static func xmlError(_ text: String) -> OwlSyntaxError? {
        let p = xmlParser(for: Data(text.utf8))
        let errors = XMLErrors()
        p.delegate = errors
        if p.parse() { return nil }
        let e = (errors.first ?? p.parserError) as NSError?
        let line = (e?.userInfo["NSXMLParserErrorLineNumber"] as? Int) ?? (p.lineNumber > 0 ? p.lineNumber : nil)
        var message = ((e?.userInfo["NSXMLParserErrorMessage"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while message.hasSuffix(".") { message.removeLast() }
        return OwlSyntaxError(message: message.isEmpty ? String(localized: "not well-formed XML") : String(message.prefix(160)), line: line)
    }

    /// Keeps the parser's first error (later ones follow from it).
    final class XMLErrors: NSObject, XMLParserDelegate {
        var first: Error?
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { if first == nil { first = parseError } }
        func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) { if first == nil { first = validationError } }
    }

    /// The parser's message, its line, and (JSONSerialization's
    /// `NSJSONSerializationErrorIndex`, a UTF-8 offset) where in `text`.
    /// A message that says "around character N" and no line gets its line
    /// from that offset.
    static func syntaxError(from error: Error, fallback: String, in text: String) -> OwlSyntaxError {
        let ns = error as NSError
        let raw = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
        let message = cleanMessage(raw)
        var offset: Int?
        let byteIndex = (ns.userInfo["NSJSONSerializationErrorIndex"] as? Int) ?? characterNumber(in: raw)
        if let byteIndex, byteIndex >= 0 {
            let head = String(decoding: text.utf8.prefix(byteIndex), as: UTF8.self)
            offset = head.utf16.count
        }
        let line = lineNumber(in: raw) ?? offset.map { o in
            1 + text.utf16.prefix(o).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        }
        return OwlSyntaxError(message: message.isEmpty ? fallback : message, line: line, offset: offset)
    }

    /// "May not parse: <reason>": an after error the edit may not have caused.
    static func mayNotParse(_ message: String) -> String {
        String(localized: "May not parse: \(message)")
    }

    /// One line, no trailing period, the "around line N, column M" (or
    /// "around character N") part left to `line`.
    static func cleanMessage(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"\s*(around|at) line \d+(, column \d+)?\.?"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        if let r = t.range(of: #"\s*around character \d+\.?"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        while t.hasSuffix(".") { t.removeLast() }
        return String(t.prefix(160))
    }

    /// A parser message without its numbers (lines, columns, offsets), to
    /// tell a different complaint from the same one moved by the edit.
    static func comparable(_ message: String) -> String {
        cleanMessage(message).replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
    }

    /// N in an older JSONSerialization's "around character N".
    static func characterNumber(in s: String) -> Int? {
        guard let r = s.range(of: #"character \d+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(s[r].dropFirst(10))
    }

    static func lineNumber(in s: String) -> Int? {
        guard let r = s.range(of: #"line \d+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(s[r].dropFirst(5))
    }

    // MARK: Brackets

    /// Unbalanced (), [] and {} outside strings, comments and regex
    /// literals, in the order found. An unmatched closer, a mismatched
    /// pair and an unclosed opener count one each.
    ///
    /// Strings and comments are blanked over the whole text by the owl's
    /// lexer (`CodeMask`) for the languages it lexes, regex literals
    /// included; otherwise (Ruby) by the syntax highlighter's tokens,
    /// which is why Ruby's count is only a warning (`bracketLanguages`).
    /// Interpolated code (Swift `\( … )`, JS/TS `${ … }`) isn't blanked:
    /// its brackets count like any others.
    public static func bracketProblems(_ text: String, language: Language) -> [OwlSyntaxError] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let index = LineIndex(ns)
        var units = [unichar](repeating: 0, count: ns.length)
        if let mask = CodeMask.make(ns, language: language.rawValue, splitInterpolations: true) {
            mask.codeNS.getCharacters(&units, range: NSRange(location: 0, length: ns.length))
        } else {
            ns.getCharacters(&units, range: NSRange(location: 0, length: ns.length))
            let tokens = HighlightEngine(language: language).tokens(forLines: 0..<index.lineCount, in: ns, index: index)
            for t in tokens where t.kind == .string || t.kind == .comment {
                let a = max(0, t.start), b = min(units.count, t.end)
                if a < b { for k in a..<b { units[k] = 32 } }
            }
        }
        func line(_ offset: Int) -> Int { index.line(containing: offset) + 1 }
        var stack: [(unichar, Int)] = []
        var out: [OwlSyntaxError] = []
        let pairs: [unichar: unichar] = [41: 40, 93: 91, 125: 123]   // ) ] }
        for (i, u) in units.enumerated() {
            switch u {
            case 40, 91, 123: stack.append((u, i))
            case 41, 93, 125:
                let closer = Character(UnicodeScalar(u)!)
                if let top = stack.last {
                    if top.0 == pairs[u] { stack.removeLast(); continue }
                    let opener = Character(UnicodeScalar(top.0)!)
                    out.append(OwlSyntaxError(message: String(localized: "“\(String(opener))” isn’t closed before the “\(String(closer))” on line \(line(i))"),
                                              line: line(top.1)))
                    stack.removeLast()
                } else {
                    out.append(OwlSyntaxError(message: String(localized: "unexpected “\(String(closer))”"), line: line(i)))
                }
            default: continue
            }
        }
        for (u, i) in stack {
            let opener = Character(UnicodeScalar(u)!)
            out.append(OwlSyntaxError(message: String(localized: "“\(String(opener))” is never closed"), line: line(i)))
        }
        return out
    }

    // MARK: Rules

    /// The rules, on the edited fragment: only what the replacement has
    /// more of than the original it replaces. (Self-initialisation runs on
    /// the whole document instead: `selfInitializationIssues`.)
    static func ruleIssues(language: String, original: String, replacement: String, firstLine: Int) -> [OwlEditIssue] {
        var out: [OwlEditIssue] = []
        func added(_ find: (String) -> [RuleHit]) {
            let before = find(original)
            var seen: [String: Int] = [:]
            for h in before { seen[h.key, default: 0] += 1 }
            for h in find(replacement) {
                if let n = seen[h.key], n > 0 { seen[h.key] = n - 1; continue }
                out.append(OwlEditIssue(check: h.check, severity: h.severity, message: h.message, line: firstLine + h.lineOffset))
            }
        }
        if ["javascript", "typescript", "c", "swift", "python"].contains(language) { added { selfAssignments($0, language: language) } }
        if language == "swift" { added(swiftLetMutations) }
        if language == "plain" || language == "markdown" {
            if let n = negationChange(original: original, replacement: replacement) {
                out.append(OwlEditIssue(check: .negation, severity: .warning, message: n, line: nil))
            }
        }
        return out
    }

    struct RuleHit {
        var check: OwlEditIssue.Check
        var severity: OwlEditIssue.Severity
        var key: String
        var message: String
        var lineOffset: Int
        /// Where in the checked text (UTF-16).
        var location: Int = 0
        var length: Int = 0
    }

    /// The fragment with strings and comments blanked, when the owl lexes the language.
    static func code(_ s: String, language: String) -> NSString {
        CodeMask.make(s as NSString, language: language)?.codeNS ?? (s as NSString)
    }

    static func lineOffset(_ s: NSString, _ at: Int) -> Int {
        var n = 0
        var i = 0
        while i < min(at, s.length) { if s.character(at: i) == 10 { n += 1 }; i += 1 }
        return n
    }

    static let selfInit = try! NSRegularExpression(
        pattern: #"(?<![\w$.])(const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::\s*[\w$.<>\[\]| ]+?)?\s*=\s*([A-Za-z_$][\w$]*)\s*(?=;|,|\)|\n|$)"#,
        options: [.anchorsMatchLines])

    /// Rule a over the whole document before and after the edit (strings
    /// and comments blanked), so a fragment's boundary can't hide a hit
    /// (`1` → `x` in `const x = 1;`) or invent one (text inside a
    /// comment). Only hits the edit adds count: per declaration, as many
    /// as the after text has more of, those in the changed region first.
    static func selfInitializationIssues(language: String, before: String, after: String, changed: NSRange) -> [OwlEditIssue] {
        let b = selfInitializations(before, language: language)
        let a = selfInitializations(after, language: language)
        var seen: [String: Int] = [:]
        for h in b { seen[h.key, default: 0] += 1 }
        var byKey: [String: [RuleHit]] = [:]
        var order: [String] = []
        for h in a {
            if byKey[h.key] == nil { order.append(h.key) }
            byKey[h.key, default: []].append(h)
        }
        let lo = changed.location, hi = NSMaxRange(changed)
        var out: [OwlEditIssue] = []
        for key in order {
            let hits = byKey[key]!
            let extra = hits.count - (seen[key] ?? 0)
            guard extra > 0 else { continue }
            let inEdit = hits.filter { $0.location + $0.length >= lo && $0.location <= hi }
            let rest = hits.filter { !($0.location + $0.length >= lo && $0.location <= hi) }
            for h in (inEdit + rest).prefix(extra) {
                out.append(OwlEditIssue(check: h.check, severity: h.severity, message: h.message, line: 1 + h.lineOffset))
            }
        }
        return out
    }

    /// Rule a. JS/TS: a variable declared from itself.
    /// - `const x = x` / `let x = x`: HARD, Apply off (and one retry for
    ///   the model), because it always throws a ReferenceError (temporal
    ///   dead zone) when it runs: it never works. A WARNING instead when
    ///   its line has a `/` that isn't `//`, `/*` or `*/`: the lexer may
    ///   have missed a regex (`if (ok) /const x = x;/.test(s);`).
    /// - `var x = x`: WARNING, Apply on: it runs (x is just undefined or
    ///   unchanged), so it is a probable mistake, not a broken program.
    static func selfInitializations(_ s: String, language: String) -> [RuleHit] {
        let ns = code(s, language: language)
        return selfInit.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let kw = ns.substring(with: m.range(at: 1)), name = ns.substring(with: m.range(at: 2))
            guard name == ns.substring(with: m.range(at: 3)) else { return nil }
            let tdz = kw != "var"
            let ambiguous = tdz && hasStraySlash(ns, lineOf: m.range.location)
            let message = !tdz
                ? String(localized: "`var \(name) = \(name)` sets `\(name)` to itself, which does nothing")
                : ambiguous
                ? String(localized: "`\(kw) \(name) = \(name)` reads `\(name)` before it is set, which throws a ReferenceError (unless it is inside a regular expression)")
                : String(localized: "`\(kw) \(name) = \(name)` reads `\(name)` before it is set, which always throws a ReferenceError")
            return RuleHit(check: .selfInitialization, severity: tdz && !ambiguous ? .hard : .warning, key: "init:\(kw):\(name)",
                           message: message, lineOffset: lineOffset(ns, m.range.location),
                           location: m.range.location, length: m.range.length)
        }
    }

    /// The line of `at` (in blanked code) has a `/` that isn't part of
    /// `//`, `/*` or `*/`: a division, or a regex the lexer missed.
    static func hasStraySlash(_ ns: NSString, lineOf at: Int) -> Bool {
        let line = ns.lineRange(for: NSRange(location: at, length: 0))
        var i = line.location
        let end = NSMaxRange(line)
        while i < end {
            let u = ns.character(at: i)
            if u == 47 {   // /
                let next: unichar = i + 1 < end ? ns.character(at: i + 1) : 0
                let prev: unichar = i > line.location ? ns.character(at: i - 1) : 0
                if next == 47 || next == 42 { i += 2; continue }   // // or /*
                if prev != 42 { return true }                      // not */
            }
            i += 1
        }
        return false
    }

    static let selfAssign = try! NSRegularExpression(
        pattern: #"(?:^|[;{])[ \t]*([A-Za-z_$][\w$]*)[ \t]*=(?!=)[ \t]*([A-Za-z_$][\w$]*)[ \t]*;?[ \t]*(?=\n|$|\})"#,
        options: [.anchorsMatchLines])

    /// Rule a. A plain statement `x = x` (C-like languages, Python):
    /// WARNING, Apply on. It does nothing, so it is probably a mistake,
    /// but it is harmless. Declarations never count here (Swift's
    /// `let x = x`, `if let x = x`, `guard let x = x` and `var x = x`
    /// are idioms), nor are keyword arguments (`f(x=x)`).
    static func selfAssignments(_ s: String, language: String) -> [RuleHit] {
        let ns = code(s, language: language)
        return selfAssign.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range(at: 1))
            guard name == ns.substring(with: m.range(at: 2)), name != "_" else { return nil }
            return RuleHit(check: .selfAssignment, severity: .warning, key: "assign:\(name)",
                           message: String(localized: "`\(name) = \(name)` sets `\(name)` to itself, which does nothing"),
                           lineOffset: lineOffset(ns, m.range(at: 1).location))
        }
    }

    static let letBinding = try! NSRegularExpression(pattern: #"(?<![\w.])let\s+([A-Za-z_]\w*)\b(?:\s*:\s*[^=,{\n]+)?(?:\s*=\s*([^,{\n]+?))?(?=\s*(?:,|\{|\n|$|else\b))"#,
                                                     options: [.anchorsMatchLines])
    static let assignOps = #"(=|\+=|-=|\*=|/=|%=|&=|\|=|\^=|<<=|>>=)(?!=)"#

    /// Rule b. Swift: a name bound with `let` (`let`, `if let`, `guard
    /// let`) in the edited text that the edited text then assigns to
    /// (`x = …`, `x += …`) or mutates a property of (`x.count -= 1`).
    /// WARNING, Apply on: property mutation through a `let` is legal for
    /// a class instance, and a lexical check can't know the type (or
    /// whether a nested scope shadows the name). Method calls like
    /// `x.items.append(…)` are out of scope.
    /// Limit (0.6): only the fragment is read, so a `let` declared outside the edit isn't seen.
    static func swiftLetMutations(_ s: String) -> [RuleHit] {
        let ns = code(s, language: "swift")
        let str = ns as String
        var out: [RuleHit] = []
        var reported = Set<String>()
        for b in letBinding.matches(in: str, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: b.range(at: 1))
            guard name != "_", !reported.contains(name) else { continue }
            let source = b.range(at: 2).location != NSNotFound
                ? ns.substring(with: b.range(at: 2)).trimmingCharacters(in: .whitespaces) : nil
            // `let x: Int` and a later `x = …`: Swift's deferred initialisation, legal.
            let deferred = source == nil && ns.substring(with: b.range).contains(":")
            let esc = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(?<![\w.$])"# + esc + #"((?:\s*(?:\.\s*[A-Za-z_]\w*|\[[^\]\n]*\]|[!?]))*)\s*"# + assignOps
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let after = NSMaxRange(b.range(at: 1))
            for m in re.matches(in: str, range: NSRange(location: after, length: ns.length - after)) {
                // Not another declaration of the same name.
                let lineStart = ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location
                let lead = ns.substring(with: NSRange(location: lineStart, length: m.range.location - lineStart))
                    .trimmingCharacters(in: .whitespaces)
                if lead.hasSuffix("let") || lead.hasSuffix("var") || lead.hasSuffix("case") { continue }
                let suffix = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
                let op = ns.substring(with: m.range(at: 2))
                if deferred, suffix.isEmpty, op == "=" { continue }
                let message: String
                if suffix.isEmpty {
                    message = String(localized: "`\(name)` is a `let`, so `\(name) \(op) …` won’t build unless another `\(name)` is in scope. Declare it with `var`.")
                } else {
                    let inPlace: String
                    if let source, !source.isEmpty, source.hasSuffix("]") || source.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) {
                        let path = suffix.hasPrefix("!") || suffix.hasPrefix("?") ? String(suffix.dropFirst()) : suffix
                        inPlace = "`\(source)?\(path) \(op) …`"
                    } else {
                        inPlace = String(localized: "on the original value")
                    }
                    message = String(localized: "`\(name)` is a `let`: if it’s a struct this won’t build, and changing a copy won’t update the original. Use `if var` and write it back, or change it in place (\(inPlace)).")
                }
                out.append(RuleHit(check: .swiftLetMutation, severity: .warning, key: "let:\(name)", message: message,
                                   lineOffset: lineOffset(ns, m.range.location)))
                reported.insert(name)
                break
            }
        }
        return out
    }

    /// Words that negate (contractions ending in n't count too).
    public static let negationWords: Set<String> = [
        "not", "never", "no", "none", "nobody", "nothing", "nowhere", "neither", "nor", "cannot", "without",
        "prohibited", "forbidden", "disallowed", "impermissible",
    ]

    /// The negations in `text`, lower-cased, in order.
    public static func negations(in text: String) -> [String] {
        var out: [String] = []
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        normalized.enumerateSubstrings(in: normalized.startIndex..., options: .byWords) { w, _, _, _ in
            guard let w = w?.lowercased() else { return }
            if negationWords.contains(w) || w.hasSuffix("n't") { out.append(w) }
        }
        return out
    }

    /// Rule c. Prose: the replacement has a different number of negations
    /// than the original. WARNING, Apply on: a rewrite may reword a
    /// negation legitimately ("isn't unclear" → "is clear"), and the user
    /// is reviewing the diff anyway. "May change the meaning: adds “not”".
    public static func negationChange(original: String, replacement: String) -> String? {
        let a = negations(in: original), b = negations(in: replacement)
        guard a.count != b.count else { return nil }
        var countA: [String: Int] = [:], countB: [String: Int] = [:]
        for w in a { countA[w, default: 0] += 1 }
        for w in b { countB[w, default: 0] += 1 }
        var parts: [String] = []
        for w in b where (countB[w] ?? 0) > (countA[w] ?? 0) && !parts.contains("adds “\(w)”") { parts.append("adds “\(w)”") }
        for w in a where (countA[w] ?? 0) > (countB[w] ?? 0) && !parts.contains("drops “\(w)”") { parts.append("drops “\(w)”") }
        guard !parts.isEmpty else { return nil }
        return String(localized: "May change the meaning: \(parts.joined(separator: ", "))")
    }
}

/// One Ask's edit validation, as the propose_edit handler uses it: the
/// first proposal that fails a hard check is refused with the parser's
/// message so the model can fix it; after that, a failing proposal is
/// kept but marked (the card shows why and Apply stays off).
///
/// With batches (the runner's tool loop calls `beginBatch`): a refusal
/// needs a tool round left to retry in, otherwise the proposal is marked
/// at once; and once one edit in a batch is refused, every further
/// hard-failing edit in that batch is refused too, so none is marked
/// before the model has had its retry round.
public struct OwlEditGate: Sendable {
    public let script: (any OwlScriptSyntaxChecker)?
    /// A hard failure was already sent back to the model in this Ask.
    public private(set) var retried = false
    /// A tool round follows this batch (the model can call propose_edit again).
    private var retryRoundLeft = true
    /// An edit in the current batch was refused for a retry.
    public private(set) var refusedInBatch = false
    /// `beginBatch` was called: batches are tracked.
    private var batched = false

    public init(script: (any OwlScriptSyntaxChecker)?) { self.script = script }

    /// A new batch of tool calls; `retryRoundLeft`: another tool round follows it.
    public mutating func beginBatch(retryRoundLeft: Bool) {
        batched = true
        self.retryRoundLeft = retryRoundLeft
        refusedInBatch = false
    }

    public enum Verdict: Sendable, Equatable {
        /// Show it (its `check` set: clean, warnings, or failing after a retry).
        case propose(OwlEditProposal)
        /// Refuse it this once: the text for the model.
        case retry(String)
    }

    public mutating func review(_ p: OwlEditProposal, in s: OwlDocumentSnapshot) -> Verdict {
        checked(p, in: s).verdict
    }

    /// The verdict and the check it came from.
    mutating func checked(_ p: OwlEditProposal, in s: OwlDocumentSnapshot) -> (verdict: Verdict, check: OwlEditCheck) {
        var p = p
        p.check = OwlEditValidation.validate(p, in: s, script: script)
        if p.check.failsValidation, let feedback = p.check.retryFeedback {
            if batched, refusedInBatch { return (.retry(feedback), p.check) }
            if !retried, retryRoundLeft {
                retried = true
                if batched { refusedInBatch = true }
                return (.retry(feedback), p.check)
            }
        }
        return (.propose(p), p.check)
    }
}

extension OwlEditGate {
    /// propose_edit's result through the gate: a proposal that fails a
    /// hard check the first time becomes a tool failure the model can act
    /// on; later, or with only warnings, the proposal carries its check
    /// (and the model is told it doesn't parse, never that it is applied).
    public mutating func screen(_ r: OwlToolResult, in s: OwlDocumentSnapshot) -> OwlToolResult {
        guard let p = r.proposal else { return r }
        let (verdict, check) = checked(p, in: s)
        switch verdict {
        case .retry(let feedback):
            // "Doesn't parse" or "Won't run", as the card would say.
            return OwlToolResult(text: "error: " + feedback, proposal: nil,
                                 summary: check.failureTitle ?? String(localized: "Doesn’t parse"), ok: false)
        case .propose(let checked):
            var out = r
            out.proposal = checked
            if let h = checked.check.hardIssue {
                out.text = "proposed, but it still fails the check (\(h.described)): the user will see that and can't apply it. "
                    + "Say what you propose and that it isn't ready to apply."
            }
            return out
        }
    }
}

extension OwlEditProposal {
    /// The proposal with its validation redone against the live document,
    /// when the document changed since it was proposed (another card was
    /// applied, the user typed): the edit applied to the live text where
    /// its anchor is now, checked as `OwlEditValidation.validate` checks a
    /// snapshot. Unchanged when the generation is the proposal's, the
    /// anchor isn't text, or the text no longer applies (that is stale
    /// anyway). The panel uses it for the card refresh and the Apply guard.
    public func revalidated(text: NSString, generation: Int, language: String, fileName: String?,
                            script: (any OwlScriptSyntaxChecker)?) -> OwlEditProposal {
        guard generation != self.generation, anchor == .text else { return self }
        let hits = Self.occurrences(of: original, in: text)
        guard hits.count == 1, let r = hits.first else { return self }
        let after = text.replacingCharacters(in: r, with: replacement)
        var line = 1
        for u in text.substring(to: r.location).utf16 where u == 10 { line += 1 }
        var p = self
        p.check = OwlEditValidation.validate(language: language, fileName: fileName, before: text as String, after: after,
                                             original: original, replacement: replacement, firstLine: line, script: script)
        return p
    }
}
