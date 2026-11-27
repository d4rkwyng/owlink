import Foundation

/// Whether this build may check for updates (Sparkle 2, docs/updates.md),
/// decided from its Info.plist alone.
///
/// Scripts/bundle-app.sh writes `SUFeedURL` and `SUPublicEDKey` from
/// CEDRIC_SPARKLE_FEED_URL and CEDRIC_SPARKLE_PUBLIC_KEY, and both are
/// empty unless those are set when the app is built. Until the feed is an
/// HTTPS URL, the key is an EdDSA (ed25519) public key and the plist asks
/// for a signed feed, the updater is off: Sparkle.framework is never
/// loaded, nothing goes to the network, and Owlink › Check for Updates…
/// is disabled with `tooltip` saying why. A check build (CEDRIC_CHECKS)
/// never turns it on.
public enum UpdateConfig: Equatable, Sendable {
    case enabled(feed: URL, publicKey: String)
    case disabled(Reason)

    public enum Reason: Equatable, Sendable {
        /// A check build (the dev switches are compiled in).
        case checkBuild
        /// SUFeedURL or SUPublicEDKey is empty or missing (the default).
        case notConfigured
        /// SUFeedURL isn't an https:// URL with a host.
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
    /// user-defaults key (it keeps it), false in Info.plist until decided.
    public static let automaticChecksKey = "SUEnableAutomaticChecks"

    public static func from(info: [String: Any]?, checksEnabled: Bool) -> UpdateConfig {
        if checksEnabled { return .disabled(.checkBuild) }
        let feedString = (info?[feedKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (info?[publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedString.isEmpty, !key.isEmpty else { return .disabled(.notConfigured) }
        guard let feed = URL(string: feedString), feed.scheme?.lowercased() == "https",
              let host = feed.host, !host.isEmpty, feed.user == nil, feed.password == nil
        else { return .disabled(.feedNotHTTPS) }
        guard let raw = Data(base64Encoded: key), raw.count == 32 else { return .disabled(.badKey) }
        guard info?[requireSignedFeedKey] as? Bool == true else { return .disabled(.unsignedFeed) }
        return .enabled(feed: feed, publicKey: key)
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
