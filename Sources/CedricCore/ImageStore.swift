import Foundation
import Darwin

/// The "images" folder next to a Markdown document, where pasted, dropped
/// and picked images are copied. Every step goes through file descriptors
/// so that what was checked is what gets written (Astra review, 0.6):
///
/// - The document's folder is opened once and pinned. "images" is opened
///   beneath it with `O_RESOLVE_BENEATH` (made with `mkdirat` if
///   missing): the kernel follows a symbolic link only while it stays
///   inside the document's folder, and refuses one that leads out. An
///   "images" that leads back to the document's folder itself is refused
///   (device and inode). No path strings are compared.
/// - A copy reads the source through one descriptor that must be a
///   regular file (`fstat`): a symbolic link's target's bytes are copied,
///   never the link; a folder, pipe or device is refused.
/// - Before any byte is written, "images" is opened beneath the pinned
///   document folder again and must still be the pinned folder (else
///   `Failure.destinationChanged`). The bytes go to a hidden staging file
///   directly in the pinned document folder (`O_EXCL`), are flushed, and
///   are then published as `images/<name>` relative to that same folder
///   with one exclusive rename (`renameatx_np` with `RENAME_EXCL |
///   RENAME_RESOLVE_BENEATH`): the kernel resolves the whole destination
///   beneath the document's folder, so an "images" moved out of it (or
///   swapped for a link out) receives neither the staged bytes nor the
///   published file. A name already taken is never overwritten and the
///   next free suffix is tried; a failure removes the staging file. A
///   partial copy never has the final name. An "images" on another volume
///   than the document's folder is reported (`Failure.otherVolume`) before
///   the staging file is made, not after a large copy.
/// - Where the kernel doesn't enforce beneath lookups for both the open
///   and the rename (`containmentEnforced` is false: macOS 15), the
///   folder-by-folder fallback is used instead (Derek, 0.6): "images" is
///   opened from the pinned document folder with `O_NOFOLLOW |
///   O_DIRECTORY` (made with `mkdirat` relative to it if missing), so any
///   symbolic link there, to a folder inside or out, is refused
///   (`Failure.imagesIsLink`) before anything is made or written. The
///   bytes are staged in the pinned "images" itself (`O_CREAT | O_EXCL |
///   O_NOFOLLOW`, one hidden name) and published with
///   `renameatx_np(images, tmp, images, name, RENAME_EXCL)`: both operands
///   are single names relative to the held folder, so an "images" swapped
///   for another folder or a link after it was checked can't redirect the
///   file, which lands in the folder that was opened or nowhere. Before
///   staging and again just before the rename, the held folder's ".." must
///   still be the pinned document folder (else
///   `Failure.destinationChanged`, the staging file removed): an "images"
///   moved out of the document's folder gets no published file, except in
///   the window between that last check and the rename itself.
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

    /// The pinned "images" folder.
    public let fd: Int32
    /// Whether this store uses the kernel-enforced beneath lookups (else
    /// the folder-by-folder fallback). Fixed when it is opened.
    let kernel: Bool
    /// The pinned document folder, and the path the links are relative to.
    private let root: Int32
    private let folder: URL
    /// Each published name (by its bytes) and the file it was given.
    private var published = Publications()
    /// Called after "images" is opened and checked (tests swap folders here).
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

    private init(fd: Int32, root: Int32, folder: URL, kernel: Bool) {
        self.fd = fd; self.root = root; self.folder = folder; self.kernel = kernel
    }
    deinit { close(fd); close(root) }

    /// Opens (making it if needed) "images" in `folder`; throws
    /// `Failure.outside` when it leads out of `folder`, and on the
    /// fallback path `Failure.imagesIsLink` (before anything is made) when
    /// it is a symbolic link.
    public static func open(in folder: URL) throws -> ImageStore {
        let dfd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { throw posix(folder.path) }
        return try open(pinned: dfd, folder: folder)
    }

    /// Opens "images" in `folder`, where `folder` itself is looked up
    /// beneath `root` (iOS: the folder the person granted, or the app's
    /// own container) from `root`'s descriptor by `Beneath.open`: a
    /// symbolic link on the way that leads out of `root` (or, where the
    /// kernel doesn't keep lookups beneath, any link) is refused with
    /// `Failure.outside`, so the grant is the boundary, not `folder`'s
    /// path. `folder` must be `root` or lexically below it (pass both
    /// resolved). `root` itself is opened without following a final
    /// symbolic link, and when `rootID` is given (the root as it was when
    /// it was granted) it must still be that folder: a root replaced by a
    /// link, or by another folder, is refused with `Failure.outside`. Then
    /// as `open(in:)`.
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
        let dfd = parts.isEmpty ? dup(rfd) : Beneath.open(parts, beneath: rfd, flags: O_RDONLY | O_DIRECTORY)
        let err = errno
        close(rfd)
        guard dfd >= 0 else {
            if err == ELOOP || err == ENOTDIR || err == Beneath.notCapable || err == EINVAL { throw Failure.outside }
            throw posix(folder.path, err)
        }
        return try open(pinned: dfd, folder: folder)
    }

    /// `dfd`: the document's folder, opened (owned from here on).
    private static func open(pinned dfd: Int32, folder: URL) throws -> ImageStore {
        let kernel = useKernel
        let ifd: Int32
        do { ifd = try openImages(in: dfd, folder: folder, create: true, kernel: kernel) } catch { close(dfd); throw error }
        let store = ImageStore(fd: ifd, root: dfd, folder: folder, kernel: kernel)
        afterOpen?()
        return store
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

    /// Fallback: the held "images" is still directly in the pinned
    /// document folder (its ".." is that folder).
    private func heldImagesInRoot() -> Bool {
        guard let up = Beneath.FileID(at: fd, ".."), let rootID = Beneath.FileID(fd: root) else { return false }
        return up == rootID
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

    /// "images" as it is now in the pinned document folder (beneath it),
    /// which must still be the pinned "images".
    private func currentImages() throws -> Int32 {
        guard let now = try? Self.openImages(in: root, folder: folder, create: false, kernel: kernel) else { throw Failure.destinationChanged }
        guard Beneath.FileID(fd: now) == Beneath.FileID(fd: fd) else { close(now); throw Failure.destinationChanged }
        return now
    }

    private func stage(_ name: String, fill: (Int32) -> Bool) throws -> String {
        guard Beneath.isName(name) else { throw Failure.badName }
        // Checked before any byte is written.
        let images = try currentImages()
        defer { close(images) }
        // The staged file is renamed into "images": both must be on one volume.
        // (A mount that changes after this still fails at the rename, below.)
        guard let imagesID = Beneath.FileID(fd: images), let rootID = Beneath.FileID(fd: root) else { throw Self.posix(name) }
        guard imagesID.dev == rootID.dev, !Self.forceOtherVolume else { throw Failure.otherVolume }
        // Fallback: the held folder must still be in the document's folder.
        if !kernel, !heldImagesInRoot() { throw Failure.destinationChanged }
        // Kernel path: staged directly in the pinned document folder, never in an
        // "images" that moved. Fallback: staged in the held "images" (one name).
        let stageDir = kernel ? root : fd
        let tmp = ".cedric-image-\(UUID().uuidString).tmp"
        guard Beneath.isName(tmp) else { throw Failure.badName }
        let dst = openat(stageDir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard dst >= 0 else { throw Self.posix(tmp) }
        var published = false
        defer { if !published { unlinkat(stageDir, tmp, 0) } }
        let filled = fill(dst)
        let err = errno
        guard filled, fsync(dst) == 0 else { close(dst); throw Self.posix(name, filled ? errno : err) }
        // The staged file's identity: a rename keeps it, so it names what was published.
        let id = Beneath.FileID(fd: dst)
        guard close(dst) == 0, let id else { throw Self.posix(name) }
        Self.beforePublish?()
        let out = try kernel ? publish(tmp, as: name, hint: images) : publishInHeld(tmp, as: name)
        published = true
        self.published.record(out, id)
        return out
    }

    /// Renames the staged file to `images/<first free name>`, resolved by
    /// the kernel beneath the pinned document folder; never replaces one.
    /// `hint` ("images" as checked) only suggests which names are free.
    private func publish(_ tmp: String, as name: String, hint: Int32) throws -> String {
        func taken(_ n: String) -> Bool {
            var st = stat()
            return fstatat(hint, n, &st, AT_SYMLINK_NOFOLLOW) == 0
        }
        for _ in 0..<10_000 {
            let candidate = MarkdownPaste.uniqueName(name, exists: taken)
            Self.beforeRename?(candidate)
            if renameatx_np(root, tmp, root, "images/" + candidate, UInt32(RENAME_EXCL) | Self.renameResolveBeneath) == 0 {
                return candidate
            }
            let err = errno
            guard err == EEXIST else {
                // ENOENT: "images" is gone from the folder; ENOTCAPABLE (Beneath.notCapable): it leads out now.
                if err == ENOENT || err == Beneath.notCapable { throw Failure.destinationChanged }
                throw Self.posix(candidate, err)
            }
            // Taken in "images" as it is now but free in the folder checked: "images" changed.
            if !taken(candidate) { throw Failure.destinationChanged }
        }
        throw Self.posix(name, EEXIST)
    }

    /// Fallback: renames the staged file (in the held "images") to the
    /// first free name there, both operands single names relative to that
    /// folder's descriptor; never replaces one (`RENAME_EXCL`). Throws
    /// `Failure.destinationChanged` if the parent check immediately before
    /// a rename attempt observes that the held folder has moved out of the
    /// document's folder.
    private func publishInHeld(_ tmp: String, as name: String) throws -> String {
        func taken(_ n: String) -> Bool {
            var st = stat()
            return fstatat(fd, n, &st, AT_SYMLINK_NOFOLLOW) == 0
        }
        for _ in 0..<10_000 {
            let candidate = MarkdownPaste.uniqueName(name, exists: taken)
            guard Beneath.isName(candidate) else { throw Failure.badName }
            Self.beforeRename?(candidate)
            guard heldImagesInRoot() else { throw Failure.destinationChanged }
            if renameatx_np(fd, tmp, fd, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let err = errno
            // Taken meanwhile: the next free name is tried.
            guard err == EEXIST else { throw Self.posix(candidate, err) }
        }
        throw Self.posix(name, EEXIST)
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
