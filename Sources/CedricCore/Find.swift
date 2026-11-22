import Foundation

public struct FindOptions: Equatable, Sendable {
    public var regex = false
    public var caseSensitive = false
    public var wholeWord = false
    public var wrap = true
    /// Match only at the start of a word (a leading `\b`), as the system
    /// find bar's "Starts With". `wholeWord` takes precedence.
    public var wordPrefix = false

    public init(regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false, wrap: Bool = true,
                wordPrefix: Bool = false) {
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.wrap = wrap
        self.wordPrefix = wordPrefix
    }
}

/// Find and replace over an NSString, with literal or regular-expression
/// patterns (ICU syntax, as NSRegularExpression; `$1` in replacements).
public enum FindEngine {
    public enum FindError: Error, Equatable {
        case emptyPattern
        case invalidPattern(String)
        case timedOut
        case tooManyMatches
        case cancelled
    }

    public static func regex(_ pattern: String, _ options: FindOptions) throws -> NSRegularExpression {
        guard !pattern.isEmpty else { throw FindError.emptyPattern }
        var p = options.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if options.wholeWord { p = "\\b(?:" + p + ")\\b" } else if options.wordPrefix { p = "\\b(?:" + p + ")" }
        var o: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { o.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: p, options: o)
        } catch {
            throw FindError.invalidPattern(pattern)
        }
    }

    /// The next match after `from` (or before it, searching backwards),
    /// wrapping around the document if `options.wrap`.
    public static func next(_ regex: NSRegularExpression, in text: NSString, from: Int, backwards: Bool = false,
                            wrap: Bool = true) -> NSRange? {
        let all = NSRange(location: 0, length: text.length)
        if !backwards {
            let start = min(max(0, from), text.length)
            if let m = firstNonEmpty(regex, text, NSRange(location: start, length: text.length - start)) { return m }
            return wrap ? firstNonEmpty(regex, text, all) : nil
        } else {
            let end = min(max(0, from), text.length)
            var last: NSRange?
            regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: end)) { m, _, _ in
                if let r = m?.range, r.length > 0, r.location + r.length <= end { last = r }
            }
            if let last { return last }
            guard wrap else { return nil }
            regex.enumerateMatches(in: text as String, range: all) { m, _, _ in
                if let r = m?.range, r.length > 0 { last = r }
            }
            return last
        }
    }

    private static func firstNonEmpty(_ regex: NSRegularExpression, _ text: NSString, _ range: NSRange) -> NSRange? {
        var found: NSRange?
        regex.enumerateMatches(in: text as String, range: range) { m, _, stop in
            if let r = m?.range, r.length > 0 { found = r; stop.pointee = true }
        }
        return found
    }

    /// All non-empty matches (for counts and Replace All).
    public static func matches(_ regex: NSRegularExpression, in text: NSString) -> [NSTextCheckingResult] {
        regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).filter { $0.range.length > 0 }
    }

    /// How long a bounded search may run for a text of `length` UTF-16 units:
    /// half a second plus a little per 200k for a live search; Replace All
    /// (`interactive: false`) is given far longer, as it runs once, off the
    /// UI thread, and can be cancelled.
    public static func timeLimit(forLength length: Int, interactive: Bool = true) -> TimeInterval {
        let n = Double(max(0, length))
        return interactive ? min(10, 0.5 + n / 200_000) : min(60, 2 + n / 50_000)
    }

    /// Searches off the UI thread, stopping even during a long ICU match.
    /// A partial result is never returned, so Replace All cannot silently
    /// replace only some occurrences. `now` is the clock (injectable).
    public static func boundedMatches(_ regex: NSRegularExpression, in text: String,
                                      timeLimit: TimeInterval = 0.5, maxMatches: Int = 10_000,
                                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                      isCancelled: @Sendable () -> Bool = { false }) throws -> [NSTextCheckingResult] {
        let deadline = now() + max(0, timeLimit)
        var found: [NSTextCheckingResult] = []
        var failure: FindError?
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            if isCancelled() {
                failure = .cancelled
                stop.pointee = true
                return
            }
            if now() >= deadline {
                failure = .timedOut
                stop.pointee = true
                return
            }
            guard let match, match.range.length > 0 else { return }
            if found.count >= maxMatches {
                failure = .tooManyMatches
                stop.pointee = true
                return
            }
            found.append(match)
        }
        if let failure { throw failure }
        return found
    }

    /// The replacement text for one match: the template with `$1`… filled
    /// in for regex searches, the literal text otherwise.
    public static func replacement(for match: NSTextCheckingResult, in text: NSString, template: String,
                                   regex: NSRegularExpression, options: FindOptions) -> String {
        guard options.regex else { return template }
        return regex.replacementString(for: match, in: text as String, offset: 0, template: template)
    }

    /// Replaces every match; returns the new text and the count.
    public static func replaceAll(in text: String, pattern: String, with template: String, options: FindOptions) throws -> (String, Int) {
        let re = try regex(pattern, options)
        let ns = text as NSString
        let found = matches(re, in: ns)
        guard !found.isEmpty else { return (text, 0) }
        let out = NSMutableString(string: text)
        for m in found.reversed() {
            out.replaceCharacters(in: m.range, with: replacement(for: m, in: ns, template: template, regex: re, options: options))
        }
        return (out as String, found.count)
    }
}
