import Foundation

/// The isolation the app checks that open Settings › Cedric need before they
/// build the pane or touch the built-in downloads (CEDRIC_CHECK=settings,
/// CEDRIC_BUILTIN_CHECK): the AI settings in a UserDefaults suite of their
/// own (CEDRIC_AI_DEFAULTS, never the app's standard domain), and the
/// models in a folder of their own (CEDRIC_MODELS_DIR, an existing folder
/// outside ~/Library, so never Application Support/Cedric/Models). Without
/// both, a check's clicks could save over the user's model choice or
/// download and delete the user's models.
public enum CheckIsolation {
    /// Why this run is not isolated, or nil when it is. `standardDomains`:
    /// the suite names that are the app's own defaults (its bundle ID and
    /// process name, the global domain).
    public static func problem(_ env: [String: String] = DevEnvironment.values,
                               home: String = NSHomeDirectory(),
                               standardDomains: Set<String> = defaultStandardDomains) -> String? {
        let suite = env["CEDRIC_AI_DEFAULTS"] ?? ""
        if suite.isEmpty { return "CEDRIC_AI_DEFAULTS is not set (the AI settings would be the user's own)" }
        if standardDomains.contains(suite) || UserDefaults(suiteName: suite) == nil {
            return "CEDRIC_AI_DEFAULTS=\(suite) is the app's standard defaults domain"
        }
        let dir = env["CEDRIC_MODELS_DIR"] ?? ""
        if dir.isEmpty { return "CEDRIC_MODELS_DIR is not set (the models folder would be the user's own)" }
        guard dir.hasPrefix("/") else { return "CEDRIC_MODELS_DIR=\(dir) is not an absolute path" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "CEDRIC_MODELS_DIR=\(dir) is not an existing folder"
        }
        let path = resolved(dir)
        let library = resolved((home as NSString).appendingPathComponent("Library"))
        if path == library || path.hasPrefix(library + "/") || path.contains("/Application Support/Cedric") {
            return "CEDRIC_MODELS_DIR=\(dir) is inside ~/Library"
        }
        return nil
    }

    public static var defaultStandardDomains: Set<String> {
        Set([Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processName, "NSGlobalDomain", ".GlobalPreferences"]
            .compactMap { $0 }.filter { !$0.isEmpty })
    }

    private static func resolved(_ p: String) -> String {
        URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
