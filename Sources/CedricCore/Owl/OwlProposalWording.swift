import Foundation

/// The app, not the model, says whether an edit happened. A model that
/// calls `propose_edit` often writes its summary as if the edit were done
/// ("Fixed 'definately'…", "Changed line 22…", "I updated the header")
/// before the user has pressed Apply. While an answer has proposals, those
/// claims are reworded as proposals, the same way `ScriptVerdict` keeps a
/// script answer from saying "safe", and each card carries a
/// "Proposed, not applied" badge until Apply (after which the card goes and
/// the transcript says "Applied. ⌘Z undoes it.").
public enum OwlProposalWording {
    /// The badge on a card until it is applied.
    public static let badge = "Proposed, not applied"

    /// The header for an answer's cards.
    public static func header(count: Int) -> String {
        count == 1 ? "Proposed 1 change, not applied" : "Proposed \(count) changes, not applied"
    }

    /// Past-tense claims and what they become: a sentence that starts with
    /// "Fixed" becomes "Proposed fix:", "I changed" becomes "I propose
    /// changing", and so on.
    static let verbs: [(past: String, noun: String, gerund: String)] = [
        ("fixed", "fix", "fixing"),
        ("changed", "change", "changing"),
        ("corrected", "correction", "correcting"),
        ("updated", "update", "updating"),
        ("replaced", "replacement", "replacing"),
        ("added", "addition", "adding"),
        ("removed", "removal", "removing"),
        ("renamed", "rename", "renaming"),
        ("rewrote", "rewrite", "rewriting"),
        ("rewritten", "rewrite", "rewriting"),
        ("inserted", "insertion", "inserting"),
        ("deleted", "deletion", "deleting"),
        ("edited", "edit", "editing"),
        ("modified", "change", "changing"),
        ("applied", "change", "applying"),
    ]

    private static let pastAlternation = verbs.map(\.past).joined(separator: "|")

    /// Where a sentence (or a list item) starts.
    private static let lead = #"(^|[.!?]\s+|\n[ \t]*(?:[-*•][ \t]+|\d+[.)][ \t]+)?)"#

    /// "Fixed X", "Changed line N" at a sentence start.
    private static let bare = try! NSRegularExpression(
        pattern: lead + #"(\#(pastAlternation))\b:?[ \t]*"#, options: [.caseInsensitive])
    /// "I fixed", "I've changed", "I have updated", "I just corrected".
    private static let firstPerson = try! NSRegularExpression(
        pattern: #"\bI(?:\s+have|'ve|’ve)?(?:\s+(?:just|also|now|already))?\s+(\#(pastAlternation))\b"#,
        options: [.caseInsensitive])
    /// "has been fixed", "is now corrected" (not "was changed": that may be
    /// the file's history, not this answer's edit).
    private static let passive = try! NSRegularExpression(
        pattern: #"\b(?:(?:has|have)\s+(?:now\s+|already\s+)?been|(?:is|are)\s+now)\s+(\#(pastAlternation))\b"#,
        options: [.caseInsensitive])

    /// `answer` with claims of a finished edit reworded as proposals.
    /// Only while there is something to apply (`proposals > 0`); idempotent.
    public static func guardClaims(_ answer: String, proposals: Int) -> String {
        guard proposals > 0, !answer.isEmpty else { return answer }
        var s = answer
        s = replace(firstPerson, in: s) { m, ns in
            let gerund = entry(ns.substring(with: m.range(at: 1)))?.gerund ?? "changing"
            return "I propose " + gerund
        }
        s = replace(passive, in: s) { m, ns in
            let noun = entry(ns.substring(with: m.range(at: 1)))?.past ?? "changed"
            return "would be " + noun + " (once you press Apply)"
        }
        s = replace(bare, in: s) { m, ns in
            let leadText = ns.substring(with: m.range(at: 1))
            let noun = entry(ns.substring(with: m.range(at: 2)))?.noun ?? "change"
            return leadText + "Proposed " + noun + ": "
        }
        return s
    }

    /// A card's reason ("Fixed the typo"), worded as a proposal: the card
    /// is itself the one thing to apply.
    public static func guardReason(_ reason: String) -> String {
        guardClaims(reason, proposals: 1)
    }

    private static func entry(_ past: String) -> (past: String, noun: String, gerund: String)? {
        verbs.first { $0.past == past.lowercased() }
    }

    private static func replace(_ re: NSRegularExpression, in s: String,
                                with make: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        let out = NSMutableString(string: s)
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            out.replaceCharacters(in: m.range, with: make(m, ns))
        }
        return out as String
    }
}
