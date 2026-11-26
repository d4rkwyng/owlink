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
    /// resolved; nil when it isn't below `root` either way.
    static func components(of file: URL, below root: URL) -> [String]? {
        func rel(_ f: String, _ r: String) -> [String]? {
            let base = r.hasSuffix("/") ? r : r + "/"
            guard f.hasPrefix(base) else { return nil }
            let parts = f.dropFirst(base.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return parts.isEmpty || !parts.allSatisfy(Beneath.isName) ? nil : parts
        }
        return rel(file.standardizedFileURL.path, root.standardizedFileURL.path)
            ?? rel(PreviewFolder.resolved(file.standardizedFileURL).path, PreviewFolder.resolved(root.standardizedFileURL).path)
    }

    /// The path the kernel has for what `fd` has open.
    static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Whether `parts` (below a root) is one a page with script on may
    /// load: no dot file or dot folder, and an image, font or CSS name.
    static func scriptSafe(_ parts: [String]) -> Bool {
        guard let last = parts.last, !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
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
            // still an image, font or CSS file outside dot folders.
            guard let r = path(of: rootFD), let f = path(of: fd) else { return nil }
            let base = r.hasSuffix("/") ? r : r + "/"
            guard f.hasPrefix(base), scriptSafe(f.dropFirst(base.count).split(separator: "/").map(String.init)) else { return nil }
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

    deinit { close(fd) }
}

/// The preview's granted roots, pinned: the document's folder, the
/// opened folder and the vault's when they are granted (`grant`), and a
/// site root the first time a file is approved under it. A grant that
/// changes drops every pin (`grant` again); a read in flight keeps its
/// own reference until it finishes. At most `limit` roots are kept.
/// A granted root that doesn't open when it is granted is denied for
/// that grant's lifetime (Astra review, batch 8c): it is never opened by
/// its path later, whatever is there by then, and a document whose own
/// folder was denied is refused altogether. Only a fresh grant (`revoke`,
/// or a grant of other roots) tries it again.
public final class PreviewGrants: @unchecked Sendable {
    public static let limit = 64
    private let lock = NSLock()
    private var pins: [String: PinnedRoot] = [:]
    private var granted: [String] = []
    private var denied: Set<String> = []

    public init() {}

    /// How many roots are held open.
    public var count: Int { lock.lock(); defer { lock.unlock() }; return pins.count }

    /// Grants `roots` (nil entries skipped): when they differ from the
    /// current grant, every pin is dropped and these are pinned now; one
    /// that doesn't open is denied until the next fresh grant.
    public func grant(_ roots: [URL?]) {
        let paths = roots.compactMap { $0?.standardizedFileURL.path }
        lock.lock(); defer { lock.unlock() }
        guard paths != granted else { return }
        granted = paths
        pins = [:]
        denied = []
        for p in paths where pins[p] == nil && !denied.contains(p) {
            if let r = PinnedRoot(URL(fileURLWithPath: p)) { pins[p] = r } else { denied.insert(p) }
        }
    }

    /// Withdraws every grant and closes the pins (reads in flight keep theirs).
    public func revoke() { lock.lock(); pins = [:]; granted = []; denied = []; lock.unlock() }

    /// The pinned descriptor for `root`: the one pinned when it was
    /// granted or first approved, or else pinned now; nil for a granted
    /// root that was denied.
    public func pin(_ root: URL) -> PinnedRoot? {
        let p = root.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if let r = pins[p] { return r }
        guard !denied.contains(p) else { return nil }
        guard let r = PinnedRoot(root) else { return nil }
        if pins.count < Self.limit { pins[p] = r }
        return r
    }

    /// Whether `root` was granted and didn't open.
    func isDenied(_ root: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return denied.contains(root.standardizedFileURL.path)
    }

    /// What the preview reads for `url`: the file `PreviewFolder.approved`
    /// approves, the pinned root it was approved under and the file's
    /// validated parts below that root; nil when refused.
    public func approve(_ url: URL, in folder: URL, openedRoot: URL?, vaultRoot: URL? = nil, scriptOn: Bool,
                        vault: WikiVault? = nil) -> (root: PinnedRoot, parts: [String], file: URL)? {
        guard !isDenied(folder), let hit = PreviewFolder.approved(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot,
                                               scriptOn: scriptOn, vault: vault),
              let root = pin(hit.root),
              let parts = PreviewRead.components(of: hit.file, below: root.url),
              !scriptOn || PreviewRead.scriptSafe(parts) else { return nil }
        return (root, parts, hit.file)
    }
}
