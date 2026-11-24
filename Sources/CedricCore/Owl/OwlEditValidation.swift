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

    public init(message: String, line: Int? = nil) {
        self.message = message; self.line = line
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
    ///
    /// - Swift, JavaScript, TypeScript, C, CSS, Python: HARD. Strings,
    ///   comments and regex literals (JS/TS `/…/`, Swift `/…/` and
    ///   `#/…/#`) are blanked over the whole text by the owl's lexer
    ///   (`CodeMask`, from `RulesHintProvider.scanCode`) before counting.
    ///   JavaScript is the exception when a syntax checker is given and
    ///   accepts the edited text: the parser wins and the brackets aren't
    ///   reported at all (a bracket the lexer missed can't block Apply).
    /// - Ruby: WARNING, Apply on. Only the highlighter's tokens can blank
    ///   its strings, and they miss `%q{…}`-style literals, regexes and
    ///   anything past the highlighter's per-line limit, so a count there
    ///   is a hint, not a verdict.
    static let bracketLanguages: [String: OwlEditIssue.Severity] = [
        "swift": .hard, "javascript": .hard, "typescript": .hard, "c": .hard, "css": .hard, "python": .hard,
        "ruby": .warning,
    ]

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

        // Single-verdict parsers: skipped when the document already failed before.
        func parser(_ check: OwlEditIssue.Check, _ run: (String) -> OwlSyntaxError?) -> OwlSyntaxError? {
            guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let e = run(after) else { return nil }
            if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || run(before) == nil {
                issues.append(OwlEditIssue(check: check, severity: .hard, message: e.message, line: e.line))
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
        if language == "javascript", let script {
            scriptAccepts = parser(.script, script.syntaxError(in:)) == nil
        }

        // Brackets: may fail an already-unbalanced document only if it gets worse.
        // JavaScript the syntax checker accepts is balanced (see `bracketLanguages`).
        if let severity = bracketLanguages[language], !scriptAccepts, let lang = Language(rawValue: language) {
            let a = bracketProblems(after, language: lang)
            if a.count > 0 {
                let b = bracketProblems(before, language: lang)
                if a.count > b.count, let first = a.first {
                    issues.append(OwlEditIssue(check: .brackets, severity: severity, message: first.message, line: first.line))
                }
            }
        }

        issues += ruleIssues(language: language, original: original, replacement: replacement, firstLine: firstLine)
        // Hard problems first.
        return OwlEditCheck(issues: issues.filter { $0.severity == .hard } + issues.filter { $0.severity == .warning })
    }

    // MARK: Parsers

    /// JSONSerialization's complaint, or nil when `text` is JSON. Newer
    /// systems' JSONSerialization accepts a trailing comma (`[1, 2,]`),
    /// which strict JSON doesn't: that is checked after it.
    public static func jsonError(_ text: String) -> OwlSyntaxError? {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            return syntaxError(from: error, fallback: String(localized: "not valid JSON"))
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
                    return OwlSyntaxError(message: String(localized: "trailing comma before “\(closer)”"), line: line)
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
            return syntaxError(from: error, fallback: String(localized: "not a valid property list"))
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

    static func syntaxError(from error: Error, fallback: String) -> OwlSyntaxError {
        let ns = error as NSError
        let raw = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
        let message = cleanMessage(raw)
        return OwlSyntaxError(message: message.isEmpty ? fallback : message, line: lineNumber(in: raw))
    }

    /// One line, no trailing period, the "around line N, column M" part
    /// left to `line`.
    static func cleanMessage(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"\s*(around|at) line \d+(, column \d+)?\.?"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        while t.hasSuffix(".") { t.removeLast() }
        return String(t.prefix(160))
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
    public static func bracketProblems(_ text: String, language: Language) -> [OwlSyntaxError] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let index = LineIndex(ns)
        var units = [unichar](repeating: 0, count: ns.length)
        if let mask = CodeMask.make(ns, language: language.rawValue) {
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
    /// more of than the original it replaces.
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
        if language == "javascript" || language == "typescript" { added { selfInitializations($0, language: language) } }
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

    /// Rule a. JS/TS: a variable declared from itself.
    /// - `const x = x` / `let x = x`: HARD, Apply off (and one retry for
    ///   the model), because it always throws a ReferenceError (temporal
    ///   dead zone) when it runs: it never works.
    /// - `var x = x`: WARNING, Apply on: it runs (x is just undefined or
    ///   unchanged), so it is a probable mistake, not a broken program.
    static func selfInitializations(_ s: String, language: String) -> [RuleHit] {
        let ns = code(s, language: language)
        return selfInit.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let kw = ns.substring(with: m.range(at: 1)), name = ns.substring(with: m.range(at: 2))
            guard name == ns.substring(with: m.range(at: 3)) else { return nil }
            let hard = kw != "var"
            let message = hard
                ? String(localized: "`\(kw) \(name) = \(name)` reads `\(name)` before it is set, which always throws a ReferenceError")
                : String(localized: "`var \(name) = \(name)` sets `\(name)` to itself, which does nothing")
            return RuleHit(check: .selfInitialization, severity: hard ? .hard : .warning, key: "init:\(kw):\(name)",
                           message: message, lineOffset: lineOffset(ns, m.range.location))
        }
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
public struct OwlEditGate: Sendable {
    public let script: (any OwlScriptSyntaxChecker)?
    /// A hard failure was already sent back to the model in this Ask.
    public private(set) var retried = false

    public init(script: (any OwlScriptSyntaxChecker)?) { self.script = script }

    public enum Verdict: Sendable, Equatable {
        /// Show it (its `check` set: clean, warnings, or failing after a retry).
        case propose(OwlEditProposal)
        /// Refuse it this once: the text for the model.
        case retry(String)
    }

    public mutating func review(_ p: OwlEditProposal, in s: OwlDocumentSnapshot) -> Verdict {
        var p = p
        p.check = OwlEditValidation.validate(p, in: s, script: script)
        if p.check.failsValidation, !retried, let feedback = p.check.retryFeedback {
            retried = true
            return .retry(feedback)
        }
        return .propose(p)
    }
}

extension OwlEditGate {
    /// propose_edit's result through the gate: a proposal that fails a
    /// hard check the first time becomes a tool failure the model can act
    /// on; later, or with only warnings, the proposal carries its check
    /// (and the model is told it doesn't parse, never that it is applied).
    public mutating func screen(_ r: OwlToolResult, in s: OwlDocumentSnapshot) -> OwlToolResult {
        guard let p = r.proposal else { return r }
        switch review(p, in: s) {
        case .retry(let feedback):
            return OwlToolResult(text: "error: " + feedback, proposal: nil,
                                 summary: String(localized: "the edit doesn’t parse"), ok: false)
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
