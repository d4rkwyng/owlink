import Foundation

// Ask Cedric (the owl's chat panel): the pure parts. A frozen snapshot of
// the document taken when the user asks, the context the model is shown,
// the quick actions, the owl's read-only tools and the edit proposals
// that become diffs the user applies (or not). No AppKit, no engines:
// the engines are in CedricAI, the panel in the app.

// MARK: - JSON values

/// A JSON value that is Sendable and Equatable (tool arguments, schemas).
public enum OwlJSON: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OwlJSON])
    case object([String: OwlJSON])

    /// From JSONSerialization output.
    public init(any value: Any) {
        switch value {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let a as [Any]: self = .array(a.map { OwlJSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { OwlJSON(any: $0) })
        default: self = .null
        }
    }

    /// For JSONSerialization.
    public var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// Parses JSON text; nil if it isn't JSON.
    public static func parse(_ text: String) -> OwlJSON? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return OwlJSON(any: obj)
    }

    /// Compact JSON, keys sorted (stable for tests and prompts).
    public var jsonString: String {
        if case .string(let s) = self {
            let d = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
            let t = String(decoding: d, as: UTF8.self)
            return String(t.dropFirst().dropLast())
        }
        guard let d = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    public subscript(key: String) -> OwlJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Integers, also from "12" (small models quote numbers).
    public var int: Int? {
        switch self {
        case .number(let n): return n.isFinite && abs(n) < 1e9 ? Int(n) : nil
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : s == "false" ? false : nil
        case .number(let n): return n != 0
        default: return nil
        }
    }

    public var object: [String: OwlJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - The document, frozen

/// The document as it was when the user asked: every tool reads this, never
/// the live text view, so a call can't race typing, and a proposal can be
/// checked against it before it is applied.
public struct OwlDocumentSnapshot: Sendable {
    public let text: String
    /// The document's edit generation (change count) at the snapshot.
    public let generation: Int
    /// UTF-16 ranges in `text`.
    public let selection: NSRange
    public let visible: NSRange
    public let fileName: String?
    /// `Language.rawValue`.
    public let language: String
    public let lines: LineIndex
    /// What the offline checks need beyond the text (check_document): the
    /// document facts the owl's rules read (Style Check's settings too).
    public let facts: OwlDocumentFacts
    /// The grammar checker's current findings (document ranges), as the
    /// editor has them; the checker itself runs in the app.
    public let grammar: [GrammarIssue]

    public init(text: String, generation: Int, selection: NSRange = NSRange(location: 0, length: 0),
                visible: NSRange? = nil, fileName: String? = nil, language: String = "plain",
                facts: OwlDocumentFacts = OwlDocumentFacts(), grammar: [GrammarIssue] = []) {
        let ns = text as NSString
        self.facts = facts
        self.grammar = grammar
        self.text = text
        self.generation = generation
        func clamp(_ r: NSRange) -> NSRange {
            let s = min(max(0, r.location), ns.length)
            return NSRange(location: s, length: min(max(0, r.length), ns.length - s))
        }
        self.selection = clamp(selection)
        self.visible = clamp(visible ?? NSRange(location: 0, length: ns.length))
        self.fileName = fileName
        self.language = language
        self.lines = LineIndex(ns)
    }

    public var length: Int { (text as NSString).length }
    public var lineCount: Int { lines.lineCount }
    /// Lines as a person counts them: a final newline's empty "line" is not one.
    public var countedLines: Int {
        lineCount > 1 && lines.contentRange(ofLine: lineCount - 1).length == 0 ? lineCount - 1 : lineCount
    }
    public var hasSelection: Bool { selection.length > 0 }

    /// 1-based line number of a UTF-16 offset.
    public func lineNumber(at offset: Int) -> Int { lines.line(containing: min(max(0, offset), length)) + 1 }

    /// The range of lines `first...last` (1-based, inclusive, clamped),
    /// without the last line's newline; nil if `first` is past the end.
    public func range(lines first: Int, _ last: Int) -> NSRange? {
        let n = lineCount
        let a = max(1, first), b = min(n, max(a, last))
        guard a <= n else { return nil }
        let start = lines.contentRange(ofLine: a - 1).location
        let end = NSMaxRange(lines.contentRange(ofLine: b - 1))
        return NSRange(location: start, length: end - start)
    }

    public func substring(_ r: NSRange) -> String { (text as NSString).substring(with: r) }

    /// The whole lines touching `r`, as a range (no trailing newline).
    public func lineSpan(_ r: NSRange) -> (range: NSRange, first: Int, last: Int) {
        let first = lineNumber(at: r.location)
        let endOffset = r.length > 0 ? NSMaxRange(r) - 1 : r.location
        var last = lineNumber(at: endOffset)
        // A selection that ends just after a newline doesn't take the next line.
        if r.length > 0, last > first, endOffset < length, (text as NSString).character(at: endOffset) == 10 {
            last = max(first, last - (lines.starts[last - 1] > endOffset ? 1 : 0))
        }
        let range = self.range(lines: first, last) ?? NSRange(location: 0, length: 0)
        return (range, first, last)
    }

    /// "12| text" for each line in `first...last`.
    public func numbered(lines first: Int, _ last: Int) -> String {
        guard let r = range(lines: first, last) else { return "" }
        let body = substring(r).components(separatedBy: "\n")
        return body.enumerated().map { "\(first + $0.offset)| \($0.element)" }.joined(separator: "\n")
    }
}

// MARK: - What the model is shown

public enum OwlChatScope: String, Sendable, CaseIterable {
    case selection, visible, wholeDocument

    public var title: String {
        switch self {
        case .selection: return String(localized: "Selection")
        case .visible: return String(localized: "Visible text")
        case .wholeDocument: return String(localized: "Whole document")
        }
    }
}

/// The text attached to a question: whole lines, numbered with their real
/// line numbers ("12| "), so answers and edits can cite them.
public struct OwlChatContext: Sendable, Equatable {
    public let scope: OwlChatScope
    /// Document range of the lines shown (no trailing newline).
    public let range: NSRange
    public let firstLine: Int
    public let lastLine: Int
    public let totalLines: Int
    public let numbered: String
    /// Some lines were left out to fit the budget.
    public let truncated: Bool

    /// A line-aligned whole-document review part.
    public static func reviewPart(_ s: OwlDocumentSnapshot, first: Int, last: Int) -> OwlChatContext {
        precondition(first >= 1 && first <= last && last <= s.countedLines)
        return OwlChatContext(scope: .wholeDocument, range: s.range(lines: first, last)!,
                              firstLine: first, lastLine: last, totalLines: s.countedLines,
                              numbered: s.numbered(lines: first, last),
                              truncated: first > 1 || last < s.countedLines)
    }

    /// "Selection (12 lines)", for the chip.
    public var label: String {
        if scope == .wholeDocument, truncated {
            return String(localized: "Lines \(firstLine)–\(lastLine) of \(totalLines) (trimmed to fit)")
        }
        let n = lastLine - firstLine + 1
        let lines = n == 1 ? String(localized: "1 line") : String(localized: "\(n) lines")
        return "\(scope.title) (\(lines)\(truncated ? ", " + String(localized: "trimmed") : ""))"
    }

    /// Selection is offered only with a selection; the other scopes are always available.
    public static func scopes(for s: OwlDocumentSnapshot, budget: Int) -> [OwlChatScope] {
        var out: [OwlChatScope] = []
        if s.hasSelection { out.append(.selection) }
        out.append(.visible)
        out.append(.wholeDocument)
        return out
    }

    /// Selection if there is one; otherwise the whole document.
    public static func defaultScope(for s: OwlDocumentSnapshot, budget: Int) -> OwlChatScope {
        if s.hasSelection { return .selection }
        return .wholeDocument
    }

    /// The context for `scope`, at most `budget` UTF-16 units of numbered
    /// text, without splitting lines. An oversized anchor line is kept.
    /// nil only when a selection was requested without one.
    public static func build(_ s: OwlDocumentSnapshot, scope: OwlChatScope, budget: Int) -> OwlChatContext? {
        func lineLength(_ line: Int) -> Int {
            s.lines.contentRange(ofLine: line - 1).length + String(line).count + 2
        }
        if scope == .wholeDocument {
            let total = s.countedLines
            let wholeLength = (1...total).reduce(0) { $0 + lineLength($1) } + total - 1
            var first = 1, last = total
            if wholeLength > budget {
                let midpoint = s.selection.location + s.selection.length / 2
                let anchor = min(total, s.lineNumber(at: midpoint))
                first = anchor
                last = anchor
                var used = lineLength(anchor)
                var below = true, canAbove = first > 1, canBelow = last < total
                while canAbove || canBelow {
                    if below && canBelow {
                        let length = lineLength(last + 1) + 1
                        if used + length <= budget { last += 1; used += length; canBelow = last < total }
                        else { canBelow = false }
                    } else if !below && canAbove {
                        let length = lineLength(first - 1) + 1
                        if used + length <= budget { first -= 1; used += length; canAbove = first > 1 }
                        else { canAbove = false }
                    }
                    below.toggle()
                }
            }
            let range = s.range(lines: first, last) ?? NSRange(location: 0, length: 0)
            return OwlChatContext(scope: scope, range: range, firstLine: first, lastLine: last, totalLines: total,
                                  numbered: s.numbered(lines: first, last), truncated: first > 1 || last < total)
        }
        let span: (range: NSRange, first: Int, last: Int)
        switch scope {
        case .selection:
            guard s.hasSelection else { return nil }
            span = s.lineSpan(s.selection)
        case .visible:
            span = s.lineSpan(s.visible)
        case .wholeDocument:
            preconditionFailure("Whole-document context is built above")
        }
        var last = span.last
        var used = 0
        for line in span.first...span.last {
            let len = lineLength(line) + (line == span.first ? 0 : 1)
            if used + len > budget, line > span.first { last = line - 1; break }
            used += len
        }
        let range = s.range(lines: span.first, last) ?? span.range
        return OwlChatContext(scope: scope, range: range, firstLine: span.first, lastLine: last, totalLines: s.countedLines,
                              numbered: s.numbered(lines: span.first, last), truncated: last < span.last)
    }
}

// MARK: - Quick actions

/// The panel's one-click questions. Each is a fixed, tested instruction
/// (OwlPrompts in CedricAI), which small models follow far better than
/// free text, and a small subset of the tools.
public enum OwlQuickAction: String, Sendable, CaseIterable {
    case explain, summarise, findProblems, rewrite, addComments
    /// Code: the selection, or the caret's line, explained.
    case explainLine
    /// Scripts: the offline scan (`ScriptSafety`), then the model's review.
    case scriptSafety

    public func title(prose: Bool) -> String {
        switch self {
        case .explainLine: return String(localized: "Explain Line")
        case .scriptSafety: return String(localized: "Check for Risks")
        case .explain: return String(localized: "Explain")
        case .summarise: return String(localized: "Summarize")
        case .findProblems: return String(localized: "Find Problems")
        case .rewrite: return prose ? String(localized: "Rewrite") : String(localized: "Simplify")
        case .addComments: return String(localized: "Add Comments")
        }
    }

    /// The answer is an edit (a proposal shown as a diff), not just words.
    public var proposesEdit: Bool { self == .rewrite || self == .addComments }

    /// Offered for this document: Summarise and Rewrite read prose; Explain
    /// Line and the script check are for code (the check only for scripts).
    public func isOffered(prose: Bool, language: Language) -> Bool {
        switch self {
        case .summarise: return prose
        case .addComments, .explainLine: return !prose
        case .scriptSafety: return !prose && ScriptSafety.isScript(language)
        default: return true
        }
    }

    /// The tools the model may use for this action.
    public var tools: [OwlToolName] {
        switch self {
        case .explain: return [.getLines, .searchDocument, .getOutline]
        case .summarise: return [.getOutline, .getLines, .documentStats]
        case .findProblems: return [.getLines, .searchDocument, .checkDocument]
        case .rewrite: return [.getSelection, .getLines, .proposeEdit]
        case .addComments: return [.getLines, .proposeEdit]
        case .explainLine: return [.getLines, .searchDocument]
        case .scriptSafety: return [.getLines, .searchDocument]
        }
    }
}

// MARK: - Tools

public enum OwlToolName: String, Sendable, CaseIterable {
    case getSelection = "get_selection"
    case getLines = "get_lines"
    case searchDocument = "search_document"
    case getOutline = "get_outline"
    case documentStats = "document_stats"
    case proposeEdit = "propose_edit"
    /// The offline checks' current findings (OwlChecks): writing checks,
    /// code checks, grammar (and Style Check when it is on).
    case checkDocument = "check_document"
    /// One Markdown section, by its heading (a close match counts); the
    /// headings when none matches.
    case readSection = "read_section"
    /// Renders the document's picture and reads it with Apple Vision, on
    /// this Mac (CedricAI's `OwlVision`). Offered only for a document that
    /// draws a picture (`OwlPicture`); `OwlTools.run` can't run it (no
    /// renderer here): the toolbox does.
    case describeImage = "describe_image"
}

/// Documents that draw a picture: an SVG is text (XML) that the preview
/// renders. Ask Cedric offers describe_image for these only.
public enum OwlPicture {
    public static func isPicture(fileName: String?) -> Bool {
        guard let fileName else { return false }
        return ["svg", "svgz"].contains((fileName as NSString).pathExtension.lowercased())
    }
}

/// A tool as the model sees it: a name, one line of description and a
/// JSON schema for its arguments.
public struct OwlToolSpec: Sendable, Equatable {
    public let name: OwlToolName
    public let description: String
    /// A JSON-schema object: {"type":"object","properties":{…},"required":[…]}.
    public let parameters: OwlJSON
}

/// A call the model asked for.
public struct OwlToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: OwlJSON

    public init(id: String = "", name: String, arguments: OwlJSON = .object([:])) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// An edit the model proposed: shown as a diff card, applied only by the
/// user's click, as one undo step. Two kinds of anchor:
///
/// - `.text` (propose_edit, 0.4.1): the exact text to find and its
///   replacement. It applies only while `original` occurs exactly once in
///   the document as it is now, wherever that is; edits elsewhere don't
///   matter, an edit that touches it (or makes it ambiguous) makes it stale.
/// - `.lines` (a quick action's ``` block): the lines the model was shown;
///   it applies only while the document is unchanged since asking.
public struct OwlEditProposal: Sendable, Equatable {
    public enum Anchor: String, Sendable, Equatable { case text, lines }

    /// Where the proposal stands against the live document.
    public enum ApplyState: Sendable, Equatable {
        /// Applies to this range of the live text.
        case ready(NSRange)
        /// The text changed under it, or isn't unique ("ask again").
        case stale
        /// The document can't be edited (read-only tab, iOS read mode).
        case readOnly
        /// The edit's validation found a hard problem (`OwlEditCheck`):
        /// "Doesn't parse: …". Apply stays off.
        case failsValidation(String)
    }

    /// Why propose_edit refused a find/replace pair.
    public enum Refusal: Error, Sendable, Equatable {
        case empty, tooLong, notFound, notUnique, noChange
    }

    /// Document range (UTF-16) in the snapshot of the text being replaced.
    public let range: NSRange
    /// The text replaced (`.text`: the model's `find`).
    public let original: String
    public let replacement: String
    public let reason: String
    public let firstLine: Int
    public let lastLine: Int
    /// The snapshot's edit generation.
    public let generation: Int
    public let anchor: Anchor
    /// The edit validation's verdict (`OwlEditValidation`); clean unless
    /// the propose_edit handler or the quick action's block path set it.
    public var check: OwlEditCheck = .clean
    /// The language and file type `check` was worked out for (`validate`,
    /// `revalidated`); nil when not recorded. A different one in the tab
    /// (the status-bar language changed) makes the verdict stale, as an
    /// edit does.
    public var checkedAs: OwlEditValidation.Target?

    public init(range: NSRange, original: String, replacement: String, reason: String,
                firstLine: Int, lastLine: Int, generation: Int, anchor: Anchor = .lines) {
        self.range = range; self.original = original; self.replacement = replacement; self.reason = reason
        self.firstLine = firstLine; self.lastLine = lastLine; self.generation = generation; self.anchor = anchor
    }

    /// Lines `first...last` of the snapshot replaced by `text`; nil when
    /// the lines don't exist, the edit is empty or no change, or too big.
    public static func lines(_ first: Int, _ last: Int, with text: String, reason: String = "",
                             in s: OwlDocumentSnapshot) -> OwlEditProposal? {
        guard first >= 1, last >= first, first <= s.lineCount, last - first < OwlTools.maxEditLines,
              (text as NSString).length <= OwlTools.maxEditLength,
              let r = s.range(lines: first, min(last, s.lineCount)) else { return nil }
        let original = s.substring(r)
        var replacement = text
        // Models often end with a newline the range doesn't have.
        if replacement.hasSuffix("\n"), !original.hasSuffix("\n") { replacement.removeLast() }
        guard replacement != original else { return nil }
        return OwlEditProposal(range: r, original: original, replacement: replacement, reason: reason,
                               firstLine: first, lastLine: min(last, s.lineCount), generation: s.generation)
    }

    /// propose_edit: `find` (exact text, once in the snapshot) replaced by
    /// `replace`. Forgiving about what small models add: "12| " line
    /// numbers copied from the shown text (dropped from both when every
    /// line of `find` has one), and a final newline `find` doesn't have.
    public static func anchored(find: String, replace: String, reason: String = "",
                                in s: OwlDocumentSnapshot) -> Result<OwlEditProposal, Refusal> {
        guard !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        guard (find as NSString).length <= OwlTools.maxFindLength, (replace as NSString).length <= OwlTools.maxReplaceLength
        else { return .failure(.tooLong) }
        let text = s.text as NSString
        var tries: [(find: String, replace: String)] = [(find, replace)]
        let bare = OwlTools.stripLineNumbers(find)
        if bare != find { tries.append((bare, OwlTools.stripLineNumbers(replace))) }
        for t in tries where t.find.hasSuffix("\n") && t.find.count > 1 {
            tries.append((String(t.find.dropLast()), t.replace.hasSuffix("\n") ? String(t.replace.dropLast()) : t.replace))
        }
        var ambiguous = false
        for t in tries {
            let hits = occurrences(of: t.find, in: text)
            if hits.count > 1 { ambiguous = true; continue }
            guard let r = hits.first else { continue }
            var replacement = t.replace
            if replacement.hasSuffix("\n"), !t.find.hasSuffix("\n") { replacement.removeLast() }
            guard replacement != t.find else { return .failure(.noChange) }
            let first = s.lineNumber(at: r.location)
            let last = s.lineNumber(at: max(r.location, NSMaxRange(r) - 1))
            let why = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(OwlTools.maxReasonLength))
            return .success(OwlEditProposal(range: r, original: t.find, replacement: replacement, reason: why,
                                            firstLine: first, lastLine: last, generation: s.generation, anchor: .text))
        }
        return .failure(ambiguous ? .notUnique : .notFound)
    }

    /// Where `needle` occurs in `text` (overlapping matches count), at most
    /// `limit` of them: two are enough to know it isn't unique.
    public static func occurrences(of needle: String, in text: NSString, limit: Int = 2) -> [NSRange] {
        let n = (needle as NSString).length
        guard n > 0, n <= text.length else { return [] }
        var out: [NSRange] = []
        var at = 0
        while out.count < limit, at + n <= text.length {
            let r = text.range(of: needle, options: .literal, range: NSRange(location: at, length: text.length - at))
            if r.location == NSNotFound { break }
            out.append(r)
            at = r.location + 1
        }
        return out
    }

    /// Against the live document: where it applies, or why it can't.
    public func state(text: NSString, generation: Int, readOnly: Bool = false) -> ApplyState {
        if readOnly { return .readOnly }
        switch anchor {
        case .text:
            let hits = Self.occurrences(of: original, in: text)
            return hits.count == 1 ? validated(.ready(hits[0])) : .stale
        case .lines:
            guard generation == self.generation, NSMaxRange(range) <= text.length,
                  text.substring(with: range) == original else { return .stale }
            return validated(.ready(range))
        }
    }

    /// A ready state, unless the validation failed (then Apply stays off).
    func validated(_ s: ApplyState) -> ApplyState {
        if case .ready = s, let why = check.failureText { return .failsValidation(why) }
        return s
    }

    /// Apply may be offered: ready, and nothing hard found by the validation.
    public func canApply(text: NSString, generation: Int, readOnly: Bool = false) -> Bool {
        if case .ready = state(text: text, generation: generation, readOnly: readOnly) { return true }
        return false
    }

    /// The edit can be applied to the live document now (`state`).
    public func isCurrent(text: NSString, generation: Int) -> Bool {
        if case .ready = state(text: text, generation: generation) { return true }
        return false
    }

    /// Overlaps `other` in the snapshot both were made from.
    public func overlaps(_ other: OwlEditProposal) -> Bool {
        NSIntersectionRange(range, other.range).length > 0 || range.location == other.range.location
    }

    /// The diff rows (LineDiff) between the original and the replacement.
    public var diffLines: [(kind: LineDiff.RowKind, text: String)] {
        let a = LineDiff.lines(original), b = LineDiff.lines(replacement)
        var out: [(LineDiff.RowKind, String)] = []
        for row in LineDiff.rows(LineDiff.diff(a, b)) {
            switch row.kind {
            case .same: out.append((.same, a[row.left!]))
            case .removed: out.append((.removed, a[row.left!]))
            case .added: out.append((.added, b[row.right!]))
            case .changed:
                out.append((.removed, a[row.left!]))
                out.append((.added, b[row.right!]))
            }
        }
        return out
    }

    /// "- old" / "+ new" / "  same", for the transcript's Markdown copy.
    public var unifiedText: String {
        diffLines.map { ($0.kind == .removed ? "- " : $0.kind == .added ? "+ " : "  ") + $0.text }.joined(separator: "\n")
    }
}

/// What a tool returned: text for the model, and possibly a proposal.
public struct OwlToolResult: Sendable, Equatable {
    public var text: String
    public var proposal: OwlEditProposal?
    /// One line for the transcript ("Looked at lines 40–80").
    public var summary: String
    public var ok: Bool
    /// The document lines the model was shown in full (get_lines), for
    /// what Cedric says he has seen.
    public var lines: ClosedRange<Int>?
    /// The line numbers of the numbered document rows ("12| text") this
    /// result was built with. Only these count as shown: a "31| …" that
    /// came from inside a row's or a key's text (an outline's JSON key
    /// with a newline in it) is not a row the tool emitted.
    public var rows: IndexSet

    public init(text: String, proposal: OwlEditProposal?, summary: String, ok: Bool, lines: ClosedRange<Int>? = nil,
                rows: IndexSet = IndexSet()) {
        self.text = text; self.proposal = proposal; self.summary = summary; self.ok = ok; self.lines = lines
        self.rows = rows
    }
}

/// The owl's v1 tools. All read the frozen snapshot; none touches the
/// network, a shell or any file; `propose_edit` only proposes. Output is
/// capped so a tool can't flood a 4K-token context.
public enum OwlTools {
    public static let maxOutputBytes = 1500
    public static let maxLines = 120
    public static let maxMatches = 20
    public static let maxPatternLength = 200
    /// A model-written regular expression: shorter, and a time limit on the search.
    public static let maxRegexLength = 100
    public static let searchTimeLimit: TimeInterval = 0.5
    /// Tool rounds per question, then the model must answer.
    public static let maxRounds = 3
    /// Calls honoured per round (more are refused).
    public static let maxCallsPerRound = 4
    public static let maxEditLines = 400
    public static let maxEditLength = 32_768
    /// propose_edit (UTF-16 units): the text to find, its replacement, the reason.
    /// Short enough that the card can show the whole replacement for review.
    public static let maxFindLength = 2_000
    public static let maxReplaceLength = 2_000
    public static let maxReasonLength = 120
    /// Edits proposed per answer; more are refused.
    public static let maxProposals = 5

    public static func spec(_ name: OwlToolName) -> OwlToolSpec {
        func obj(_ props: [String: OwlJSON], required: [String]) -> OwlJSON {
            .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) })])
        }
        let int: OwlJSON = .object(["type": .string("integer")])
        let str: OwlJSON = .object(["type": .string("string")])
        switch name {
        case .getSelection:
            return OwlToolSpec(name: name, description: "The user's selected text, with line numbers.", parameters: obj([:], required: []))
        case .getLines:
            return OwlToolSpec(name: name, description: "Lines start to end of the document (1-based, at most 120), with line numbers.",
                               parameters: obj(["start": int, "end": int], required: ["start", "end"]))
        case .searchDocument:
            return OwlToolSpec(name: name, description: "Finds lines containing query (regex if regex is true); returns line numbers and text.",
                               parameters: obj(["query": .object(["type": .string("string"), "maxLength": .number(Double(maxPatternLength))]),
                                                "regex": .object(["type": .string("boolean")])], required: ["query"]))
        case .getOutline:
            return OwlToolSpec(name: name, description: "The whole document's headings or top-level structure, with line numbers; for Markdown also how many list items and table rows each section and the whole document have.", parameters: obj([:], required: []))
        case .documentStats:
            return OwlToolSpec(name: name, description: "Words, lines, characters, language and file name of the document.", parameters: obj([:], required: []))
        case .proposeEdit:
            return OwlToolSpec(name: name, description: "Proposes replacing the exact text find (copied from the document without line numbers, long enough to occur only once) with replace. It only proposes: the user reviews and applies it. One call per separate change.",
                               parameters: obj(["find": str, "replace": str,
                                                "reason": .object(["type": .string("string"), "maxLength": .number(Double(maxReasonLength))])],
                                               required: ["find", "replace", "reason"]))
        case .checkDocument:
            return OwlToolSpec(name: name, description: "Problems Owlink's offline checks found in the document (links, headings, footnotes, code rules, grammar), with line numbers.",
                               parameters: obj([:], required: []))
        case .readSection:
            return OwlToolSpec(name: name, description: "The text of one Markdown section, found by its heading (a close match is enough), with line numbers.",
                               parameters: obj(["heading": .object(["type": .string("string"), "maxLength": .number(Double(maxPatternLength))])], required: ["heading"]))
        case .describeImage:
            return OwlToolSpec(name: name, description: "Looks at the picture this document draws (rendered on this Mac): what it shows, any text in it, its size and colours.",
                               parameters: obj([:], required: []))
        }
    }

    public static func specs(_ names: [OwlToolName]) -> [OwlToolSpec] { names.map(spec) }

    /// The tools offered for a typed question (a model trusted with tools):
    /// get_lines, search_document and get_outline always, and each other
    /// tool only when the question or the document calls for it, so a
    /// small model chooses among few (Apple's TN3193: 3–5 tools at most)
    /// and a document's text can't talk the model into an edit nobody
    /// asked for. The tool eval offers the same set (`OwlToolEval`).
    public static func typedTools(question: String, snapshot s: OwlDocumentSnapshot) -> [OwlToolName] {
        let q = question.lowercased()
        let words = Set(q.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        var out: [OwlToolName] = [.getLines, .searchDocument, .getOutline]
        if s.hasSelection || !words.isDisjoint(with: ["select", "selected", "selection", "highlighted"]) { out.insert(.getSelection, at: 0) }
        if !words.isDisjoint(with: statsWords) || q.contains("how many") || q.contains("how long") || q.contains("file name") {
            out.append(.documentStats)
        }
        if OwlChecks.asksAboutProblems(question) { out.append(.checkDocument) }
        if asksAboutSection(words, snapshot: s) { out.append(.readSection) }
        if asksForChange(question) {
            out.append(.proposeEdit)
            // An edit request keeps to five tools: get_lines finds the text to
            // change; the outline goes first, then the stats, the section, the search.
            for spare in [OwlToolName.getOutline, .documentStats, .readSection, .searchDocument] where out.count > 5 {
                out.removeAll { $0 == spare }
            }
        }
        return out
    }

    /// The question asks for a change to the text ("Rewrite line 3",
    /// "Can you fix the typo?", "In helper10, change the multiplier…"):
    /// some clause starts with an edit verb, after polite fillers ("please",
    /// "could you", "I want you to"). A question about the text ("Is line 3
    /// correct?", "What would you change?", "How do I fix it?") is not one.
    /// Only then is propose_edit offered, so a question can't turn into an
    /// edit, and the document's text can't ask for one either.
    public static func asksForChange(_ question: String) -> Bool {
        let clauses = question.lowercased().components(separatedBy: CharacterSet(charactersIn: ".,;:!?\n()"))
        for clause in clauses {
            let words = clause.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
                .filter { !$0.isEmpty }
            guard let verb = words.first(where: { !changeFillers.contains($0) }) else { continue }
            if editVerbs.contains(verb) { return true }
        }
        return false
    }

    /// Words before the verb of a request ("please could you just …").
    static let changeFillers: Set<String> = ["please", "pls", "can", "could", "would", "will", "you", "kindly", "now", "then", "also", "just",
                                             "and", "so", "ok", "okay", "hey", "cedric", "help", "me", "let's", "lets", "let", "us", "go",
                                             "ahead", "try", "to", "i", "i'd", "i’d", "id", "want", "like", "need", "we", "first", "next", "finally"]
    /// Verbs that ask for an edit when they start a clause.
    static let editVerbs: Set<String> = ["change", "edit", "rewrite", "rename", "replace", "fix", "correct", "propose", "update",
                                         "add", "insert", "remove", "delete", "make", "convert", "shorten", "lengthen", "reword",
                                         "rephrase", "simplify", "improve", "reformat", "capitalize", "capitalise", "swap", "sort",
                                         "tidy", "polish", "proofread", "tighten", "trim", "condense", "expand",
                                         "turn", "set", "move", "put", "uncomment", "indent", "spell", "punctuate"]

    /// "12| text" lines → "text", only when every non-empty line has a number.
    public static func stripLineNumbers(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        let re = try! NSRegularExpression(pattern: #"^\s*\d+\| ?"#)
        let numbered = lines.allSatisfy { $0.isEmpty || re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        guard numbered, lines.contains(where: { !$0.isEmpty }) else { return s }
        return lines.map { re.stringByReplacingMatches(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length), withTemplate: "") }
            .joined(separator: "\n")
    }

    /// Whether the coverage note applies ("I can see lines 1–40 of 111…").
    /// On by default when the question is non-empty: a missing note reads
    /// as if the whole file had been seen, which is worse than an extra
    /// note. It stays off only for a pure sum ("what is 12 times 7",
    /// "3+4*2") or an explicit translation whose source text appears
    /// nowhere in the file ("translate hello into French"). A question
    /// about the open document keeps the note ("Who wrote the first
    /// section?", "Define the selected term"), and so does a
    /// general-knowledge question ("what is the capital of France").
    /// Not the tool gate (`typedTools`).
    public static func coverageNoteApplies(_ question: String, snapshot s: OwlDocumentSnapshot) -> Bool {
        let q = question.lowercased()
        if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if isPureArithmetic(q) { return false }
        if let sources = translationSources(q), !sources.isEmpty,
           !sources.contains(where: { documentHasWord($0, in: s.text) }) {
            return false
        }
        return true
    }

    /// A sum and nothing else: digits, an operator or an arithmetic word
    /// ("plus", "times"), and question words. "How many games per system?"
    /// is not one; neither is "how many times does Sonic appear?".
    private static func isPureArithmetic(_ question: String) -> Bool {
        let words = normalizedWords(question)
        let arith: Set<String> = ["plus", "minus", "times", "divided", "multiply", "multiplied", "multiplying",
                                  "squared", "square", "percent", "percentage", "half"]
        let hasOperator = question.range(of: #"\d\s*[+*/×÷^\-]\s*\d"#, options: .regularExpression) != nil
            || question.range(of: #"\d\s+x\s+\d"#, options: .regularExpression) != nil
        let hasNumber = words.contains { $0.allSatisfy(\.isNumber) }
        guard hasNumber, hasOperator || words.contains(where: { arith.contains($0) }) else { return false }
        let filler: Set<String> = ["what", "whats", "is", "are", "was", "how", "much", "many", "does", "do", "did",
                                   "the", "a", "an", "of", "please", "equals", "equal", "calculate", "compute",
                                   "calculation", "sum", "product", "quotient", "difference", "by", "and", "to",
                                   "it", "me", "answer", "result"]
        return words.allSatisfy { filler.contains($0) || arith.contains($0) || $0.allSatisfy(\.isNumber) }
    }

    /// Words of the text an explicit translation request asks to translate
    /// ("translate hello into French" → hello, french). nil when the
    /// question is not a translation, so the coverage note stays. An empty
    /// list means the source is a pronoun ("translate this"): not clearly
    /// unrelated.
    private static func translationSources(_ question: String) -> [String]? {
        let translation = question.range(of: #"\btranslat(?:e|ion|ing)\b"#, options: .regularExpression) != nil
            || question.range(of: #"\bhow do you say\b"#, options: .regularExpression) != nil
        guard translation else { return nil }
        let words = normalizedWords(question)
        let boilerplate: Set<String> = [
            "translate", "translation", "translating", "into", "to", "from", "in", "the", "a", "an",
            "what", "whats", "is", "are", "of", "does", "do", "how", "you", "say", "please", "word",
            "phrase", "this", "that", "it", "me", "for", "and", "its", "my", "your",
        ]
        return words.filter { $0.count >= 2 && !boilerplate.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// `word` as a whole word in `text` (also the form without a trailing s, so "games" matches "game").
    private static func documentHasWord(_ word: String, in text: String) -> Bool {
        if textHasWord(word, in: text) { return true }
        if word.count >= 5, word.hasSuffix("s"), !word.hasSuffix("ss") {
            return textHasWord(String(word.dropLast()), in: text)
        }
        return false
    }

    private static func textHasWord(_ word: String, in text: String) -> Bool {
        let ns = text as NSString
        guard ns.length > 0, !word.isEmpty else { return false }
        var at = 0
        while at < ns.length {
            let r = ns.range(of: word, options: .caseInsensitive, range: NSRange(location: at, length: ns.length - at))
            if r.location == NSNotFound { return false }
            let before = r.location == 0 || !isAskWordChar(ns.character(at: r.location - 1))
            let end = r.location + r.length
            let after = end >= ns.length || !isAskWordChar(ns.character(at: end))
            if before && after { return true }
            at = max(end, r.location + 1)
        }
        return false
    }

    private static func isAskWordChar(_ u: unichar) -> Bool {
        guard let s = UnicodeScalar(u) else { return false }
        return Character(s).isLetter || Character(s).isNumber
    }

    /// A Markdown document with headings, and a question that names a
    /// section ("section", "heading", "chapter"…) or a word of a heading's title.
    static func asksAboutSection(_ words: Set<String>, snapshot s: OwlDocumentSnapshot) -> Bool {
        guard isMarkdown(s) else { return false }
        let heads = MarkdownOutline.headings(in: s.text, limit: 200)
        guard !heads.isEmpty else { return false }
        if !words.isDisjoint(with: ["section", "sections", "heading", "headings", "chapter", "chapters", "part", "subsection"]) { return true }
        let titleWords = Set(heads.flatMap { normalizedWords($0.title) }.filter { $0.count >= 4 })
        return !words.isDisjoint(with: titleWords)
    }

    static func isMarkdown(_ s: OwlDocumentSnapshot) -> Bool {
        s.language == "markdown" || (s.fileName?.lowercased().hasSuffix(".md") ?? false)
    }

    static func normalizedWords(_ t: String) -> [String] {
        t.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Words in a read_section argument that aren't part of the heading.
    static let sectionFillers: Set<String> = ["the", "section", "heading", "chapter", "part", "called", "named", "a", "an", "of", "on", "about"]

    /// The best-matching heading for `query`: the same words, then one
    /// containing the other, then most words in common, then a small typo.
    /// nil when nothing is close.
    public static func matchHeading(_ query: String, _ heads: [MarkdownOutline.Heading]) -> MarkdownOutline.Heading? {
        let qw = normalizedWords(query).filter { !sectionFillers.contains($0) }
        let q = qw.joined(separator: " ")
        guard !q.isEmpty else { return nil }
        var best: (score: Double, h: MarkdownOutline.Heading)?
        for h in heads {
            let hw = normalizedWords(h.title)
            let t = hw.joined(separator: " ")
            guard !t.isEmpty else { continue }
            var score = 0.0
            if t == q { score = 100 }
            else if t.contains(q) || q.contains(t) { score = 80 - Double(abs(t.count - q.count)) / 10 }
            else {
                let common = Set(qw).intersection(hw).count
                if common > 0 { score = 60 * Double(common) / Double(max(qw.count, hw.count)) }
                let d = editDistance(q, t, limit: 3)
                if d <= max(1, min(3, q.count / 4)) { score = max(score, 50 - Double(d)) }
            }
            if score >= 30, score > (best?.score ?? 0) { best = (score, h) }
        }
        return best?.h
    }

    /// Levenshtein distance, giving up (limit + 1) once it is over `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= limit else { return limit + 1 }
        var prev = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            var rowMin = cur[0]
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev = cur
        }
        return x.isEmpty ? y.count : prev[y.count]
    }

    /// read_section: the heading's line through the line before the next
    /// heading of the same or a higher level (its subsections included),
    /// numbered and capped; the headings when none matches.
    static func readSection(_ query: String, in s: OwlDocumentSnapshot) -> OwlToolResult {
        let summary = String(localized: "Read the section “\(String(query.prefix(40)))”")
        guard isMarkdown(s) else {
            return OwlToolResult(text: "error: read_section reads Markdown sections; use get_outline and get_lines", proposal: nil, summary: summary, ok: false)
        }
        let heads = MarkdownOutline.headings(in: s.text)
        guard !heads.isEmpty else {
            return OwlToolResult(text: "This document has no headings; use get_lines or search_document.", proposal: nil, summary: summary, ok: true)
        }
        guard let h = matchHeading(query, heads), let i = heads.firstIndex(of: h) else {
            let list = heads.prefix(60).map { "\($0.line + 1)| " + String(repeating: "#", count: $0.level) + " " + $0.title }.joined(separator: "\n")
            return OwlToolResult(text: cap("No heading matches “\(query.prefix(60))”. The headings are:\n" + list), proposal: nil, summary: summary, ok: true,
                                 rows: IndexSet(heads.prefix(60).map { $0.line + 1 }))
        }
        let first = h.line + 1
        let next = heads[(i + 1)...].first { $0.level <= h.level }
        var last = next.map { $0.line } ?? s.countedLines
        last = max(first, last)
        // Trailing blank lines are not part of it.
        while last > first, s.lines.contentRange(ofLine: last - 1).length == 0 { last -= 1 }
        let body = s.numbered(lines: first, last)
        let room = maxOutputBytes - 120
        if body.utf8.count <= room {
            return OwlToolResult(text: "Section (lines \(first)-\(last)):\n" + body, proposal: nil, summary: summary, ok: true, lines: first...last,
                                 rows: IndexSet(integersIn: first...last))
        }
        // Too long: the lines that fit whole, and where the rest is.
        var shown = first, used = 0
        for l in first...last {
            let n = s.numbered(lines: l, l).utf8.count + 1
            if used + n > room { break }
            used += n
            shown = l
        }
        let text = "Section (lines \(first)-\(last)), first part:\n" + s.numbered(lines: first, shown)
            + "\n[… cut: the section goes on to line \(last); call get_lines from line \(shown + 1) for the rest]"
        return OwlToolResult(text: text, proposal: nil, summary: summary, ok: true, lines: first...shown,
                             rows: IndexSet(integersIn: first...shown))
    }

    static let statsWords: Set<String> = ["words", "characters", "chars", "count", "length", "long", "filename", "language", "size", "stats", "statistics"]
    /// Caps `s` at `maxOutputBytes` of UTF-8 on a line boundary where possible.
    public static func cap(_ s: String, bytes: Int = maxOutputBytes) -> String {
        guard s.utf8.count > bytes else { return s }
        var out = ""
        var used = 0
        for line in s.components(separatedBy: "\n") {
            let n = line.utf8.count + 1
            if used + n > bytes - 20 {
                if out.isEmpty { out = String(decoding: Array(line.utf8.prefix(bytes - 20)), as: UTF8.self) }
                break
            }
            out += (out.isEmpty ? "" : "\n") + line
            used += n
        }
        return out + "\n[… cut]"
    }

    /// Runs `call` on the snapshot. Unknown tools, bad arguments and
    /// refusals come back as `ok: false` with a short reason the model
    /// can act on.
    public static func run(_ call: OwlToolCall, on s: OwlDocumentSnapshot, allowed: Set<OwlToolName> = Set(OwlToolName.allCases)) -> OwlToolResult {
        func fail(_ why: String) -> OwlToolResult { OwlToolResult(text: "error: " + why, proposal: nil, summary: why, ok: false) }
        guard let name = OwlToolName(rawValue: call.name) else { return fail("unknown tool \(call.name.prefix(40))") }
        guard allowed.contains(name) else { return fail("\(name.rawValue) is not available for this question") }
        let a = call.arguments
        switch name {
        case .getSelection:
            guard s.hasSelection else { return OwlToolResult(text: "(nothing selected)", proposal: nil, summary: String(localized: "Looked at the selection"), ok: true) }
            let span = s.lineSpan(s.selection)
            let text = s.substring(s.selection)
            let body = text.count <= 1500
                ? "Selected text (lines \(span.first)-\(span.last)):\n" + s.numbered(lines: span.first, span.last)
                : "Selected text (lines \(span.first)-\(span.last)), first part:\n" + s.numbered(lines: span.first, min(span.last, span.first + maxLines - 1))
            return OwlToolResult(text: cap(body), proposal: nil, summary: String(localized: "Looked at the selection"), ok: true,
                                 rows: IndexSet(integersIn: span.first...max(span.first, span.last)))
        case .getLines:
            guard let start = a["start"]?.int else { return fail("get_lines needs start and end") }
            let end = a["end"]?.int ?? start
            guard start >= 1, start <= s.lineCount else { return fail("start must be 1...\(s.lineCount)") }
            let last = min(s.lineCount, max(start, min(end, start + maxLines - 1)))
            let text = s.numbered(lines: start, last)
            // A capped result showed fewer lines: count only the ones that arrived whole.
            let shown = text.utf8.count > maxOutputBytes ? start + max(0, cap(text).components(separatedBy: "\n").count - 3) : last
            return OwlToolResult(text: cap(text), proposal: nil,
                                 summary: String(localized: "Looked at lines \(start)–\(last)"), ok: true,
                                 lines: shown >= start ? start...shown : nil, rows: IndexSet(integersIn: start...last))
        case .searchDocument:
            guard let q = a["query"]?.string, !q.isEmpty else { return fail("search_document needs a query") }
            guard q.count <= maxPatternLength else { return fail("query too long") }
            let regex = a["regex"]?.bool ?? false
            // The model writes the pattern, and a prompt injection in the
            // document can ask for a catastrophic one: shorter for a regex,
            // and the search stops at a time limit with an error the model
            // can act on (security review 0.2.1).
            guard !regex || q.count <= maxRegexLength else { return fail("regular expression too long (at most \(maxRegexLength) characters)") }
            let re: NSRegularExpression
            do {
                re = try NSRegularExpression(pattern: regex ? q : NSRegularExpression.escapedPattern(for: q), options: [.caseInsensitive])
            } catch { return fail("not a valid regular expression") }
            let ns = s.text as NSString
            var lines: [Int] = []
            var seen = Set<Int>()
            var total = 0
            let deadline = Date().addingTimeInterval(searchTimeLimit)
            var timedOut = false
            // .reportProgress: called now and then during a long match too,
            // so a pattern that backtracks forever can be stopped.
            re.enumerateMatches(in: s.text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                if Date() > deadline { timedOut = true; stop.pointee = true; return }
                guard let m else { return }
                let line = s.lineNumber(at: m.range.location)
                if seen.insert(line).inserted {
                    total += 1
                    if lines.count < maxMatches { lines.append(line) }
                }
                if total > 999 { stop.pointee = true }
            }
            if timedOut { return fail("the search took too long and was stopped; use a plain query or a simpler regular expression") }
            let summary = String(localized: "Searched for “\(String(q.prefix(40)))”")
            guard !lines.isEmpty else { return OwlToolResult(text: "no matches", proposal: nil, summary: summary, ok: true) }
            var body = lines.map { l -> String in
                let r = s.lines.contentRange(ofLine: l - 1)
                let t = s.substring(NSRange(location: r.location, length: min(r.length, 200)))
                return "\(l)| \(t)"
            }.joined(separator: "\n")
            if total > lines.count { body += "\n(\(total - lines.count) more lines match)" }
            return OwlToolResult(text: cap(body), proposal: nil, summary: summary, ok: true, rows: IndexSet(lines))
        case .getOutline:
            let o = outlineRows(s)
            return OwlToolResult(text: cap(o.text), proposal: nil, summary: String(localized: "Read the outline"), ok: true, rows: o.rows)
        case .documentStats:
            let c = TextStats.count(s.text as NSString, range: NSRange(location: 0, length: s.length))
            var body = "lines: \(s.lineCount)\ncharacters: \(c?.characters ?? s.length)\n"
            if let w = c?.words { body += "words: \(w)\n" }
            body += "language: \(Language(rawValue: s.language)?.displayName ?? s.language)\n"
            if let f = s.fileName { body += "file: \(f)\n" }
            if s.hasSelection { body += "selection: lines \(s.lineSpan(s.selection).first)-\(s.lineSpan(s.selection).last)\n" }
            return OwlToolResult(text: body, proposal: nil, summary: String(localized: "Counted the document"), ok: true)
        case .proposeEdit:
            guard case .string(let find)? = a["find"], case .string(let replace)? = a["replace"] else {
                return fail("propose_edit needs find (the exact text to change), replace and reason")
            }
            switch OwlEditProposal.anchored(find: find, replace: replace, reason: a["reason"]?.string ?? "", in: s) {
            case .failure(.empty): return fail("find is empty; copy the exact text to change from the document")
            case .failure(.tooLong): return fail("too long: find at most \(maxFindLength) characters, replace at most \(maxReplaceLength); propose a smaller change")
            case .failure(.notFound): return fail("find was not found; copy it exactly from the document, without the \"12| \" line numbers (call get_lines to see the text)")
            case .failure(.notUnique): return fail("find occurs more than once; include more of the surrounding text so it occurs only once")
            case .failure(.noChange): return fail("replace is the same as find")
            case .success(let p):
                let at = p.firstLine == p.lastLine ? "line \(p.firstLine)" : "lines \(p.firstLine)-\(p.lastLine)"
                let summary = p.firstLine == p.lastLine ? String(localized: "Proposed a change to line \(p.firstLine)")
                    : String(localized: "Proposed a change to lines \(p.firstLine)–\(p.lastLine)")
                return OwlToolResult(text: "proposed: the user will review the change to \(at) and apply it or not. For another separate change call propose_edit again (at most \(maxProposals) in all); otherwise briefly say what you propose. Nothing is applied until the user presses Apply.",
                                     proposal: p, summary: summary, ok: true)
            }
        case .checkDocument:
            let r = OwlChecks.run(s)
            return OwlToolResult(text: OwlChecks.listing(r, bytes: maxOutputBytes), proposal: nil,
                                 summary: String(localized: "Ran the document checks"), ok: true)
        case .readSection:
            guard let q = a["heading"]?.string, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return fail("read_section needs a heading") }
            guard q.count <= maxPatternLength else { return fail("heading too long") }
            return readSection(q, in: s)
        case .describeImage:
            // Needs a renderer: OwlToolbox runs it, with the document's picture.
            return fail(OwlPicture.isPicture(fileName: s.fileName) ? "describe_image is not available here" : "this document is text, not a picture")
        }
    }

    /// Per Markdown section: list items (nested ones too) and table data
    /// rows (not the header or the |---| line), outside fenced code.
    public struct SectionCount: Sendable, Equatable {
        public var heading: MarkdownOutline.Heading?
        /// 1-based lines of the section, its heading included.
        public var first: Int
        public var last: Int
        public var listItems = 0
        public var nestedItems = 0
        public var tableRows = 0
    }

    /// The sections of a Markdown document with their counts: a section
    /// runs from its heading to the line before the next heading (of any
    /// level); text before the first heading is a section with no heading.
    public static func sectionCounts(_ s: OwlDocumentSnapshot) -> [SectionCount] {
        let heads = MarkdownOutline.headings(in: s.text)
        var out: [SectionCount] = []
        if heads.first.map({ $0.line > 0 }) ?? true {
            out.append(SectionCount(heading: nil, first: 1, last: heads.first.map { $0.line } ?? s.lineCount))
        }
        for (i, h) in heads.enumerated() {
            let last = i + 1 < heads.count ? heads[i + 1].line : s.lineCount
            out.append(SectionCount(heading: h, first: h.line + 1, last: max(h.line + 1, last)))
        }
        let ns = s.text as NSString
        let item = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*+]|\d{1,9}[.)])\s+\S"#)
        let sep = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#)
        var fence: Character?
        var section = 0
        var previousWasRow = false
        for i in 0..<s.lineCount {
            while section + 1 < out.count, out[section + 1].first <= i + 1 { section += 1 }
            let line = ns.substring(with: s.lines.contentRange(ofLine: i))
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if t.hasPrefix(String(repeating: f, count: 3)) { fence = nil }
                previousWasRow = false
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = t.first; previousWasRow = false; continue }
            let full = NSRange(location: 0, length: (line as NSString).length)
            if let m = item.firstMatch(in: line, range: full) {
                out[section].listItems += 1
                if m.range(at: 1).length >= 2 { out[section].nestedItems += 1 }
            }
            if t.hasPrefix("|") {
                if sep.firstMatch(in: line, range: full) != nil {
                    // The row above was the header, not data.
                    if previousWasRow { out[section].tableRows -= 1 }
                } else {
                    out[section].tableRows += 1
                }
                previousWasRow = true
            } else {
                previousWasRow = false
            }
        }
        return out
    }

    /// "3 list items (1 nested), 2 table rows", or nil for none.
    static func countNote(_ c: SectionCount) -> String? {
        var parts: [String] = []
        if c.listItems > 0 { parts.append("\(c.listItems) list item\(c.listItems == 1 ? "" : "s")" + (c.nestedItems > 0 ? " (\(c.nestedItems) nested)" : "")) }
        if c.tableRows > 0 { parts.append("\(c.tableRows) table row\(c.tableRows == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Markdown headings; JSON top-level keys; CSV header; else lines that
    /// start at column 0 and look like declarations (code), at most 60.
    public static func outline(_ s: OwlDocumentSnapshot) -> String { outlineRows(s).text }

    /// `outline`, with the line numbers of the numbered rows in it.
    static func outlineRows(_ s: OwlDocumentSnapshot) -> (text: String, rows: IndexSet) {
        if s.language == "markdown" || (s.fileName?.lowercased().hasSuffix(".md") ?? false) {
            let h = MarkdownOutline.headings(in: s.text, limit: 60)
            if !h.isEmpty {
                // With each section's list items and table rows when it has
                // any, and the totals: a "how many" question needs them.
                let sections = sectionCounts(s)
                let byLine = Dictionary(sections.compactMap { c in c.heading.map { ($0.line, c) } }, uniquingKeysWith: { a, _ in a })
                var out = h.map { "\($0.line + 1)| " + String(repeating: "#", count: $0.level) + " " + $0.title
                    + (byLine[$0.line].flatMap(countNote).map { " [\($0)]" } ?? "") }
                let items = sections.reduce(0) { $0 + $1.listItems }, rows = sections.reduce(0) { $0 + $1.tableRows }
                if let before = sections.first, before.heading == nil, let n = countNote(before) {
                    out.insert("(before the first heading: \(n))", at: 0)
                }
                // First: the output is capped, and the totals must survive it.
                if items + rows > 0 {
                    let more = h.count < sections.filter({ $0.heading != nil }).count ? "; more headings than listed" : ""
                    out.insert("Total in all \(s.countedLines) lines: \(items) list items, \(rows) table rows\(more)", at: 0)
                }
                return (out.joined(separator: "\n"), IndexSet(h.map { $0.line + 1 }))
            }
        }
        if s.language == "json", let obj = OwlJSON.parse(s.text)?.object {
            return ("top-level keys: " + obj.keys.sorted().prefix(60).joined(separator: ", "), IndexSet())
        }
        if s.language == "csv" || s.language == "tsv" {
            let rows = (1..<max(1, s.lineCount)).filter { s.lines.contentRange(ofLine: $0).length > 0 }.count
            return ("\(rows) data rows; header: " + s.substring(s.lines.contentRange(ofLine: 0)), IndexSet())
        }
        let decl = try! NSRegularExpression(pattern: #"^(?:export\s+|public\s+|private\s+|static\s+|async\s+)*(?:func|function|def|class|struct|enum|protocol|extension|interface|type|fn|impl|module|sub|procedure|const|let|var)\b"#)
        var out: [String] = []
        var numbers = IndexSet()
        let ns = s.text as NSString
        for i in 0..<s.lineCount where out.count < 60 {
            let r = s.lines.contentRange(ofLine: i)
            guard r.length > 0, r.length < 400 else { continue }
            let line = ns.substring(with: r)
            let isHeading = line.hasPrefix("#") && s.language != "python" && s.language != "shell"
            if isHeading || decl.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                out.append("\(i + 1)| \(line)")
                numbers.insert(i + 1)
            }
        }
        return (out.isEmpty ? "(no outline: \(s.lineCount) lines)" : out.joined(separator: "\n"), numbers)
    }
}

// MARK: - The conversation

/// The notes on one part of a whole-document answer (lines `first`–`last`),
/// shown collapsed under the one answer they were combined into.
public struct OwlChatSection: Sendable, Equatable {
    public var first: Int
    public var last: Int
    public var text: String

    public init(first: Int, last: Int, text: String) {
        self.first = first; self.last = last; self.text = text
    }

    /// "Lines 1–40".
    public var title: String {
        first == last ? String(localized: "Line \(first)") : String(localized: "Lines \(first)–\(last)")
    }

    /// "Section notes (6)", the collapsed disclosure's title.
    public static func disclosureTitle(count: Int) -> String {
        String(localized: "Section notes (\(count))")
    }
}

/// One entry in a document's Ask Cedric history (kept in memory only).
public struct OwlChatEntry: Sendable, Equatable {
    /// `scan`: the offline script check's findings (no AI).
    public enum Role: String, Sendable { case user, owl, tool, note, scan }
    public var role: Role
    public var text: String
    /// The edits proposed with this answer, in the order proposed.
    public var proposals: [OwlEditProposal]
    public var proposal: OwlEditProposal? { proposals.first }
    /// A whole-document answer's per-part notes, below the answer and
    /// collapsed (never sent back to the model as history).
    public var sections: [OwlChatSection]

    public init(role: Role, text: String, proposals: [OwlEditProposal] = [], sections: [OwlChatSection] = []) {
        self.role = role; self.text = text; self.proposals = proposals; self.sections = sections
    }

    public init(role: Role, text: String, proposal: OwlEditProposal?) {
        self.init(role: role, text: text, proposals: proposal.map { [$0] } ?? [])
    }

    /// The history as Markdown (Copy as Markdown).
    public static func markdown(_ entries: [OwlChatEntry], fileName: String?) -> String {
        var out = "# Ask Cedric" + (fileName.map { " — \($0)" } ?? "") + "\n"
        for e in entries {
            switch e.role {
            case .user: out += "\n**You:** \(e.text)\n"
            case .owl:
                out += "\n**Cedric:** \(e.text)\n"
                for p in e.proposals {
                    if !p.reason.isEmpty { out += "\n_\(p.reason)_\n" }
                    out += "\n```diff\n\(p.unifiedText)\n```\n"
                }
                if !e.sections.isEmpty {
                    out += "\n<details><summary>\(OwlChatSection.disclosureTitle(count: e.sections.count))</summary>\n"
                    for sec in e.sections { out += "\n**\(sec.title):** \(sec.text)\n" }
                    out += "\n</details>\n"
                }
            case .tool: out += "\n> _\(e.text)_\n"
            case .note: out += "\n_\(e.text)_\n"
            case .scan: out += "\n**Offline scan:**\n\(e.text)\n"
            }
        }
        return out
    }
}
