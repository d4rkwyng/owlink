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
///
/// A class so it can own the security scope `resolve()` starts: it is
/// stopped on the same URL instance when that document is forgotten
/// (couldn't be opened, or closed cleanly) or another resolve replaces it.
@MainActor final class LastOpenDocument {
    static let bookmarkKey = "ios.lastOpenDocument.bookmark"
    static let pathKey = "ios.lastOpenDocument.path"

    static let shared = LastOpenDocument(defaults: .standard)

    let defaults: UserDefaults
    /// Starts and stops a URL's security scope (replaced by tests).
    let startAccess: (URL) -> Bool
    let stopAccess: (URL) -> Void

    /// The URL instance `resolve()` started a security scope on, if it did.
    private(set) var scopedURL: URL?

    init(defaults: UserDefaults,
         startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.defaults = defaults
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    /// Whether launch should reopen the last document: never when launch
    /// opens a file of its own (a URL from another app, `-OwlinkOpen`).
    nonisolated static func shouldReopenAtLaunch(openingExplicitFile: Bool, reopenSetting: Bool) -> Bool {
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
    /// iPad window closing one file leaves another window's record). The
    /// scope `resolve()` started ends if it is that document's (another
    /// window's still-open document keeps its own).
    func forget(_ url: URL? = nil) {
        endAccess(url)
        if let url, let stored = storedPath, stored != Self.key(url) { return }
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathKey)
    }

    /// Stops the security scope `resolve()` started, if it is `url`'s (any
    /// with nil). Path-fallback resolves started none, so stop nothing.
    func endAccess(_ url: URL? = nil) {
        guard let scoped = scopedURL else { return }
        if let url, Self.key(url) != Self.key(scoped) { return }
        scopedURL = nil
        stopAccess(scoped)
    }

    /// The document if it is still there (with its security scope
    /// started and owned here until it is forgotten), else nil and the
    /// record is forgotten. Ends the scope of an earlier resolve.
    func resolve() -> URL? {
        endAccess()
        guard let path = storedPath else { return nil }
        if let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let started = startAccess(url)
                if FileManager.default.fileExists(atPath: url.path) {
                    if started { scopedURL = url }
                    if stale { remember(url) }
                    return url
                }
                if started { stopAccess(url) }
            }
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        forget()
        return nil
    }

    nonisolated private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}

/// The launch's one chance to reopen the last document, taken by the first
/// window of the process whatever it opens: a launch that opens a file of
/// its own (or the setting off) means no window reopens one later.
struct LaunchReopenGate {
    private(set) var considered = false

    /// Whether this window reopens the last document. Marks the launch
    /// considered on the first call; later calls are always false.
    mutating func consider(openingExplicitFile: Bool, reopenSetting: Bool) -> Bool {
        guard !considered else { return false }
        considered = true
        return LastOpenDocument.shouldReopenAtLaunch(openingExplicitFile: openingExplicitFile, reopenSetting: reopenSetting)
    }
}
