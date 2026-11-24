import Foundation

/// The hints Cedric gives without any AI: plain checks on the text in view
/// and on the document facts. Pure and fast (one pass over at most 8 KB).
public struct RulesHintProvider: OwlFactsAwareProvider {
    public static let jsonID = "rules.json-format"

    /// The long one-line JSON hint (only the file's start in view, no
    /// range, no replacement): its Fix it checks and formats the whole
    /// file. Not a stale replay of the in-view hint (`OwlCoordinator.replay`
    /// strips its range and replacement but keeps the ID): that one's text
    /// has changed, so it gets no Fix it at all.
    public static func formatsWholeJSONFile(_ hint: OwlHint, isStale: Bool) -> Bool {
        hint.id == jsonID && hint.replacement == nil && hint.range == nil && !isStale
    }
    public static let mixedIndentID = "rules.mixed-indent"
    public static let reloadID = "rules.changed-on-disk"
    public static let saveCopyID = "rules.unsaved-long"
    public static let trailingID = "rules.trailing-whitespace"
    public static let crlfID = "rules.crlf"
    public static let letterID = "rules.letter"

    public let name = "rules"
    /// Unsaved this long → "Save a copy?".
    public var unsavedThreshold: TimeInterval = 2 * 3600
    /// At least this many lines ending in spaces or tabs → "Trim?".
    public var trailingMinLines = 5
    public var tabWidth = 4
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func hints(for context: OwlContext) async -> [OwlHint] {
        check(context, facts: OwlDocumentFacts())
    }

    public func hints(for context: OwlContext, facts: OwlDocumentFacts) async -> [OwlHint] {
        check(context, facts: facts)
    }

    /// All the rules, most useful first.
    public func check(_ c: OwlContext, facts: OwlDocumentFacts) -> [OwlHint] {
        var out: [OwlHint] = []
        let text = c.text as NSString
        let all = NSRange(location: 0, length: text.length)
        func hint(_ id: String, _ kind: OwlHint.Kind, _ title: String, _ detail: String? = nil, range: NSRange? = nil, replacement: String? = nil) {
            out.append(OwlHint(id: id, kind: kind, title: title, detail: detail, range: range, replacement: replacement, source: "rules"))
        }

        if facts.changedOnDisk {
            hint(Self.reloadID, .warning, String(localized: "This file changed on disk. Reload?"),
                 String(localized: "The file on disk changed since this tab last read or saved it. Reloading replaces your unsaved changes (you can undo it)."))
        }
        if let since = facts.unsavedSince, now().timeIntervalSince(since) > unsavedThreshold {
            hint(Self.saveCopyID, .tip, String(localized: "Unsaved for over 2 hours. Save a copy?"),
                 String(localized: "Owlink keeps unsaved tabs across launches, but a copy on disk is safer."))
        }
        // CSV/TSV: a leading or trailing tab or space is an empty field or
        // part of a value, not indentation or stray whitespace.
        let table = c.language == Language.csv.rawValue
        if facts.isWholeDocument, !table, Self.isLetter(c.text) {
            hint(Self.letterID, .tip, String(localized: "It looks like you’re writing a letter. Would you like help?"))
        }
        if facts.isWholeDocument, let pretty = JSONFormatter.prettyIfMinified(c.text) {
            hint(Self.jsonID, .fix, String(localized: "Looks like JSON. Format it?"),
                 String(localized: "Pretty-prints it with two-space indents; key order is kept."), range: all, replacement: pretty)
        } else if !facts.isWholeDocument, Self.startsLongOneLineJSON(c) {
            // Only the start of a long one-line file is in view: no
            // replacement here. Fix it formats the whole file (the app
            // checks all of it first, see wholeDocumentJSONID).
            hint(Self.jsonID, .fix, String(localized: "Looks like JSON. Format it?"),
                 String(localized: "Pretty-prints the whole file with two-space indents; key order is kept. If the whole file isn’t valid JSON, nothing changes."))
        }
        let lines = Self.lines(text)
        moreHints(c, facts: facts, text: text, lines: lines) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        languageHints(c, facts: facts, text: text, lines: lines) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        let ec = facts.editorConfig
        // Not where whitespace is the data (INI/.env, logs), and never tabs where tabs are invalid (YAML).
        if !table, !Self.isPatch(c), Self.mayTidyWhitespace(c), let r = editorConfigIndent(text, lines: lines, fileName: c.fileName, config: ec),
           !(r.toTabs && Self.forbidsTabIndent(c)) {
            hint(Self.editorConfigIndentID, .fix,
                 r.toTabs ? String(localized: ".editorconfig says tabs; this file uses spaces. Convert?")
                          : String(localized: ".editorconfig says spaces; this file uses tabs. Convert?"),
                 r.toTabs ? String(localized: "\(r.count) lines indent with spaces. Every \(r.width) spaces become a tab.")
                          : String(localized: "\(r.count) lines indent with tabs. Each tab becomes \(r.width) spaces."),
                 range: r.range, replacement: r.replacement)
        }
        if !table, !Self.isPatch(c), c.language != "yaml" || !out.contains(where: { $0.id == Self.yamlTabsID }),
           !out.contains(where: { $0.id == Self.editorConfigIndentID }),
           let r = mixedIndent(text, lines: lines, fileName: c.fileName, style: ec?.indentStyle, width: ec?.width),
           !(r.toTabs && Self.forbidsTabIndent(c)) {
            hint(Self.mixedIndentID, .fix,
                 r.toTabs ? String(localized: "Mixed tabs and spaces. Convert to tabs?") : String(localized: "Mixed tabs and spaces. Convert to spaces?"),
                 r.toTabs ? String(localized: "\(r.tabs) lines indent with tabs and \(r.spaces) with spaces. Every \(tabWidth) spaces become a tab.")
                          : String(localized: "\(r.tabs) lines indent with tabs and \(r.spaces) with spaces. Tabs become \(tabWidth) spaces."),
                 range: r.range, replacement: r.replacement)
        }
        tidyHints(c, facts: facts, text: text, lines: lines) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        if Self.mayTidyWhitespace(c), ec?.trimTrailingWhitespace != false, let r = trailing(text, lines: lines, markdown: c.language == "markdown",
                                                         keep: c.language == Language.powershell.rawValue ? Self.powerShellHereStrings(text) : []) {
            hint(Self.trailingID, .fix, String(localized: "\(r.count) lines end in spaces. Trim?"),
                 String(localized: "Removes spaces and tabs at the ends of lines."), range: r.range, replacement: r.replacement)
        }
        fileHints(c, facts: facts, text: text) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        // Style Check (off by default): after every other hint, one per phrase.
        styleHints(c, facts: facts, text: text, lines: lines) { hint($0, $1, $2, $3, range: $4, replacement: $5) }
        if !facts.isWholeDocument {
            // A window of a longer file: say that a fix covers only it.
            let note = String(localized: "Only the part of the file around what’s on screen is changed.")
            out = out.map { h in
                guard h.replacement != nil, h.range != nil else { return h }
                return OwlHint(id: h.id, kind: h.kind, title: h.title, detail: [h.detail, note].compactMap { $0 }.joined(separator: " "),
                               range: h.range, replacement: h.replacement, source: h.source)
            }
        }
        // A shell script's CRLF has its own warning (it won't run).
        if facts.lineEnding == .crlf, !facts.mixedLineEndings, !out.contains(where: { $0.id == ShellRules.crlfID }) {
            hint(Self.crlfID, .explain, String(localized: "Windows line endings (CRLF)."),
                 String(localized: "Owlink keeps CRLF when you save. Change it from the status bar."))
        }
        return out
    }

    // MARK: Rules

    /// A window that is the start of a file whose first line runs past it,
    /// beginning like a JSON object or array: a long minified JSON file.
    public static func startsLongOneLineJSON(_ c: OwlContext) -> Bool {
        guard c.language == "json", c.textStart == 0, !c.isWholeDocument else { return false }
        let t = c.text.drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
        return (t.first == "{" || t.first == "[") && !c.text.contains("\n")
    }

    /// Formats a whole document for the owl's Fix it on a long one-line
    /// JSON file: the pretty text, or why not (the whole file must be
    /// valid JSON). Pure; the app runs it off the main thread.
    public static func formatWholeJSON(_ s: String) -> Result<String, TextToolError> {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let pretty = try JSONFormatter.format(trimmed, pretty: true)
            return .success(pretty + (s.hasSuffix("\n") ? "\n" : ""))
        } catch let e as TextToolError {
            return .failure(e)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    /// A letter: a greeting line ("Dear Sam," – not "Dear diary") within
    /// the first dozen lines, and either a sign-off line after it ("Yours
    /// sincerely,", "Best regards,", "Love,") or address or date lines
    /// before it. A diary entry or "Dear me, …" is not one.
    public static func isLetter(_ s: String) -> Bool {
        let lines = s.prefix(4_000).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let g = lines.prefix(12).firstIndex(where: isGreeting) else { return false }
        let before = lines[..<g].filter { !$0.isEmpty }
        if before.count >= 2 { return true }
        return lines[(g + 1)...].contains(where: isSignOff)
    }

    /// "Dear Sam," "Dear Mrs Patel:" "Dear Sir or Madam" – a name, short,
    /// at most a comma or colon after it.
    static func isGreeting(_ line: String) -> Bool {
        guard line.hasPrefix("Dear "), line.count <= 48 else { return false }
        var rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if rest.hasSuffix(",") || rest.hasSuffix(":") { rest.removeLast() }
        guard let first = rest.first, first.isUppercase else { return false }
        let words = rest.split(separator: " ")
        if words.count > 5 || rest.contains(where: { "!?;".contains($0) }) { return false }
        return !["diary", "me", "god", "lord"].contains(words[0].lowercased())
    }

    static let signOffs = ["yours sincerely", "yours faithfully", "yours truly", "sincerely", "faithfully", "best regards",
                           "kind regards", "warm regards", "regards", "best wishes", "with best wishes", "all the best",
                           "love", "lots of love", "with love", "cheers", "thanks", "many thanks", "thank you",
                           "best", "warmly", "yours", "respectfully", "cordially"]

    /// "Yours sincerely," "Best regards" "Love," – alone on a line.
    static func isSignOff(_ line: String) -> Bool {
        var t = line.lowercased()
        while let last = t.last, ",.!".contains(last) { t.removeLast() }
        return signOffs.contains(t)
    }

    /// Content ranges of each line (without the newline).
    static func lines(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var i = 0
        let n = s.length
        while i < n {
            var end = i
            while end < n, s.character(at: end) != 10 { end += 1 }
            out.append(NSRange(location: i, length: end - i))
            i = end + 1
        }
        return out
    }

    struct Rewrite { var range: NSRange; var replacement: String; var count: Int }

    /// Rewrites the span from the first to the last changed line.
    static func rewrite(_ s: NSString, _ lines: [NSRange], _ change: (NSRange) -> String?) -> Rewrite? {
        var first = -1, last = -1, count = 0
        var changed: [Int: String] = [:]
        for (i, r) in lines.enumerated() {
            if let new = change(r) {
                changed[i] = new
                if first < 0 { first = i }
                last = i
                count += 1
            }
        }
        guard first >= 0 else { return nil }
        let span = NSRange(location: lines[first].location, length: NSMaxRange(lines[last]) - lines[first].location)
        var out = ""
        for i in first...last {
            if i > first { out += "\n" }
            out += changed[i] ?? s.substring(with: lines[i])
        }
        return Rewrite(range: span, replacement: out, count: count)
    }

    /// YAML forbids tabs for indentation: never offered "Convert to tabs"
    /// there, whatever .editorconfig says (by language or by name).
    static func forbidsTabIndent(_ c: OwlContext) -> Bool {
        if c.language == Language.yaml.rawValue { return true }
        guard let n = c.fileName?.lowercased() else { return false }
        return n.hasSuffix(".yml") || n.hasSuffix(".yaml") || n == ".clang-format" || n == ".clang-tidy"
    }

    /// Makefiles need tabs: never offered "Convert to spaces" there.
    static func needsTabs(_ fileName: String?) -> Bool {
        guard let n = fileName else { return false }
        return n == "Makefile" || n == "makefile" || n == "GNUmakefile" || n.hasSuffix(".mk") || n.hasSuffix(".go") || n == "go.mod"
    }

    /// Lines indented with tabs and lines indented with spaces: converts the
    /// minority to the majority (spaces on a tie, tabs in a Makefile).
    func mixedIndent(_ s: NSString, lines: [NSRange], fileName: String? = nil, style: EditorConfig.Values.IndentStyle? = nil,
                     width: Int? = nil) -> (range: NSRange, replacement: String, tabs: Int, spaces: Int, toTabs: Bool)? {
        var tabs = 0, spaces = 0
        for r in lines where r.length > 0 {
            let c = s.character(at: r.location)
            if c == 9 { tabs += 1 } else if c == 32, r.length > 1, s.character(at: r.location + 1) == 32 { spaces += 1 }
        }
        guard tabs > 0, spaces > 0 else { return nil }
        let w = width.map { max(1, min($0, 16)) } ?? tabWidth
        // .editorconfig's indent_style decides the side (a Makefile still keeps tabs).
        let toTabs = style.map { $0 == .tab } ?? (tabs > spaces) || Self.needsTabs(fileName)
        guard let rw = Self.rewrite(s, lines, { r in
            var i = r.location, col = 0, sawTab = false, sawSpace = false
            while i < NSMaxRange(r) {
                let c = s.character(at: i)
                if c == 9 { sawTab = true; col += w - col % w } else if c == 32 { sawSpace = true; col += 1 } else { break }
                i += 1
            }
            let rest = s.substring(with: NSRange(location: i, length: NSMaxRange(r) - i))
            if toTabs {
                // Only whole tab stops of spaces become tabs; a remainder (alignment) stays.
                guard sawSpace, col >= w else { return nil }
                let new = String(repeating: "\t", count: col / w) + String(repeating: " ", count: col % w)
                return new == s.substring(with: NSRange(location: r.location, length: i - r.location)) ? nil : new + rest
            }
            guard sawTab else { return nil }
            return String(repeating: " ", count: col) + rest
        }) else { return nil }
        return (rw.range, rw.replacement, tabs, spaces, toTabs)
    }

    public static let editorConfigIndentID = "rules.editorconfig-indent"

    /// A file that indents only the other way from its `.editorconfig`'s
    /// indent_style (at least 3 indented lines, none the configured way):
    /// the rewrite to the configured style. Not Makefiles or Go (tabs).
    func editorConfigIndent(_ s: NSString, lines: [NSRange], fileName: String?, config: EditorConfig.Values?)
        -> (range: NSRange, replacement: String, count: Int, toTabs: Bool, width: Int)? {
        guard let style = config?.indentStyle, !Self.needsTabs(fileName) else { return nil }
        let w = max(1, min(config?.width ?? tabWidth, 16))
        var tabs = 0, spaces = 0
        for r in lines where r.length > 1 {
            let c = s.character(at: r.location)
            if c == 9 { tabs += 1 } else if c == 32, s.character(at: r.location + 1) == 32 { spaces += 1 }
        }
        let toTabs = style == .tab
        guard toTabs ? (spaces >= 3 && tabs == 0) : (tabs >= 3 && spaces == 0) else { return nil }
        guard let rw = Self.rewrite(s, lines, { r in
            var i = r.location, col = 0
            while i < NSMaxRange(r) {
                let c = s.character(at: i)
                if c == 9 { col += w - col % w } else if c == 32 { col += 1 } else { break }
                i += 1
            }
            guard i > r.location, i < NSMaxRange(r) else { return nil }   // indented, not blank
            let rest = s.substring(with: NSRange(location: i, length: NSMaxRange(r) - i))
            let new = toTabs ? String(repeating: "\t", count: col / w) + String(repeating: " ", count: col % w) : String(repeating: " ", count: col)
            return new == s.substring(with: NSRange(location: r.location, length: i - r.location)) ? nil : new + rest
        }) else { return nil }
        return (rw.range, rw.replacement, rw.count, toTabs, w)
    }

    /// Whether whitespace fixes (trim, tabs vs spaces, stray marks) may
    /// touch this text. Not where the bytes are the data: a patch (its
    /// context lines must match exactly), CSV/TSV (fields), INI/.env
    /// values (`KEY=value ` keeps its space), and logs or other data files
    /// that open as Plain Text (trimming them is noise, not help).
    /// Certificates, keys and requests (PEM, by name, or PEM text in an
    /// untitled or Plain Text tab) too: base64 and armour, not writing, and
    /// a signed block's bytes must not change.
    static func isWhitespaceSignificant(_ c: OwlContext) -> Bool {
        if isPatch(c) || ["csv", "ini"].contains(c.language) { return true }
        if c.language == Language.plain.rawValue, PEM.contains(c.text, limit: 64 * 1024) { return true }
        guard let name = c.fileName else { return false }
        return ProseDetector.dataExtensions.contains((name as NSString).pathExtension.lowercased()) || SpellScope.isDataFile(name)
    }

    /// PowerShell here-strings' bodies (`@' … '@`, `@" … "@`, the closer at
    /// the start of a line): string data, whose trailing spaces are kept.
    static let powerShellHereString = try! NSRegularExpression(pattern: #"@(['"])[ \t\r]*\n([\s\S]*?)\r?\n\1@"#)

    static func powerShellHereStrings(_ s: NSString) -> [NSRange] {
        guard s.range(of: "@'").location != NSNotFound || s.range(of: "@\"").location != NSNotFound else { return [] }
        return powerShellHereString.matches(in: s as String, range: NSRange(location: 0, length: s.length)).map { $0.range(at: 2) }
    }

    /// A diff or patch, by language or by name: every byte of it matters.
    static func isPatch(_ c: OwlContext) -> Bool {
        if c.language == "diff" { return true }
        guard let name = c.fileName else { return false }
        return ["diff", "patch", "rej"].contains((name as NSString).pathExtension.lowercased())
    }

    static func mayTidyWhitespace(_ c: OwlContext) -> Bool { !isWhitespaceSignificant(c) }

    /// In Markdown, two or more trailing spaces before another line of the
    /// same paragraph are a hard line break, so those stay.
    /// Lines starting inside a `keep` range (a PowerShell here-string's
    /// body) are left as they are.
    func trailing(_ s: NSString, lines: [NSRange], markdown: Bool = false, keep: [NSRange] = []) -> Rewrite? {
        let ends = Set(lines.map(\.location))
        let rw = Self.rewrite(s, lines) { r in
            if !keep.isEmpty, keep.contains(where: { NSLocationInRange(r.location, $0) }) { return nil }
            var e = NSMaxRange(r)
            while e > r.location, s.character(at: e - 1) == 32 || s.character(at: e - 1) == 9 { e -= 1 }
            // A whitespace-only line is left alone (often an editor's auto-indent).
            guard e < NSMaxRange(r), e > r.location else { return nil }
            if markdown {
                let tail = s.substring(with: NSRange(location: e, length: NSMaxRange(r) - e))
                let next = NSMaxRange(r) + 1
                let nextHasText: Bool = {
                    guard ends.contains(next) else { return false }
                    var i = next
                    while i < s.length, s.character(at: i) != 10 {
                        if s.character(at: i) != 32, s.character(at: i) != 9 { return true }
                        i += 1
                    }
                    return false
                }()
                if tail.count >= 2, !tail.contains("\t"), nextHasText { return nil }
            }
            return s.substring(with: NSRange(location: r.location, length: e - r.location))
        }
        guard let rw, rw.count >= trailingMinLines else { return nil }
        return rw
    }
}

/// The owl's "pretty-print this?" check, on the same validating formatter
/// as Text Tools › JSON Pretty Print (TextTools.swift), so the owl's fix and
/// the menu command always produce identical text.
extension JSONFormatter {
    /// The pretty-printed text if `s` is a JSON object or array written on
    /// one line; nil if it isn't valid JSON or already spans several lines.
    public static func prettyIfMinified(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[", !trimmed.contains("\n"),
              let pretty = try? format(trimmed, pretty: true) else { return nil }
        guard pretty.contains("\n") else { return nil } // {} or []
        return pretty + (s.hasSuffix("\n") ? "\n" : "")
    }
}
