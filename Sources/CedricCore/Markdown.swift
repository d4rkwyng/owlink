import Foundation

/// A small Markdown → HTML renderer for the preview: CommonMark's common
/// constructs (emphasis by CommonMark's delimiter-run rules, reference
/// links) plus GitHub's tables, task lists, strikethrough, autolinks,
/// footnotes and alerts (`> [!NOTE]`), and YAML frontmatter shown as a
/// small metadata table. Not a full CommonMark implementation (no lazy
/// continuation in quotes, simplified HTML blocks); good enough to preview
/// READMEs and notes, with no dependencies.
///
/// Blocks carry `data-line="N"` (0-based source line), list items and
/// blocks inside lists and quotes too, so the preview can scroll in step
/// with the editor both ways.
public enum Markdown {
    /// What to render beyond the plain HTML.
    public struct Options: Sendable {
        /// Fenced code coloured by its language, as `<span class="tk-…">`
        /// (CodeHTML: Cedric's own tokenizers, no script in the page).
        public var highlightCode = false
        /// Obsidian's syntax: `[[wikilinks]]`, `![[embeds]]`, callouts
        /// (`> [!info] Title`, foldable with `-`/`+`), `==highlight==`,
        /// `%%comments%%` (hidden) and `#tags`. Never inside code.
        public var obsidian = false
        /// Where wikilinks and embeds resolve (nil: every wikilink is shown
        /// unresolved and embeds stay as typed).
        public var vault: WikiVault?
        /// Embeds inside an embedded note stay links (transclusion is one level).
        var embedDepth = 0
        /// For a file that leaves the app (exported HTML or PDF, copied
        /// HTML): wikilinks and embeds point at their files by a path
        /// relative to the document's folder, not by a `cedric-doc:` URL,
        /// and an unresolved wikilink is plain text.
        public var exportLinks = false
        public init(highlightCode: Bool = false, obsidian: Bool = false, vault: WikiVault? = nil, exportLinks: Bool = false) {
            self.highlightCode = highlightCode
            self.obsidian = obsidian
            self.vault = vault
            self.exportLinks = exportLinks
        }
        /// The live preview's (and export's) options.
        public static let preview = Options(highlightCode: true, obsidian: true)
        /// `preview`, resolving wikilinks in `vault`.
        public static func preview(vault: WikiVault?) -> Options { Options(highlightCode: true, obsidian: true, vault: vault) }
        /// `preview(vault:)` for export (see `exportLinks`).
        public static func export(vault: WikiVault?) -> Options { Options(highlightCode: true, obsidian: true, vault: vault, exportLinks: true) }
    }

    public static func render(_ source: String, options: Options = Options()) -> String {
        MarkdownRenderer(options: options).render(source)
    }

    /// One line of inline Markdown, for tests.
    static func inline(_ text: String) -> String { MarkdownRenderer(options: Options()).inline(text) }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// A heading's anchor, as GitHub makes it: lower case, letters, digits,
    /// `-` and `_`, spaces as `-`.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "_" { out.append(ch) } else if ch == " " || ch == "-" { out.append("-") }
        }
        return escape(out)
    }

    /// A link label as matched: case-folded, inner white space collapsed.
    static func normalizeLabel<S: StringProtocol>(_ label: S) -> String {
        label.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ").lowercased()
    }
}

/// One render: holds the document's link and footnote definitions and the
/// heading anchors handed out so far.
final class MarkdownRenderer {
    let options: Markdown.Options
    /// `[label]: url "title"` definitions, by normalized label.
    private var refs: [String: (url: String, title: String?)] = [:]
    /// `[^label]: text` definitions (their lines, continuation unindented).
    private var footnoteDefs: [String: [String]] = [:]
    /// Footnotes in the order of their first reference, and their numbers.
    private var footnoteOrder: [String] = []
    private var footnoteNumber: [String: Int] = [:]
    private var footnoteRefs: [String: Int] = [:]
    private var slugs: [String: Int] = [:]
    /// Lists and quotes inside each other so far. Past `maxNesting` the
    /// rest renders as plain text: a 2 000-deep crafted list took 45 s and
    /// deep recursion can overflow a render thread's stack.
    private var nesting = 0
    private var linkDepth = 0
    static let maxNesting = 64

    /// Lines past the nesting cap: shown as their text, not parsed further.
    private func flat(_ lines: ArraySlice<String>, attr: String) -> String {
        let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? "" : "<p\(attr)>\(escape(text))</p>\n"
    }

    init(options: Markdown.Options) { self.options = options }

    func escape(_ s: String) -> String { Markdown.escape(s) }

    func render(_ source: String) -> String {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = ""
        var start = 0
        if let end = frontmatterEnd(lines) {
            out += frontmatter(lines[1..<end])
            start = end + 1
        }
        if options.obsidian, source.contains("%%") { stripComments(&lines, from: start) }
        collectDefinitions(&lines, from: start)
        renderBlocks(lines[start...], firstLine: start, into: &out)
        out += footnotesSection()
        return out
    }

    // MARK: Frontmatter

    /// The line closing a YAML frontmatter block that opens on line 0.
    func frontmatterEnd(_ lines: [String]) -> Int? {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---", lines.count > 1 else { return nil }
        for k in 1..<min(lines.count, 2_000) {
            let t = lines[k].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { return k }
        }
        return nil
    }

    /// The frontmatter as a small key/value table (nested values verbatim).
    func frontmatter(_ lines: ArraySlice<String>) -> String {
        var rows: [(String, String)] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let f = line.first, f != " ", f != "\t", f != "-", f != "#", let colon = line.firstIndex(of: ":"),
               line.index(after: colon) == line.endIndex || line[line.index(after: colon)] == " " {
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
                rows.append((String(line[..<colon]), value))
            } else if !rows.isEmpty {
                rows[rows.count - 1].1 += (rows[rows.count - 1].1.isEmpty ? "" : "\n") + line
            } else {
                rows.append(("", line))
            }
        }
        var out = "<table class=\"frontmatter\" data-line=\"0\">\n<tbody>\n"
        for (k, v) in rows { out += "<tr><th>\(escape(k))</th><td>\(escape(v))</td></tr>\n" }
        return out + "</tbody>\n</table>\n"
    }

    // MARK: Definitions

    /// Takes the link reference and footnote definitions out of `lines`
    /// (outside code), leaving blank lines so the line numbers stay.
    func collectDefinitions(_ lines: inout [String], from start: Int) {
        var fence: String?
        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)
            if let f = fence {
                if indent <= 3, trimmed.hasPrefix(f), trimmed.allSatisfy({ $0 == f.first }) { fence = nil }
                i += 1
                continue
            }
            if indent <= 3, let f = fenceMarker(trimmed) { fence = f; i += 1; continue }
            guard indent <= 3, trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"),
                  trimmed.index(after: close) < trimmed.endIndex, trimmed[trimmed.index(after: close)] == ":" else { i += 1; continue }
            let label = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(close, offsetBy: 2)...].trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("^"), label.count > 1 {
                var body = [rest]
                lines[i] = ""
                var j = i + 1
                // Continuation: indented lines, and blank lines followed by one.
                while j < lines.count {
                    if leadingSpaces(lines[j]) >= 4 { body.append(String(lines[j].dropFirst(min(4, lines[j].prefix { $0 == " " }.count)))); lines[j] = ""; j += 1; continue }
                    if lines[j].trimmingCharacters(in: .whitespaces).isEmpty, j + 1 < lines.count, leadingSpaces(lines[j + 1]) >= 4,
                       !lines[j + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                        body.append(""); j += 1; continue
                    }
                    break
                }
                let key = Markdown.normalizeLabel(label.dropFirst())
                if footnoteDefs[key] == nil { footnoteDefs[key] = body }
                i = j
                continue
            }
            guard !label.isEmpty, !rest.isEmpty, let def = linkDestination(Array(rest), from: 0, needsClose: false),
                  def.end == rest.count else { i += 1; continue }
            let key = Markdown.normalizeLabel(label)
            if refs[key] == nil { refs[key] = (def.url, def.title) }
            lines[i] = ""
            i += 1
        }
    }

    func footnotesSection() -> String {
        guard !footnoteOrder.isEmpty else { return "" }
        var out = "<section class=\"footnotes\">\n<hr>\n<ol>\n"
        var k = 0
        // A footnote may refer to another one: the list grows as it is rendered.
        while k < footnoteOrder.count {
            let label = footnoteOrder[k]
            k += 1
            let id = Markdown.slug(label)
            var inner = ""
            renderBlocks((footnoteDefs[label] ?? [])[...], firstLine: nil, into: &inner)
            let back = "<a href=\"#fnref-\(id)\" class=\"footnote-backref\">↩</a>"
            if inner.hasSuffix("</p>\n") {
                inner = String(inner.dropLast(5)) + " \(back)</p>\n"
            } else {
                inner += back + "\n"
            }
            out += "<li id=\"fn-\(id)\">\n\(inner)</li>\n"
        }
        return out + "</ol>\n</section>\n"
    }

    func uniqueSlug(_ text: String) -> String {
        // The anchor of the heading's text, not its Markdown.
        probing = true
        let plain = Self.stripTags(inline(text))
        probing = false
        let base = Markdown.slug(Self.unescapeEntities(plain))
        let n = slugs[base, default: 0]
        slugs[base] = n + 1
        return n == 0 ? base : "\(base)-\(n)"
    }

    static func stripTags(_ html: String) -> String {
        guard html.contains("<") else { return html }
        return html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }

    static func unescapeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `> [!NOTE]` and its kin: the alert's kind, lower case.
    func alertKind(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[!"), t.hasSuffix("]") else { return nil }
        let kind = t.dropFirst(2).dropLast().lowercased()
        return ["note", "tip", "important", "warning", "caution"].contains(kind) ? kind : nil
    }

    /// Obsidian `%%comments%%`, inline or across lines, taken out (lines
    /// kept, emptied, so data-line numbers still match the source); not
    /// inside fenced code or code spans.
    func stripComments(_ lines: inout [String], from start: Int) {
        var fence: String?
        var inComment = false
        for k in start..<lines.count {
            let line = lines[k]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inComment {
                if let f = fence {
                    if trimmed.hasPrefix(f), trimmed.drop(while: { $0 == f.first }).allSatisfy(\.isWhitespace) { fence = nil }
                    continue
                }
                if let f = fenceMarker(trimmed) { fence = f; continue }
            }
            guard inComment || line.contains("%%") else { continue }
            var out = ""
            var ticks = 0
            var chars = Array(line)
            var i = 0
            while i < chars.count {
                if inComment {
                    if chars[i] == "%", i + 1 < chars.count, chars[i + 1] == "%" { inComment = false; i += 2 } else { i += 1 }
                    continue
                }
                if chars[i] == "`" {
                    var run = 0
                    while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                    ticks = ticks == 0 ? run : (ticks == run ? 0 : ticks)
                    out += String(repeating: "`", count: run)
                    i += run
                    continue
                }
                if ticks == 0, chars[i] == "%", i + 1 < chars.count, chars[i + 1] == "%" { inComment = true; i += 2; continue }
                out.append(chars[i])
                i += 1
            }
            chars = []
            lines[k] = out.allSatisfy(\.isWhitespace) && !line.allSatisfy(\.isWhitespace) ? "" : out
        }
    }

    /// An Obsidian callout's first line, `[!type]` with an optional `-`
    /// (folded) or `+` (foldable, open) and a title.
    struct Callout { var type: String; var fold: Character?; var title: String }

    func callout(_ line: String) -> Callout? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[!"), let close = t.firstIndex(of: "]") else { return nil }
        let type = t[t.index(t.startIndex, offsetBy: 2)..<close].lowercased()
        guard !type.isEmpty, type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        var rest = t[t.index(after: close)...]
        var fold: Character?
        if let f = rest.first, f == "-" || f == "+" { fold = f; rest = rest.dropFirst() }
        return Callout(type: type, fold: fold, title: rest.trimmingCharacters(in: .whitespaces))
    }

    /// Obsidian's callout types (aliases to their family) and their icons.
    static let calloutFamily: [String: String] = [
        "note": "note", "abstract": "abstract", "summary": "abstract", "tldr": "abstract", "info": "info", "todo": "todo",
        "tip": "tip", "hint": "tip", "important": "important", "success": "success", "check": "success", "done": "success",
        "question": "question", "help": "question", "faq": "question", "warning": "warning", "attention": "warning",
        "caution": "caution", "failure": "failure", "fail": "failure", "missing": "failure", "danger": "danger", "error": "danger",
        "bug": "bug", "example": "example", "quote": "quote", "cite": "quote",
    ]
    static let calloutIcon: [String: String] = [
        "note": "✎", "abstract": "☰", "info": "ℹ︎", "todo": "☑︎", "tip": "✦", "important": "❗︎", "success": "✔︎",
        "question": "?", "warning": "⚠︎", "caution": "⚠︎", "failure": "✘", "danger": "⚡︎", "bug": "🐞︎", "example": "☷", "quote": "❝",
    ]

    // MARK: Blocks

    /// `firstLine`: the source line of `lines.first` (nil: no data-line).
    /// Each slice line is one source line, so nested blocks know theirs.
    func renderBlocks(_ lines: ArraySlice<String>, firstLine: Int?, into out: inout String) {
        var i = lines.startIndex
        let end = lines.endIndex
        func srcLine(_ idx: Int) -> Int? { firstLine.map { $0 + idx - lines.startIndex } }
        func attr(_ idx: Int) -> String { srcLine(idx).map { " data-line=\"\($0)\"" } ?? "" }

        while i < end {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code.
            if indent <= 3, let fence = fenceMarker(trimmed) {
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var j = i + 1
                while j < end, !(leadingSpaces(lines[j]) <= 3 && lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence)
                                 && lines[j].trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first })) {
                    body.append(String(lines[j].dropFirst(min(indent, leadingSpaces(lines[j])))))
                    j += 1
                }
                let lang = info.split(separator: " ").first.map { " class=\"language-\(escape(String($0)))\"" } ?? ""
                let code = body.joined(separator: "\n")
                let html = options.highlightCode ? Language(fenceInfo: info).map { CodeHTML.highlight(code, language: $0) } ?? escape(code) : escape(code)
                out += "<pre\(attr(i))><code\(lang)>\(html)\(body.isEmpty ? "" : "\n")</code></pre>\n"
                i = min(end, j + 1)
                continue
            }

            // Indented code.
            if indent >= 4 {
                var body: [String] = []
                var j = i
                while j < end, leadingSpaces(lines[j]) >= 4 || lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(String(lines[j].dropFirst(min(4, leadingSpaces(lines[j])))))
                    j += 1
                }
                while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
                out += "<pre\(attr(i))><code>\(escape(body.joined(separator: "\n")))\n</code></pre>\n"
                i = j
                continue
            }

            // ATX heading.
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.first == " " {
                    var text = rest.trimmingCharacters(in: .whitespaces)
                    // Optional closing #s.
                    while text.hasSuffix("#") { text.removeLast() }
                    text = text.trimmingCharacters(in: .whitespaces)
                    out += "<h\(level)\(attr(i)) id=\"\(uniqueSlug(text))\">\(inline(text))</h\(level)>\n"
                    i += 1
                    continue
                }
            }

            // Thematic break.
            if isThematicBreak(trimmed) {
                out += "<hr\(attr(i))>\n"
                i += 1
                continue
            }

            // Block quote.
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                var j = i
                while j < end {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    j += 1
                }
                if nesting >= Self.maxNesting {
                    out += "<blockquote\(attr(i))>\n" + flat(inner[...], attr: "") + "</blockquote>\n"
                    i = j
                    continue
                }
                nesting += 1
                defer { nesting -= 1 }
                if options.obsidian, let first = inner.first, alertKind(first) == nil, let c = callout(first) {
                    // An Obsidian callout: > [!info] Title, folded with `-`.
                    let family = Self.calloutFamily[c.type] ?? "note"
                    let icon = Self.calloutIcon[family] ?? "✎"
                    let name = c.type.prefix(1).uppercased() + c.type.dropFirst().replacingOccurrences(of: "-", with: " ")
                    let title = "<span class=\"callout-icon\" aria-hidden=\"true\">\(icon)</span> " + (c.title.isEmpty ? escape(name) : inline(c.title))
                    let cls = "markdown-alert markdown-alert-\(family) callout"
                    let typeAttr = " data-callout=\"\(escape(c.type))\""
                    if let fold = c.fold {
                        out += "<details\(attr(i)) class=\"\(cls)\"\(typeAttr)\(fold == "+" ? " open" : "")>\n<summary class=\"markdown-alert-title\">\(title)</summary>\n"
                        renderBlocks(inner[(inner.startIndex + 1)...], firstLine: srcLine(i).map { $0 + 1 }, into: &out)
                        out += "</details>\n"
                    } else {
                        out += "<div\(attr(i)) class=\"\(cls)\"\(typeAttr)>\n<p class=\"markdown-alert-title\">\(title)</p>\n"
                        renderBlocks(inner[(inner.startIndex + 1)...], firstLine: srcLine(i).map { $0 + 1 }, into: &out)
                        out += "</div>\n"
                    }
                } else if let kind = inner.first.flatMap(alertKind) {
                    // A GitHub alert: > [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION].
                    out += "<div\(attr(i)) class=\"markdown-alert markdown-alert-\(kind)\">\n<p class=\"markdown-alert-title\">\(kind.prefix(1).uppercased() + kind.dropFirst())</p>\n"
                    renderBlocks(inner[(inner.startIndex + 1)...], firstLine: srcLine(i).map { $0 + 1 }, into: &out)
                    out += "</div>\n"
                } else {
                    out += "<blockquote\(attr(i))>\n"
                    renderBlocks(inner[...], firstLine: srcLine(i), into: &out)
                    out += "</blockquote>\n"
                }
                i = j
                continue
            }

            // Lists.
            if let marker = listMarker(line) {
                i = renderList(lines, from: i, first: marker, firstLine: srcLine(i), into: &out)
                continue
            }

            // HTML block: passed through until a blank line.
            if indent <= 3, isHTMLBlockStart(trimmed) {
                var j = i
                while j < end, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                out += lines[i..<j].joined(separator: "\n") + "\n"
                i = j
                continue
            }

            // Table: a header row, then a delimiter row.
            if trimmed.contains("|"), i + 1 < end, isTableDelimiter(lines[i + 1]) {
                i = renderTable(lines, from: i, attr: attr(i), into: &out)
                continue
            }

            // Paragraph (or setext heading).
            var para: [String] = [line.hasSuffix("  ") ? trimmed + "  " : trimmed]
            var j = i + 1
            var setext = 0
            while j < end {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; j += 1; break }
                if t.count >= 1, t.allSatisfy({ $0 == "-" }), leadingSpaces(lines[j]) <= 3 { setext = 2; j += 1; break }
                if leadingSpaces(lines[j]) <= 3,
                   fenceMarker(t) != nil || t.hasPrefix("#") || t.hasPrefix(">") || isThematicBreak(t) || listMarker(lines[j]) != nil
                    || isHTMLBlockStart(t) {
                    break
                }
                para.append(lines[j].hasSuffix("  ") ? t + "  " : t)
                j += 1
            }
            if setext > 0 {
                let text = para.joined(separator: " ")
                out += "<h\(setext)\(attr(i)) id=\"\(uniqueSlug(text))\">\(inline(text))</h\(setext)>\n"
            } else {
                out += "<p\(attr(i))>\(inlineLines(para))</p>\n"
            }
            i = j
        }
    }

    struct ListMarker {
        var ordered: Bool
        var start: Int
        var bullet: Character
        /// Columns from the line start to the item's content.
        var contentIndent: Int
    }

    func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let f = rest.first else { return nil }
        if f == "-" || f == "*" || f == "+" {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            if isThematicBreak(String(rest).trimmingCharacters(in: .whitespaces)) { return nil }
            let pad = min(4, max(1, after.prefix { $0 == " " }.count))
            return ListMarker(ordered: false, start: 1, bullet: f, contentIndent: indent + 1 + (after.isEmpty ? 1 : pad))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")" else { return nil }
        let afterDelim = after.dropFirst()
        guard afterDelim.isEmpty || afterDelim.first == " " else { return nil }
        let pad = min(4, max(1, afterDelim.prefix { $0 == " " }.count))
        return ListMarker(ordered: true, start: Int(digits) ?? 1, bullet: delim, contentIndent: indent + digits.count + 1 + pad)
    }

    func renderList(_ lines: ArraySlice<String>, from start: Int, first: ListMarker, firstLine: Int?,
                                   into out: inout String) -> Int {
        let attr = firstLine.map { " data-line=\"\($0)\"" } ?? ""
        var items: [[String]] = []
        var itemLines: [Int?] = []
        var loose = false
        var i = start
        let end = lines.endIndex
        var marker = first
        while i < end, let m = listMarker(lines[i]), m.ordered == first.ordered, m.bullet == first.bullet {
            marker = m
            var item: [String] = [String(lines[i].dropFirst(min(m.contentIndent, lines[i].count)))]
            var j = i + 1
            var sawBlank = false
            while j < end {
                let l = lines[j]
                if isBlank(l) { sawBlank = true; item.append(""); j += 1; continue }
                if leadingSpaces(l) >= marker.contentIndent {
                    if sawBlank { loose = true }
                    item.append(dropIndent(l, marker.contentIndent))
                    sawBlank = false
                    j += 1
                    continue
                }
                if sawBlank { break }
                // Lazy continuation of the item's paragraph.
                let t = l.trimmingCharacters(in: .whitespaces)
                if listMarker(l) == nil, !t.hasPrefix("#"), !t.hasPrefix(">"), fenceMarker(t) == nil {
                    item.append(t)
                    j += 1
                    continue
                }
                break
            }
            while item.last == "" { item.removeLast() }
            items.append(item)
            itemLines.append(firstLine.map { $0 + i - start })
            // A blank line before the next item makes the list loose.
            if j > i + 1, j < end, lines[j - 1].trimmingCharacters(in: .whitespaces).isEmpty, listMarker(lines[j]) != nil { loose = true }
            i = j
            while i < end, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  i + 1 < end, let next = listMarker(lines[i + 1]), next.ordered == first.ordered, next.bullet == first.bullet {
                loose = true
                i += 1
            }
        }
        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        out += "<\(tag)\(attr)\(startAttr)>\n"
        for (k, item) in items.enumerated() {
            var body = item
            var checkbox = ""
            if let firstLine = body.first, firstLine.hasPrefix("[ ] ") || firstLine.hasPrefix("[x] ") || firstLine.hasPrefix("[X] ") {
                checkbox = firstLine.hasPrefix("[ ]") ? "<input type=\"checkbox\" disabled> " : "<input type=\"checkbox\" checked disabled> "
                body[0] = String(firstLine.dropFirst(4))
            }
            var inner = ""
            if nesting >= Self.maxNesting {
                inner = flat(body[...], attr: "")
            } else {
                nesting += 1
                renderBlocks(body[...], firstLine: itemLines[k], into: &inner)
                nesting -= 1
            }
            if !loose {
                // Tight: unwrap the item's paragraphs.
                inner = inner.replacingOccurrences(of: #"<p( data-line="\d+")?>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "</p>\n", with: "\n")
            }
            while inner.hasSuffix("\n") { inner.removeLast() }
            let liAttr = itemLines[k].map { " data-line=\"\($0)\"" } ?? ""
            out += "<li\(liAttr)>\(checkbox)\(inner)</li>\n"
        }
        out += "</\(tag)>\n"
        return i
    }

    func renderTable(_ lines: ArraySlice<String>, from start: Int, attr: String, into out: inout String) -> Int {
        let header = cells(lines[start])
        let aligns: [String?] = cells(lines[start + 1]).map { c in
            let t = c.trimmingCharacters(in: .whitespaces)
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): return "center"
            case (false, true): return "right"
            case (true, false): return "left"
            default: return nil
            }
        }
        func cellTag(_ tag: String, _ k: Int, _ text: String) -> String {
            let a = k < aligns.count ? aligns[k].map { " style=\"text-align:\($0)\"" } ?? "" : ""
            return "<\(tag)\(a)>\(inline(text))</\(tag)>"
        }
        out += "<table\(attr)>\n<thead>\n<tr>" + header.enumerated().map { cellTag("th", $0.offset, $0.element) }.joined() + "</tr>\n</thead>\n"
        var i = start + 2
        var rows = ""
        while i < lines.endIndex {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            let row = cells(lines[i])
            rows += "<tr>" + (0..<header.count).map { cellTag("td", $0, $0 < row.count ? row[$0] : "") }.joined() + "</tr>\n"
            i += 1
        }
        if !rows.isEmpty { out += "<tbody>\n\(rows)</tbody>\n" }
        out += "</table>\n"
        return i
    }

    func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { result.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") else { return false }
        return cells(line).allSatisfy { c in
            let s = c.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
        }
    }

    func fenceMarker(_ trimmed: String) -> String? {
        for f in ["```", "~~~"] where trimmed.hasPrefix(f) {
            let ch = f.first!
            let run = trimmed.prefix { $0 == ch }
            if f == "```", trimmed.dropFirst(run.count).contains("`") { return nil }
            return String(run)
        }
        return nil
    }

    func isThematicBreak(_ trimmed: String) -> Bool {
        guard let f = trimmed.first, f == "-" || f == "*" || f == "_" else { return false }
        let chars = trimmed.filter { $0 != " " && $0 != "\t" }
        return chars.count >= 3 && chars.allSatisfy { $0 == f }
    }

    static let htmlBlockTags: Set<String> = ["address", "article", "aside", "blockquote", "details", "dialog", "div",
        "dl", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "main", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "script", "style", "iframe", "center", "img", "picture", "video"]

    func isHTMLBlockStart(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<") else { return false }
        if trimmed.hasPrefix("<!--") { return true }
        let name = trimmed.dropFirst().drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
        return Self.htmlBlockTags.contains(name)
    }

    func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for b in line.utf8 {
            if b == 0x20 { n += 1 } else if b == 0x09 { n += 4 - n % 4 } else { break }
        }
        return n
    }

    /// `line` without its first `k` characters; by bytes when they are
    /// ASCII (the indent of a nested list item), which is the same thing.
    func dropIndent(_ line: String, _ k: Int) -> String {
        let u = line.utf8
        if let cut = u.index(u.startIndex, offsetBy: k, limitedBy: u.endIndex), u[u.startIndex..<cut].allSatisfy({ $0 < 0x80 }) {
            return String(line[cut...])
        }
        return String(line.dropFirst(k))
    }

    /// Only spaces and tabs (what `trimmingCharacters(in: .whitespaces).isEmpty`
    /// says for Markdown's purposes), without making a trimmed copy.
    func isBlank(_ line: String) -> Bool {
        for b in line.utf8 where b != 0x20 && b != 0x09 {
            // ASCII: not blank. Otherwise maybe a Unicode space: ask Foundation.
            return b >= 0x80 && line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    // MARK: Inline

    /// A paragraph's lines: hard breaks (two spaces or a backslash at the
    /// end) become <br>; emphasis may run across the lines.
    func inlineLines(_ lines: [String]) -> String {
        var text = ""
        for (k, l) in lines.enumerated() {
            let last = k == lines.count - 1
            if !last, l.hasSuffix("  ") {
                text += l.trimmingCharacters(in: .whitespaces) + Self.breakMark + "\n"
            } else if !last, l.hasSuffix("\\"), !l.hasSuffix("\\\\") {
                text += String(l.dropLast()) + Self.breakMark + "\n"
            } else {
                text += l.trimmingCharacters(in: .whitespaces) + (last ? "" : "\n")
            }
        }
        return inline(text)
    }

    /// Stands for a hard line break until the placeholders are restored.
    static let breakMark = "\u{E002}"
    private static let open: Character = "\u{E000}", close: Character = "\u{E001}"

    /// Inline Markdown → HTML. 1: code spans, autolinks, raw inline tags,
    /// bare URLs and escapes are lifted out into placeholders, so nothing
    /// inside them is reinterpreted. 2: links and images (inline,
    /// reference and footnote) become placeholders too, their labels
    /// rendered on their own. 3: emphasis, strong and strikethrough by
    /// CommonMark's delimiter-run rules, text HTML-escaped. 4: the
    /// placeholders are put back.
    func inline(_ text: String) -> String {
        var held: [String] = []
        let s = liftCode(Array(text), &held)
        let linked = links(s, &held, allowLinks: true)
        let marked = options.obsidian ? highlights(linked, &held) : linked
        return restore(emphasis(marked), held)
    }

    private func hold(_ html: String, _ held: inout [String]) -> [Character] {
        held.append(html)
        return [Self.open] + Array(String(held.count - 1)) + [Self.close]
    }

    private func restore(_ s: String, _ held: [String]) -> String {
        var s = s
        if s.contains(Self.breakMark) { s = s.replacingOccurrences(of: Self.breakMark, with: "<br>") }
        guard !held.isEmpty, s.contains(Self.open) else { return s }
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            if ch == Self.open {
                var num = ""
                while let d = it.next(), d != Self.close { num.append(d) }
                if let k = Int(num), k < held.count { out += restore(held[k], held) }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static let escapable: Set<Character> = Set("\\`*_{}[]()#+-.!|~<>\"'")

    /// Phase 1.
    private func liftCode(_ chars: [Character], _ held: inout [String]) -> [Character] {
        var s: [Character] = []
        s.reserveCapacity(chars.count)
        var i = 0
        let n = chars.count
        let hasLT = chars.contains("<")
        let nextGT = hasLT ? Self.nextIndex(of: ">", in: chars) : []
        let nextLT = hasLT ? Self.nextIndex(of: "<", in: chars) : []
        while i < n {
            let c = chars[i]
            if c == "\\", i + 1 < n, Self.escapable.contains(chars[i + 1]) {
                s += hold(escape(String(chars[i + 1])), &held)
                i += 2
                continue
            }
            if c == "`" {
                var run = 0
                while i + run < n, chars[i + run] == "`" { run += 1 }
                var j = i + run
                var found: Int?
                while j < n {
                    if chars[j] == "`" {
                        var r = 0
                        while j + r < n, chars[j + r] == "`" { r += 1 }
                        if r == run { found = j; break }
                        j += r
                    } else {
                        j += 1
                    }
                }
                if let close = found {
                    var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    s += hold("<code>\(escape(code))</code>", &held)
                    i = close + run
                } else {
                    s += Array(repeating: "`", count: run)
                    i += run
                }
                continue
            }
            // A tag or autolink never holds another `<`: the next `>` counts
            // only before the next `<`, so a run of `<` is linear.
            if c == "<", let close = nextGT[i + 1], (nextLT[i + 1] ?? Int.max) > close {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:"), !inner.contains(" ") {
                    let href = escape(safeURL(inner))
                    s += hold("<a href=\"\(href)\">\(escape(inner))</a>", &held)
                    i = close + 1
                    continue
                }
                if inner.range(of: #"^/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?$"#, options: .regularExpression) != nil
                    || inner.hasPrefix("!--") {
                    s += hold("<\(inner)>", &held)
                    i = close + 1
                    continue
                }
            }
            // An Obsidian #tag: after a space or the start, letters, digits,
            // `_`, `-`, `/`, not all digits (`#1` is no tag).
            if c == "#", options.obsidian, i == 0 || chars[i - 1].isWhitespace {
                var j = i + 1
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "-" || chars[j] == "/" { j += 1 }
                let tag = String(chars[(i + 1)..<j])
                if !tag.isEmpty, !tag.allSatisfy(\.isNumber) {
                    s += hold("<span class=\"tag\">#\(escape(tag))</span>", &held)
                    i = j
                    continue
                }
            }
            if c == "h", i + 8 < n, chars[i + 1] == "t", chars[i + 2] == "t", chars[i + 3] == "p",
               i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || "\"'=/>([".contains(chars[i - 1])),
               let end = bareURLEnd(chars, from: i) {
                let u = String(chars[i..<end])
                s += hold("<a href=\"\(escape(u))\">\(escape(u))</a>", &held)
                i = end
                continue
            }
            s.append(c)
            i += 1
        }
        return s
    }

    /// The end of a bare http(s) URL at `i`, as GitHub autolinks it.
    private func bareURLEnd(_ c: [Character], from i: Int) -> Int? {
        let head = String(c[i..<min(c.count, i + 8)])
        let skip = head.hasPrefix("https://") ? 8 : head.hasPrefix("http://") ? 7 : 0
        guard skip > 0 else { return nil }
        var j = i + skip
        while j < c.count, !c[j].isWhitespace, c[j] != "<", c[j] != Self.open { j += 1 }
        // Not trailing punctuation, nor a closing paren without its opener.
        // Counted once, then kept up to date as the end moves back (a URL
        // followed by thousands of `)` was quadratic).
        let opens = c[i..<j].filter { $0 == "(" }.count
        var closes = c[i..<j].filter { $0 == ")" }.count
        while j > i + skip {
            let last = c[j - 1]
            if ".,:;\"'!?*_~".contains(last) { j -= 1; continue }
            if last == ")", closes > opens { closes -= 1; j -= 1; continue }
            break
        }
        return j > i + skip ? j : nil
    }

    /// Phase 2: `[text](url "title")`, `[text][ref]`, `[ref]`, `![alt](src)`
    /// and `[^note]`.
    private func links(_ s: [Character], _ held: inout [String], allowLinks: Bool) -> [Character] {
        guard s.contains("[") else { return s }
        var out: [Character] = []
        out.reserveCapacity(s.count)
        var i = 0
        let n = s.count
        // Linear on crafted input (security review 0.2.1): every `[`'s
        // matching `]` and the next `]` after each place are worked out in
        // one pass, not rescanned per `[`; link destinations share a scan
        // budget a real document never reaches (each scans only its own URL).
        let pairs = Self.bracketPairs(s)
        let nextClose = Self.nextIndex(of: "]", in: s)
        var budget = 4 * n + 65_536
        while i < n {
            let c = s[i]
            let isImage = c == "!" && i + 1 < n && s[i + 1] == "["
            guard c == "[" || isImage else { out.append(c); i += 1; continue }
            let open = isImage ? i + 1 : i
            // An Obsidian [[wikilink]] or ![[embed]]: `[[` whose inner
            // brackets close right before the outer ones, nothing nested.
            if options.obsidian, open + 1 < n, s[open + 1] == "[", let inner = pairs[open + 1], inner + 1 < n, s[inner + 1] == "]",
               pairs[open] == inner + 1, inner - open - 2 <= 999, inner > open + 2, !s[(open + 2)..<inner].contains("\n") {
                let body = String(s[(open + 2)..<inner])
                if let html = wikiLink(body, embed: isImage, &held) {
                    out += hold(html, &held)
                    i = inner + 2
                    continue
                }
                // An embed that isn't found (or can't be shown) stays as typed.
                if isImage {
                    out += Array("![[") + Array(body) + Array("]]")
                    i = inner + 2
                    continue
                }
            }
            // A footnote reference.
            if !isImage, open + 2 < n, s[open + 1] == "^", let close = nextClose[open + 2],
               !s[(open + 2)..<close].contains("["), let def = footnoteRef(String(s[(open + 2)..<close])) {
                out += hold(def, &held)
                i = close + 1
                continue
            }
            guard let close = pairs[open] else { out.append(c); i += 1; continue }
            // A reference label is at most 999 characters (CommonMark), so a
            // long bracketed span is never copied just to be looked up.
            let labelFits = close - open - 1 <= 999
            func labelText() -> String { String(s[(open + 1)..<close]) }
            var target: (url: String, title: String?)?
            var end = close + 1
            if close + 1 < n, s[close + 1] == "(", budget > 0,
               let d = linkDestination(s, from: close + 2, needsClose: true, budget: &budget) {
                target = (d.url, d.title)
                end = d.end
            } else if close + 1 < n, s[close + 1] == "[", close + 2 < n, let rclose = nextClose[close + 2] {
                if rclose - close - 2 <= 999, rclose == close + 2 ? labelFits : true {
                    let ref = String(s[(close + 2)..<rclose])
                    if let r = refs[Markdown.normalizeLabel(ref.isEmpty ? labelText() : ref)] { target = r; end = rclose + 1 }
                }
            } else if labelFits, !refs.isEmpty, let r = refs[Markdown.normalizeLabel(labelText())] {
                target = r
            }
            guard let target, isImage || allowLinks else { out.append(c); i += 1; continue }
            let label = Array(s[(open + 1)..<close])
            let title = target.title.map { " title=\"\(escape($0))\"" } ?? ""
            let url = escape(safeURL(target.url))
            // Labels hold images (a badge) in images in…: past
            // `maxNesting` levels the rest stays text, so crafted nesting
            // can't overflow the render thread's stack.
            linkDepth += 1
            let labelChars = linkDepth > Self.maxNesting ? label : links(label, &held, allowLinks: false)
            linkDepth -= 1
            if isImage {
                let alt = Self.stripTags(restore(emphasis(labelChars), held))
                out += hold("<img src=\"\(url)\" alt=\"\(alt)\"\(title)>", &held)
            } else {
                // The label may hold images (a badge), not other links.
                let inner = emphasis(labelChars)
                out += hold("<a href=\"\(url)\"\(title)>\(inner)</a>", &held)
            }
            i = end
        }
        return out
    }

    /// A wikilink's HTML (nil: leave the text as typed). `[[note]]`,
    /// `[[note|alias]]`, `[[note#Heading]]`, `[[note#^block]]`; with
    /// `embed`, `![[image.png]]`, `![[image.png|300]]` (width) and
    /// `![[note]]` / `![[note#Heading]]` quoted in place, one level deep.
    private func wikiLink(_ body: String, embed: Bool, _ held: inout [String]) -> String? {
        guard !body.contains("\n"), !body.contains(Self.open) || !embed else { return nil }
        let bar = body.firstIndex(of: "|")
        let target = bar.map { String(body[..<$0]) } ?? body
        let alias = bar.map { String(body[body.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
        let (name, fragment) = WikiVault.split(target)
        let vault = options.vault
        let file = name.isEmpty ? nil : (embed ? (vault?.resolveImage(name) ?? vault?.resolve(name)) : vault?.resolve(name))
        let exporting = options.exportLinks
        func href(_ file: URL, heading: String? = nil) -> String? {
            guard exporting else { return WikiVault.href(file, heading: heading) }
            return vault.map { WikiVault.relativeHref(file, from: $0.documentFolder) }
        }
        if embed {
            guard let vault, let file else { return nil }
            let ext = file.pathExtension.lowercased()
            if WikiVault.imageExtensions.contains(ext) {
                guard let src = href(file) else { return nil }
                var size = ""
                if let alias, let m = alias.wholeMatch(of: #/(\d{1,5})(?:x(\d{1,5}))?/#) {
                    size = " width=\"\(m.1)\""
                    if let h = m.2 { size += " height=\"\(h)\"" }
                }
                let alt = alias.flatMap { $0.wholeMatch(of: #/\d{1,5}(x\d{1,5})?/#) == nil ? $0 : nil } ?? file.lastPathComponent
                return "<img class=\"embed\" src=\"\(escape(src))\" alt=\"\(escape(alt))\"\(size)>"
            }
            guard ext == "md" || ext == "markdown" else { return nil }
            let link = href(file, heading: fragment).map { " href=\"\(escape($0))\"" } ?? ""
            let label = escape(name + (fragment.flatMap { $0.hasPrefix("^") ? nil : " › " + $0 } ?? ""))
            // Inside an embedded note, or too big: a link, not a second copy.
            guard options.embedDepth == 0, let text = vault.embedText(file, fragment: fragment) else {
                return "<a class=\"wikilink\"\(link)>\(label)</a>"
            }
            var sub = options
            sub.embedDepth += 1
            let body = MarkdownRenderer(options: sub).render(text)
            return "<blockquote class=\"embed\"><p class=\"embed-title\"><a class=\"wikilink\"\(link)>\(label)</a></p>\n\(body)</blockquote>"
        }
        let shown = alias.flatMap { $0.isEmpty ? nil : $0 } ?? (fragment.map { name.isEmpty ? $0 : name + " › " + $0 } ?? name)
        guard !shown.isEmpty else { return nil }
        let text = emphasis(Array(shown))
        if let file, let href = href(file, heading: fragment) {
            return "<a class=\"wikilink\" href=\"\(escape(href))\">\(text)</a>"
        }
        // Exported: no link to nowhere, just the words.
        if exporting { return text }
        return "<a class=\"wikilink is-unresolved\" title=\"\(escape(name)) (not found)\">\(text)</a>"
    }

    /// Obsidian `==highlight==` as `<mark>`: `==` not followed by a space,
    /// closed by the next `==` not after one.
    private func highlights(_ s: [Character], _ held: inout [String]) -> [Character] {
        guard s.count >= 5, s.contains("=") else { return s }
        var out: [Character] = []
        out.reserveCapacity(s.count)
        var i = 0
        let n = s.count
        while i < n {
            if s[i] == "=", i + 2 < n, s[i + 1] == "=", s[i + 2] != "=", !s[i + 2].isWhitespace {
                var j = i + 2
                var close: Int?
                while j + 1 < n {
                    if s[j] == "=", s[j + 1] == "=" {
                        if !s[j - 1].isWhitespace, j > i + 2 { close = j }
                        break
                    }
                    j += 1
                }
                if let close {
                    out += hold("<mark>" + emphasis(Array(s[(i + 2)..<close])) + "</mark>", &held)
                    i = close + 2
                    continue
                }
                // No closer from here on: the rest is plain.
                out += s[i...]
                return out
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// For each `[`, the `]` closing it (brackets nest), in one pass: the
    /// same answer as scanning on from each `[` and counting depth.
    static func bracketPairs(_ s: [Character]) -> [Int?] {
        var pairs = [Int?](repeating: nil, count: s.count)
        var stack: [Int] = []
        for (j, c) in s.enumerated() {
            if c == "[" { stack.append(j) } else if c == "]", let o = stack.popLast() { pairs[o] = j }
        }
        return pairs
    }

    /// For each place, the first index at or after it holding `c`.
    static func nextIndex(of c: Character, in s: [Character]) -> [Int?] {
        var next = [Int?](repeating: nil, count: s.count + 1)
        var j = s.count - 1
        while j >= 0 {
            next[j] = s[j] == c ? j : next[j + 1]
            j -= 1
        }
        return next
    }

    /// A link destination and optional title starting at `from` (after the
    /// `(`); with `needsClose`, up to and including the `)`.
    /// `budget`: characters it may still scan; it stops (nil) when spent.
    func linkDestination(_ s: [Character], from: Int, needsClose: Bool) -> (url: String, title: String?, end: Int)? {
        var unlimited = Int.max
        return linkDestination(s, from: from, needsClose: needsClose, budget: &unlimited)
    }

    func linkDestination(_ s: [Character], from: Int, needsClose: Bool, budget: inout Int) -> (url: String, title: String?, end: Int)? {
        // Every scan stops at `n`: what is left of the budget past `from`.
        let n = budget >= s.count - from ? s.count : from + max(0, budget)
        var far = from
        defer { budget -= max(0, far - from) + 1 }
        func first(_ c: Character, after k: Int) -> Int? {
            var x = k
            while x < n, s[x] != c { x += 1 }
            far = max(far, x)
            return x < n ? x : nil
        }
        var j = from
        while j < n, s[j] == " " || s[j] == "\t" { j += 1 }
        var url = ""
        if j < n, s[j] == "<" {
            guard let close = first(">", after: j + 1) else { return nil }
            url = String(s[(j + 1)..<close])
            j = close + 1
        } else {
            var depth = 0
            while j < n, s[j] != " ", s[j] != "\t", s[j] != "\n" {
                if s[j] == "(" { depth += 1 } else if s[j] == ")" { if depth == 0 { break }; depth -= 1 }
                url.append(s[j])
                j += 1
            }
        }
        far = max(far, j)
        while j < n, s[j] == " " || s[j] == "\t" { j += 1 }
        var title: String?
        if j < n, s[j] == "\"" || s[j] == "'" || s[j] == "(" {
            let closer: Character = s[j] == "(" ? ")" : s[j]
            guard let close = first(closer, after: j + 1) else { return nil }
            title = String(s[(j + 1)..<close])
            j = close + 1
            while j < n, s[j] == " " || s[j] == "\t" { j += 1 }
        }
        far = max(far, j)
        if needsClose {
            guard j < n, s[j] == ")" else { return nil }
            j += 1
        }
        return (url, title, j)
    }

    /// `[^label]`: a numbered superscript link, if the note is defined.
    private func footnoteRef(_ label: String) -> String? {
        let key = Markdown.normalizeLabel(label)
        guard footnoteDefs[key] != nil else { return nil }
        let id = Markdown.slug(key)
        if probing { return "" }
        let number: Int
        if let k = footnoteNumber[key] { number = k } else {
            footnoteOrder.append(key)
            number = footnoteOrder.count
            footnoteNumber[key] = number
        }
        let count = footnoteRefs[key, default: 0] + 1
        footnoteRefs[key] = count
        let refID = count == 1 ? " id=\"fnref-\(id)\"" : ""
        return "<sup class=\"footnote-ref\"><a href=\"#fn-\(id)\"\(refID)>\(number)</a></sup>"
    }

    /// Set while working out a heading's anchor (no footnote numbers taken).
    private var probing = false

    /// Phase 3: `*em*`, `**strong**`, `~~del~~` by CommonMark's
    /// delimiter runs (left/right flanking, the rule of three, `_` not
    /// inside words), so `**bold *mix***` nests properly. Text is escaped.
    private func emphasis(_ s: [Character]) -> String {
        struct Node { var text: String; var delim: Character?; var count = 0; var orig = 0
                      var canOpen = false; var canClose = false; var active = true; var opens: [String] = []; var closes: [String] = [] }
        guard s.contains(where: { $0 == "*" || $0 == "_" || $0 == "~" }) else { return escape(String(s)) }
        var nodes: [Node] = []
        var text = ""
        func isSpace(_ c: Character?) -> Bool { c == nil || c!.isWhitespace }
        func isPunct(_ c: Character?) -> Bool {
            guard let c, c != Self.open, c != Self.close else { return false }
            return c.isPunctuation || c.isSymbol
        }
        var i = 0
        let n = s.count
        while i < n {
            let c = s[i]
            guard c == "*" || c == "_" || c == "~" else { text.append(c); i += 1; continue }
            var j = i
            while j < n, s[j] == c { j += 1 }
            let run = j - i
            if c == "~", run > 2 { text += String(repeating: "~", count: run); i = j; continue }
            let before: Character? = i > 0 ? s[i - 1] : nil, after: Character? = j < n ? s[j] : nil
            let left = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before))
            let right = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after))
            var canOpen = left, canClose = right
            if c == "_" {
                canOpen = left && (!right || isPunct(before))
                canClose = right && (!left || isPunct(after))
            }
            if !text.isEmpty { nodes.append(Node(text: text)); text = "" }
            nodes.append(Node(text: "", delim: c, count: run, orig: run, canOpen: canOpen, canClose: canClose))
            i = j
        }
        if !text.isEmpty { nodes.append(Node(text: text)) }
        // Delimiters in order, as a linked list (prev) so a matched pair
        // drops the ones between it in O(1); `floor` is CommonMark's
        // "openers bottom": where an earlier search for a closer of the
        // same kind found nothing, the next one stops. Linear on crafted
        // input such as 20 000 `**a` (security review 0.2.1).
        let delims = nodes.indices.filter { nodes[$0].delim != nil }
        var prev = Array((-1)..<(delims.count - 1))
        var floor: [String: Int] = [:]
        var ci = 0
        while ci < delims.count {
            let closer = delims[ci]
            guard nodes[closer].canClose, nodes[closer].active, nodes[closer].count > 0 else { ci += 1; continue }
            let cn = nodes[closer]
            let key = "\(cn.delim!)\(cn.delim == "~" ? cn.orig : cn.orig % 3)\(cn.canOpen)"
            let bottom = floor[key] ?? 0
            var oi = prev[ci]
            var opener: Int?
            while oi >= bottom {
                let on = nodes[delims[oi]]
                if on.active, on.canOpen, on.delim == cn.delim, on.count > 0 {
                    if cn.delim == "~" {
                        if on.count == cn.count { opener = oi; break }
                    } else if !((on.canClose || cn.canOpen) && (on.orig + cn.orig) % 3 == 0 && !(on.orig % 3 == 0 && cn.orig % 3 == 0)) {
                        opener = oi; break
                    }
                }
                oi = prev[oi]
            }
            guard let found = opener else {
                floor[key] = ci
                ci += 1
                continue
            }
            let o = delims[found]
            let ch = nodes[closer].delim!
            let use = ch == "~" ? nodes[closer].count : (nodes[o].count >= 2 && nodes[closer].count >= 2 ? 2 : 1)
            let tag = ch == "~" ? "del" : use == 2 ? "strong" : "em"
            nodes[o].count -= use
            nodes[closer].count -= use
            nodes[o].opens.insert("<\(tag)>", at: 0)
            nodes[closer].closes.append("</\(tag)>")
            // Delimiters between the pair are plain text now.
            var k = prev[ci]
            while k > found { nodes[delims[k]].active = false; k = prev[k] }
            prev[ci] = found
            if nodes[o].count == 0 { nodes[o].active = false; prev[ci] = prev[found] }
            if nodes[closer].count == 0 {
                if ci + 1 < delims.count { prev[ci + 1] = prev[ci] }
                ci += 1
            }
        }
        var out = ""
        for node in nodes {
            if let d = node.delim {
                out += node.closes.joined() + String(repeating: d, count: node.count) + node.opens.joined()
            } else {
                out += escape(node.text)
            }
        }
        return out
    }

    /// No `javascript:` (or other script-capable) links in the preview.
    private func safeURL(_ url: String) -> String {
        let lower = url.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
        return url
    }
}

/// Cleans rendered HTML that leaves Cedric (security audit L4, M3). The
/// preview never runs page script (CSP and WebKit settings), but an
/// exported page or copied HTML is opened elsewhere, so raw HTML blocks'
/// `<script>`, `<iframe>`, `<object>`, `<embed>`, `on…=` handlers and
/// `javascript:` URLs are removed. For rich text, remote resources go too
/// (an `<img src="https://tracker/…">` must not phone home on copy).
public enum HTMLScrub {
    static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators]) }
    nonisolated(unsafe) static let pairs = regex(#"<(script|iframe|object|embed|noscript)\b[^>]*>.*?</\1\s*>"#)
    nonisolated(unsafe) static let singles = regex(#"<(script|iframe|object|embed|frame|frameset|base)\b[^>]*/?>"#)
    nonisolated(unsafe) static let refresh = regex(#"<meta\b[^>]*http-equiv\s*=\s*["']?refresh[^>]*>"#)
    /// A start tag, quoted attribute values included (a `>` inside quotes
    /// doesn't end it).
    nonisolated(unsafe) static let tags = regex(#"<[a-z][a-z0-9:-]*(?:"[^"]*"|'[^']*'|[^'">])*>?"#)
    /// An `on…=` handler inside a tag: after whitespace, a `/` (`<svg/onload=…>`)
    /// or a closing quote (`<a href="x"onclick=…>`), as browsers read them.
    nonisolated(unsafe) static let handlers = regex(#"(?<=[\s/"'])on[a-z0-9_-]*\s*=\s*("[^"]*"|'[^']*'|[^\s>]*)"#)
    /// A URL attribute inside a tag, after whitespace, a `/` (`<a/href=…>`)
    /// or a closing quote, as browsers read them. Group 1 is everything up
    /// to the value, group 2 the value with its quotes.
    nonisolated(unsafe) static let urlAttr = regex(#"((?<=[\s/"'])(?:href|src|action|formaction|xlink:href)\s*=\s*)("[^"]*"|'[^']*'|[^\s>]*)"#)
    nonisolated(unsafe) static let remoteAttr = regex(#"\s(?:src|href|srcset|background|poster|data|xlink:href)\s*=\s*("\s*(?:https?:|ftp:|//)[^"]*"|'\s*(?:https?:|ftp:|//)[^']*'|(?:https?:|ftp:|//)[^\s>]*)"#)
    nonisolated(unsafe) static let links = regex(#"<link\b[^>]*>"#)
    nonisolated(unsafe) static let remoteCSS = regex(#"(@import\s+)?url\(\s*["']?\s*(?:https?:|ftp:|//)[^)]*\)|@import\s+["']\s*(?:https?:|ftp:|//)[^"']*["']"#)

    static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    /// No script, frames, handlers or script URLs.
    public static func noScript(_ html: String) -> String {
        var s = replace(pairs, in: html, with: "")
        s = replace(singles, in: s, with: "")
        s = replace(refresh, in: s, with: "")
        s = noHandlers(s)
        return s
    }

    /// Every start tag without its event-handler attributes, and with any
    /// script URL replaced by `"#"` (text between tags is left alone).
    static func noHandlers(_ html: String) -> String {
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += noScriptURLs(replace(handlers, in: ns.substring(with: m.range), with: ""))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// One tag with each `javascript:` / `vbscript:` URL attribute value
    /// replaced by `"#"`. The value is read the way a browser reads it
    /// before the scheme check: character references decoded, then every
    /// whitespace and control character dropped (`java&#9;script:`,
    /// `&#x6a;avascript:`, `javascript&colon;` are all caught).
    static func noScriptURLs(_ tag: String) -> String {
        let ns = tag as NSString
        var out = ""
        var last = 0
        for m in urlAttr.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let valueRange = m.range(at: 2)
            var value = ns.substring(with: valueRange)
            if let q = value.first, q == "\"" || q == "'" { value = String(value.dropFirst().dropLast()) }
            guard isScriptURL(value) else { continue }
            out += ns.substring(with: NSRange(location: last, length: valueRange.location - last)) + "\"#\""
            last = valueRange.location + valueRange.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Whether an attribute value (still entity-encoded) is a script URL.
    static func isScriptURL(_ value: String) -> Bool {
        let drop = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let scalars = decodeCharacterReferences(value).unicodeScalars.filter { !drop.contains($0) }
        let plain = String(String.UnicodeScalarView(scalars)).lowercased()
        return plain.hasPrefix("javascript:") || plain.hasPrefix("vbscript:")
    }

    /// Named references a browser would turn into a character that matters
    /// for a URL scheme (letters have no named references in ASCII).
    static let namedReferences: [String: String] = [
        "Tab": "\t", "NewLine": "\n", "nbsp": "\u{A0}", "colon": ":", "sol": "/", "bsol": "\\",
        "lpar": "(", "rpar": ")", "period": ".", "comma": ",", "semi": ";", "excl": "!",
        "quot": "\"", "QUOT": "\"", "apos": "'", "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">",
        "num": "#", "equals": "=", "plus": "+", "lowbar": "_", "UnderBar": "_", "percnt": "%",
    ]
    nonisolated(unsafe) static let characterReference = try! NSRegularExpression(pattern: #"&(?:#[xX]([0-9a-fA-F]+);?|#([0-9]+);?|([A-Za-z][A-Za-z0-9]*);)"#)

    /// `&#106;`, `&#x6A;` (the `;` optional, as browsers allow in
    /// attributes) and the named references above, decoded once.
    static func decodeCharacterReferences(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in characterReference.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var decoded: String?
            // Leading zeros are allowed (`&#0000106;`); a number too big is U+FFFD.
            func scalar(_ digits: String, _ radix: Int) -> String? {
                let d = digits.drop { $0 == "0" }
                guard d.count <= 8 else { return nil }
                return UInt32(d.isEmpty ? "0" : String(d), radix: radix).flatMap(Unicode.Scalar.init).map { String($0) }
            }
            if m.range(at: 1).location != NSNotFound {
                decoded = scalar(ns.substring(with: m.range(at: 1)), 16)
            } else if m.range(at: 2).location != NSNotFound {
                decoded = scalar(ns.substring(with: m.range(at: 2)), 10)
            } else {
                decoded = namedReferences[ns.substring(with: m.range(at: 3))]
            }
            // Out of range or unknown: U+FFFD for numbers (as browsers do), else kept as written.
            out += decoded ?? (m.range(at: 3).location == NSNotFound ? "\u{FFFD}" : ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `noScript`, and nothing that loads from the network.
    public static func noScriptNoRemote(_ html: String) -> String {
        var s = noScript(html)
        s = replace(links, in: s, with: "")
        s = replace(remoteAttr, in: s, with: "")
        s = replace(remoteCSS, in: s, with: "none")
        return s
    }
}
