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
/// nobody has seen AppKit's pass use, or a spelling dictionary that
/// changed since the early check (`SpellDictionaryState`: Ignore, Learn,
/// a language change). The view also clears it before continuous checking
/// is turned off or on (Fix Typos' Ignore All and Learn Word redraw the
/// marks that way), when its context menu opens (Learn, Ignore, Unlearn),
/// on Ignore Spelling, and when the spell checker says a word was learned
/// or unlearned in Owlink (the spelling panel's Learn).
///
/// Learned words are the spell server's, a round trip per word to ask
/// about, so the marked words are asked about at AppKit's pass only when
/// another app could have learned one: when something other than Owlink
/// or the lock screen has been the frontmost app since the early check
/// (`asksLearned`). Words are learned where the user types; while Owlink
/// is in front a word is learned only in Owlink, which clears the record,
/// and while the screen is locked nobody types into any app.
public struct SpellCheckCoverage: Equatable, Sendable {
    /// What the early check covered; nil when there is nothing to skip.
    public private(set) var range: NSRange?
    public private(set) var types: UInt64 = 0
    /// The early check's results have come back.
    public private(set) var answered = false
    /// The spelling dictionary when the early check asked.
    public private(set) var dictionary: SpellDictionaryState?
    /// The words the early check's results marked (to see whether one
    /// has been learned since), each once, in the order first marked:
    /// asking the spell server about one is a round trip
    /// (`hasLearnedWord`), and a page of text marks the same few words
    /// many times over.
    public private(set) var markedWords: [String] = []
    /// Another app may have been in front since the early check, so a word
    /// may have been learned there (nothing tells Owlink): AppKit's pass
    /// asks about the marked words.
    public private(set) var asksLearned = true

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

    /// The early check is about to check `range` for `types`;
    /// `onlyOwlinkInFront`: the frontmost app is Owlink or the lock screen.
    public mutating func checked(_ range: NSRange, types: UInt64, dictionary: SpellDictionaryState, onlyOwlinkInFront: Bool) {
        self.range = range
        self.types = types & Self.publicTypes
        self.dictionary = dictionary
        answered = false
        markedWords = []
        asksLearned = !onlyOwlinkInFront
    }

    /// The marked words AppKit's pass must ask the spell server about
    /// (`hasLearnedWord`): all of them when another app could have learned
    /// one since the early check, none while only Owlink or the lock screen was in front.
    public var wordsToAskLearned: [String] { asksLearned ? markedWords : [] }

    /// Another app came (or may have come) to the front: a word may be learned there.
    public mutating func anotherAppInFront() {
        asksLearned = true
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
        asksLearned = true
    }

    /// AppKit asks to check `request` for `requestTypes`, with options
    /// (`hasOptions`), the dictionary now being `dictionary`. True when the
    /// early check already did all of it (skip the request). Always clears.
    public mutating func take(_ request: NSRange, types requestTypes: UInt64, hasOptions: Bool = false,
                              dictionary now: SpellDictionaryState) -> Bool {
        defer { clear() }
        guard answered, !hasOptions, let range, request.location >= range.location, NSMaxRange(request) <= NSMaxRange(range),
              requestTypes & ~Self.knownTypes == 0, dictionary == now else { return false }
        return requestTypes & Self.publicTypes & ~types == 0
    }
}

/// What the spell checker's answers depend on besides the text: its
/// language (or Automatic by Language), the words ignored in the
/// document, and which of the early check's marked words have since been
/// learned (asked only when `SpellCheckCoverage.asksLearned`). Learning
/// another word can't change the early marks (it wasn't marked);
/// unlearning one is offered by the context menu, which clears the record
/// itself, and by the spelling panel, which the view hears about.
public struct SpellDictionaryState: Equatable, Sendable {
    public var language: String
    public var automaticByLanguage: Bool
    public var ignored: Set<String>
    public var learned: Set<String>

    public init(language: String, automaticByLanguage: Bool, ignored: Set<String>, learned: Set<String> = []) {
        self.language = language
        self.automaticByLanguage = automaticByLanguage
        self.ignored = ignored
        self.learned = learned
    }
}
