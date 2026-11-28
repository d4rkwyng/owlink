import Foundation

/// Whether this process can actually read the document's folder.
///
/// A directory listing is not enough. Files and iCloud often list a parent
/// the app was not granted (the security scope is the file alone): the
/// listing succeeds, then every sibling read fails, and the preview would
/// keep broken images and hide the "Open the folder" hint. `canRead` is
/// true only when a sibling file can be opened, or — when the folder holds
/// nothing but the document — when a fresh path URL of that document opens
/// (a sandbox path). A file-only security scope does not count.
public enum PreviewFolderAccess {
    public struct Facts: Equatable, Sendable {
        /// `contentsOfDirectory` failed. Not access.
        public var listingFailed: Bool
        /// Entries beside the document, dotfiles excluded.
        public var siblingCount: Int
        /// At least one of those siblings (or a file one or two levels down,
        /// such as `images/logo.webp`) opened for reading.
        public var anySiblingReadable: Bool
        /// The document itself opened via a fresh path URL, not via the
        /// security-scoped URL it was opened with. Used only when there are
        /// no siblings: a lone file in a sandbox is readable; a lone file
        /// from Files is not, once the scope is left behind.
        public var documentReadableAtPath: Bool

        public init(listingFailed: Bool, siblingCount: Int, anySiblingReadable: Bool, documentReadableAtPath: Bool) {
            self.listingFailed = listingFailed
            self.siblingCount = siblingCount
            self.anySiblingReadable = anySiblingReadable
            self.documentReadableAtPath = documentReadableAtPath
        }
    }

    public static func canRead(_ facts: Facts) -> Bool {
        if facts.listingFailed { return false }
        if facts.siblingCount > 0 { return facts.anySiblingReadable }
        return facts.documentReadableAtPath
    }

    /// Probes `folder` from this process. Stops at the first file that
    /// actually opens; does not read the file's bytes.
    public static func facts(folder: URL, document: URL, fileManager fm: FileManager = .default) -> Facts {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else {
            return Facts(listingFailed: true, siblingCount: 0, anySiblingReadable: false, documentReadableAtPath: false)
        }
        let docPath = document.standardizedFileURL.path
        let siblings = names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            return folder.appendingPathComponent(name).standardizedFileURL.path != docPath
        }
        if siblings.isEmpty {
            return Facts(listingFailed: false, siblingCount: 0, anySiblingReadable: false,
                         documentReadableAtPath: canOpen(URL(fileURLWithPath: document.path)))
        }
        var budget = 24
        let readable = siblings.contains { name in
            guard budget > 0 else { return false }
            return opens(folder.appendingPathComponent(name), depth: 2, budget: &budget, fileManager: fm)
        }
        return Facts(listingFailed: false, siblingCount: siblings.count, anySiblingReadable: readable,
                     documentReadableAtPath: false)
    }

    /// A file opens, or a directory has a file that opens within `depth`
    /// more levels (`images/set/card.webp` is two levels under the folder).
    private static func opens(_ url: URL, depth: Int, budget: inout Int, fileManager fm: FileManager) -> Bool {
        guard budget > 0 else { return false }
        budget -= 1
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            guard depth > 0, let names = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
            for name in names where !name.hasPrefix(".") {
                if opens(url.appendingPathComponent(name), depth: depth - 1, budget: &budget, fileManager: fm) { return true }
                if budget <= 0 { return false }
            }
            return false
        }
        return canOpen(url)
    }

    private static func canOpen(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }
}

/// Folder grants the iOS preview keeps. One bookmark per resolved path,
/// and one security-scoped start per resolved path for this value's
/// lifetime (one app launch). `apply` decides before anything is started
/// or stored, so a duplicate never starts access and never adds a bookmark.
public struct PreviewGrantSet: Equatable, Sendable {
    public struct Decision: Equatable, Sendable {
        /// Call `startAccessingSecurityScopedResource`. False when this
        /// resolved path was already started.
        public var start: Bool
        /// Write a bookmark. False when this resolved path is already stored.
        public var store: Bool

        public init(start: Bool, store: Bool) {
            self.start = start
            self.store = store
        }
    }

    /// Resolved paths already stored, oldest first.
    public private(set) var stored: [String]
    /// Resolved paths whose security scope has already been started.
    public private(set) var started: Set<String>

    public init() {
        stored = []
        started = []
    }

    /// The path grants are compared by, with symbolic links resolved.
    public static func resolvedPath(_ url: URL) -> String {
        var path = PreviewFolder.resolved(url.standardizedFileURL).standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// What to do with `url`, before starting access or storing a bookmark.
    public func decide(_ url: URL) -> Decision {
        let path = Self.resolvedPath(url)
        return Decision(start: !started.contains(path), store: !stored.contains(path))
    }

    /// Starts access at most once and stores at most one bookmark per
    /// resolved path. `start` is skipped when this path was already
    /// started; `store` is skipped when it is already stored. A `false`
    /// from `store` leaves the path unstored, so a later call can try the
    /// bookmark again without starting access a second time.
    ///
    /// `start` returns whether access started: only a start that worked is
    /// remembered, so a failed one is tried again by the next `apply`.
    public mutating func apply(_ url: URL, start: (URL) -> Bool, store: (URL) -> Bool) {
        let decision = decide(url)
        if decision.start, start(url) {
            started.insert(Self.resolvedPath(url))
        }
        if decision.store, store(url) {
            let path = Self.resolvedPath(url)
            if !stored.contains(path) { stored.append(path) }
        }
    }

    /// `path` (a resolved path) is no longer kept: its bookmark fell out of
    /// the stored list. Returns whether its access had been started (the
    /// caller then stops it).
    @discardableResult
    public mutating func forget(_ path: String) -> Bool {
        stored.removeAll { $0 == path }
        return started.remove(path) != nil
    }
}

/// How the preview's custom-scheme handler answers, so a WKWebView will
/// paint the page and its images.
///
/// `loadHTMLString` with a `cedric-doc:` base URL does not give the
/// document that origin on iOS: root-absolute `/images/…` never reaches
/// the handler. The page itself is therefore served at the folder's page
/// URL, and every reply is an HTTP response with a type and a length
/// (a plain `URLResponse` comes back with status 0, and WebKit then drops
/// the image). WebP is named explicitly; Uniform Type Identifiers often
/// report it as `application/octet-stream`.
public enum PreviewScheme {
    public static let htmlMIME = "text/html; charset=utf-8"

    public struct ResponseFields: Equatable, Sendable {
        public var status: Int
        public var mimeType: String
        public var contentLength: Int
        public var cacheControl: String
    }

    public static func responseFields(mimeType: String, byteCount: Int) -> ResponseFields {
        ResponseFields(status: 200, mimeType: mimeType, contentLength: byteCount, cacheControl: "no-store")
    }

    /// Image, font and style types the preview serves. Nil for anything
    /// else, so the caller can ask the system.
    public static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "tif", "tiff": return "image/tiff"
        case "css": return "text/css"
        case "html", "htm": return htmlMIME
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return nil
        }
    }

    /// The preview page itself (the folder URL), not a file under it.
    /// Trailing slashes and percent-encoding are ignored, and so is a
    /// cache-busting query.
    public static func isPageRequest(_ request: URL, page: URL) -> Bool {
        guard request.scheme?.lowercased() == PreviewFolder.scheme,
              page.scheme?.lowercased() == PreviewFolder.scheme,
              (request.host ?? "").lowercased() == (page.host ?? "").lowercased() else { return false }
        return normalizedPath(request) == normalizedPath(page)
    }

    public static func normalizedPath(_ url: URL) -> String {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        var path = raw.removingPercentEncoding ?? raw
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
