import Foundation

/// Cedric's version. `source` is the one place it is written down:
/// Scripts/bundle-app.sh reads it into Info.plist (unless CEDRIC_VERSION
/// overrides it), and Scripts/release.sh refuses to sign a build whose
/// Info.plist, CEDRIC_VERSION or tag says anything else.
public enum CedricVersion {
    /// This tree's version.
    public static let source = "0.5.2"

    /// Inside "Owlink.app", the bundle's CFBundleShortVersionString (what
    /// About shows); elsewhere (tests, `swift run`) `source`. A release's
    /// plist is required to equal `source`, so shipped builds get the same
    /// string either way.
    public static let string: String = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)

    /// The apps that carry their own version: the Mac app and the iOS app.
    public static let appBundleIdentifiers: Set<String> = ["net.mindtricks.cedric", "app.owlink.ios"]

    /// The rule behind `string`: one of Cedric's own app bundles (the Mac's
    /// net.mindtricks.cedric, the iOS app's app.owlink.ios) with a non-empty
    /// short version uses it. The marketing version only, never the build.
    public static func resolve(bundleIdentifier: String?, shortVersion: String?) -> String {
        guard let id = bundleIdentifier, appBundleIdentifiers.contains(id),
              let v = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty
        else { return source }
        return v
    }
}
