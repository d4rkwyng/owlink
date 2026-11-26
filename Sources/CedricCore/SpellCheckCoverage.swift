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
/// record, and so does any edit. Every later pass (scrolling, typing,
/// Learn or Ignore, a language change, Check Document Now) is AppKit's own.
public struct SpellCheckCoverage: Equatable, Sendable {
    /// What the early check covered; nil when there is nothing to skip.
    public private(set) var range: NSRange?
    public private(set) var types: UInt64 = 0
    /// The early check's results have come back.
    public private(set) var answered = false

    public init() {}

    /// The public NSTextCheckingType bits (orthography through transit
    /// information). AppKit's own private bits above them differ between
    /// a view's enabled types and its scheduled pass, so they aren't
    /// compared.
    public static let publicTypes: UInt64 = (1 << 13) - 1

    /// Correction: AppKit's scheduled pass asks for it even with automatic
    /// correction off, so the early check asks for it too.
    public static let correction: UInt64 = 1 << 9

    /// The types the early check asks for: the view's enabled public types,
    /// plus correction, as AppKit's scheduled pass does.
    public static func earlyTypes(enabled: UInt64) -> UInt64 {
        (enabled & publicTypes) | correction
    }

    public var isEmpty: Bool { range == nil }

    /// The early check is about to check `range` for `types`.
    public mutating func checked(_ range: NSRange, types: UInt64) {
        self.range = range
        self.types = types & Self.publicTypes
        answered = false
    }

    /// Results came back for `checked`: if that is the early check's range,
    /// it is done.
    public mutating func resultsArrived(for checked: NSRange) {
        if let range, NSEqualRanges(range, checked) { answered = true }
    }

    /// An edit, a setting change: nothing is known to be checked any more.
    public mutating func clear() {
        range = nil
        types = 0
        answered = false
    }

    /// AppKit asks to check `request` for `requestTypes`. True when the
    /// early check already did all of it (skip the request). Always clears.
    public mutating func take(_ request: NSRange, types requestTypes: UInt64) -> Bool {
        defer { clear() }
        guard answered, let range, request.location >= range.location, NSMaxRange(request) <= NSMaxRange(range) else { return false }
        return requestTypes & Self.publicTypes & ~types == 0
    }
}
