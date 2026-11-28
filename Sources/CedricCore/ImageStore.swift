import Foundation
import Darwin
import os

/// The "images" folder next to a Markdown document, where pasted, dropped
/// and picked images are copied. Every step goes through file descriptors
/// so that what was checked is what gets written (Astra review, 0.6; the
/// handle-based publish, round 6):
///
/// - Opened once: a boundary (iOS: the folder grant, opened without
///   following a final link and checked against its identity as granted;
///   the Mac: the document's folder itself), the document's folder (iOS:
///   walked from the grant one component at a time, `O_NOFOLLOW |
///   O_DIRECTORY` each), and "images" in it (made with `mkdirat` if
///   missing). Where the kernel keeps lookups beneath a folder
///   (`containmentEnforced`), "images" is opened with `O_RESOLVE_BENEATH`:
///   a link to a folder inside the document's folder is followed, one that
///   leads out, or back to the folder itself, is refused
///   (`Failure.outside`). Elsewhere (the fallback) only a real folder is
///   used (`O_NOFOLLOW`; `Failure.imagesIsLink`). The boundary's path as
///   the kernel reports it (`F_GETPATH`) and the folders' identities
///   (device and inode) are recorded.
/// - `verify`, at open and again before staging and before each publishing
///   attempt: the boundary is still at its recorded path; the document's
///   folder is still found beneath it at the same components (iOS); "images"
///   looked up again by the same rule is still the held folder; and the held
///   folder's own path (`F_GETPATH`) is still below the document's folder as
///   recorded. Else `Failure.destinationChanged`: a folder moved out of the
///   grant, or an "images" moved away or swapped for another folder or a
///   link, gets nothing.
/// - A copy reads the source through one descriptor that must be a
///   regular file (`fstat`): a symbolic link's target's bytes are copied,
///   never the link; a folder, pipe or device is refused.
/// - The bytes go to a hidden staging file in the held "images" (`openat`
///   with `O_CREAT | O_EXCL | O_NOFOLLOW`, mode 0666: the process umask
///   gives it the mode any new file gets, and nothing changes it after),
///   are flushed, and are published with `renameatx_np(images, tmp, images,
///   name, RENAME_EXCL)`: both operands are single names relative to the
///   held folder, so nothing is resolved through a path. A name already
///   taken is never overwritten and the next free suffix is tried. A volume
///   that can't rename exclusively (ENOTSUP) refuses: nothing is published
///   another way. A partial copy never has the final name.
/// - The staging file stays open from its creation until the rename or the
///   cleanup is done, so its inode can't be freed and its number reused.
///   Before each rename and before the cleanup's unlink the entry (looked up
///   without following) must be that file: the same device, inode, birth
///   time and generation as the held descriptor, which still has exactly
///   one link. Else the entry is left alone and logged.
/// - On any failure after the staging file is made, it is removed only while
///   the entry is still that file; an entry another writer put there, or
///   one that can't be looked up (an error other than ENOENT), is left in
///   place and logged.
/// - After the first open nothing here uses a path (no FileManager, no
///   path rename or unlink). The window between the last check and the
///   rename itself, and between the cleanup's identity check and its
///   unlink, remains (Darwin has no rename or unlink by identity).
/// - An "images" on another volume than the document's folder is reported
///   (`Failure.otherVolume`) before the staging file is made.
/// - The document's folder stays open until the links go in. `link(for:)`,
///   called just before the Markdown is inserted, checks that the
///   document's folder path is still that folder, that "images" looked up
///   in it again (by the same rules) is still the pinned folder, and that
///   `images/<name>` there is the very file published (device and inode).
///   Otherwise it throws `Failure.destinationChanged` and nothing is
///   inserted: a link that would show another file, or none, never goes in.
/// - `name` is checked at this boundary: one name, not empty, not `.` or
///   `..`, no `/` or NUL (`Failure.badName`), before anything is staged.
public final class ImageStore {
    public enum Failure: Error, Equatable {
        /// "images" resolves outside the document's folder.
        case outside
        /// The source isn't a regular file (a folder named x.png, a pipe).
        case notRegularFile
        /// The wanted name isn't a single file name.
        case badName
        /// The document's folder or its "images" changed after it was
        /// opened: `images/<name>` doesn't (or no longer does) lead into
        /// the folder that was checked.
        case destinationChanged
        /// "images" is a symbolic link, on the fallback path (a kernel
        /// without `RENAME_RESOLVE_BENEATH`), where only a real folder is
        /// used: nothing is written.
        case imagesIsLink
        /// "images" is on another volume than the document's folder (a
        /// separate mount): the staged file couldn't be renamed into it.
        /// Found before the staging file is filled.
        case otherVolume
    }

    /// The pinned "images" folder: everything is staged and published here.
    public let fd: Int32
    /// Whether this store opens "images" with the kernel keeping the lookup
    /// beneath the document's folder (else the no-link fallback). Fixed
    /// when it is opened.
    let kernel: Bool
    /// The pinned document folder, and the path the links are relative to.
    private let root: Int32
    private let folder: URL
    /// The boundary held for the store's life: iOS the verified grant, the
    /// Mac the document's folder (a second descriptor). `below`: the
    /// document folder's components beneath it (empty: it is the folder).
    private let boundary: Int32
    private let below: [String]
    /// Recorded at open: the boundary's and the document folder's paths as
    /// the kernel reports them (`F_GETPATH`), and the folders' identities.
    private let boundaryPath: [String]
    private let folderPath: [String]
    private let rootID: Beneath.FileID
    private let imagesID: Beneath.FileID
    /// Each published name (by its bytes) and the file it was given.
    private var published = Publications()
    /// Checks only (`DevEnvironment.checksEnabled`), like the hooks below:
    /// called after "images" is opened and checked (tests swap folders here).
    nonisolated(unsafe) public static var afterOpen: (() -> Void)?
    /// Called after the bytes are staged, just before they are published
    /// (tests move folders here).
    nonisolated(unsafe) public static var beforePublish: (() -> Void)?
    /// Called with each candidate name just before the publishing rename
    /// (tests take the name here to check it is never overwritten).
    nonisolated(unsafe) static var beforeRename: ((String) -> Void)?
    /// Tests: use the folder-by-folder fallback even where the kernel
    /// enforces beneath lookups (so a macOS 26 run covers it too).
    nonisolated(unsafe) static var forceFallback = false
    /// Tests: behave as if "images" were on another volume.
    nonisolated(unsafe) static var forceOtherVolume = false
    /// Checks only: called with the staging file once it is filled; an
    /// errno returned is a write that failed there (ENOSPC, EIO).
    nonisolated(unsafe) static var writeFault: ((Int32) -> Int32?)?
    /// Checks only: called with a staging name the cleanup left in place
    /// because the entry there is no longer the file it made.
    nonisolated(unsafe) static var leftBehind: ((String) -> Void)?
    /// Checks only: rewrites what a lookup of the staging entry found (its
    /// `stat`, and 0 or the errno the lookup failed with): tests stand in
    /// another file's identity, or an I/O error, here.
    nonisolated(unsafe) static var stagedLookup: ((String, inout stat, inout Int32) -> Void)?

    /// `RENAME_RESOLVE_BENEATH` from sys/stdio.h, written as its value:
    /// older SDKs may not name it.
    static let renameResolveBeneath: UInt32 = 0x0000_0020

    /// Whether this kernel keeps both an `openat` (`Beneath.kernelEnforced`)
    /// and an exclusive rename beneath a folder: a rename to `../x` with
    /// `RENAME_RESOLVE_BENEATH` must be refused with `ENOTCAPABLE` (the
    /// containment error, not just any failure) while one to `x` works,
    /// tried on a file in a fresh temporary folder (removed after). A
    /// kernel that ignored or didn't know the flag fails the probe.
    public static let containmentEnforced: Bool = Beneath.kernelEnforced && renameBeneathProbe()

    /// Whether a store opened now uses the kernel-enforced path.
    static var useKernel: Bool { !forceFallback && containmentEnforced }

    static func renameBeneathProbe() -> Bool {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("cedric-rename-probe.XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { return false }
        let base = String(cString: made)
        defer { rmdir(base) }
        let top = Darwin.open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard top >= 0 else { return false }
        defer { close(top) }
        guard mkdirat(top, "d", 0o700) == 0 else { return false }
        defer { unlinkat(top, "d", AT_REMOVEDIR) }
        let d = openat(top, "d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard d >= 0 else { return false }
        defer { close(d) }
        let f = openat(d, "f", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { return false }
        close(f)
        defer { unlinkat(d, "f", 0); unlinkat(d, "g", 0); unlinkat(top, "out", 0) }
        let flags = UInt32(RENAME_EXCL) | renameResolveBeneath
        if renameatx_np(d, "f", d, "../out", flags) == 0 { return false }
        guard errno == Beneath.notCapable else { return false }
        return renameatx_np(d, "f", d, "g", flags) == 0
    }

    private init(fd: Int32, root: Int32, folder: URL, kernel: Bool, boundary: Int32, below: [String],
                 boundaryPath: [String], folderPath: [String], rootID: Beneath.FileID, imagesID: Beneath.FileID) {
        self.fd = fd; self.root = root; self.folder = folder; self.kernel = kernel
        self.boundary = boundary; self.below = below
        self.boundaryPath = boundaryPath; self.folderPath = folderPath
        self.rootID = rootID; self.imagesID = imagesID
    }
    deinit { close(fd); close(root); close(boundary) }

    /// Opens (making it if needed) "images" in `folder`; throws
    /// `Failure.outside` when it leads out of `folder`, and on the
    /// fallback path `Failure.imagesIsLink` (before anything is made) when
    /// it is a symbolic link.
    public static func open(in folder: URL) throws -> ImageStore {
        let dfd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { throw posix(folder.path) }
        let bfd = dup(dfd)
        guard bfd >= 0 else { let err = errno; close(dfd); throw posix(folder.path, err) }
        return try open(pinned: dfd, folder: folder, boundary: bfd, below: [])
    }

    /// Opens "images" in `folder`, where `folder` itself is looked up
    /// beneath `root` (iOS: the folder the person granted, or the app's
    /// own container) from `root`'s descriptor one component at a time
    /// (`O_NOFOLLOW | O_DIRECTORY` each): a symbolic link on the way is
    /// refused with `Failure.outside`, so the grant is the boundary, not
    /// `folder`'s path. `folder` must be `root` or lexically below it (pass
    /// both resolved). `root` itself is opened without following a final
    /// symbolic link, and when `rootID` is given (the root as it was when
    /// it was granted) it must still be that folder: a root replaced by a
    /// link, or by another folder, is refused with `Failure.outside`. Then
    /// as `open(in:)`, with `root` held as the boundary `verify` checks
    /// against before each publishing step.
    public static func open(in folder: URL, beneath root: URL, rootID: Beneath.FileID? = nil) throws -> ImageStore {
        let base = root.standardizedFileURL.pathComponents
        let path = folder.standardizedFileURL.pathComponents
        guard path.count >= base.count, Array(path.prefix(base.count)) == base else { throw Failure.outside }
        let rfd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rfd >= 0 else {
            let err = errno
            if err == ELOOP || err == ENOTDIR { throw Failure.outside }
            throw posix(root.path, err)
        }
        if let rootID, Beneath.FileID(fd: rfd) != rootID {
            close(rfd)
            throw Failure.outside
        }
        let parts = Array(path.dropFirst(base.count))
        let dfd = parts.isEmpty ? dup(rfd) : Beneath.open(parts, beneath: rfd, flags: O_RDONLY | O_DIRECTORY, walk: true)
        let err = errno
        guard dfd >= 0 else {
            close(rfd)
            if err == ELOOP || err == ENOTDIR || err == Beneath.notCapable || err == EINVAL { throw Failure.outside }
            throw posix(folder.path, err)
        }
        return try open(pinned: dfd, folder: folder, boundary: rfd, below: parts)
    }

    /// `dfd`: the document's folder, opened, and `boundary` the folder it
    /// was opened beneath (`below` it), both owned from here on. The paths
    /// and identities are recorded and checked once (`verify`) before
    /// `afterOpen`; a failure there is `Failure.outside`.
    private static func open(pinned dfd: Int32, folder: URL, boundary: Int32, below: [String]) throws -> ImageStore {
        let kernel = useKernel
        let ifd: Int32
        do { ifd = try openImages(in: dfd, folder: folder, create: true, kernel: kernel) } catch {
            close(dfd); close(boundary)
            throw error
        }
        guard let boundaryPath = kernelPath(of: boundary), let folderPath = kernelPath(of: dfd),
              folderPath.count == boundaryPath.count + below.count, Array(folderPath.prefix(boundaryPath.count)) == boundaryPath,
              let rootID = Beneath.FileID(fd: dfd), let imagesID = Beneath.FileID(fd: ifd)
        else {
            close(ifd); close(dfd); close(boundary)
            throw Failure.outside
        }
        let store = ImageStore(fd: ifd, root: dfd, folder: folder, kernel: kernel, boundary: boundary, below: below,
                               boundaryPath: boundaryPath, folderPath: folderPath, rootID: rootID, imagesID: imagesID)
        do { try store.verify() } catch { throw Failure.outside }
        if DevEnvironment.checksEnabled { afterOpen?() }
        return store
    }

    /// The path the kernel has for what `fd` has open (`F_GETPATH`), as
    /// components; nil when it can't say.
    static func kernelPath(of fd: Int32) -> [String]? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return nil }
        let path = String(cString: buf)
        guard path.hasPrefix("/") else { return nil }
        return (path as NSString).pathComponents
    }

    /// The held "images" is still inside the boundary, where it was opened:
    /// the boundary is at its recorded path; the document's folder is
    /// still found beneath it at the same components (no link followed)
    /// with the same identity; "images" looked up in it again, by the rule
    /// it was opened with, is still the held folder; and the held folder's
    /// own path is still below the document's folder's recorded path.
    /// Else `Failure.destinationChanged`.
    func verify() throws {
        guard Self.kernelPath(of: boundary) == boundaryPath else { throw Failure.destinationChanged }
        if !below.isEmpty {
            let now = Beneath.open(below, beneath: boundary, flags: O_RDONLY | O_DIRECTORY, walk: true)
            guard now >= 0 else { throw Failure.destinationChanged }
            defer { close(now) }
            guard Beneath.FileID(fd: now) == rootID else { throw Failure.destinationChanged }
        }
        guard let again = try? Self.openImages(in: root, folder: folder, create: false, kernel: kernel) else { throw Failure.destinationChanged }
        defer { close(again) }
        guard Beneath.FileID(fd: again) == imagesID, Beneath.FileID(fd: fd) == imagesID,
              let here = Self.kernelPath(of: fd), here.count > folderPath.count, Array(here.prefix(folderPath.count)) == folderPath
        else { throw Failure.destinationChanged }
    }

    /// "images" in the folder `dfd` has open, made if `create` and missing.
    /// `kernel`: opened with the kernel keeping the lookup beneath `dfd`: a
    /// folder, or a symbolic link to a folder inside `dfd`'s (not `dfd`'s
    /// itself). Else (fallback): a folder only, never a symbolic link.
    static func openImages(in dfd: Int32, folder: URL, create: Bool, kernel: Bool) throws -> Int32 {
        guard kernel else { return try openImagesNoFollow(in: dfd, folder: folder, create: create) }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | Beneath.resolveBeneath
        var ifd = openat(dfd, "images", flags)
        if ifd < 0, errno == ENOENT, create {
            // ENOENT for a dangling link too: mkdirat then fails with EEXIST and the open below fails again.
            guard mkdirat(dfd, "images", 0o777) == 0 || errno == EEXIST else { throw posix(folder.appendingPathComponent("images").path) }
            ifd = openat(dfd, "images", flags)
        }
        if ifd < 0 {
            let err = errno
            // A symbolic link the kernel wouldn't follow beneath the folder (or that leads nowhere).
            var st = stat()
            if fstatat(dfd, "images", &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFLNK { throw Failure.outside }
            throw posix(folder.appendingPathComponent("images").path, err)
        }
        // A link back to the document's folder itself is refused.
        guard let inner = Beneath.FileID(fd: ifd), let outer = Beneath.FileID(fd: dfd), inner != outer else {
            close(ifd)
            throw Failure.outside
        }
        return ifd
    }

    /// The fallback's "images": one component opened from `dfd` with
    /// `O_NOFOLLOW | O_DIRECTORY` (`Beneath.open`'s component walk), made
    /// with `mkdirat` relative to `dfd` if missing. A symbolic link (ELOOP,
    /// or ENOTDIR) is refused with `Failure.imagesIsLink`, a dangling one
    /// too (never made through). What opened must be a folder (`fstat`)
    /// other than `dfd`'s.
    static func openImagesNoFollow(in dfd: Int32, folder: URL, create: Bool) throws -> Int32 {
        let path = folder.appendingPathComponent("images").path
        func openIt() -> Int32 { Beneath.open(["images"], beneath: dfd, flags: O_RDONLY | O_DIRECTORY, walk: true) }
        var ifd = openIt()
        if ifd < 0, errno == ENOENT, create {
            // mkdirat doesn't follow a final link: one made meanwhile fails EEXIST, and the open below refuses it.
            guard mkdirat(dfd, "images", 0o777) == 0 || errno == EEXIST else { throw posix(path) }
            ifd = openIt()
        }
        if ifd < 0 {
            let err = errno
            var st = stat()
            if fstatat(dfd, "images", &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFLNK { throw Failure.imagesIsLink }
            throw posix(path, err)
        }
        var st = stat()
        guard fstat(ifd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { close(ifd); throw posix(path, ENOTDIR) }
        guard let inner = Beneath.FileID(fd: ifd), let outer = Beneath.FileID(fd: dfd), inner != outer else {
            close(ifd)
            throw Failure.outside
        }
        return ifd
    }

    /// The link to insert for `name` (published by this store):
    /// "images/<name>", encoded, once it is checked to lead to the file
    /// written. Throws `Failure.destinationChanged` when it doesn't.
    public func link(for name: String) throws -> String {
        guard // The document's folder, looked up by its path again, is the pinned one.
              Beneath.FileID(path: folder.path, followLast: true) == Beneath.FileID(fd: root),
              // "images" in it, by the same rules as at open, is the pinned folder.
              let again = try? Self.openImages(in: root, folder: folder, create: false, kernel: kernel)
        else { throw Failure.destinationChanged }
        defer { close(again) }
        guard Beneath.FileID(fd: again) == Beneath.FileID(fd: fd), let here = Beneath.FileID(at: again, name),
              published.isPublished(name, here: here, lookup: { Beneath.FileID(at: again, $0) })
        else { throw Failure.destinationChanged }
        return MarkdownPaste.imagesPath(name)
    }

    /// Copies the bytes `source` holds (a symbolic link is followed and its
    /// target read, unless `followLink` is false: then a link is refused
    /// with `Failure.notRegularFile`) into "images" as `name` or the first
    /// free "name-2.ext"… Returns the name it got.
    public func copy(from source: URL, name: String, followLink: Bool = true) throws -> String {
        // O_NONBLOCK: opening a named pipe doesn't wait for a writer.
        let src = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followLink ? 0 : O_NOFOLLOW))
        guard src >= 0 else {
            if !followLink, errno == ELOOP { throw Failure.notRegularFile }
            throw Self.posix(source.path)
        }
        defer { close(src) }
        var st = stat()
        guard fstat(src, &st) == 0 else { throw Self.posix(source.path) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        _ = fcntl(src, F_SETFL, fcntl(src, F_GETFL) & ~O_NONBLOCK)
        return try stage(name) { dst in fcopyfile(src, dst, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 }
    }

    /// Writes `data` into "images" as `name` or the first free variant.
    public func write(_ data: Data, name: String) throws -> String {
        try stage(name) { dst in
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(dst, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    off += n
                }
                return true
            }
        }
    }

    static let log = Logger(subsystem: "CedricCore", category: "ImageStore")

    private func stage(_ name: String, fill: (Int32) -> Bool) throws -> String {
        guard Beneath.isName(name) else { throw Failure.badName }
        // Checked before any byte is written.
        try verify()
        // Reported before anything is staged (as before the staging moved into "images").
        guard imagesID.dev == rootID.dev, !Self.forceOtherVolume else { throw Failure.otherVolume }
        let tmp = ".cedric-image-\(UUID().uuidString).tmp"
        guard Beneath.isName(tmp) else { throw Failure.badName }
        // 0666 like any new file: the umask gives it the mode it keeps (nothing changes it after).
        let dst = openat(fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard dst >= 0 else { throw Self.posix(tmp) }
        // Held open until the rename or the cleanup is done (this defer runs last): the inode
        // can't be freed meanwhile, so no other file can get its number.
        defer { close(dst) }
        // The staging file's identity, taken at once: a rename keeps it, so it names what was published.
        guard let id = Beneath.FileID(fd: dst) else {
            let err = errno
            leave(tmp)
            throw Self.posix(tmp, err)
        }
        var done = false
        defer { if !done { removeStaged(tmp, held: dst) } }
        var filled = fill(dst)
        var err = errno
        if DevEnvironment.checksEnabled, filled, let fault = Self.writeFault?(dst) { filled = false; err = fault }
        if filled, fsync(dst) != 0 { filled = false; err = errno }
        guard filled else { throw Self.posix(name, err) }
        if DevEnvironment.checksEnabled { Self.beforePublish?() }
        let out = try publish(tmp, as: name, held: dst)
        done = true
        self.published.record(out, id)
        return out
    }

    /// Renames the staged file to the first free name in the held
    /// "images", both operands single names relative to it; never replaces
    /// one (`RENAME_EXCL`). Before each attempt the held folder must still
    /// be inside the boundary (`verify`) and the staging entry still the
    /// file `held` has open (`isHeld`). Any error but EEXIST (ENOTSUP from a volume that can't
    /// rename exclusively among them) refuses: nothing is published another way.
    private func publish(_ tmp: String, as name: String, held dst: Int32) throws -> String {
        // Names a rename found taken that a stat doesn't (the simulator's folders answer a stat
        // case-sensitively and a rename case-insensitively): skipped like any taken name.
        var clashed: Set<FolderTree.PathKey> = []
        func taken(_ n: String) -> Bool {
            var st = stat()
            return fstatat(fd, n, &st, AT_SYMLINK_NOFOLLOW) == 0 || clashed.contains(FolderTree.PathKey(n))
        }
        for _ in 0..<10_000 {
            let candidate = MarkdownPaste.uniqueName(name, exists: taken)
            guard Beneath.isName(candidate) else { throw Failure.badName }
            if DevEnvironment.checksEnabled { Self.beforeRename?(candidate) }
            try verify()
            guard case .found(let entry) = stagedEntry(tmp), isHeld(dst, entry) else { throw Failure.destinationChanged }
            if renameatx_np(fd, tmp, fd, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let err = errno
            // Taken meanwhile: the next free name is tried.
            guard err == EEXIST else { throw Self.posix(candidate, err) }
            clashed.insert(FolderTree.PathKey(candidate))
        }
        throw Self.posix(name, EEXIST)
    }

    /// A failure after the staging file was made: the entry is removed only
    /// while it is still the file `held` has open (`isHeld`); one another
    /// writer put there, or one that can't be looked up (an error other than
    /// ENOENT), is left in place and logged. (Darwin has no unlink by
    /// identity: the window between this check and the unlink remains.)
    private func removeStaged(_ tmp: String, held dst: Int32) {
        switch stagedEntry(tmp) {
        case .missing:
            return  // nothing there: nothing left
        case .failed(let err):
            leave(tmp, why: "its lookup failed (errno \(err))")
        case .found(let entry):
            if isHeld(dst, entry), unlinkat(fd, tmp, 0) == 0 { return }
            leave(tmp, why: "not the staging file this copy made")
        }
    }

    /// What a lookup of the staging entry found.
    enum Lookup { case found(stat), missing, failed(Int32) }

    /// What the staging entry `tmp` in the held folder is now (not followed).
    private func stagedEntry(_ tmp: String) -> Lookup {
        var st = stat()
        var rc: Int32 = fstatat(fd, tmp, &st, AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno
        if DevEnvironment.checksEnabled, let lookup = Self.stagedLookup { lookup(tmp, &st, &rc) }
        return rc == 0 ? .found(st) : rc == ENOENT ? .missing : .failed(rc)
    }

    /// `entry` is the file `dst` has open, now (`isSame`).
    private func isHeld(_ dst: Int32, _ entry: stat) -> Bool {
        var held = stat()
        return fstat(dst, &held) == 0 && Self.isSame(held: held, entry: entry)
    }

    /// The entry is the held file: the held file still has exactly one link
    /// (not unlinked, not linked elsewhere too), and the entry has its
    /// device, inode, birth time and generation (the generation is 0 where
    /// it isn't given out, on both). The inode number alone can name another
    /// file once ours is freed; ours is held open, and a file made later has
    /// another birth time.
    static func isSame(held: stat, entry: stat) -> Bool {
        held.st_nlink == 1
            && entry.st_dev == held.st_dev && entry.st_ino == held.st_ino
            && entry.st_birthtimespec.tv_sec == held.st_birthtimespec.tv_sec
            && entry.st_birthtimespec.tv_nsec == held.st_birthtimespec.tv_nsec
            && entry.st_gen == held.st_gen
    }

    /// The staging name `tmp` is left in "images" (not, or not provably, the file made).
    private func leave(_ tmp: String, why: String = "not the staging file this copy made") {
        Self.log.error("left \(tmp, privacy: .public) in images: \(why, privacy: .public)")
        if DevEnvironment.checksEnabled { Self.leftBehind?(tmp) }
    }

    /// What this store published: each name by its UTF-8 bytes, with the
    /// file (device and inode) it was given. Byte keys keep two
    /// canonically equivalent names two records, so one never takes the
    /// other's file (a `String` key folded them: the second publication
    /// replaced the first's record, and an unchanged first file was then
    /// refused). Whether `name` still leads to a published file is decided
    /// by identity: under the exact bytes it must be that record's file;
    /// a name with no record of its own bytes counts only if it is the
    /// same file as a recorded name now is (one name to APFS spelled
    /// another way), never by its text.
    struct Publications {
        private var byName: [FolderTree.PathKey: Beneath.FileID] = [:]

        mutating func record(_ name: String, _ id: Beneath.FileID) { byName[FolderTree.PathKey(name)] = id }

        /// `here`: the file `name` leads to now. `lookup`: the file a
        /// recorded name leads to now.
        func isPublished(_ name: String, here: Beneath.FileID, lookup: (String) -> Beneath.FileID?) -> Bool {
            if let want = byName[FolderTree.PathKey(name)] { return want == here }
            return byName.contains { $0.value == here && lookup($0.key.string) == here }
        }
    }

    static func posix(_ path: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
