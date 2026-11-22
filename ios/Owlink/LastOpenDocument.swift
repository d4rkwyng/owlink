import Foundation

/// The document last open in an editor, reopened at launch when Settings ›
/// "Reopen files from last session" is on. One per app, like the Mac's
/// session but with iOS's one document per window: the editor that opened
/// last wins. Kept as a security-scoped bookmark (files from other apps and
/// providers) with the path as a fallback, as `RecoveryRecord` does.
///
/// Remembered when an editor opens a document; forgotten on a clean close
/// (the person went back to the browser). A crash, a forced quit or a
/// window going away leaves it, so the next launch opens it again.
struct LastOpenDocument {
    static let bookmarkKey = "ios.lastOpenDocument.bookmark"
    static let pathKey = "ios.lastOpenDocument.path"

    static let shared = LastOpenDocument(defaults: .standard)

    let defaults: UserDefaults

    /// Whether launch should reopen the last document: never when launch
    /// opens a file of its own (a URL from another app, `-OwlinkOpen`).
    static func shouldReopenAtLaunch(openingExplicitFile: Bool, reopenSetting: Bool) -> Bool {
        !openingExplicitFile && reopenSetting
    }

    var storedPath: String? { defaults.string(forKey: Self.pathKey) }

    func remember(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        } else {
            defaults.removeObject(forKey: Self.bookmarkKey)
        }
        defaults.set(Self.key(url), forKey: Self.pathKey)
    }

    /// Forgets the record, or with `url` only if it is that document (an
    /// iPad window closing one file leaves another window's record).
    func forget(_ url: URL? = nil) {
        if let url, let stored = storedPath, stored != Self.key(url) { return }
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathKey)
    }

    /// The document if it is still there (with its security scope
    /// started), else nil and the record is forgotten.
    func resolve() -> URL? {
        guard let path = storedPath else { return nil }
        if let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: url.path) {
                    if stale { remember(url) }
                    return url
                }
                url.stopAccessingSecurityScopedResource()
            }
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        forget()
        return nil
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
