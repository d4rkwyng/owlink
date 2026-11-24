import Foundation

/// "Looks like JSON. Format it?" shown again from Recent hints after its
/// text changed (0.5.4 QA #12): the stale replay kept the question but
/// offered only Not now / Don't show again, a question with no yes. Now
/// the current text is checked again: still a one-line JSON document, a
/// fresh hint for the text as it is now (Fix it formats it, nothing
/// else); otherwise a past hint that asks nothing.
extension RulesHintProvider {
    /// The past hint's title.
    public static var staleJSONTitle: String { String(localized: "Looked like JSON (the text has changed since).") }
    /// …and when its document is closed.
    public static var closedJSONTitle: String { String(localized: "Looked like JSON.") }

    /// Longest document checked again on the main thread (the hint itself
    /// was only given for a document wholly in view).
    public static let replayJSONLimit = 64 * 1024

    /// `r`, a recent hint shown again, for the bubble. Only a stale JSON
    /// hint changes; `document` is the document's text now (nil: closed).
    public static func replayJSON(_ r: OwlCoordinator.Replay, document: NSString?) -> OwlCoordinator.Replay {
        guard r.hint.id == jsonID, r.isStale else { return r }
        if let doc = document, doc.length <= replayJSONLimit, let pretty = JSONFormatter.prettyIfMinified(doc as String) {
            let all = NSRange(location: 0, length: doc.length)
            let hint = OwlHint(id: jsonID, kind: .fix, title: String(localized: "Looks like JSON. Format it?"),
                               detail: String(localized: "Pretty-prints it with two-space indents; key order is kept."),
                               range: all, replacement: pretty, source: r.hint.source)
            return OwlCoordinator.Replay(hint: hint, documentRange: all, expected: doc as String, isStale: false)
        }
        let past = OwlHint(id: jsonID, kind: .tip, title: document == nil ? closedJSONTitle : staleJSONTitle,
                           detail: nil, source: r.hint.source)
        return OwlCoordinator.Replay(hint: past, documentRange: nil, expected: nil, isStale: true)
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
