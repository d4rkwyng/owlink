import Foundation

/// "Looks like JSON. Format it?" shown again from Recent hints after its
/// text changed (0.5.4 QA #12): the stale replay kept the question but
/// offered only Not now / Don't show again, a question with no yes. Now
/// the current text is checked again (off the main thread): still a
/// one-line JSON document, a fresh hint for the text as it is now (Fix it
/// formats it, nothing else); otherwise a past hint that asks nothing.
extension RulesHintProvider {
    /// The past hint's title.
    public static var staleJSONTitle: String { String(localized: "Looked like JSON (the text has changed since).") }
    /// …and when its document is closed.
    public static var closedJSONTitle: String { String(localized: "Looked like JSON.") }

    /// Longest document checked again (the hint itself was only given for
    /// a document wholly in view).
    public static let replayJSONLimit = 64 * 1024
    /// Most UTF-8 bytes of formatted output: 64 KB nested 500 deep would
    /// indent to tens of megabytes.
    public static let replayJSONOutputLimit = 1024 * 1024

    /// What showing a recent JSON hint again needs.
    public enum JSONReplay: Equatable, Sendable {
        /// Show this.
        case ready(OwlCoordinator.Replay)
        /// Check `text`, the whole document now, again with `recheckJSON`
        /// (off the main thread), and show the result only if the
        /// document still holds `text`.
        case recheck(text: String, source: String)
    }

    /// `r`, a recent hint shown again, for the bubble. Only a JSON hint
    /// changes; `document` is the document's text now (nil: closed).
    /// - Its document closed: a past hint (no question), with or without
    ///   a range.
    /// - The long one-line file's hint (no range): checked again like a
    ///   changed one, up to `replayJSONLimit` (it asked "Format it?" over
    ///   any text, and Fix it then said the file isn't JSON); past that, as
    ///   it was only while the text still has one-line JSON's shape
    ///   (`looksLikeOneLineJSON`; its Fix it checks the whole file before
    ///   it formats anything), else a past hint.
    /// - Its range still holds the text, and that is the whole document:
    ///   as it was. Text added around it (the JSON kept as a prefix) or
    ///   changed: checked again (`.recheck`), up to `replayJSONLimit`;
    ///   past that, a past hint.
    public static func replayJSON(_ r: OwlCoordinator.Replay, document: NSString?) -> JSONReplay {
        guard r.hint.id == jsonID else { return .ready(r) }
        guard let doc = document else { return .ready(pastJSON(closed: true, source: r.hint.source)) }
        if !r.isStale, r.documentRange == nil {
            if doc.length <= replayJSONLimit { return .recheck(text: doc as String, source: r.hint.source) }
            return .ready(looksLikeOneLineJSON(doc) ? r : pastJSON(closed: false, source: r.hint.source))
        }
        if !r.isStale, r.documentRange == NSRange(location: 0, length: doc.length) { return .ready(r) }
        guard doc.length <= replayJSONLimit else { return .ready(pastJSON(closed: false, source: r.hint.source)) }
        return .recheck(text: doc as String, source: r.hint.source)
    }

    /// `replayJSON` resolved all the way (a `.recheck` by `recheckJSON`)
    /// for `document`, the whole document now (nil: closed). Pure, and
    /// it may scan the whole document (the long range-less hint's shape
    /// check, past `replayJSONLimit`): the app calls it off the main
    /// thread, on a copy of the text, and shows the result only if the
    /// tab still holds that text.
    public static func resolveJSONReplay(_ r: OwlCoordinator.Replay, document: String?) -> OwlCoordinator.Replay {
        switch replayJSON(r, document: document.map { $0 as NSString }) {
        case .ready(let r): return r
        case .recheck(let text, let source): return recheckJSON(text, source: source)
        }
    }

    /// `text` (a whole document) checked again: still one-line JSON, a
    /// fresh hint for it (Fix it formats exactly that, nothing else);
    /// otherwise, or formatted past `replayJSONOutputLimit`, a past hint
    /// that asks nothing. Pure; call it off the main thread.
    public static func recheckJSON(_ text: String, source: String) -> OwlCoordinator.Replay {
        guard let pretty = JSONFormatter.prettyIfMinified(text, limit: replayJSONOutputLimit) else {
            return pastJSON(closed: false, source: source)
        }
        let all = NSRange(location: 0, length: (text as NSString).length)
        let hint = OwlHint(id: jsonID, kind: .fix, title: String(localized: "Looks like JSON. Format it?"),
                           detail: String(localized: "Pretty-prints it with two-space indents; key order is kept."),
                           range: all, replacement: pretty, source: source)
        return OwlCoordinator.Replay(hint: hint, documentRange: all, expected: text, isStale: false)
    }

    /// A cheap look at a text too long to check again: one line (ignoring
    /// whitespace at its ends) that opens with `{` or `[` and closes with
    /// the matching bracket. Not a parse.
    public static func looksLikeOneLineJSON(_ doc: NSString) -> Bool {
        let blank = CharacterSet.whitespacesAndNewlines
        var start = 0, end = doc.length
        while start < end, let u = UnicodeScalar(doc.character(at: start)), blank.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(doc.character(at: end - 1)), blank.contains(u) { end -= 1 }
        guard end - start >= 2 else { return false }
        let first = doc.character(at: start), last = doc.character(at: end - 1)
        guard (first == 0x7B && last == 0x7D) || (first == 0x5B && last == 0x5D) else { return false }
        return doc.rangeOfCharacter(from: .newlines, options: .literal, range: NSRange(location: start, length: end - start)).location == NSNotFound
    }

    /// Whether a fix computed for `expected` at `range` can still be
    /// applied to `text` (Fix it, Show Me): the range holds exactly those
    /// UTF-16 units (not a canonically equivalent spelling: Swift's `==`
    /// took "Å" for "A" + ring, and Fix it wrote the old scalar back), and
    /// for the JSON hint, whose replacement is the whole document
    /// formatted, the range is still the whole document (text added after
    /// it since the bubble came had its JSON prefix formatted).
    public static func stillApplies(_ hint: OwlHint, range: NSRange, expected: String, in text: NSString) -> Bool {
        guard NSMaxRange(range) <= text.length, (text.substring(with: range) as NSString).isEqual(to: expected) else { return false }
        if hint.id == jsonID, range != NSRange(location: 0, length: text.length) { return false }
        return true
    }

    /// The past JSON hint: "Looked like JSON (the text has changed
    /// since)." or, `closed`, "Looked like JSON.".
    public static func pastJSON(closed: Bool, source: String) -> OwlCoordinator.Replay {
        OwlCoordinator.Replay(hint: OwlHint(id: jsonID, kind: .tip, title: closed ? closedJSONTitle : staleJSONTitle,
                                            detail: nil, source: source),
                              documentRange: nil, expected: nil, isStale: true)
    }

    /// Whether `hint` is the past JSON hint (no question: OK and Don't
    /// show again, not Not now).
    public static func isPastJSONHint(_ hint: OwlHint) -> Bool {
        hint.id == jsonID && (hint.title == staleJSONTitle || hint.title == closedJSONTitle)
    }
}

extension OwlCoordinator {
    /// What VoiceOver reads for a row under Recent hints: the time, the
    /// title and the start of the detail, as sentences, without doubled
    /// punctuation ("Format it?." in 0.5.4).
    public static func spokenRecent(time: String, title: String, detail: String?) -> String {
        var spoken = "\(time), \(title)"
        guard let d = detail, !d.isEmpty else { return spoken }
        let ends = title.last.map { ".?!…:;".contains($0) } ?? false
        spoken += (ends ? " " : ". ") + (d.count > 120 ? String(d.prefix(120)) + "…" : d)
        return spoken
    }
}
