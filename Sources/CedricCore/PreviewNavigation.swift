import Foundation

/// What the Markdown/HTML preview's web view does with a navigation
/// (0.5.2 S1). The preview only ever shows Cedric's own page, loaded with
/// `loadHTMLString` at a `cedric-doc:` (or `about:blank`) base URL; the
/// JavaScript and Network settings are applied to that page. So:
///
/// - the main-frame load of that page, while Cedric is loading it, is
///   allowed, and nothing else that isn't a click;
/// - a clicked link to a `#place` in the page itself stays in the page;
/// - any other clicked link (`target=_blank` too) is cancelled and decided
///   by `PreviewLinkAction`, which asks before a web page opens in the
///   browser: a web page never loads in the preview;
/// - everything else is cancelled: redirects, meta refresh, `location =`
///   from page script, form submits, frames and iframes, new windows, and
///   any scheme but the page's own.
///
/// Images, styles and fonts are subresources, not navigations: the
/// Network setting (content rule list and CSP) governs those.
public enum PreviewNavigation: Equatable, Sendable {
    /// Cedric's own page load.
    case allowPage
    /// A link to a place in the page: WebKit's navigation is cancelled and
    /// Cedric scrolls to the place itself (no document load, either spelling).
    case scrollInPage
    /// A clicked link elsewhere: cancelled, then routed by `PreviewLinkAction`.
    case route
    /// Cancelled.
    case cancel

    /// The schemes the preview's own page may have. Anything else (http,
    /// https, file, data, blob, javascript, an unknown scheme) is never
    /// shown in the preview.
    public static let pageSchemes: Set<String> = [PreviewFolder.scheme, "about"]

    /// - Parameters:
    ///   - url: the request's URL.
    ///   - linkClick: WebKit calls it `.linkActivated` (a click, or page script's `a.click()`).
    ///   - mainFrame: `targetFrame?.isMainFrame`: nil for a new window.
    ///   - page: the page now shown (`webView.url`).
    ///   - expectedPage: the base URL of the page Cedric is loading.
    ///   - loadingShell: Cedric is loading its page now.
    public static func decide(url: URL?, linkClick: Bool, mainFrame: Bool?, page: URL?,
                              expectedPage: URL?, loadingShell: Bool) -> PreviewNavigation {
        guard let url else { return .cancel }
        if linkClick {
            // In the page: the main frame only. What WebKit hands over for a
            // click on `#x` is not the same on every macOS: `about:blank#x`
            // on macOS 26, `about:blank%23x` on macOS 15 (its Foundation
            // keeps an `about:` URL's `#` in the path). So for the blank
            // page alone, `%23` is read as the `#` (`split`), and only when
            // the page shown is the blank page too. Either way the caller
            // cancels WebKit's navigation and scrolls in Cedric's own world:
            // neither spelling can load another document (a literal
            // `about:blank%23x` href would otherwise blank the page).
            guard mainFrame == true, isPageScheme(url), samePage(url, page) else { return .route }
            if !url.absoluteString.contains("#") {
                guard let page, split(page).page == "about:blank", split(url).page == "about:blank" else { return .route }
            }
            return .scrollInPage
        }
        guard loadingShell, mainFrame == true, isPageScheme(url), let expectedPage, url == expectedPage else { return .cancel }
        return .allowPage
    }

    /// A navigation response is let through only for the preview's own
    /// page in the main frame (a second line behind `decide`).
    public static func allowsResponse(url: URL?, mainFrame: Bool) -> Bool {
        guard mainFrame, let url else { return false }
        return isPageScheme(url)
    }

    static func isPageScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), pageSchemes.contains(scheme) else { return false }
        // `about:` only as the blank page an untitled document is shown at.
        return scheme != "about" || url.absoluteString.lowercased().hasPrefix("about:blank")
    }

    /// Whether `url` is the page itself plus a fragment (an in-page link).
    public static func samePage(_ url: URL, _ page: URL?) -> Bool {
        let target = split(url)
        guard target.fragment != nil else { return false }
        guard let page else { return target.page == "about:blank" }
        return target.page == split(page).page
    }

    /// `url` as written, split at its first `#` into the page and the raw
    /// (still percent-encoded) fragment, the same on every macOS: macOS 26
    /// Foundation parses `about:blank#x` with a fragment, but macOS 15's
    /// `URL(string:)` keeps the `#` of an `about:` URL in the path as
    /// `about:blank%23x` (no fragment). That `%23` is read as the `#` only
    /// for `about:`, where no page has a `#` in its name; any other URL's
    /// `%23` stays part of its path.
    public static func split(_ url: URL) -> (page: String, fragment: String?) {
        let s = url.absoluteString
        let about = url.scheme?.lowercased() == "about"
        // An `about:` page's name is case-insensitive (`ABOUT:BLANK`).
        func page(_ p: Substring) -> String { about ? p.lowercased() : String(p) }
        if let i = s.firstIndex(of: "#") { return (page(s[..<i]), String(s[s.index(after: i)...])) }
        if about, let r = s.range(of: "%23", options: .caseInsensitive) {
            return (page(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }
        return (page(s[...]), nil)
    }
}
