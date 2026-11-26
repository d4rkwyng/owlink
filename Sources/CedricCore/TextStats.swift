import Foundation

/// Words, lines and characters, for the status bar and the stats popover.
public struct TextCounts: Equatable, Sendable {
    public var words: Int
    public var lines: Int
    /// Unicode scalars (a surrogate pair counts once, and so does a
    /// CR LF pair).
    public var characters: Int

    public init(words: Int, lines: Int, characters: Int) {
        self.words = words
        self.lines = lines
        self.characters = characters
    }

    /// Minutes to read the words (`ReadingTime`).
    public var readingMinutes: Int { ReadingTime.minutes(words: words) }
}

public enum TextStats {
    /// Longer ranges aren't counted (the status bar shows lines only):
    /// counting is a scan, and it runs after edits and selection changes.
    public static let maxCounted = 1_000_000

    /// Counts `range` of `text`, or nil if it is longer than `limit`.
    ///
    /// Words:
    /// - A word is a run of letters, digits, marks and "_"
    ///   (Occurrences.isWordUnit) holding at least one letter or digit, so
    ///   "don't" is two, "snake_case" one and "___" none.
    /// - Han ideographs and kana are one word each (Chinese and Japanese
    ///   don't put spaces between words; this is how word processors count
    ///   them). Hangul is written with spaces and counts like Latin.
    /// - Emoji and symbols are never words (they still count as characters).
    /// - Markdown: markers are punctuation (`#`, `*`, `>`, `-`, `|`, the
    ///   brackets and backticks), so they never count, nor does a "___"
    ///   rule. Everything typed as text counts as written, link targets,
    ///   code and a ticked box's "x" included: one scan for every file
    ///   type, no parse.
    ///
    /// Lines are the lines the range touches; a range ending just after a
    /// newline doesn't touch the next line. An empty range is one (empty)
    /// line. CR LF is one line break and one character (the editor keeps
    /// LF in memory anyway); a lone CR is an ordinary character.
    public static func count(_ text: NSString, range: NSRange, limit: Int = maxCounted) -> TextCounts? {
        let start = max(0, min(range.location, text.length))
        let end = min(text.length, NSMaxRange(range))
        let len = end - start
        guard len <= limit else { return nil }
        var words = 0, newlines = 0, chars = 0
        // In a run of word units; whether the run has had a letter or digit.
        var inWord = false, counted = false
        var lastWasNewline = false
        var previous: unichar = 0
        var pendingLead: unichar = 0
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: chunk)
        var pos = start
        while pos < end {
            let n = min(chunk, end - pos)
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: pos, length: n))
                for k in 0..<n {
                    let c = p[k]
                    defer { previous = c }
                    if pendingLead != 0, !UTF16.isTrailSurrogate(c) { chars += 1; pendingLead = 0 }   // an unpaired lead
                    lastWasNewline = c == 10
                    if c == 10 {
                        newlines += 1
                        if previous != 13 { chars += 1 }   // CR LF: one character
                        inWord = false
                        continue
                    }
                    if c < 128 {
                        chars += 1
                        let digitOrLetter = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
                        if digitOrLetter || c == 95 {
                            if !inWord { inWord = true; counted = false }
                            if digitOrLetter && !counted { counted = true; words += 1 }
                        } else {
                            inWord = false
                        }
                        continue
                    }
                    // Non-ASCII: a whole scalar (a surrogate pair waits for its trail).
                    if UTF16.isLeadSurrogate(c) { pendingLead = c; continue }
                    let scalar: Unicode.Scalar?
                    if UTF16.isTrailSurrogate(c) {
                        scalar = pendingLead == 0 ? nil
                            : Unicode.Scalar(0x10000 + ((UInt32(pendingLead) - 0xD800) << 10) + (UInt32(c) - 0xDC00))
                        pendingLead = 0
                    } else {
                        scalar = Unicode.Scalar(c)
                    }
                    chars += 1
                    guard let s = scalar else { inWord = false; continue }
                    switch classify(s) {
                    case .ideograph:
                        words += 1
                        inWord = false
                    case .letter:
                        if !inWord { inWord = true; counted = false }
                        if !counted { counted = true; words += 1 }
                    case .mark:
                        // Combining marks continue a word (é as e + ◌́); alone they aren't one.
                        break
                    case .other:
                        inWord = false
                    }
                }
            }
            pos += n
        }
        // A lead surrogate cut off by the range end is still one character.
        if pendingLead != 0 { chars += 1 }
        let lines = len == 0 ? 1 : newlines + (lastWasNewline ? 0 : 1)
        return TextCounts(words: words, lines: lines, characters: chars)
    }

    enum Kind { case ideograph, letter, mark, other }

    static func classify(_ s: Unicode.Scalar) -> Kind {
        let v = s.value
        // Kana (hiragana, katakana, their extensions, halfwidth katakana).
        if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v) {
            // The prolonged sound mark and iteration marks lengthen the word before.
            return v == 0x30FC || v == 0x309D || v == 0x309E || v == 0x30FD || v == 0x30FE ? .mark : .ideograph
        }
        let p = s.properties
        if p.isIdeographic { return .ideograph }
        switch p.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return .letter
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return .mark
        case .connectorPunctuation:
            return .mark   // "_" and its wide forms join a word, as in ASCII
        default:
            return .other
        }
    }
}

/// Reading time for the stats popover.
public enum ReadingTime {
    /// Words per minute for silent reading of non-fiction in English:
    /// Brysbaert, M. (2019). "How many words do we read per minute? A review
    /// and meta-analysis of reading rate." Journal of Memory and Language
    /// 109, 104047. doi:10.1016/j.jml.2019.104047 (238 non-fiction, 260 fiction).
    public static let wordsPerMinute = 238

    /// Whole minutes, rounded; any text at all is at least 1 minute.
    public static func minutes(words: Int, wordsPerMinute wpm: Int = wordsPerMinute) -> Int {
        guard words > 0, wpm > 0 else { return 0 }
        return max(1, Int((Double(words) / Double(wpm)).rounded()))
    }
}

/// A per-file word goal (the stats popover). Kept in the session, never
/// in the file.
public enum WordGoal {
    /// Goals outside this range aren't kept.
    public static let range = 1...10_000_000

    /// A goal typed in the popover: digits (grouping separators and
    /// spaces allowed); nil or 0 clears it.
    public static func parse(_ s: String) -> Int? {
        let digits = s.filter { !$0.isWhitespace && $0 != "," && $0 != "." && $0 != "\u{2019}" && $0 != "'" && $0 != "\u{202F}" && $0 != "\u{00A0}" }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), range.contains(n) else { return nil }
        return n
    }

    /// 0…1, for the ring.
    public static func progress(words: Int, goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        return min(1, max(0, Double(words) / Double(goal)))
    }

    /// Whole percent (can pass 100: "112 %" once over the goal).
    public static func percent(words: Int, goal: Int) -> Int {
        guard goal > 0 else { return 0 }
        return Int((Double(max(0, words)) * 100 / Double(goal)).rounded(.down))
    }
}

/// The word goals of files, by path, in the session (`Session.wordGoals`):
/// most recently set last, at most `limit` (the oldest go). A goal lives
/// with the file's path, so it comes back when the file is opened again
/// in a new tab; an untitled tab keeps its own (`SessionTab.wordGoal`).
public struct FileWordGoal: Codable, Equatable, Sendable {
    public var path: String
    public var words: Int
    public init(path: String, words: Int) {
        self.path = path
        self.words = words
    }
}

public enum FileWordGoals {
    public static let limit = 500

    public static func goal(for path: String, in list: [FileWordGoal]) -> Int? {
        list.last { FolderTree.sameBytes($0.path, path) }?.words
    }

    /// `list` with `path`'s goal set (moved to the end) or, with nil or an
    /// out-of-range goal, removed.
    public static func setting(_ words: Int?, for path: String, in list: [FileWordGoal], limit: Int = limit) -> [FileWordGoal] {
        var out = list.filter { !FolderTree.sameBytes($0.path, path) }
        if let w = words, WordGoal.range.contains(w) { out.append(FileWordGoal(path: path, words: w)) }
        if out.count > max(1, limit) { out.removeFirst(out.count - max(1, limit)) }
        return out
    }
}
