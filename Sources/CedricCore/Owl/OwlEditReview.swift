import Foundation

/// What a wholesale buffer replacement does to pending edit proposals.
/// `setText` (a clean-tab disk reload, reopening in another encoding,
/// Follow File's reset) swaps the whole buffer without a user edit.
/// Proposals were made against the previous text and must not apply to
/// the new one: a `.lines` edit matches a stored offset, and the new
/// buffer can hold the same substring there; a `.text` edit can still
/// be unique in text it was never proposed against.
public enum OwlBufferReplacement {
    /// The document's edit generation after the replacement. One more
    /// than before, so a `.lines` proposal's stored generation no longer
    /// matches even when the offset still holds `original`.
    public static func generation(after generation: Int) -> Int { generation + 1 }

    /// Pending proposals after the replacement: none are kept.
    public static func kept(_ proposals: [OwlEditProposal]) -> [OwlEditProposal] {
        proposals.filter { _ in false }
    }
}

/// When Apply is refused and the card says the document is read-only.
public enum OwlEditAccess {
    /// Not editable, following the file on disk, in large-document mode
    /// (the text is chunked, including after Turn On Anyway), or with the
    /// extras paused (also the moment a paste trips large mode, before the
    /// bar is shown). Also a file that can't be written (FileWriteAccess:
    /// permissions, locked, read-only volume), even after Allow Editing:
    /// a read-only document never applies.
    public static func readOnly(editable: Bool, following: Bool, largeDocument: Bool, extrasPaused: Bool,
                                unwritableFile: Bool = false) -> Bool {
        !editable || following || largeDocument || extrasPaused || unwritableFile
    }
}

/// Rechecking open edit cards after typing. One pass per burst, and only
/// while Ask Cedric is on screen: a hidden panel has nothing to update,
/// and large mode already refuses Apply, so it must not scan the buffer.
public enum OwlCardRefresh {
    /// The pause after a key before the cards are rechecked.
    public static let debounce: TimeInterval = 0.15

    public static func shouldRefresh(panelVisible: Bool, largeDocument: Bool, extrasPaused: Bool, hasCards: Bool) -> Bool {
        hasCards && panelVisible && !largeDocument && !extrasPaused
    }
}

/// One refresh of the open cards: each distinct find string is searched
/// at most once, and each search stops after two hits (enough to know
/// the text is not unique). A read-only document is not searched.
public struct OwlEditRefresh: Equatable, Sendable {
    public var states: [OwlEditProposal.ApplyState]
    public var searches: Int
}

extension OwlEditProposal {
    public static func refresh(_ proposals: [OwlEditProposal], text: NSString, generation: Int, readOnly: Bool) -> OwlEditRefresh {
        if readOnly {
            return OwlEditRefresh(states: Array(repeating: .readOnly, count: proposals.count), searches: 0)
        }
        var cache: [String: [NSRange]] = [:]
        var searches = 0
        var states: [ApplyState] = []
        states.reserveCapacity(proposals.count)
        for p in proposals {
            switch p.anchor {
            case .lines:
                states.append(p.state(text: text, generation: generation))
            case .text:
                let hits: [NSRange]
                if let found = cache[p.original] {
                    hits = found
                } else {
                    hits = occurrences(of: p.original, in: text, limit: 2)
                    cache[p.original] = hits
                    searches += 1
                }
                states.append(hits.count == 1 ? .ready(hits[0]) : .stale)
            }
        }
        return OwlEditRefresh(states: states, searches: searches)
    }

    /// 1-based lines covering `range`. The last line is the one that holds
    /// the last character, so a range ending on a newline stays on that line.
    public static func lineSpan(_ range: NSRange, in index: LineIndex) -> (first: Int, last: Int) {
        lineSpan(range, lines: index, length: index.length)
    }

    public static func lineSpan(_ range: NSRange, lines: LineIndex, length: Int) -> (first: Int, last: Int) {
        let limit = max(0, length)
        let loc = min(max(0, range.location), limit)
        let end = min(max(loc, NSMaxRange(range)), limit)
        let lastOffset = end == loc ? loc : end - 1
        let first = lines.line(containing: loc) + 1
        let last = lines.line(containing: min(lastOffset, limit)) + 1
        return (first, max(first, last))
    }

    /// VoiceOver reads the whole change. Invisible characters are named,
    /// so a zero-width space is not skipped, and nothing is clipped.
    public var spokenDiff: String {
        let old = OwlEditInvisibles.spoken(original)
        let new = OwlEditInvisibles.spoken(replacement)
        if replacement.isEmpty { return String(localized: "Delete “\(old)”.") }
        return String(localized: "Replace “\(old)” with “\(new)”.")
    }
}

/// Zero-width and other invisible or control characters, drawn so a
/// reviewer can see them. Tab and newline stay as themselves: they are
/// the document's own whitespace, not a hidden insert.
public enum OwlEditInvisibles {
    public static let warning = String(localized: "Contains invisible characters")

    public struct Rendered: Equatable, Sendable {
        public var text: String
        /// UTF-16 ranges of the `⟨U+XXXX⟩` tokens in `text`.
        public var invisibleRanges: [NSRange]
        public var containsInvisible: Bool { !invisibleRanges.isEmpty }
    }

    public static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        if u == "\n" || u == "\r" || u == "\t" { return false }
        // Combining grapheme joiner draws nothing and is not a format character.
        if u.value == 0x034F { return true }
        switch u.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    public static func contains(_ s: String) -> Bool { s.unicodeScalars.contains(where: isInvisible) }

    /// `a` + U+200B becomes `a⟨U+200B⟩`, with the token's range marked so
    /// the card can draw it in a distinct style.
    public static func render(_ s: String) -> Rendered {
        let out = NSMutableString()
        var ranges: [NSRange] = []
        for u in s.unicodeScalars {
            if isInvisible(u) {
                let token = "⟨U+\(String(format: "%04X", u.value))⟩"
                let loc = out.length
                out.append(token)
                ranges.append(NSRange(location: loc, length: out.length - loc))
            } else {
                out.append(String(u))
            }
        }
        return Rendered(text: out as String, invisibleRanges: ranges)
    }

    /// The same text for VoiceOver: "zero width space (U+200B)", not a
    /// character the synth skips.
    public static func spoken(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if isInvisible(u) {
                if !out.isEmpty, !out.hasSuffix(" ") { out += " " }
                out += spokenName(u)
                out += " "
            } else {
                out += String(u)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func spokenName(_ u: Unicode.Scalar) -> String {
        let code = String(format: "U+%04X", u.value)
        if let name = names[u.value] { return "\(name) (\(code))" }
        return code
    }

    private static let names: [UInt32: String] = [
        0x0000: "null", 0x0007: "bell", 0x0008: "backspace", 0x000C: "form feed", 0x001B: "escape", 0x007F: "delete",
        0x00AD: "soft hyphen", 0x034F: "combining grapheme joiner", 0x180E: "mongolian vowel separator",
        0x200B: "zero width space", 0x200C: "zero width non-joiner", 0x200D: "zero width joiner",
        0x200E: "left-to-right mark", 0x200F: "right-to-left mark",
        0x202A: "left-to-right embedding", 0x202B: "right-to-left embedding", 0x202C: "pop directional formatting",
        0x202D: "left-to-right override", 0x202E: "right-to-left override",
        0x2060: "word joiner", 0x2061: "function application", 0x2062: "invisible times",
        0x2063: "invisible separator", 0x2064: "invisible plus",
        0x2066: "left-to-right isolate", 0x2067: "right-to-left isolate",
        0x2068: "first strong isolate", 0x2069: "pop directional isolate",
        0xFEFF: "byte order mark",
    ]
}

/// Whether the card's diff shows the whole replacement. The scroll shows
/// at most `visibleRows` lines; a longer diff, or one line that wraps
/// past that, stays unapplied until the user opens Show all.
public enum OwlEditReview {
    public static let visibleRows = 6
    /// Used before the card has a width: narrow, so a long line is gated.
    public static let fallbackCharsPerRow = 40

    public static func visualRows(_ text: String, charsPerRow: Int) -> Int {
        let width = max(1, charsPerRow)
        let ns = text as NSString
        if ns.length == 0 { return 1 }
        var rows = 0
        var start = 0
        while start <= ns.length {
            let rest = NSRange(location: start, length: ns.length - start)
            let br = ns.range(of: "\n", options: [], range: rest)
            let end = br.location == NSNotFound ? ns.length : br.location
            rows += max(1, (end - start + width - 1) / width)
            if br.location == NSNotFound { break }
            start = end + br.length
            if start == ns.length { rows += 1; break }
        }
        return rows
    }

    /// `rows` are the diff lines (original and replacement). Invisible
    /// characters are counted as their visible tokens.
    public static func needsShowAll(rows: [String], charsPerRow: Int) -> Bool {
        let width = max(1, charsPerRow)
        var visual = 0
        for row in rows {
            visual += visualRows(OwlEditInvisibles.render(row).text, charsPerRow: width)
            if visual > visibleRows { return true }
        }
        return false
    }

    public static func applyEnabled(ready: Bool, needsShowAll: Bool, hasShownAll: Bool) -> Bool {
        ready && (!needsShowAll || hasShownAll)
    }
}

/// What an Apply does with the undo stack. A refused change (the text
/// view declines the edit) opens no group and records no bookmarks, so
/// it cannot leave an empty "Cedric's Edit" step. An accepted change
/// records the bookmark state before the replacement, then the text,
/// then the bookmarks again.
public enum OwlApplyUndo {
    public struct Plan: Equatable, Sendable {
        public var openGroup: Bool
        public var registerBookmarkBefore: Bool
        public var replaceText: Bool
        public var registerBookmarkAfter: Bool
        public var closeAndNameGroup: Bool
    }

    public static func plan(changeAccepted: Bool, tracksBookmarks: Bool) -> Plan {
        guard changeAccepted else {
            return Plan(openGroup: false, registerBookmarkBefore: false, replaceText: false,
                        registerBookmarkAfter: false, closeAndNameGroup: false)
        }
        return Plan(openGroup: true, registerBookmarkBefore: tracksBookmarks, replaceText: true,
                    registerBookmarkAfter: tracksBookmarks, closeAndNameGroup: true)
    }
}
