import Foundation
import Darwin

/// Reading a file the preview's `cedric-doc:` handler approved (Astra
/// review, 0.6 batch 4). The approval (`PreviewFolder.approved`) works on
/// paths; between it and the read a folder or file can be swapped for a
/// symbolic link or another file. So the read never reopens the path: it
/// opens the approved root, looks the file up beneath that descriptor
/// with the kernel keeping the lookup inside (`Beneath`), checks what it
/// opened (a regular file; with page script on, an image, font or CSS
/// file outside any dot folder, judged on the opened file's real path)
/// and reads that same descriptor. Anything it can't establish fails
/// closed (nil).
public enum PreviewRead {
    /// The largest file served (a page asset, not a disk image).
    public static let maxBytes = 512 << 20

    /// `file`'s parts below `root`, by the paths as given or else as
    /// resolved; nil when it isn't below `root` either way. Compared and
    /// split as bytes (`FolderTree.relativePath`, `FolderTree.components`):
    /// a slash followed by a combining mark is one Swift character, so a
    /// text prefix refused a first-level mark-leading name (Astra batch 13d).
    static func components(of file: URL, below root: URL) -> [String]? {
        func rel(_ f: URL, _ r: URL) -> [String]? {
            guard let rel = FolderTree.relativePath(of: f, in: r), !rel.isEmpty else { return nil }
            let parts = FolderTree.components(rel)
            return parts.isEmpty || !parts.allSatisfy(Beneath.isName) ? nil : parts
        }
        let f = file.standardizedFileURL, r = root.standardizedFileURL
        return rel(f, r) ?? rel(PreviewFolder.resolved(f), PreviewFolder.resolved(r))
    }

    /// The path the kernel has for what `fd` has open.
    static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Whether `parts` (below a root) is one a page with script on may
    /// load: no dot file or dot folder (a leading `.` byte, even with a
    /// combining mark after it), and an image, font or CSS name.
    static func scriptSafe(_ parts: [String]) -> Bool {
        guard let last = parts.last, !parts.contains(where: FolderTree.isDotName) else { return false }
        return PreviewFolder.scriptSafeExtensions.contains((last as NSString).pathExtension.lowercased())
    }

    /// `file`'s bytes, read beneath `root` as described above, or nil.
    /// `walk` forces the component walk (tests), as in `Beneath.open`.
    /// This opens `root` by its path now: the preview pins its roots when
    /// it grants them (`PreviewGrants`) and reads with
    /// `data(_:beneath:scriptOn:walk:)` on the pinned descriptor instead.
    public static func data(_ file: URL, beneath root: URL, scriptOn: Bool, walk: Bool = !Beneath.kernelEnforced) -> Data? {
        guard let pinned = PinnedRoot(root), let parts = components(of: file, below: pinned.url) else { return nil }
        return data(parts, beneath: pinned, scriptOn: scriptOn, walk: walk)
    }

    /// The bytes of `parts` (validated names) beneath the folder `root`
    /// holds open, as described above, or nil. `root` stays open for the
    /// read (the caller's reference keeps it alive).
    public static func data(_ parts: [String], beneath root: PinnedRoot, scriptOn: Bool, walk: Bool = !Beneath.kernelEnforced) -> Data? {
        guard !parts.isEmpty, parts.allSatisfy(Beneath.isName), !scriptOn || scriptSafe(parts) else { return nil }
        // `root` (and so its descriptor) stays alive until the read is done.
        defer { withExtendedLifetime(root) {} }
        let rootFD = root.fd
        // Non-blocking, so a FIFO swapped in can't hang the open.
        let fd = Beneath.open(parts, beneath: rootFD, flags: O_RDONLY | O_NONBLOCK, followLast: true, walk: walk)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxBytes else { return nil }
        if scriptOn {
            // What was opened, by its real path: below the root's, and
            // still an image, font or CSS file outside dot folders; by the
            // bytes, split at each `/` byte (a text split keeps a slash
            // before a combining mark inside a name, and a dot then a
            // mark isn't a text "." prefix).
            guard let r = path(of: rootFD), let f = path(of: fd),
                  let rel = FolderTree.relativePath(of: URL(fileURLWithPath: f), in: URL(fileURLWithPath: r)), !rel.isEmpty,
                  scriptSafe(FolderTree.components(rel)) else { return nil }
        }
        _ = fcntl(fd, F_SETFL, 0)
        var out = Data()
        out.reserveCapacity(Int(st.st_size))
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            out.append(buf, count: n)
            if out.count > maxBytes { return nil }
        }
        return out
    }
}

/// A folder the preview was granted, held open by descriptor from the
/// grant on (Astra review, 0.6 batch 7c): reads look files up beneath
/// this descriptor, so renaming the folder away and putting another in
/// its place can't make the replacement the root. Closed when the last
/// reference goes (the grant withdrawn and no read still using it).
public final class PinnedRoot: @unchecked Sendable {
    /// The folder's path when it was pinned (standardized).
    public let url: URL
    public let fd: Int32
    public let id: Beneath.FileID

    /// Opens `url` (following links, as a granted folder may be one);
    /// nil when it isn't a folder that opens.
    public init?(_ url: URL) {
        let u = url.standardizedFileURL
        let fd = Darwin.open(u.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard let id = Beneath.FileID(fd: fd) else { close(fd); return nil }
        self.url = u
        self.fd = fd
        self.id = id
    }

    /// Takes over `fd`, a folder open at `url` (closed here when it
    /// isn't usable); nil then.
    init?(adopting fd: Int32, url: URL) {
        guard let id = Beneath.FileID(fd: fd) else { close(fd); return nil }
        self.url = url.standardizedFileURL
        self.fd = fd
        self.id = id
    }

    deinit { close(fd) }
}

/// The preview's granted roots, pinned: the document's folder, the
/// opened folder and the vault's when they are granted (`grant`), and a
/// site root the first time a file is approved under it. A grant that
/// changes drops every pin (`grant` again); a read in flight keeps its
/// own reference until it finishes. At most `capacity` roots (`limit`,
/// 64) are kept: at the cap a request for a file in a site root not yet
/// pinned is refused (a pin that isn't kept would be found again on the
/// next request), while the roots already pinned are still served; a
/// granted root past the cap is denied for that grant (batch 10c).
/// A granted root that doesn't open when it is granted is denied for
/// that grant's lifetime (Astra review, batch 8c): it is never opened by
/// its path later, whatever is there by then, and a document whose own
/// folder was denied is refused altogether. Only a fresh grant (`revoke`,
/// or a grant of other roots) tries it again.
///
/// Nothing is pinned by its path after the grant (batch 8c). A site root
/// (`PreviewRoot`'s search) is found by descriptor: each folder searched
/// is a granted root's pin, or a folder above the document's reached
/// from that folder's pin by `..` and taken only when it is also what
/// its path names now; the site layout's folder (`static/` and the rest)
/// and the file are looked up beneath that, as the read does. The file
/// is approved under the root so found and read beneath that same
/// descriptor, so a root swapped once it is found is never the one read.
public final class PreviewGrants: @unchecked Sendable {
    public static let limit = 64
    /// How many roots may be held open (`limit`; less in tests).
    public let capacity: Int
    private let lock = NSLock()
    // Keyed by the paths' bytes (`FolderTree.PathKey`): a `String` key is
    // canonical, so two spellings a volume keeps apart (the Ohm sign and
    // Omega) shared one pin, and a grant changed between them kept the
    // old descriptor (Astra batch 13d, must 3).
    private var pins: [FolderTree.PathKey: PinnedRoot] = [:]
    private var granted: [FolderTree.PathKey] = []
    private var denied: Set<FolderTree.PathKey> = []
    /// Tests: called with a site root's path once its descriptor is found,
    /// before the file is approved under it (under the lock: it must not
    /// call back in).
    var siteRootFound: ((URL) -> Void)?

    public init(capacity: Int = PreviewGrants.limit) { self.capacity = capacity }

    /// How many roots are held open.
    public var count: Int { lock.lock(); defer { lock.unlock() }; return pins.count }

    /// Grants `roots` (nil entries skipped): when they differ from the
    /// current grant, every pin is dropped and these are pinned now; one
    /// that doesn't open, or comes past `capacity` distinct roots, is
    /// denied until the next fresh grant.
    public func grant(_ roots: [URL?]) {
        let paths = roots.compactMap { $0.map(FolderTree.PathKey.init) }
        lock.lock(); defer { lock.unlock() }
        guard paths != granted else { return }
        granted = paths
        pins = [:]
        denied = []
        for p in paths where pins[p] == nil && !denied.contains(p) {
            // Past the cap a root is denied for this grant, never opened.
            guard pins.count < capacity, let r = PinnedRoot(URL(fileURLWithPath: p.string)) else { denied.insert(p); continue }
            pins[p] = r
        }
    }

    /// Withdraws every grant and closes the pins (reads in flight keep theirs).
    public func revoke() { lock.lock(); pins = [:]; granted = []; denied = []; lock.unlock() }

    /// The descriptor pinned for `root` (granted, or a site root found
    /// before), or nil. Never opens anything.
    public func pinned(_ root: URL) -> PinnedRoot? {
        lock.lock(); defer { lock.unlock() }
        return pins[FolderTree.PathKey(root)]
    }

    /// What the preview reads for `url`: the file `PreviewFolder.approved`
    /// approves under a granted root, or else under a site root found by
    /// descriptor (above); the pinned root and the file's validated parts
    /// below it. nil when refused: the document's folder isn't granted
    /// (or was denied), the root isn't pinned, or the rules refuse it.
    /// `walk` is the lookup's, as in `Beneath.open` (tests).
    public func approve(_ url: URL, in folder: URL, openedRoot: URL?, vaultRoot: URL? = nil, scriptOn: Bool,
                        vault: WikiVault? = nil, walk: Bool = !Beneath.kernelEnforced) -> (root: PinnedRoot, parts: [String], file: URL)? {
        lock.lock(); defer { lock.unlock() }
        let folderPath = FolderTree.PathKey(folder)
        guard granted.contains(folderPath), let docPin = pins[folderPath] else { return nil }
        if let hit = PreviewFolder.approved(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot,
                                            scriptOn: scriptOn, vault: vault, siteRoots: false) {
            let p = FolderTree.PathKey(hit.root)
            guard granted.contains(p), let root = pins[p],
                  let parts = PreviewRead.components(of: hit.file, below: root.url),
                  !scriptOn || PreviewRead.scriptSafe(parts) else { return nil }
            return (root, parts, hit.file)
        }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let rel = PreviewRoot.parts(of: path), rel.allSatisfy(Beneath.isName),
              let site = siteRoot(holding: rel, from: folder, docPin: docPin, openedRoot: openedRoot, walk: walk) else { return nil }
        siteRootFound?(site.url)
        // The path rules, as for any root (symbolic links; with script on
        // images, fonts and CSS only, no dot files), judged by the paths;
        // the read beneath `site` keeps to what that descriptor holds.
        guard let page = PreviewFolder.pageURL(forFile: site.url.appendingPathComponent(rel.joined(separator: "/"))),
              let file = PreviewFolder.file(for: page, in: site.url, scriptOn: scriptOn),
              !scriptOn || PreviewRead.scriptSafe(rel) else { return nil }
        if pins[FolderTree.PathKey(site.url)] == nil {
            guard pins.count < capacity else { return nil }
            pins[FolderTree.PathKey(site.url)] = site
        }
        return (site, rel, file)
    }

    /// The first site root holding `rel` (`PreviewRoot.resolve`'s order),
    /// by descriptor: see the type's notes. Called with the lock held.
    private func siteRoot(holding rel: [String], from folder: URL, docPin: PinnedRoot, openedRoot: URL?, walk: Bool) -> PinnedRoot? {
        for dir in PreviewRoot.searchFolders(from: folder, openedRoot: openedRoot) {
            guard let base = searchFolder(dir, docPin: docPin) else { continue }
            for sub in PreviewRoot.siteFolders {
                let url = sub.isEmpty ? base.url : base.url.appendingPathComponent(sub, isDirectory: true).standardizedFileURL
                guard !denied.contains(FolderTree.PathKey(url)) else { continue }
                let candidate: PinnedRoot
                if let r = pins[FolderTree.PathKey(url)] {
                    candidate = r
                } else if sub.isEmpty {
                    candidate = base
                } else {
                    let fd = Beneath.open(FolderTree.components(sub), beneath: base.fd,
                                          flags: O_RDONLY | O_DIRECTORY, followLast: true, walk: walk)
                    guard fd >= 0, let r = PinnedRoot(adopting: fd, url: url) else { continue }
                    candidate = r
                }
                if Self.holds(rel, beneath: candidate, walk: walk) { return candidate }
            }
        }
        return nil
    }

    /// The folder `dir` the site search looks in, open: its pin when it
    /// is pinned, else (a folder above the document's) the document
    /// folder's pin's parent the right number of levels up, taken only
    /// when `dir`'s path names that same folder now. nil otherwise. How
    /// far above is counted in the bytes (`FolderTree.relativePath`, split
    /// at `/` bytes): as text a document folder whose name starts with a
    /// combining mark wasn't below its parent.
    private func searchFolder(_ dir: URL, docPin: PinnedRoot) -> PinnedRoot? {
        let p = dir.standardizedFileURL.path
        guard !denied.contains(FolderTree.PathKey(p)) else { return nil }
        if let r = pins[FolderTree.PathKey(p)] { return r }
        guard let rel = FolderTree.relativePath(of: docPin.url, in: dir), !rel.isEmpty else { return nil }
        let levels = FolderTree.components(rel).count
        guard levels > 0 else { return nil }
        var fd = openat(docPin.fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        for _ in 1..<levels where fd >= 0 {
            let up = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            close(fd)
            fd = up
        }
        guard fd >= 0, let r = PinnedRoot(adopting: fd, url: dir),
              Beneath.FileID(path: p, followLast: true) == r.id else { return nil }
        return r
    }

    /// Whether `rel` beneath `root` is there and isn't a folder (what
    /// `PreviewRoot.resolve` asks of a path).
    static func holds(_ rel: [String], beneath root: PinnedRoot, walk: Bool) -> Bool {
        let fd = Beneath.open(rel, beneath: root.fd, flags: O_RDONLY | O_NONBLOCK, followLast: true, walk: walk)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) != S_IFDIR
    }
}
