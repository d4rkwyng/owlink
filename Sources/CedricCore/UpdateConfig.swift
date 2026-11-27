import Foundation

/// Whether this build may check for updates (Sparkle 2, docs/updates.md),
/// decided from its Info.plist alone.
///
/// Scripts/bundle-app.sh writes Owlink's committed `SUFeedURL`
/// (https://owlink.app/appcast.xml) and `SUPublicEDKey` (Scripts/sparkle-defaults.sh)
/// into every build, unless CEDRIC_SPARKLE_FEED_URL / CEDRIC_SPARKLE_PUBLIC_KEY
/// override them, so a release build is `.enabled`. A check build
/// (CEDRIC_CHECKS) is always `.disabled(.checkBuild)`, whatever its plist
/// says: it never loads Sparkle. Otherwise the updater stays off (Sparkle is
/// never loaded, nothing goes to the network, and Owlink › Check for
/// Updates… is disabled with `tooltip` saying why) unless the feed is an
/// https:// URL with a host, the key is an EdDSA (ed25519) public key and
/// the plist asks for a signed feed.
///
/// One exception to https: a loopback http:// feed (host exactly
/// `127.0.0.1` or `localhost`, any port, no user or password), for a local
/// end-to-end update test against a feed served on this Mac. It reaches
/// nothing off the machine, and Sparkle still requires the signed feed and
/// EdDSA-signed updates; release.sh refuses any feed but https://.
public enum UpdateConfig: Equatable, Sendable {
    case enabled(feed: URL, publicKey: String)
    case disabled(Reason)

    public enum Reason: Equatable, Sendable {
        /// A check build (the dev switches are compiled in).
        case checkBuild
        /// SUFeedURL or SUPublicEDKey is empty or missing (a hand-edited
        /// plist; bundle-app.sh always writes both).
        case notConfigured
        /// SUFeedURL isn't an https:// URL with a host (or a loopback
        /// http:// one, see above).
        case feedNotHTTPS
        /// SUPublicEDKey isn't base64 for 32 bytes.
        case badKey
        /// SURequireSignedFeed isn't true.
        case unsignedFeed
        /// The app has no Sparkle.framework, or it wouldn't load (decided by the app).
        case frameworkMissing
    }

    /// Info.plist keys (Sparkle's names).
    public static let feedKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    public static let requireSignedFeedKey = "SURequireSignedFeed"
    /// Settings › General › Automatically check for updates: Sparkle's own
    /// user-defaults key (it keeps it). Info.plist sets it true, the
    /// default until the user turns checks off.
    public static let automaticChecksKey = "SUEnableAutomaticChecks"

    public static func from(info: [String: Any]?, checksEnabled: Bool) -> UpdateConfig {
        if checksEnabled { return .disabled(.checkBuild) }
        let feedString = (info?[feedKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (info?[publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedString.isEmpty, !key.isEmpty else { return .disabled(.notConfigured) }
        guard let feed = URL(string: feedString), let host = feed.host, !host.isEmpty,
              feed.user == nil, feed.password == nil,
              feed.scheme?.lowercased() == "https" || isLoopbackHTTP(feed)
        else { return .disabled(.feedNotHTTPS) }
        guard let raw = Data(base64Encoded: key), raw.count == 32 else { return .disabled(.badKey) }
        guard info?[requireSignedFeedKey] as? Bool == true else { return .disabled(.unsignedFeed) }
        return .enabled(feed: feed, publicKey: key)
    }

    /// http://127.0.0.1 or http://localhost (any port): the local-test
    /// exception above. No other host, not even another loopback address.
    static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    /// Check for Updates…'s tooltip while it is disabled (nil when enabled).
    public var tooltip: String? {
        guard case .disabled(let reason) = self else { return nil }
        switch reason {
        case .checkBuild: return String(localized: "Updates are off in this development build.")
        case .notConfigured: return String(localized: "Updates aren’t set up for this build yet. Install new versions from GitHub or with Homebrew.")
        case .feedNotHTTPS: return String(localized: "Updates are off: this build’s update feed isn’t an HTTPS address.")
        case .badKey: return String(localized: "Updates are off: this build’s update signing key isn’t valid.")
        case .unsignedFeed: return String(localized: "Updates are off: this build doesn’t require a signed update feed.")
        case .frameworkMissing: return String(localized: "Updates are off: this build doesn’t include the updater.")
        }
    }
}
