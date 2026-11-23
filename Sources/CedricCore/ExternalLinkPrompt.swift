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

/// What the "Open this link?" prompt shows for `url` (0.5.2 S1 security
/// read), all made visible with `PromptText.visible`:
///
/// - `host`: the site the link really goes to, for a line of its own, so
///   `https://www.apple.com%2Fsignin@evil.example/` reads as evil.example.
///   It is the host as the URL that opens spells it: a non-ASCII name is
///   its punycode (`xn--pple-43d.com`), never the Unicode look-alike
///   (`аpple.com`, Cyrillic а), so a homograph can't pass as the real site;
/// - `unicodeHost`: the name as Unicode, only when the host is not plain
///   ASCII letters, digits, `-` and `.` read as written (a punycode label,
///   a percent escape, non-ASCII), so the prompt can flag it;
/// - `userinfo`: the user name (and password) before the `@`, when the
///   link has one, so the prompt can say it is not the site;
/// - `url`: the whole URL, or for a long one the URL cut in the middle
///   (`…`): the scheme, the host and its port are always kept whole, a
///   long user name is cut, and the path, query and fragment share what
///   is left, their start and their end.
public struct ExternalLinkText: Equatable, Sendable {
    public let host: String?
    public let unicodeHost: String?
    public let userinfo: String?
    public let url: String

    /// Longest URL shown whole, and longest user name.
    public static let maxURL = 160
    public static let maxUserinfo = 32

    public init(_ url: URL, maxURL: Int = Self.maxURL) {
        let raw = url.absoluteString
        let c = URLComponents(string: raw)
        // The host as written in the URL that opens (Foundation's
        // `absoluteString` spells an IDN host in punycode), not
        // `URLComponents.host`, which decodes it to Unicode.
        let written = c?.rangeOfHost.map { String(raw[$0]) }.flatMap { $0.isEmpty ? nil : $0 }
        host = written.map { PromptText.visible($0) }
        unicodeHost = written.flatMap { w in
            let plain = w.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.[]:".unicodeScalars.contains($0)) }
            let puny = w.lowercased().split(separator: ".").contains { $0.hasPrefix("xn--") }
            guard !plain || puny else { return nil }
            let decoded = c?.host ?? w.removingPercentEncoding ?? w
            return PromptText.visible(decoded)
        }
        var user: Substring?
        if let c, let u = c.rangeOfUser {
            user = raw[u.lowerBound..<(c.rangeOfPassword?.upperBound ?? u.upperBound)]
        }
        userinfo = user.map { u in
            let decoded = u.removingPercentEncoding.map { $0[...] } ?? u
            return PromptText.visible(Self.middle(decoded, Self.maxUserinfo))
        }
        self.url = PromptText.visible(Self.shortened(raw, c, maxURL: maxURL))
    }

    static func shortened(_ raw: String, _ c: URLComponents?, maxURL: Int) -> String {
        guard raw.count > maxURL else { return raw }
        guard let c, let h = c.rangeOfHost else { return middle(raw[...], maxURL) }
        // The head: scheme://[user@]host[:port], with a long user name cut.
        let authorityEnd = c.rangeOfPort?.upperBound ?? h.upperBound
        var head = String(raw[..<authorityEnd])
        if let u = c.rangeOfUser {
            let userEnd = c.rangeOfPassword?.upperBound ?? u.upperBound
            head = String(raw[..<u.lowerBound]) + middle(raw[u.lowerBound..<userEnd], maxUserinfo) + String(raw[userEnd..<authorityEnd])
        }
        let rest = raw[authorityEnd...]
        return head + middle(rest, max(maxURL - head.count, 24))
    }

    /// `s`, cut to `n` characters in the middle with `…`.
    static func middle(_ s: Substring, _ n: Int) -> String {
        guard s.count > n, n > 2 else { return String(s) }
        let keep = n - 1
        return String(s.prefix(keep - keep / 2)) + "…" + String(s.suffix(keep / 2))
    }
}
