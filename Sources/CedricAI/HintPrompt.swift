import Foundation
import CedricCore

/// Builds the request and parses the model's answer. Pure functions, so the
/// whole path from context to hints is unit-testable without a server.
public enum HintPrompt {
    /// The most text ever sent: OwlContext promises ≤ 8 KB; this enforces it.
    public static let maxContextBytes = 8 * 1024
    public static let maxHints = 2
    public static let minConfidence = 0.6
    public static let maxTitle = 60
    /// Non-whitespace characters a document must have before any engine is
    /// asked for a hint. Below this the prompt's code fence is empty or
    /// nearly so, and the model invents a problem (an "empty code block"
    /// on a blank Plain Text document).
    public static let minimumHintCharacters = 20

    /// False when `text`, ignoring whitespace, is empty or shorter than
    /// `minimumHintCharacters`.
    public static func hasEnoughText(_ text: String) -> Bool {
        var n = 0
        for ch in text where !ch.isWhitespace {
            n += 1
            if n >= minimumHintCharacters { return true }
        }
        return false
    }

    /// Clamps `text` to `maxBytes` of UTF-8 on a character boundary, keeping
    /// the start (the context builder puts the visible range first + margin;
    /// cutting the tail keeps returned ranges valid against `text`).
    public static func capped(_ text: String, maxBytes: Int = maxContextBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// The code-hints prompt (`OwlPrompts`: the owl's persona + the task).
    static var system: String { OwlPrompts.system(for: .codeHints) }

    public static func messages(for context: OwlContext, text: String, model: String, server: Bool = false) -> [ChatMessage] {
        OwlPrompts.messages(for: .codeHints, context: context, text: text, model: model, server: server)
    }

    /// The json_schema sent as response_format.
    public static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "hints": [
                    "type": "array",
                    "maxItems": maxHints,
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": ["type": "string", "enum": ["fix", "warning", "tip", "explain"]],
                            "category": ["type": "string", "enum": HintVerifier.Category.modelCases.map(\.rawValue)],
                            "title": ["type": "string"],
                            "detail": ["type": "string"],
                            "line": ["type": "integer"],
                            "find": ["type": "string"],
                            "replacement": ["type": "string"],
                            "confidence": ["type": "number"],
                        ],
                        "required": ["kind", "category", "title", "detail", "line", "find", "replacement", "confidence"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["hints"],
            "additionalProperties": false,
        ]
    }

    /// Parses the model output defensively. Drops: non-JSON, unknown kinds,
    /// empty or filler titles, confidence below `minConfidence`, a `find`
    /// that isn't in `text` (so a replacement can never land outside the
    /// context), and no-op replacements. Ranges are UTF-16 offsets into
    /// `text` — the context the provider was given.
    public static func parse(_ raw: String, text: String, source: String, language: String = "", wholeDocument: Bool = true) -> [OwlHint] {
        guard let json = extractJSON(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]]
        if let dict = obj as? [String: Any], let list = dict["hints"] as? [[String: Any]] {
            items = list
        } else if let list = obj as? [[String: Any]] {
            items = list
        } else {
            return []
        }
        let ns = text as NSString
        let lineStarts = Self.lineStarts(ns)
        var out: [OwlHint] = []
        for item in items {
            guard let kindRaw = (item["kind"] as? String)?.lowercased(),
                  let kind = OwlHint.Kind(rawValue: kindRaw),
                  var title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, !isFiller(title) else { continue }
            if let c = (item["confidence"] as? NSNumber)?.doubleValue, c < minConfidence { continue }
            let detail = (item["detail"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let find = stripLineNumber((item["find"] as? String) ?? "")
            var replacement = (item["replacement"] as? String).map(stripLineNumber).flatMap { $0.isEmpty ? nil : $0 }
            let line = (item["line"] as? NSNumber)?.intValue ?? (item["line"] as? String).flatMap { Int($0) }
            var range: NSRange?
            if !find.isEmpty {
                let all = occurrences(of: find, in: ns)
                if let line, line > 0 {
                    // The model must cite the snippet on (or right next to) the
                    // line it names; anything else is a hallucinated location.
                    let near = all.filter { abs(lineNumber(of: $0.location, starts: lineStarts) - line) <= 2 }
                    guard let best = near.min(by: {
                        abs(lineNumber(of: $0.location, starts: lineStarts) - line) < abs(lineNumber(of: $1.location, starts: lineStarts) - line)
                    }) else { continue }
                    range = best
                } else if let first = all.first {
                    range = first
                } else if replacement != nil {
                    // A hint about code that isn't there is a hallucination;
                    // with a replacement it could apply anywhere. Drop it.
                    continue
                }
            }
            // Contradicted by the code ("`<html>` is not closed" when it is)?
            let categories = HintVerifier.categories(model: item["category"] as? String, title: title, detail: detail)
            guard HintVerifier.holds(categories, title: title, detail: detail, find: find, text: text, language: language) else { continue }
            // What an offline rule already says here: the rule's hint wins (it has a real Fix it).
            if HintVerifier.duplicatesRule(categories, text: text, language: language, wholeDocument: wholeDocument) { continue }
            // "This JSON doesn't parse" about a window of a longer file: a
            // fragment never parses, so the claim can't be checked (and its
            // fix would only touch the window). Dropped.
            if !wholeDocument, categories.contains(.json) { continue }
            if title.count > maxTitle { title = String(title.prefix(maxTitle - 1)) + "…" }
            // A replacement needs an anchor inside the context, and must change something.
            if range == nil || replacement.map({ squash($0) == squash(find) }) == true { replacement = nil }
            // Small models sometimes "fix" a snippet with unrelated code
            // ("if (x == 0)" → "return x === 0"). An Apply button must only
            // offer edits that stay close to what they replace: similar
            // words, a similar size, and (where a checker exists) a fix that
            // actually makes the tags / brackets / JSON check pass.
            // A respelt word or two in prose ("definately" → "definitely",
            // "their are" → "there are") shares no whole word with what it
            // fixes, but is close letter by letter: kept. Not in code, where
            // a respelt identifier ("value" → "valve") is a different name.
            let prose = ["plain", "markdown"].contains(language.lowercased())
            if let rep = replacement, wordOverlap(find, rep) <= minReplacementOverlap,
               !(prose && isRespelling(find, rep)) { replacement = nil }
            if let rep = replacement, rep.count > max(find.count * 3, find.count + 80) { replacement = nil }
            if let rep = replacement, let r = range,
               !HintVerifier.fixPasses(categories, text: text, range: r, replacement: rep, language: language) {
                replacement = nil
            }
            if replacement == nil && detail == nil && range == nil && kind == .tip { continue }
            let hint = OwlHint(id: stableID(source: source, title: title, find: find),
                               kind: kind, title: title, detail: detail,
                               range: range, replacement: replacement, source: source)
            if !out.contains(where: { $0.id == hint.id }) { out.append(hint) }
        }
        // Hints that can be fixed in one click come first.
        let ranked = out.filter { $0.replacement != nil } + out.filter { $0.replacement == nil }
        return Array(ranked.prefix(maxHints))
    }

    /// "12| code" → "code": small models sometimes copy the line numbers.
    static func stripLineNumber(_ s: String) -> String {
        s.replacingOccurrences(of: "(?m)^\\s*\\d+\\| ?", with: "", options: .regularExpression)
    }

    static func occurrences(of find: String, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: find, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            out.append(r)
            from = r.location + max(1, r.length)
        }
        return out
    }

    static func lineStarts(_ ns: NSString) -> [Int] {
        var starts = [0]
        for i in 0..<ns.length where ns.character(at: i) == 10 { starts.append(i + 1) }
        return starts
    }

    /// 1-based line of a UTF-16 offset.
    static func lineNumber(of offset: Int, starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// Strips Qwen `<think>` blocks and Markdown fences, returns the
    /// outermost {...} or [...] span.
    static func extractJSON(_ raw: String) -> String? {
        var s = raw
        while let open = s.range(of: "<think>"), let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let firstObj = s.firstIndex(of: "{"), firstArr = s.firstIndex(of: "[")
        let start: String.Index
        let closer: Character
        switch (firstObj, firstArr) {
        case let (o?, a?): (start, closer) = o < a ? (o, "}") : (a, "]")
        case let (o?, nil): (start, closer) = (o, "}")
        case let (nil, a?): (start, closer) = (a, "]")
        default: return nil
        }
        guard let end = s.lastIndex(of: closer), end > start else { return nil }
        return String(s[start...end])
    }

    /// A replacement must share more than this fraction of its words with `find`.
    public static let minReplacementOverlap = 0.5

    /// Jaccard overlap of the identifier/number words in two snippets.
    static func wordOverlap(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .filter { !$0.isEmpty })
        }
        let wa = words(a), wb = words(b)
        if wa.isEmpty && wb.isEmpty { return 1 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }

    /// Prose respellings: both sides a few words of letters (an apostrophe
    /// or hyphen inside is fine), the same number of words give or take
    /// one ("alot" → "a lot"), and at least `minRespellingSimilarity` alike
    /// letter by letter. Code (brackets, operators, dots) never qualifies.
    static func isRespelling(_ find: String, _ replacement: String) -> Bool {
        func words(_ s: String) -> [Substring]? {
            let w = s.split(separator: " ")
            guard !w.isEmpty, w.count <= 4 else { return nil }
            for word in w {
                var core = Substring(word)
                while let last = core.last, ",.!?;:".contains(last) { core = core.dropLast() }
                guard !core.isEmpty, core.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) else { return nil }
            }
            return w
        }
        guard let a = words(find), let b = words(replacement), abs(a.count - b.count) <= 1 else { return false }
        return similarity(find.lowercased(), replacement.lowercased()) >= minRespellingSimilarity
    }

    public static let minRespellingSimilarity = 0.6

    /// 1 − Levenshtein distance / the longer length (characters).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var prev = Array(0...y.count), cur = prev
        for i in 1...max(1, x.count) where !x.isEmpty {
            cur[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        let d = x.isEmpty ? y.count : prev[y.count]
        return 1 - Double(d) / Double(max(x.count, y.count))
    }

    /// Whitespace-insensitive form, so "cart = []" vs "cart=[]" is a no-op.
    static func squash(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    static func isFiller(_ title: String) -> Bool {
        let t = title.lowercased()
        let filler = ["under 60 chars", "names the specific problem", "short title","no issues", "looks good", "no problems", "code is correct", "nothing to",
                      "lgtm", "no bugs", "well written", "add comments", "add documentation"]
        return filler.contains { t.contains($0) }
    }

    /// FNV-1a over source + title + snippet: stable across launches (unlike
    /// Hasher) and independent of where the snippet sits, so a snoozed hint
    /// stays snoozed when lines move.
    static func stableID(source: String, title: String, find: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(source)|\(title.lowercased())|\(find)".utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return "ai-" + String(h, radix: 16)
    }
}
