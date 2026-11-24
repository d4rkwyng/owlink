import Foundation
import CedricCore

/// A scripted engine for tests, the in-app checks (CEDRIC_AI_FAKE) and the
/// tool eval's CI mode. No model, no network. It streams its answer in
/// small pieces (`delay` apart, cancellable), picks tools by keywords, and
/// for an edit it reads the lines and proposes (find/replace) adding a
/// comment line above the first one ("// Cedric: checked", or "# …" for hash-comment
/// languages), so a check can see exactly what Apply changed.
public struct FakeChatEngine: OwlChatEngine {
    public var delay: TimeInterval
    public var pieces: Int

    /// What the script check answers instead of its usual review (tests:
    /// a model talked into "Verdict: safe to run" by the script itself).
    public var scriptAnswer: String?

    /// What the spelling pick answers (OwlSpellingPicker); nil: the first
    /// suggestion, as a JSON string.
    public var spellingAnswer: String?

    public init(delay: TimeInterval = 0.05, pieces: Int = 8, scriptAnswer: String? = nil) {
        self.delay = delay; self.pieces = pieces; self.scriptAnswer = scriptAnswer
    }

    public var title: String { "Fake engine" }
    public var scoreKey: String { "fake" }
    public var contextBudget: Int { 6_000 }

    public static let commentText = "Cedric: checked"
    /// What the fake grammar check "finds".
    public static let grammarFixes = [("we was", "we were"), ("He go ", "He goes "), ("then I expected", "than I expected")]

    public func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                     onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        // The grammar task: a few fixed mistakes, as JSON.
        if case .system(let sys)? = messages.first, sys.contains("find grammar mistakes") {
            let text = messages.compactMap { m -> String? in if case .user(let s) = m { return s }; return nil }.last ?? ""
            var issues: [OwlJSON] = []
            for (find, rep) in Self.grammarFixes where text.contains(find) {
                issues.append(.object(["find": .string(find), "replacement": .string(rep), "why": .string("Fake grammar fix.")]))
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            return .answer(OwlJSON.object(["issues": .array(issues)]).jsonString)
        }
        // The spelling pick: one suggestion (or the scripted answer).
        if case .system(let sys)? = messages.first, sys.hasPrefix(OwlSpellingChoice.task) {
            let user = messages.compactMap { m -> String? in if case .user(let s) = m { return s }; return nil }.last ?? ""
            let first = user.components(separatedBy: "Suggestions: ").last?.components(separatedBy: ", ").first ?? ""
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            return .answer(spellingAnswer ?? first)
        }
        let names = Set(tools.map(\.name))
        let question = messages.compactMap { m -> String? in if case .user(let s) = m { return s }; return nil }
            .last { !$0.hasPrefix("Answer now") } ?? ""
        let results = messages.compactMap { m -> String? in if case .toolResult(_, let n, _) = m { return n }; return nil }
        let (first, last) = Self.shownLines(question)
        // The question itself: after the attached text.
        let asked = question.range(of: "```\n\n", options: .backwards).map { String(question[$0.upperBound...]) } ?? question
        if !names.isEmpty, results.isEmpty,
           let call = Self.choose(asked, tools: names, first: first, last: last, picture: question.contains(OwlPrompts.pictureKind)) {
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            return .toolCalls([call])
        }
        // After get_lines for an edit: propose it.
        if names.contains(.proposeEdit), results.last == OwlToolName.getLines.rawValue || results.last == OwlToolName.getSelection.rawValue,
           !results.contains(OwlToolName.proposeEdit.rawValue), let lines = Self.lastToolText(messages) {
            let original = Self.firstNumberedLine(lines)
            return .toolCalls([OwlToolCall(id: "fake_edit", name: "propose_edit", arguments: .object([
                "find": .string(original.text), "replace": .string(Self.commented(original.text, question: question)),
                "reason": .string("adds a comment")]))])
        }
        var answer: String
        if results.last == OwlToolName.describeImage.rawValue, let seen = Self.lastToolText(messages) {
            // Quotes the tool's output, so a check can see it reached the answer.
            answer = "Here is what describe_image saw (test engine):\n" + seen
        } else if results.contains(OwlToolName.proposeEdit.rawValue) {
            answer = "I added a short comment above line \(first)."
        } else if tools.isEmpty, question.contains("``` block") {
            // No tools: the replacement comes back as a block.
            let block = Self.numberedBody(question).first.map { Self.commented($0.text, question: question) } ?? ""
            let rest = Self.numberedBody(question).dropFirst().map(\.text)
            answer = "```\n" + ([block] + rest).joined(separator: "\n") + "\n```\nI added a short comment above line \(first)."
        } else if let task = question.range(of: OwlPrompts.scriptCheckTask) {
            // The script check: confirms each line the scan flagged.
            let instruction = String(question[task.lowerBound...])
            let re = try? NSRegularExpression(pattern: #"- line (\d+)"#)
            let ns = instruction as NSString
            let flagged = (re?.matches(in: instruction, range: NSRange(location: 0, length: ns.length)) ?? []).map { ns.substring(with: $0.range(at: 1)) }
            answer = scriptAnswer ?? (flagged.isEmpty ? "Nothing risky that I can see.\nVerdict: \(ScriptVerdict.noRedFlags)."
                : flagged.map { "Line \($0): risky, as the scan says (test engine)." }.joined(separator: "\n")
                    + "\nVerdict: \(ScriptVerdict.trustSource).")
        } else {
            answer = "Lines \(first)–\(last) look fine to me. This is a fake answer from the test engine, streamed in pieces so you can watch it arrive."
        }
        // Stream it.
        let chars = Array(answer)
        let size = max(1, chars.count / max(1, pieces))
        var i = 0
        while i < chars.count {
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            let piece = String(chars[i..<min(chars.count, i + size)])
            onText(piece)
            i += size
        }
        return .answer(answer)
    }

    /// The keyword policy (also what the eval's CI mode measures).
    /// `picture`: the document draws one (its "File kind:" line says so).
    public static func choose(_ q: String, tools: Set<OwlToolName>, first: Int, last: Int, picture: Bool = false) -> OwlToolCall? {
        let s = q.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if picture, tools.contains(.describeImage), has(["picture", "image", "icon", "look like", "looks like", "show", "drawn", "draws", "see"]) {
            return OwlToolCall(name: "describe_image")
        }
        let lineRef = firstNumber(after: "line", in: s)
        if tools.contains(.proposeEdit), has(["add short, useful comments", "rewrite", "simplify", "rename", "replace", "change line", "fix line",
                                              "propose", "shorten", "update the", "rephrase"]) {
            if tools.contains(.getLines) { return OwlToolCall(name: "get_lines", arguments: .object(["start": .number(Double(lineRef ?? first)), "end": .number(Double(lineRef ?? last))])) }
            if tools.contains(.getSelection) { return OwlToolCall(name: "get_selection") }
        }
        if tools.contains(.checkDocument), OwlChecks.asksAboutProblems(q), !has(["line "]) {
            return OwlToolCall(name: "check_document")
        }
        if tools.contains(.documentStats), has(["how many words", "how many lines", "word count", "how long is", "how many characters", "what language", "file name"]) {
            return OwlToolCall(name: "document_stats")
        }
        if tools.contains(.getOutline), has(["outline", "headings", "sections", "structure", "table of contents", "functions are defined"]) {
            return OwlToolCall(name: "get_outline")
        }
        if tools.contains(.readSection), let name = sectionName(q) {
            return OwlToolCall(name: "read_section", arguments: .object(["heading": .string(name)]))
        }
        if tools.contains(.getSelection), has(["selected", "selection", "highlighted"]) {
            return OwlToolCall(name: "get_selection")
        }
        if tools.contains(.searchDocument), let quoted = quotedTerm(q), has(["find", "where", "search", "how many times", "occur", "mention", "uses of", "used"]) {
            return OwlToolCall(name: "search_document", arguments: .object(["query": .string(quoted)]))
        }
        if tools.contains(.getLines), let n = lineRef, !(first...max(first, last)).contains(n) || has(["show me line", "read line", "read lines"]) {
            let end = firstNumber(after: "to", in: s) ?? n
            return OwlToolCall(name: "get_lines", arguments: .object(["start": .number(Double(n)), "end": .number(Double(max(n, end)))]))
        }
        return nil
    }

    /// "the Pests section" → "Pests" (a capitalised name before "section").
    static func sectionName(_ q: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"\b([A-Z][\w’'-]*(?: [A-Z][\w’'-]*)*) section\b"#)
        guard let m = re.firstMatch(in: q, range: NSRange(location: 0, length: (q as NSString).length)) else { return nil }
        return (q as NSString).substring(with: m.range(at: 1))
    }

    static func firstNumber(after word: String, in s: String) -> Int? {
        let re = try! NSRegularExpression(pattern: "\\b\(word)s? (\\d+)")
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return Int((s as NSString).substring(with: m.range(at: 1)))
    }

    static func quotedTerm(_ s: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"[“"']([^”"']{1,60})[”"']"#)
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    /// "Shown: …, lines A-B" in the user turn.
    static func shownLines(_ q: String) -> (Int, Int) {
        let re = try! NSRegularExpression(pattern: #"Shown: \w+, lines (\d+)-(\d+)"#)
        guard let m = re.firstMatch(in: q, range: NSRange(location: 0, length: (q as NSString).length)) else { return (1, 1) }
        let ns = q as NSString
        return (Int(ns.substring(with: m.range(at: 1))) ?? 1, Int(ns.substring(with: m.range(at: 2))) ?? 1)
    }

    static func numberedBody(_ q: String) -> [(number: Int, text: String)] {
        guard let body = OwlChatRunner.fencedBlock(q) else { return [] }
        return numbered(body)
    }

    static func numbered(_ body: String) -> [(number: Int, text: String)] {
        body.components(separatedBy: "\n").compactMap { line in
            guard let bar = line.range(of: "| ") ?? line.range(of: "|"), let n = Int(line[..<bar.lowerBound]) else { return nil }
            return (n, String(line[bar.upperBound...]))
        }
    }

    static func lastToolText(_ messages: [OwlChatMessage]) -> String? {
        for m in messages.reversed() { if case .toolResult(_, _, let c) = m { return c } }
        return nil
    }

    static func firstNumberedLine(_ text: String) -> (number: Int, text: String) {
        numbered(text).first ?? (1, "")
    }

    static func commented(_ line: String, question: String) -> String {
        let hash = question.contains("Language: Python") || question.contains("Language: Shell") || question.contains("Language: YAML")
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        return indent + (hash ? "# " : "// ") + commentText + "\n" + line
    }
}
