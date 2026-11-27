import Foundation
import CedricCore

/// Checks a model's hint against the code where the claim can be checked
/// deterministically, and drops the hint when the code contradicts it
/// ("`<html>` is not closed" when it is). Unknown categories pass.
///
/// Every check only ever *drops*: when the context is a slice of a bigger
/// file (tags or brackets opened above it), a scan that finds a problem
/// proves nothing, so the hint is kept.
public enum HintVerifier {
    public enum Category: String, Sendable, CaseIterable {
        case unclosedTag = "unclosed-tag", brackets, unused, undefined, json, logic, other
        // 0.3.0: what the offline rules check (never offered to the model;
        // found from the hint's words). An AI hint in one of these whose
        // offline rule fires on the same text is dropped: the rule's hint
        // says the same thing and has a real Fix it.
        case secret, nullCompare = "null-compare", shellSyntax = "shell-syntax", quoting, escape
        case mutableDefault = "mutable-default", duplicateKey = "duplicate-key", configValue = "config-value"
        case markdownLink = "markdown-link", codeFence = "code-fence", csv, sqlWhere = "sql-where", redirect
        case leftover, lineEndings = "line-endings", markup, whitespace, style, safety

        /// The categories the model may name (its JSON schema): unchanged by 0.3.0.
        public static let modelCases: [Category] = [.unclosedTag, .brackets, .unused, .undefined, .json, .logic, .other]
    }

    /// Every offline rule id and the category of its claim (0.3.0; the
    /// language packs, the secrets and the whitespace rules).
    public static let ruleCategory: [String: Category] = [
        // Pack 1: shell.
        "rules.sh.crlf": .lineEndings, "rules.sh.assign-spaces": .shellSyntax, "rules.sh.test-brackets": .shellSyntax,
        "rules.sh.pasted-punctuation": .quoting, "rules.sh.shebang": .shellSyntax, "rules.sh.cd-unchecked": .safety,
        "rules.sh.unquoted-var": .quoting, "rules.sh.backticks": .style,
        // Pack 2: Python.
        "rules.py.invalid-escape": .escape, "rules.py.mutable-default": .mutableDefault, "rules.py.none-compare": .nullCompare,
        "rules.py.is-literal": .logic, "rules.py.print-statement": .logic, "rules.py.bare-except": .style, "rules.py.bool-compare": .style,
        // Pack 3: JavaScript / TypeScript.
        "rules.js.debugger": .leftover, "rules.js.nan-compare": .logic, "rules.js.typeof-typo": .logic,
        // Pack 4: config.
        "rules.yaml.duplicate-key": .duplicateKey, "rules.json.duplicate-key": .duplicateKey, "rules.env.duplicate-key": .duplicateKey,
        "rules.yaml.version-float": .configValue, "rules.xml.invalid": .markup, "rules.toml.duplicate": .duplicateKey,
        "rules.toml.bare-string": .configValue, "rules.env.spaces": .configValue,
        // Pack 5: Markdown, CSV.
        "rules.md.unclosed-fence": .codeFence, "rules.md.broken-anchor": .markdownLink, "rules.md.broken-link": .markdownLink,
        "rules.md.image-alt": .style, "rules.md.footnote": .markdownLink, "rules.md.empty-link": .markdownLink,
        "rules.md.heading-skip": .markup, "rules.md.duplicate-heading": .markup, "rules.csv.unclosed-quote": .csv, "rules.csv.ragged-rows": .csv,
        // Pack 6: SQL, PowerShell.
        "rules.sql.null-compare": .nullCompare, "rules.sql.no-where": .sqlWhere,
        "rules.ps.redirect-compare": .redirect, "rules.ps.backtick-space": .shellSyntax,
        // Pack 7: safety.
        "rules.secret": .secret, "rules.downloaded-script": .safety,
        // Whitespace and file rules.
        "rules.editorconfig-indent": .whitespace, "rules.mixed-indent": .whitespace, "rules.trailing-whitespace": .whitespace,
        "rules.final-newline": .whitespace, "rules.crlf": .lineEndings, "rules.mixed-line-endings": .lineEndings,
        "rules.json-invalid": .json, "rules.brackets": .brackets, "rules.yaml-tabs": .whitespace, "rules.smart-quotes-in-code": .quoting,
    ]

    /// Categories an offline rule can confirm.
    static let ruleBacked: Set<Category> = Set(ruleCategory.values).subtracting([.json, .brackets, .logic])

    /// True when the hint repeats what an offline rule says about this
    /// text: one of its rule-backed categories, and a rule of that category
    /// fires here. The rules are run only when a category could match.
    public static func duplicatesRule(_ categories: Set<Category>, text: String, language: String, fileName: String? = nil,
                                      wholeDocument: Bool = true) -> Bool {
        let wanted = categories.intersection(ruleBacked)
        guard !wanted.isEmpty else { return false }
        let ctx = OwlContext(fileName: fileName, language: language, text: text, textStart: 0, visibleRange: NSRange(location: 0, length: 0),
                             selection: nil, documentID: UUID(), editGeneration: 0, isWholeDocument: wholeDocument)
        let fired = RulesHintProvider().check(ctx, facts: OwlDocumentFacts(isWholeDocument: wholeDocument))
        return fired.contains { ruleCategory[$0.id].map(wanted.contains) ?? false }
    }

    /// The categories a hint claims: the model's own field plus keywords.
    public static func categories(model: String?, title: String, detail: String?) -> Set<Category> {
        var out: Set<Category> = []
        if let m = model.flatMap({ Category(rawValue: $0.lowercased()) }) { out.insert(m) }
        let t = (title + " " + (detail ?? "")).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["closing tag", "not closed", "unclosed tag", "unclosed `<", "mismatched tag", "end tag", "missing </", "tag is never closed", "tag is not closed"]) {
            out.insert(.unclosedTag)
        }
        if has(["unbalanced", "parenthes", "missing bracket", "missing brace", "closing bracket", "closing brace", "unmatched",
                "unterminated string", "missing quote", "unclosed string", "unclosed quote", "missing closing quote"]) {
            out.insert(.brackets)
        }
        if has(["unused", "never used", "not used", "is assigned but"]) { out.insert(.unused) }
        if has(["undefined", "not defined", "undeclared", "is not declared", "unknown variable", "never declared"]) { out.insert(.undefined) }
        if has(["invalid json", "json syntax", "trailing comma", "malformed json", "not valid json"]) { out.insert(.json) }
        // 0.3.0: the offline rules' topics.
        if has(["api key", "secret", "access token", "hardcoded password", "hard-coded password", "credential", "password in"]) { out.insert(.secret) }
        if has(["== none", "!= none", "= null", "<> null", "is none", "is null", "is not null", "compare with none", "comparison with null"]) { out.insert(.nullCompare) }
        if has(["shebang", "spaces around =", "space around =", "around the =", "line continuation", "backtick"]) { out.insert(.shellSyntax) }
        if has(["unquoted variable", "quote the variable", "word splitting", "curly quote", "smart quote"]) { out.insert(.quoting) }
        if has(["escape sequence", "invalid escape", "raw string"]) { out.insert(.escape) }
        if has(["mutable default", "default argument is a list", "default argument is a dict"]) { out.insert(.mutableDefault) }
        if has(["duplicate key", "key is defined twice", "defined twice", "duplicated key"]) { out.insert(.duplicateKey) }
        if has(["broken link", "anchor", "link target", "relative link", "image path", "missing image"]) { out.insert(.markdownLink) }
        if has(["code block", "code fence", "fence is", "unclosed fence"]) { out.insert(.codeFence) }
        if has(["field count", "number of fields", "number of columns", "ragged", "csv"]) { out.insert(.csv) }
        if has(["without where", "without a where", "no where", "missing where", "every row", "all rows"]) { out.insert(.sqlWhere) }
        if has(["redirect", "-gt", "-ge", "writes a file"]) { out.insert(.redirect) }
        if has(["debugger statement", "debugger;", "leftover debug"]) { out.insert(.leftover) }
        if has(["crlf", "line ending", "windows line"]) { out.insert(.lineEndings) }
        if has(["trailing whitespace", "trailing space", "tabs and spaces", "indentation style", "final newline", "newline at the end"]) { out.insert(.whitespace) }
        return out
    }

    /// False when the code contradicts the claim, when the claim names a
    /// construct the document does not have, or when it quotes text that
    /// is not in the document.
    public static func holds(_ categories: Set<Category>, title: String, detail: String?, find: String,
                             text: String, language: String) -> Bool {
        if !citationsAreInDocument(title: title, detail: detail, find: find, text: text) { return false }
        if namesAbsentConstruct(title: title, detail: detail, text: text, language: language) { return false }
        let claim = title + " " + (detail ?? "") + " " + find
        for c in categories {
            switch c {
            case .unclosedTag:
                guard looksLikeMarkup(text, language) else { continue }
                let r = TagScan.scan(text, html: !language.lowercased().contains("xml"))
                let named = TagScan.namedTags(in: title + " " + (detail ?? ""))
                if named.isEmpty {
                    if r.unclosed.isEmpty && r.stray.isEmpty { return false }
                } else if named.allSatisfy({ !r.unclosed.contains($0) && !r.stray.contains($0) }) {
                    return false
                }
            case .brackets:
                if BracketScan.scan(text, language: language).isBalanced { return false }
            case .unused:
                guard let name = identifier(in: claim, near: ["variable", "constant", "parameter", "import", "value"]) else { continue }
                if wordCount(name, in: text) != 1 { return false }   // used again, or not there at all
            case .undefined:
                guard let name = identifier(in: claim, near: ["variable", "function", "name", "symbol", "identifier"]) else { continue }
                if wordCount(name, in: text) == 0 || isDeclared(name, in: text) { return false }
            case .json:
                guard language.lowercased() == "json" else { continue }
                if isStrictJSON(text) { return false }
            case .logic, .other:
                continue
            default:
                // A topic of the offline rules: the rules can confirm it (see
                // duplicatesRule), not refute it.
                continue
            }
        }
        return true
    }

    /// For a fix in a checkable category: the code after the replacement
    /// must pass the same check (tags or brackets balance), or the fix is
    /// not offered. Only applies when the code before it fails the check.
    public static func fixPasses(_ categories: Set<Category>, text: String, range: NSRange, replacement: String,
                                 language: String) -> Bool {
        let fixed = (text as NSString).replacingCharacters(in: range, with: replacement)
        if categories.contains(.unclosedTag), looksLikeMarkup(text, language) {
            let html = !language.lowercased().contains("xml")
            let before = TagScan.scan(text, html: html), after = TagScan.scan(fixed, html: html)
            if after.problemCount >= before.problemCount { return false }
        }
        if categories.contains(.brackets) {
            let before = BracketScan.scan(text, language: language), after = BracketScan.scan(fixed, language: language)
            if after.problemCount >= before.problemCount { return false }
        }
        if categories.contains(.json), language.lowercased() == "json", !isStrictJSON(fixed) { return false }
        return true
    }

    /// RFC 8259 JSON. JSONSerialization alone is not enough: on recent
    /// macOS it accepts trailing commas, so those are checked separately.
    public static func isStrictJSON(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil else { return false }
        var inString = false, escaped = false, lastSignificant: Character? = nil
        for ch in text {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true; lastSignificant = ch; continue }
            if ch.isWhitespace { continue }
            if (ch == "]" || ch == "}") && lastSignificant == "," { return false }
            lastSignificant = ch
        }
        return true
    }

    // MARK: Claims the text cannot support

    /// Plain text and Markdown are where a model invents a code block,
    /// table, link, heading or list. Code languages keep those words
    /// ("scans the table" in SQL).
    static func checksDocumentShape(_ language: String) -> Bool {
        ["plain", "text", "txt", "markdown", "md"].contains(language.lowercased())
    }

    /// The `find` snippet, and every backtick or double-quoted span in the
    /// title and detail, must occur in `text`. An empty citation is not a
    /// claim about the text. A quote of a fix that was never in the
    /// document is still a claim the text doesn't support, so it is dropped.
    static func citationsAreInDocument(title: String, detail: String?, find: String, text: String) -> Bool {
        let cited = find.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cited.isEmpty, !text.contains(cited) { return false }
        let claim = title + "\n" + (detail ?? "")
        for span in quotedSpans(in: claim) {
            let q = span.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { continue }
            if !text.contains(q) { return false }
        }
        return true
    }

    /// Backticks, `"straight quotes"` and “curly quotes”. An unclosed quote
    /// is ignored: half a mark is not a citation.
    static func quotedSpans(in claim: String) -> [String] {
        var out: [String] = []
        func pairs(_ open: Character, _ close: Character) {
            let chars = Array(claim)
            var i = 0
            while i < chars.count {
                guard chars[i] == open else { i += 1; continue }
                var j = i + 1
                while j < chars.count, chars[j] != close { j += 1 }
                if j >= chars.count { break }
                if j > i + 1 { out.append(String(chars[(i + 1)..<j])) }
                i = j + 1
            }
        }
        pairs("`", "`")
        pairs("\"", "\"")
        pairs("“", "”")
        return out
    }

    /// True when the claim names a code block, or (in plain text or
    /// Markdown) a table, link, heading or list, and the document has no
    /// such construct. Cheap scans of the lines; a construct we are not
    /// sure about is left alone.
    static func namesAbsentConstruct(title: String, detail: String?, text: String, language: String) -> Bool {
        let claim = (title + " " + (detail ?? "")).lowercased()
        if claim.contains("code block") || claim.contains("fenced code") || claim.contains("code fence")
            || claim.contains("unclosed fence") || claim.contains("fence is") {
            if !hasCodeBlock(text) { return true }
        }
        guard checksDocumentShape(language) else { return false }
        if mentions(claim, "table"), !text.contains("|") { return true }
        if (mentions(claim, "link") || mentions(claim, "hyperlink")), !hasLink(text) { return true }
        if mentions(claim, "heading"), !hasHeading(text) { return true }
        if mentions(claim, "list"), !hasListMarker(text) { return true }
        return false
    }

    /// `word` or `words`, as a whole word.
    static func mentions(_ claim: String, _ word: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "s?\\b"
        return claim.range(of: pattern, options: .regularExpression) != nil
    }

    /// A ``` or ~~~ fence (a line of its own), or a CommonMark indented
    /// code block (four spaces or a tab, then something that isn't space).
    static func hasCodeBlock(_ text: String) -> Bool {
        for line in lines(of: text) {
            let fenceAt = firstNonSpace(line, limit: 3)
            if fenceAt.spaces <= 3, let c = fenceAt.char, (c == "`" || c == "~") {
                var run = 0
                var j = fenceAt.index
                while j < line.endIndex, line[j] == c { run += 1; j = line.index(after: j) }
                if run >= 3 { return true }
            }
            if line.hasPrefix("\t") {
                if line.dropFirst().contains(where: { !$0.isWhitespace }) { return true }
            } else if line.hasPrefix("    "), line.dropFirst(4).contains(where: { !$0.isWhitespace }) {
                return true
            }
        }
        return false
    }

    static func hasLink(_ text: String) -> Bool {
        if text.contains("](") || text.contains("][") || text.contains("[[") { return true }
        let lower = text.lowercased()
        return lower.contains("https://") || lower.contains("http://") || lower.contains("mailto:")
    }

    static func hasHeading(_ text: String) -> Bool {
        var previousWasText = false
        for line in lines(of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isATXHeading(line) { return true }
            if previousWasText, isSetextUnderline(trimmed) { return true }
            previousWasText = !trimmed.isEmpty && !isSetextUnderline(trimmed)
        }
        return false
    }

    static func isATXHeading(_ line: String) -> Bool {
        let start = firstNonSpace(line, limit: 3)
        guard start.spaces <= 3, start.char == "#" else { return false }
        var hashes = 0
        var i = start.index
        while i < line.endIndex, line[i] == "#", hashes < 7 {
            hashes += 1
            i = line.index(after: i)
        }
        guard (1...6).contains(hashes) else { return false }
        if i == line.endIndex { return true }
        return line[i] == " " || line[i] == "\t"
    }

    static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard let c = trimmed.first, c == "=" || c == "-" else { return false }
        return trimmed.allSatisfy { $0 == c }
    }

    static func hasListMarker(_ text: String) -> Bool {
        for line in lines(of: text) {
            let start = firstNonSpace(line, limit: 3)
            guard start.spaces <= 3, let c = start.char else { continue }
            if c == "-" || c == "*" || c == "+" {
                let n = line.index(after: start.index)
                if n < line.endIndex, line[n] == " " || line[n] == "\t" { return true }
                continue
            }
            var j = start.index
            var digits = 0
            while j < line.endIndex, line[j].isNumber, digits < 9 {
                digits += 1
                j = line.index(after: j)
            }
            guard digits > 0, j < line.endIndex, line[j] == "." || line[j] == ")" else { continue }
            let n = line.index(after: j)
            if n < line.endIndex, line[n] == " " || line[n] == "\t" { return true }
        }
        return false
    }

    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Up to `limit` leading spaces, then the next character.
    static func firstNonSpace(_ line: String, limit: Int) -> (spaces: Int, index: String.Index, char: Character?) {
        var i = line.startIndex
        var spaces = 0
        while i < line.endIndex, line[i] == " ", spaces < limit + 1 {
            spaces += 1
            i = line.index(after: i)
        }
        return (spaces, i, i < line.endIndex ? line[i] : nil)
    }

    static func looksLikeMarkup(_ text: String, _ language: String) -> Bool {
        let l = language.lowercased()
        return ["html", "xml", "svg", "xhtml", "vue", "plist"].contains(where: l.contains) || text.contains("</")
    }

    // MARK: Identifiers

    /// The identifier a claim is about: the first `backticked` word, else
    /// the word after "variable"/"function"/….
    static func identifier(in claim: String, near keywords: [String]) -> String? {
        let parts = claim.components(separatedBy: "`")
        if parts.count >= 3 {
            for i in stride(from: 1, to: parts.count, by: 2) {
                let w = parts[i].trimmingCharacters(in: .whitespaces)
                if isIdentifier(w) { return w }
            }
        }
        let words = claim.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).inverted)
            .filter { !$0.isEmpty }
        for (i, w) in words.enumerated() where keywords.contains(w.lowercased()) && i + 1 < words.count {
            let next = words[i + 1]
            if isIdentifier(next), !["is", "was", "the", "a", "an"].contains(next.lowercased()) { return next }
        }
        return nil
    }

    static func isIdentifier(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, CharacterSet.letters.union(CharacterSet(charactersIn: "_$")).contains(f) else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).contains($0) }
    }

    static func wordCount(_ name: String, in text: String) -> Int {
        let pattern = "(?<![A-Za-z0-9_$])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_$])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Whether `name` is declared in `text`: the name being declared (left
    /// of any `=`, including destructuring), a function, type or class
    /// name, a parameter (also of an arrow function), a loop variable, an
    /// import, or a plain assignment at the start of a line. A use on the
    /// right of `=` (`const user = await db.find(id)`) is not.
    static func isDeclared(_ name: String, in text: String) -> Bool {
        let n = NSRegularExpression.escapedPattern(for: name)
        let w = "(?<![A-Za-z0-9_$.])\(n)(?![A-Za-z0-9_$])"
        let patterns = [
            // let/var/const/val: the targets, up to the = (or ; or the line end).
            "\\b(let|var|const|val)\\s+[^=;\\n]*?\(w)",
            // Further declarators in the same statement: "var a = 1, db = 2".
            "\\b(let|var|const)\\s+[^;\\n]*,\\s*\(n)\\s*(=|,|;|$)",
            // Named things.
            "\\b(func|function|def|class|struct|enum|fn|type|interface|protocol|typealias)\\s+\(n)\\b",
            // Imports: up to a quoted path (never the path itself).
            "\\bimport\\s+[^'\"\\n]*?\(w)",
            "(?m)^\\s*\(n)\\s*=[^=]",                      // Python/Ruby/shell assignment
            "\\b(func|def|function|fn)\\b[^\\n(]*\\([^)\\n]*\(w)",   // a parameter
            "\\(([^()\\n]*\(w)[^()\\n]*)?\\)\\s*=>|\(w)\\s*=>",   // an arrow function's parameter
            "\\bfor\\s+\\(?\\s*(let|var|const)?\\s*\(n)\\b",   // a loop variable
        ]
        return patterns.contains { p in
            (try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]))?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }
}

/// A tolerant tag-balance scan: skips comments, `<!DOCTYPE>`, processing
/// instructions, CDATA, `<script>`/`<style>` bodies, void and self-closed
/// elements; in HTML, elements whose end tag is optional (html, head, body,
/// p, li, …) may close implicitly.
public enum TagScan {
    public struct Result: Equatable {
        /// Elements opened and never closed (lower-case names).
        public var unclosed: Set<String> = []
        /// End tags with no matching start tag.
        public var stray: Set<String> = []
        var count = 0
        public var problemCount: Int { count }
    }

    static let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                    "param", "source", "track", "wbr", "keygen", "command"]
    static let optionalEnd: Set<String> = ["html", "head", "body", "p", "li", "dt", "dd", "option", "optgroup",
                                           "tr", "td", "th", "thead", "tbody", "tfoot", "colgroup", "caption", "rb", "rt", "rp", "rtc"]

    public static func scan(_ text: String, html: Bool = true) -> Result {
        var s = text
        for (open, close) in [("<!--", "-->"), ("<![CDATA[", "]]>"), ("<?", "?>")] { s = strip(s, open, close) }
        for raw in ["script", "style"] { s = stripBody(s, raw) }
        let re = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9:._-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*?)(/?)>")
        var stack: [String] = []
        var r = Result()
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = html ? ns.substring(with: m.range(at: 2)).lowercased() : ns.substring(with: m.range(at: 2))
            let selfClosed = ns.substring(with: m.range(at: 4)) == "/"
            if !closing {
                if selfClosed || (html && void.contains(name)) { continue }
                stack.append(name)
                continue
            }
            if html && void.contains(name) { continue }
            guard let idx = stack.lastIndex(of: name) else { r.stray.insert(name); r.count += 1; continue }
            for open in stack[(idx + 1)...] where !(html && optionalEnd.contains(open)) {
                r.unclosed.insert(open); r.count += 1
            }
            stack.removeSubrange(idx...)
        }
        for open in stack where !(html && optionalEnd.contains(open)) { r.unclosed.insert(open); r.count += 1 }
        return r
    }

    /// Tag names a claim mentions: `<div>`, `</div>`, "the div tag".
    static func namedTags(in claim: String) -> Set<String> {
        var out: Set<String> = []
        let re = try! NSRegularExpression(pattern: "</?([A-Za-z][A-Za-z0-9:-]*)[^>]*>|\\b([A-Za-z][A-Za-z0-9-]*)\\s+(?:tag|element)\\b|(?:tag|element)\\s+`?([A-Za-z][A-Za-z0-9-]*)`?")
        let ns = claim as NSString
        for m in re.matches(in: claim, range: NSRange(location: 0, length: ns.length)) {
            for g in 1...3 where m.range(at: g).location != NSNotFound {
                let w = ns.substring(with: m.range(at: g)).lowercased()
                if !["the", "a", "an", "closing", "opening", "end", "start", "this", "that", "html5", "missing", "unclosed"].contains(w) || g == 1 {
                    out.insert(w)
                }
            }
        }
        return out
    }

    private static func strip(_ s: String, _ open: String, _ close: String) -> String {
        var out = s
        while let a = out.range(of: open) {
            if let b = out.range(of: close, range: a.upperBound..<out.endIndex) {
                out.replaceSubrange(a.lowerBound..<b.upperBound, with: " ")
            } else {
                out.removeSubrange(a.lowerBound..<out.endIndex)
            }
        }
        // <!DOCTYPE …> and other declarations.
        return out.replacingOccurrences(of: "<![A-Za-z][^>]*>", with: " ", options: .regularExpression)
    }

    private static func stripBody(_ s: String, _ tag: String) -> String {
        s.replacingOccurrences(of: "(?is)(<\(tag)\\b[^>]*>).*?(</\(tag)\\s*>)", with: "$1$2", options: .regularExpression)
    }
}

/// Bracket and quote balance, skipping strings and comments per language.
public enum BracketScan {
    public struct Result: Equatable {
        public var unmatched = 0
        public var unterminatedString = false
        public var isBalanced: Bool { unmatched == 0 && !unterminatedString }
        public var problemCount: Int { unmatched + (unterminatedString ? 1 : 0) }
    }

    public static func scan(_ text: String, language: String) -> Result {
        let lang = language.lowercased()
        let hashComments = ["python", "ruby", "shell", "bash", "sh", "zsh", "yaml", "toml", "perl", "r", "makefile", "dockerfile"].contains(lang)
        let dashComments = ["sql", "lua", "haskell"].contains(lang)
        let slashComments = !hashComments && !dashComments && !["html", "xml", "markdown", "json", "plain", "text"].contains(lang)
        let backtickStrings = ["javascript", "typescript", "go", "jsx", "tsx", "shell", "bash", "sh", "zsh"].contains(lang)
        let singleQuoteStrings = lang != "rust" && lang != "swift"   // 'a' lifetimes / not a Swift string
        let markup = ["html", "xml", "markdown", "plain", "text"].contains(lang)
        let c = Array(text.unicodeScalars)
        var stack: [UnicodeScalar] = []
        var r = Result()
        var i = 0
        func at(_ k: Int) -> UnicodeScalar? { k < c.count ? c[k] : nil }
        func starts(_ s: String, _ k: Int) -> Bool {
            let u = Array(s.unicodeScalars)
            return k + u.count <= c.count && Array(c[k..<k + u.count]) == u
        }
        while i < c.count {
            let ch = c[i]
            if !markup {
                if slashComments && starts("//", i) { while i < c.count && c[i] != "\n" { i += 1 }; continue }
                if slashComments && starts("/*", i) {
                    i += 2
                    while i < c.count && !starts("*/", i) { i += 1 }
                    i += 2; continue
                }
                if hashComments && ch == "#" { while i < c.count && c[i] != "\n" { i += 1 }; continue }
                if dashComments && starts("--", i) { while i < c.count && c[i] != "\n" { i += 1 }; continue }
                if starts("\"\"\"", i) || (hashComments && starts("'''", i)) {
                    let q = String(c[i]) + String(c[i]) + String(c[i])
                    i += 3
                    while i < c.count && !starts(q, i) { if c[i] == "\\" { i += 1 }; i += 1 }
                    if i >= c.count { r.unterminatedString = true }
                    i += 3; continue
                }
                if ch == "\"" || (ch == "'" && singleQuoteStrings) || (ch == "`" && backtickStrings) {
                    let multiline = ch == "`"
                    i += 1
                    var closed = false
                    while i < c.count {
                        if c[i] == "\\" { i += 2; continue }
                        if c[i] == ch { closed = true; break }
                        if c[i] == "\n" && !multiline { break }
                        i += 1
                    }
                    if !closed { r.unterminatedString = true }
                    i += 1; continue
                }
            }
            switch ch {
            case "(", "[", "{": stack.append(ch)
            case ")", "]", "}":
                let want: UnicodeScalar = ch == ")" ? "(" : ch == "]" ? "[" : "{"
                if stack.last == want { stack.removeLast() } else { r.unmatched += 1 }
            default: break
            }
            _ = at(i)
            i += 1
        }
        r.unmatched += stack.count
        return r
    }
}

/// How the bubble names where a hint came from.
public enum HintSource {
    /// "rules" and "notice" → nil (the owl's own rules and notices need no
    /// label); "apple" → "AI
    /// suggestion · Apple Intelligence"; "local:qwen2.5-coder-3b-instruct-q4_k_m"
    /// → "AI suggestion · Qwen2.5 Coder 3B".
    public static func displayName(_ source: String, catalog: ModelCatalog? = nil) -> String? {
        // "notice": Owlink's own notices (the built-in model didn't load).
        if source == "rules" || source == "notice" || source.isEmpty { return nil }
        if source == "apple" { return "AI suggestion · Apple Intelligence" }
        guard source.hasPrefix("local:") else { return "AI suggestion" }
        let id = String(source.dropFirst(6))
        if let m = catalog?.model(id: id) { return "AI suggestion · \(m.name)" }
        return "AI suggestion · \(shortModelName(id))"
    }

    /// "qwen/qwen2.5-coder-1.5b-instruct-mlx" → "Qwen2.5 Coder 1.5B".
    public static func shortModelName(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        let drop: Set<String> = ["instruct", "mlx", "gguf", "chat", "it", "hf", "latest", "k", "m", "s", "l"]
        let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" }).map(String.init).filter { w in
            let l = w.lowercased()
            if drop.contains(l) { return false }
            if l.range(of: "^(q\\d.*|\\d+bit|fp16|bf16|f16|int[48])$", options: .regularExpression) != nil { return false }
            return true
        }
        let pretty = words.map { w -> String in
            if w.range(of: "^\\d+(\\.\\d+)?[bB]$", options: .regularExpression) != nil { return w.uppercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        return pretty.isEmpty ? id : pretty.joined(separator: " ")
    }
}
