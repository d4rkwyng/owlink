import Foundation

/// The first spell check of a document that has just been shown, and the
/// pass AppKit schedules over the same text.
///
/// NSTextView's continuous checking (TextKit 2: NSTextCheckingController)
/// checks only the visible text, but it schedules that first pass about
/// 1 s after the first layout. Owlink checks the visible range itself as
/// soon as the first frame is up, so the marks show about a second sooner,
/// and records here what it checked. When AppKit's pass comes, it is
/// skipped if it asks for nothing more: a range inside the checked one, no
/// public checking type the early check didn't ask for, and no edit since;
/// and only once the early check's results have come back (otherwise
/// AppKit's pass is what marks the text).
///
/// One-shot: the first request AppKit makes, skipped or not, clears the
/// record, and so does any edit. Every later pass (scrolling, typing, a
/// language change, Check Document Now) is AppKit's own. Nor is a request
/// skipped when it asks for anything the early check can't vouch for:
/// options (AppKit's scheduled pass passes none), a checking type bit
/// nobody has seen AppKit's pass use, a language change
/// (`SpellDictionaryState`), or a marked word the spell checker no longer
/// flags (learned or ignored since, here or in the spelling panel or in
/// another app: `stillMarked`). The view also clears it before continuous
/// checking is turned off or on (Fix Typos' Ignore All and Learn Word
/// redraw the marks that way), when its context menu opens (Learn, Ignore,
/// Unlearn) and on Ignore Spelling.
public struct SpellCheckCoverage: Equatable, Sendable {
    /// What the early check covered; nil when there is nothing to skip.
    public private(set) var range: NSRange?
    public private(set) var types: UInt64 = 0
    /// The early check's results have come back.
    public private(set) var answered = false
    /// The spelling dictionary when the early check asked.
    public private(set) var dictionary: SpellDictionaryState?
    /// The words the early check's results marked (to see whether one
    /// has been learned or ignored since), each once, in the order first
    /// marked: a page of text marks the same few words many times over.
    public private(set) var markedWords: [String] = []

    public init() {}

    /// The public NSTextCheckingType bits (orthography through transit
    /// information). AppKit's own private bits above them differ between
    /// a view's enabled types and its scheduled pass, so they aren't
    /// compared.
    public static let publicTypes: UInt64 = (1 << 13) - 1

    /// Correction: AppKit's scheduled pass asks for it even with automatic
    /// correction off, so the early check asks for it too.
    public static let correction: UInt64 = 1 << 9

    /// Every bit a request may carry and still be skipped: the public
    /// types, and the two AppKit's own passes carry on macOS 27 (13:
    /// automatic text completion, in the view's enabled types; 28: its
    /// scheduled pass). Any other bit is something the early check knows
    /// nothing about, so that request runs.
    public static let knownTypes: UInt64 = publicTypes | (1 << 13) | (1 << 28)

    /// The types the early check asks for: the view's enabled public types,
    /// plus correction, as AppKit's scheduled pass does.
    public static func earlyTypes(enabled: UInt64) -> UInt64 {
        (enabled & publicTypes) | correction
    }

    public var isEmpty: Bool { range == nil }

    /// The early check is about to check `range` for `types`.
    public mutating func checked(_ range: NSRange, types: UInt64, dictionary: SpellDictionaryState) {
        self.range = range
        self.types = types & Self.publicTypes
        self.dictionary = dictionary
        answered = false
        markedWords = []
    }

    /// The early check's results for `checked` haven't come back yet.
    public func awaitsResults(for checked: NSRange) -> Bool {
        guard !answered, let range else { return false }
        return NSEqualRanges(range, checked)
    }

    /// Results came back for `checked`, marking `words`: if that is the
    /// early check's range, it is done. (The view builds `words` only when
    /// `awaitsResults(for:)`, not on every typing or scrolling pass.)
    public mutating func resultsArrived(for checked: NSRange, marking words: [String] = []) {
        guard awaitsResults(for: checked) else { return }
        answered = true
        var seen = Set<String>()
        markedWords = words.filter { seen.insert($0).inserted }
    }

    /// An edit, a setting change: nothing is known to be checked any more.
    public mutating func clear() {
        range = nil
        types = 0
        answered = false
        dictionary = nil
        markedWords = []
    }

    /// AppKit asks to check `request` for `requestTypes`, with options
    /// (`hasOptions`), the language now being `dictionary`. True when the
    /// early check already did all of it (skip the request). Always clears.
    ///
    /// `stillMarked` is asked last, only when everything else allows the
    /// skip and something was marked: given the marked words, the ones the
    /// spell checker still flags now (one check of them all in the
    /// document's spell tag, `MarkedWordsBatch`). A word learned or ignored
    /// since the early check isn't flagged any more, so AppKit's pass runs
    /// and takes its mark away.
    public mutating func take(_ request: NSRange, types requestTypes: UInt64, hasOptions: Bool = false,
                              dictionary now: SpellDictionaryState,
                              stillMarked: ([String]) -> Set<String> = { _ in [] }) -> Bool {
        defer { clear() }
        guard answered, !hasOptions, let range, request.location >= range.location, NSMaxRange(request) <= NSMaxRange(range),
              requestTypes & ~Self.knownTypes == 0, dictionary == now,
              requestTypes & Self.publicTypes & ~types == 0 else { return false }
        guard !markedWords.isEmpty else { return true }
        return stillMarked(markedWords).isSuperset(of: markedWords)
    }
}

/// What the spell checker's answers depend on besides the text and its
/// dictionaries: its language, or Automatic by Language. Both are read
/// in-process. (Learned and ignored words are the spell server's: the
/// marked words are checked again instead, `MarkedWordsBatch`.)
public struct SpellDictionaryState: Equatable, Sendable {
    public var language: String
    public var automaticByLanguage: Bool

    public init(language: String, automaticByLanguage: Bool) {
        self.language = language
        self.automaticByLanguage = automaticByLanguage
    }
}

/// The early check's marked words as one text for one spelling check
/// (one round trip to the spell server, however many words), and which
/// of them that check flags again. A word counts as still marked only if
/// a spelling result covers exactly it; anything else (not flagged, or
/// flagged in part) counts as changed, which only means AppKit's pass runs.
public struct MarkedWordsBatch: Equatable, Sendable {
    public let text: String
    /// Each word's range in `text`, in the order given.
    public let ranges: [NSRange]
    public let words: [String]

    /// Words joined by newlines (a word never holds one: it's marked
    /// inside a line).
    public init(_ words: [String]) {
        var text = ""
        var ranges: [NSRange] = []
        for w in words {
            if !ranges.isEmpty { text += "\n" }
            ranges.append(NSRange(location: (text as NSString).length, length: (w as NSString).length))
            text += w
        }
        self.text = text
        self.ranges = ranges
        self.words = words
    }

    /// The words flagged by spelling results at `flagged` (ranges in `text`).
    public func stillMarked(_ flagged: [NSRange]) -> Set<String> {
        let hits = Set(flagged.map { "\($0.location):\($0.length)" })
        var out = Set<String>()
        for (w, r) in zip(words, ranges) where hits.contains("\(r.location):\(r.length)") { out.insert(w) }
        return out
    }
}
