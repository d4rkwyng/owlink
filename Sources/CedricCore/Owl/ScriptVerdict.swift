import Foundation

/// The script check's verdict, kept honest in code whatever the model
/// says. Cedric never tells anyone a script is safe: a line that claims
/// so becomes "No obvious red flags (not a guarantee)", and the verdict is
/// forced to "Don't run it — review the flagged lines" when the offline
/// scan found a high-risk line or not all of the script was reviewed.
/// The model is told the same (OwlPrompts); this is the backstop, which
/// also holds when a script's own text talks the model into a verdict.
public enum ScriptVerdict {
    /// The three verdicts the model is asked to choose from.
    public static let noRedFlags = "No obvious red flags (not a guarantee)"
    public static let trustSource = "Run only if you trust the source"
    public static let dontRun = "Don't run it"
    /// The verdict forced by a high finding or a partial review.
    public static let forcedDontRun = "Don't run it — review the flagged lines"

    /// Why a verdict is forced.
    public enum Reason: Sendable, Equatable {
        case highFinding, truncated
        public var note: String {
            switch self {
            case .highFinding: return String(localized: "The offline scan found a high-risk line, so the verdict is fixed whatever the model says.")
            case .truncated: return String(localized: "Only part of the script was reviewed, so no reassuring verdict can be given.")
            }
        }
    }

    /// The forced reason, if any: a high finding comes first.
    public static func forcedReason(scanHasHigh: Bool, truncated: Bool) -> Reason? {
        scanHasHigh ? .highFinding : truncated ? .truncated : nil
    }

    /// How much of an answer about a script is guarded.
    public enum Guard: Sendable, Equatable {
        /// A verdict on running the script: the script check, or a typed
        /// question about running it ("is this safe?", "should I run
        /// it?"). Every safety claim rewrites its whole line; on the
        /// verdict and last lines any reassuring word counts.
        case verdict
        /// Any other question about a script ("is this queue thread
        /// safe?", "summarise it"): only a sentence that says running the
        /// script is fine ("safe to run", "the script is harmless") is
        /// rewritten. "Thread safe", "type-safe", "safe with spaces" stay.
        case runClaims
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    private static let verdictLine = re(#"^[\s>*_#-]*verdict\b"#)
    /// Running the script, as a verb.
    private static let runVerb = #"(?:run|execute|install|launch)"#
    /// A reassuring word: "safe", its synonyms, "fine to run", "nothing to worry about".
    private static let safeWord = re(#"\bsafe\b|\bharmless\b|\bbenign\b|\b(?:fine|ok|okay|alright|all\s+right)\s+to\s+"# + runVerb
        + #"\b|\bnothing\s+to\s+worry\s+about\b|\bgo\s+ahead\s+and\s+"# + runVerb + #"\b"#)
    /// A claim of safety anywhere in the answer, not only the verdict.
    private static let safeClaim = re(
        #"\b(?:safe|harmless|fine|ok|okay|alright)\s+to\s+(?:run|use|execute|install|launch)\b|\b(?:is|are|looks|seems|appears|perfectly|completely|totally|entirely|100%)\s+(?:\w+\s+)?(?:safe|harmless|benign)\b|\bnothing\s+to\s+worry\s+about\b|\bgo\s+ahead\s+and\s+"#
        + runVerb + #"\b"#)
    /// `Guard.runClaims`: only a claim that running the script is fine.
    private static let runClaim = re(
        #"\b(?:safe|harmless|fine|ok|okay|alright)\s+to\s+"# + runVerb + #"\b|\bgo\s+ahead\s+and\s+"# + runVerb
        + #"\b|\b(?:this|the)\s+(?:script|file)\s+(?:is|looks|seems|appears)\s+(?:\w+\s+)?(?:safe|harmless|benign)\s*(?:[.!,;:]|$)"#)
    /// The reassuring word in a match, for the negation and qualifier checks.
    private static let keyWord = re(#"\b(?:safe|harmless|benign|fine|ok|okay|alright|all\s+right|nothing|go)\b"#)
    /// Words that negate a "safe" right after them ("not safe", "isn't really safe").
    private static let negation = re(
        #"\b(?:not|never|no\s+longer|isn['’]t|aren['’]t|wasn['’]t|won['’]t|wouldn['’]t|cannot|can['’]t|don['’]t|doesn['’]t|shouldn['’]t)\s+(?:\w+\s+)?$"#)
    /// A "safe" that is a property of code, not a verdict on running it:
    /// "thread safe", "type-safe", "memory-safe", "fail-safe" (what comes before it).
    private static let qualifier = re(
        #"\b(?:thread|threads|type|memory|null|nil|signal|async|interrupt|exception|fork|fail|crash|unicode|url|uri|html|xml|json|sql|shell|quote|quoting|filename|path|space|whitespace|binary|locale|concurrency|re-?entrant|race|overflow|injection|escape|escaping|cancel|cancellation)[-\s]+$"#)
    /// A question that asks for a verdict on running the script (`Guard.verdict`).
    private static let runQuestion = re(
        #"\b(?:harm(?:ful|less)?|danger(?:ous)?|malicious|malware|virus|trojan|backdoor|ransomware|spyware|sketchy|shady|legit(?:imate)?|scam|trust(?:worthy)?|risk(?:y|s)?|suspicious|benign)\b|\b(?:ok|okay|fine|alright)\s+to\s+"#
        + runVerb + #"\b|\b(?:should|can|could|may)\s+i\s+(?:safely\s+)?"# + runVerb + #"\b|\bsafe(?:ly|ty)?\b"#)
    /// "Don't run it" in the same line.
    private static let dontRunPhrase = re(#"\bdon['’]t\s+run\b|\bdo\s+not\s+run\b"#)

    static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Characters that draw nothing: zero-width spaces and joiners, the
    /// soft hyphen, bidi controls, variation selectors, the BOM.
    private static func invisible(_ v: UInt32) -> Bool {
        v == 0x00AD || v == 0x034F || v == 0x180E || (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
            || (0x2060...0x206F).contains(v) || (0xFE00...0xFE0F).contains(v) || v == 0xFEFF
    }

    /// Cyrillic and Greek letters drawn like Latin ones ("ѕafe" with a Cyrillic s).
    private static let homoglyphs: [UInt32: Unicode.Scalar] = {
        let pairs: [(UInt32, Character)] = [
            (0x0430, "a"), (0x0435, "e"), (0x043E, "o"), (0x0440, "p"), (0x0441, "c"), (0x0443, "y"), (0x0445, "x"),
            (0x0455, "s"), (0x0456, "i"), (0x0458, "j"), (0x0501, "d"), (0x04BB, "h"), (0x04CF, "l"), (0x0475, "v"),
            (0x0410, "A"), (0x0412, "B"), (0x0415, "E"), (0x041A, "K"), (0x041C, "M"), (0x041D, "H"), (0x041E, "O"),
            (0x0420, "P"), (0x0421, "C"), (0x0422, "T"), (0x0425, "X"), (0x0405, "S"), (0x0406, "I"), (0x0408, "J"),
            (0x03B1, "a"), (0x03B5, "e"), (0x03BF, "o"), (0x03C1, "p"), (0x03BD, "v"), (0x03B9, "i"), (0x03BA, "k"),
            (0x0391, "A"), (0x0392, "B"), (0x0395, "E"), (0x0396, "Z"), (0x0397, "H"), (0x0399, "I"), (0x039A, "K"),
            (0x039C, "M"), (0x039D, "N"), (0x039F, "O"), (0x03A1, "P"), (0x03A4, "T"), (0x03A5, "Y"), (0x03A7, "X"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1.unicodeScalars.first!) })
    }()

    /// The text as matched: NFKC (fullwidth and mathematical letters
    /// become plain ones), invisible characters removed, look-alike
    /// Cyrillic and Greek letters folded to Latin. Only for matching:
    /// what is shown is the original text or a canned line.
    public static func normalized(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.precomposedStringWithCompatibilityMapping.unicodeScalars where !invisible(u.value) {
            out.append(homoglyphs[u.value] ?? u)
        }
        return String(out)
    }

    /// Some match of `re` in `s` (normalised) is a reassuring word that
    /// isn't negated ("not safe") or a property of code ("thread safe").
    static func hasClaim(_ re: NSRegularExpression, _ s: String, negatable: Bool = true) -> Bool {
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let r = keyWord.firstMatch(in: s, range: m.range)?.range ?? m.range
            let before = ns.substring(to: r.location)
            if negatable, has(negation, before) { continue }
            if ns.substring(with: r).lowercased() == "safe", has(qualifier, before) { continue }
            return true
        }
        return false
    }

    /// A line claims the script is safe: some "safe" (or "harmless",
    /// "fine to run", …) in it isn't directly negated. `strict` (the
    /// verdict and final lines): any such word counts.
    public static func claimsSafe(_ line: String, strict: Bool) -> Bool {
        hasClaim(strict ? safeWord : safeClaim, normalized(line))
    }

    /// A sentence says running the script is fine (`Guard.runClaims`).
    public static func claimsSafeToRun(_ text: String) -> Bool { hasClaim(runClaim, normalized(text)) }

    /// The question asks for a verdict on running the script ("is it
    /// safe?", "is this malware?", "should I run it?"), not about a
    /// property of the code ("is this queue thread safe?").
    public static func asksAboutRunning(_ question: String) -> Bool { hasClaim(runQuestion, normalized(question), negatable: false) }

    public static func isVerdictLine(_ line: String) -> Bool { has(verdictLine, line) }

    /// How severe a verdict line is: 2 for don't-run, 1 for trust-the-source, 0 otherwise.
    /// Matches both straight and curly apostrophes (`don['’]t run`).
    public static func severity(ofVerdict line: String) -> Int {
        if has(dontRunPhrase, line) { return 2 }
        return line.localizedCaseInsensitiveContains("trust") ? 1 : 0
    }

    private static let inlineVerdict = try! NSRegularExpression(pattern: #"[*_]*\bverdict\b[*_]*\s*:.*$"#, options: [.caseInsensitive])

    /// The answer as shown. `.verdict`: every claim of safety rewritten,
    /// and, when `forced`, any verdict the model gave replaced by
    /// `forcedDontRun`. `.runClaims`: only sentences that say running the
    /// script is fine (`forced` is the script check's, so unused there).
    public static func clamp(_ answer: String, forced: Reason? = nil, guard mode: Guard = .verdict) -> String {
        var lines = answer.components(separatedBy: "\n")
        if mode == .runClaims { return lines.map(clampRunClaims).joined(separator: "\n") }
        // Forced: the model's verdicts go first, so none is rewritten into a reassuring line.
        if forced != nil {
            lines.removeAll { isVerdictLine($0) }
            lines = lines.map(withoutInlineVerdict)
        }
        let lastText = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for i in lines.indices {
            lines[i] = clampLine(lines[i], strict: i == lastText)
        }
        if let forced {
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += forcedLines(forced)
        }
        return lines.joined(separator: "\n")
    }

    /// One line with any safe claim rewritten. `last`: it is the answer's
    /// last line, where any "safe" counts (as on a verdict line).
    public static func clampLine(_ line: String, strict last: Bool) -> String {
        let verdict = isVerdictLine(line)
        guard claimsSafe(line, strict: verdict || last) else { return line }
        // "Safe" and "don't run" together: keep the warning, drop the claim.
        let text = has(dontRunPhrase, line) ? dontRun : noRedFlags
        return verdict ? "Verdict: " + text + "." : text + "."
    }

    /// One line with each sentence that says running the script is fine
    /// replaced by "No obvious red flags (not a guarantee)."; the rest of
    /// the line is kept as written (`Guard.runClaims`).
    public static func clampRunClaims(_ line: String) -> String {
        guard claimsSafeToRun(line) else { return line }
        var out = ""
        let ns = line as NSString
        var last = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { sentence, r, _, _ in
            guard let sentence else { return }
            // What lies between sentences (spaces, a list marker) is kept.
            if r.location > last { out += ns.substring(with: NSRange(location: last, length: r.location - last)) }
            if claimsSafeToRun(sentence) {
                // The sentence's own trailing spaces are kept.
                let trailing = String(sentence.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
                out += (has(dontRunPhrase, sentence) ? dontRun : noRedFlags) + "." + trailing
            } else {
                out += sentence
            }
            last = NSMaxRange(r)
        }
        if last < ns.length { out += ns.substring(from: last) }
        // Whatever the sentence split did, no claim survives.
        return claimsSafeToRun(out) ? (has(dontRunPhrase, line) ? dontRun : noRedFlags) + "." : out
    }

    /// A verdict at the end of a sentence ("… shown lines. Verdict: Don't run it") cut off.
    static func withoutInlineVerdict(_ l: String) -> String {
        guard let m = inlineVerdict.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) else { return l }
        return (l as NSString).substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
    }

    /// Where a partial "Verdict" starts at the end of `s`, if one does.
    static func partialVerdictMatch(_ s: String) -> Int? {
        partialVerdict.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range.location
    }

    static func forcedLines(_ forced: Reason) -> [String] { [forced.note, "Verdict: " + forcedDontRun + "."] }

    /// The start of a "Verdict" still arriving at the end of the text ("… Verd").
    private static let partialVerdict = try! NSRegularExpression(pattern: #"[*_]*\bv(?:e(?:r(?:d(?:i(?:c(?:t)?)?)?)?)?)?[*_]*\s*$"#, options: [.caseInsensitive])
}

/// The script check's answer as it streams in: every update is clamped
/// before it is shown, so "safe to run" never appears, not even for one
/// frame, and with a forced verdict the model's own verdict never shows.
/// Incremental: finished lines are clamped once and kept; each update
/// clamps only the line still arriving (cheap however long the answer).
public struct ScriptVerdictStream: Sendable {
    public let forced: ScriptVerdict.Reason?
    /// How much is rewritten (`ScriptVerdict.Guard`).
    public let mode: ScriptVerdict.Guard
    /// Everything received.
    public private(set) var raw = ""
    /// Finished lines as shown (a hidden verdict line is left out).
    private var done: [String] = []
    /// Where in `raw` (UTF-8 offset) the line still arriving starts.
    private var tailOffset = 0
    private var tailStart: String.Index { raw.utf8.index(raw.utf8.startIndex, offsetBy: tailOffset) }

    public init(forced: ScriptVerdict.Reason?, guard mode: ScriptVerdict.Guard = .verdict) {
        self.forced = mode == .verdict ? forced : nil
        self.mode = mode
    }

    /// Adds a streamed piece; the text to show now.
    @discardableResult
    public mutating func append(_ piece: String) -> String {
        raw += piece
        while let nl = raw.utf8[tailStart...].firstIndex(of: 0x0A) {
            let line = String(raw[tailStart..<nl])
            tailOffset = raw.utf8.distance(from: raw.utf8.startIndex, to: nl) + 1
            if mode == .runClaims {
                done.append(ScriptVerdict.clampRunClaims(line))
            } else if forced != nil {
                if ScriptVerdict.isVerdictLine(line) { continue }
                done.append(ScriptVerdict.clampLine(ScriptVerdict.withoutInlineVerdict(line), strict: false))
            } else {
                done.append(ScriptVerdict.clampLine(line, strict: false))
            }
        }
        return display
    }

    /// The text to show for what has arrived so far.
    public var display: String {
        var tail = String(raw[tailStart...])
        if mode == .runClaims { return (done + [ScriptVerdict.clampRunClaims(tail)]).joined(separator: "\n") }
        if forced != nil {
            // The model's verdict, whole or still arriving, never shows.
            if ScriptVerdict.isVerdictLine(tail) { tail = "" }
            tail = ScriptVerdict.withoutInlineVerdict(tail)
            if let m = ScriptVerdict.partialVerdictMatch(tail) {
                tail = (tail as NSString).substring(to: m).trimmingCharacters(in: .whitespaces)
            }
        }
        var lines = done + [ScriptVerdict.clampLine(tail, strict: true)]
        if let forced {
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += ScriptVerdict.forcedLines(forced)
        }
        return lines.joined(separator: "\n")
    }
}
