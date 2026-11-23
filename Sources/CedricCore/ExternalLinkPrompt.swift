import Foundation

/// Whether the preview may ask "Open this link?" again (0.5.2 S1 security
/// read). With page JavaScript on, script can "click" a link whenever it
/// likes (WebKit reports `a.click()` as a link click), so a page could put
/// the prompt straight back after every Cancel, each time with a new URL.
/// Once the user says Cancel to a page that can run script, that page load
/// asks nothing more: every further web or mail link from it is dropped.
/// A new load (an edit, Refresh, a toggle, navigating) asks again. With
/// JavaScript off only the user can click, so every click asks.
public struct ExternalLinkGate: Equatable, Sendable {
    /// The page load the user said Cancel to (while script could click).
    public private(set) var declinedLoad: Int?

    public init() {}

    /// Whether a link from page load `load` may ask.
    public func asks(load: Int, scriptCanClick: Bool) -> Bool {
        !(scriptCanClick && declinedLoad == load)
    }

    /// The user answered a prompt asked from page load `load`.
    public mutating func answered(opened: Bool, load: Int, scriptCanClick: Bool) {
        if !opened && scriptCanClick { declinedLoad = load }
    }
}
