import Foundation

/// What Owlink › About Owlink and the Help menu show, after Tankard's
/// `AboutInfo` (0.2.1): "Version X" with no build number, the author, the
/// repository, the licence, the third-party credits, the copyright.
public enum AboutInfo {
    public static let repository = URL(string: "https://github.com/d4rkwyng/owlink")!
    public static let newIssue = URL(string: "https://github.com/d4rkwyng/owlink/issues/new")!
    public static let llamaCpp = URL(string: "https://github.com/ggml-org/llama.cpp")!

    /// Help › Owlink Help: the manual of this version, so it describes the
    /// app the user has, not what main has changed since.
    public static var help: URL { help(version: CedricVersion.string) }

    /// The manual at the release tag `v<version>` for a release version
    /// ("0.2.1", "0.2.1-rc1"); main for anything else (a dev build, an
    /// empty or unknown version), where no tag can be assumed to exist.
    public static func help(version: String) -> URL {
        let ref = isReleaseVersion(version) ? "v" + version : "main"
        return URL(string: repository.absoluteString + "/blob/\(ref)/docs/MANUAL.md")!
    }

    /// "1.2.3" or "1.2.3-rc1": digits, then at most an `-rcN` suffix.
    static func isReleaseVersion(_ v: String) -> Bool {
        v.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/) != nil
    }

    public static let author = String(localized: "Made by d4rkwyng")
    public static let licence = keepTogether(String(localized: "BSD-2-Clause license"))
    public static let llamaCredit = String(localized: "Built-in AI runs on llama.cpp (MIT license).")
    public static let modelsCredit = String(localized: "AI models are downloaded on request, each under its own license.")
    /// Cedric the owl, honestly and briefly: a fan's nod, nothing official.
    public static let tribute = String(localized: "Cedric the owl is a fan’s tribute. Owlink is not affiliated with or endorsed by Sierra or its successors.")
    /// In the owner's name, as Tankard's; LICENSE keeps "Cedric contributors".
    public static let copyright = "© 2026 d4rkwyng"

    /// A word joiner (U+2060) after each hyphen of the licence name forbids
    /// a line break there ("BSD-2-" / "Clause") and draws nothing.
    public static func keepTogether(_ s: String) -> String {
        s.replacingOccurrences(of: "BSD-2-Clause", with: "BSD-\u{2060}2-\u{2060}Clause")
    }

    /// The version alone ("0.2.1"): short, else build, else CedricVersion.
    public static func versionString(short: String?, build: String?) -> String {
        (short?.isEmpty == false ? short : nil) ?? (build?.isEmpty == false ? build : nil) ?? CedricVersion.string
    }

    /// The panel's application-version slot ("0.2.1", shown as "Version
    /// 0.2.1") and build slot (always empty, so AppKit adds no "(N)").
    public static func panelVersions(bundle: [String: Any]?) -> (application: String, build: String) {
        (versionString(short: bundle?["CFBundleShortVersionString"] as? String, build: bundle?["CFBundleVersion"] as? String), "")
    }
}
