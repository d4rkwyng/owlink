import Foundation

/// Cedric's version. `source` is the one place it is written down:
/// Scripts/bundle-app.sh reads it into Info.plist (unless CEDRIC_VERSION
/// overrides it), and Scripts/release.sh refuses to sign a build whose
/// Info.plist, CEDRIC_VERSION or tag says anything else.
public enum CedricVersion {
    /// This tree's version.
    public static let source = "0.5.0"

    /// Inside "Owlink.app", the bundle's CFBundleShortVersionString (what
    /// About shows); elsewhere (tests, `swift run`) `source`. A release's
    /// plist is required to equal `source`, so shipped builds get the same
    /// string either way.
    public static let string: String = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)

    /// The rule behind `string`: Cedric's own bundle (net.mindtricks.cedric)
    /// with a non-empty short version uses it.
    public static func resolve(bundleIdentifier: String?, shortVersion: String?) -> String {
        guard bundleIdentifier == "net.mindtricks.cedric",
              let v = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty
        else { return source }
        return v
    }
}
