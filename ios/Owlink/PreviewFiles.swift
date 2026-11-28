import Foundation
import WebKit
import UniformTypeIdentifiers
import CedricCore

/// Serves the preview's `cedric-doc:` URLs from disk, in the app's own
/// process (which holds the security-scoped access to the document and any
/// folder the person granted): the document's folder, a site-root path
/// (`/images/x.webp`) found by `PreviewRoot`, and the Obsidian vault for
/// `![[embeds]]`. The page runs no script, so nothing else can ask.
@MainActor
final class PreviewFiles: NSObject, WKURLSchemeHandler {
    var folder: URL?
    var openedRoot: URL?
    var vaultRoot: URL?
    var vault: WikiVault?
    /// The rendered page, served at `pageURL` so the document's origin is
    /// `cedric-doc` (see `PreviewScheme`). Nil until a preview has rendered.
    var pageHTML: String?
    var pageURL: URL?
    private var stopped: Set<ObjectIdentifier> = []
    /// Links to these open in Owlink.
    static let notes: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // The page itself, not a file: generated HTML, already in hand.
        if let pageURL, let pageHTML, PreviewScheme.isPageRequest(url, page: pageURL) {
            guard !stopped.contains(id) else { stopped.remove(id); return }
            let data = Data(pageHTML.utf8)
            task.didReceive(Self.response(url: url, data: data, mime: PreviewScheme.htmlMIME))
            task.didReceive(data)
            task.didFinish()
            return
        }
        guard let folder else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        // Resolving can walk the vault (a bare-name image), so it runs off
        // the main thread with the roots captured now; only the task calls
        // and `stopped` stay on main.
        let openedRoot = openedRoot, vaultRoot = vaultRoot, vault = vault
        let box = PreviewTaskBox(task)
        DispatchQueue.global(qos: .userInitiated).async {
            let file = PreviewFolder.file(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, scriptOn: false, vault: vault)
            let data = file.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            let ext = file?.pathExtension ?? ""
            let mime = PreviewScheme.mimeType(forExtension: ext)
                ?? UTType(filenameExtension: ext)?.preferredMIMEType
                ?? "application/octet-stream"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let task = box.task
                    guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
                    guard file != nil else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
                    guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
                    task.didReceive(Self.response(url: url, data: data, mime: mime))
                    task.didReceive(data)
                    task.didFinish()
                }
            }
        }
    }

    /// An HTTP response. A plain `URLResponse` has no status, and iOS
    /// WebKit then does not paint the image.
    private static func response(url: URL, data: Data, mime: String) -> URLResponse {
        let fields = PreviewScheme.responseFields(mimeType: mime, byteCount: data.count)
        let headers = [
            "Content-Type": fields.mimeType,
            "Content-Length": String(fields.contentLength),
            "Cache-Control": fields.cacheControl,
        ]
        return HTTPURLResponse(url: url, statusCode: fields.status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    func file(for url: URL) -> URL? {
        guard let folder else { return nil }
        return PreviewFolder.file(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, scriptOn: false, vault: vault)
    }

    /// A clicked link's file, when its resolved path sits under the
    /// document's folder, a granted folder, the vault or the site root
    /// it resolved in. Anything else is refused (nil).
    func linkTarget(_ url: URL) -> URL? {
        guard let folder else { return nil }
        return PreviewFolder.linkTarget(url, folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot)
    }

    /// The root a link's file (from `linkTarget`) may open in: the vault,
    /// the granted folder or the document's folder, whichever holds it.
    func linkFolder(_ file: URL) -> URL? {
        let path = file.standardizedFileURL.path
        for root in [vaultRoot, openedRoot, folder].compactMap({ $0 }) {
            let r = root.standardizedFileURL.path
            if path.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return root }
        }
        return folder
    }
}

private final class PreviewTaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    init(_ task: any WKURLSchemeTask) { self.task = task }
}

/// Folders the person let the preview read (from the "Open the folder"
/// hint, and the Backlinks and Insert Image folder pickers), kept as
/// bookmarks so the grant outlives the launch. A folder covers every
/// document inside it. Each resolved path is stored once, and its security
/// scope is started once while its bookmark is kept: a start that failed is
/// not remembered (the next `add` tries again), and a folder whose bookmark
/// falls out of the kept list (`maxKept`) has its access stopped.
@MainActor
final class PreviewFolderGrants {
    static let shared = PreviewFolderGrants()
    private static let key = "previewFolderGrants"
    /// Bookmarks kept (the oldest dropped first).
    static let maxKept = 20
    private var open: [URL] = []
    private var loaded = false
    /// One start and one bookmark per resolved path (see PreviewGrantSet).
    private var grants = PreviewGrantSet()
    /// The URL each started scope was started on (stopped on the same one).
    private var startedURLs: [String: URL] = [:]
    /// Each kept folder as it was when granted (device and inode, by its
    /// resolved path): what is opened beneath it must still be that folder.
    private var ids: [String: Beneath.FileID] = [:]
    /// Where the bookmarks are kept (tests: a suite of their own).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppSettings.defaults) {
        self.defaults = defaults
    }

    /// The granted folder holding `folder` (the nearest), access started.
    func root(for folder: URL) -> URL? {
        loadIfNeeded()
        let path = folder.standardizedFileURL.path + "/"
        return open.filter { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Keeps `url` as a grant. False when Owlink still can't read it (its
    /// security scope didn't start and it isn't readable without one).
    @discardableResult
    func add(_ url: URL) -> Bool {
        loadIfNeeded()
        let path = PreviewGrantSet.resolvedPath(url)
        // Bookmarks that fell out are let go once `apply` is done with
        // `grants` (forgetting changes it too).
        var dropped: [String] = []
        grants.apply(url, start: { self.start($0) }, store: { url in
            guard let out = self.storeBookmark(url) else { return false }
            dropped = out
            return true
        })
        for old in dropped { forget(old) }
        guard grants.started.contains(path) || FileManager.default.isReadableFile(atPath: url.path) else { return false }
        adopt(url)
        return true
    }

    private func start(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        startedURLs[PreviewGrantSet.resolvedPath(url)] = url
        return true
    }

    /// Keeps `url` if its resolved path is not already open.
    private func adopt(_ url: URL) {
        let path = PreviewGrantSet.resolvedPath(url)
        guard !open.contains(where: { PreviewGrantSet.resolvedPath($0) == path }) else { return }
        open.append(url.standardizedFileURL)
        ids[path] = Beneath.FileID(path: path, followLast: false)
    }

    /// The granted folder `root` (compared resolved) as it was when it was
    /// granted; nil when `root` isn't one of the kept grants.
    func identity(of root: URL) -> Beneath.FileID? {
        loadIfNeeded()
        return ids[PreviewGrantSet.resolvedPath(root)]
    }

    /// Appends one bookmark, unless the same resolved path is already stored.
    /// The caller (`PreviewGrantSet`) has already decided it is new. Past
    /// `maxKept`, the oldest bookmarks are dropped: their resolved paths
    /// are returned, for the caller to let go (nil: nothing stored).
    private func storeBookmark(_ url: URL) -> [String]? {
        guard let b = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        var saved = savedBookmarks
        saved.append(b)
        let dropped = saved.dropLast(Self.maxKept)
        defaults.set(Array(saved.suffix(Self.maxKept)), forKey: Self.key)
        let keep = PreviewGrantSet.resolvedPath(url)
        var out: [String] = []
        for data in dropped {
            var stale = false
            guard let old = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let path = PreviewGrantSet.resolvedPath(old)
            guard path != keep else { continue }
            out.append(path)
        }
        return out
    }

    /// `path`'s grant is no longer kept: not offered again, its access stopped.
    private func forget(_ path: String) {
        if grants.forget(path), let url = startedURLs.removeValue(forKey: path) {
            url.stopAccessingSecurityScopedResource()
        }
        open.removeAll { PreviewGrantSet.resolvedPath($0) == path }
        ids[path] = nil
    }

    private var savedBookmarks: [Data] {
        (defaults.array(forKey: Self.key) as? [Data]) ?? []
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let saved = savedBookmarks
        var kept: [Data] = []
        var changed = false
        for data in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                kept.append(data)
                continue
            }
            let count = grants.stored.count
            grants.apply(url, start: { self.start($0) }, store: { _ in true })
            let path = PreviewGrantSet.resolvedPath(url)
            if grants.started.contains(path) || FileManager.default.isReadableFile(atPath: url.path) { adopt(url) }
            if grants.stored.count == count {
                changed = true
            } else {
                kept.append(data)
            }
        }
        if changed { defaults.set(kept, forKey: Self.key) }
    }
}
