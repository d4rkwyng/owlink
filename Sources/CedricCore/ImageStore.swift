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
///   and the rename (`containmentEnforced`), nothing is opened, made or
///   written: `Failure.noContainment`.
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
        /// This system can't keep the lookups beneath the document's
        /// folder (no kernel-enforced `O_RESOLVE_BENEATH` and
        /// `RENAME_RESOLVE_BENEATH`): nothing is written.
        case noContainment
        /// "images" is on another volume than the document's folder (a
        /// separate mount): the staged file couldn't be renamed into it.
        /// Found before the staging file is filled.
        case otherVolume
    }

    /// The pinned "images" folder.
    public let fd: Int32
    /// The pinned document folder, and the path the links are relative to.
    private let root: Int32
    private let folder: URL
    /// Each published name and the file it was given.
    private var published: [String: Beneath.FileID] = [:]
    /// Called after "images" is opened and checked (tests swap folders here).
    nonisolated(unsafe) public static var afterOpen: (() -> Void)?
    /// Called after the bytes are staged, just before they are published
    /// (tests move folders here).
    nonisolated(unsafe) public static var beforePublish: (() -> Void)?
    /// Tests: behave as on a kernel without beneath lookups.
    nonisolated(unsafe) static var forceNoContainment = false
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

    static var containment: Bool { !forceNoContainment && containmentEnforced }

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

    private init(fd: Int32, root: Int32, folder: URL) { self.fd = fd; self.root = root; self.folder = folder }
    deinit { close(fd); close(root) }

    /// Opens (making it if needed) "images" in `folder`; throws
    /// `Failure.outside` when it leads out of `folder`, and
    /// `Failure.noContainment` (before anything is made) where the kernel
    /// can't keep the lookups inside it.
    public static func open(in folder: URL) throws -> ImageStore {
        guard containment else { throw Failure.noContainment }
        let dfd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { throw posix(folder.path) }
        let ifd: Int32
        do { ifd = try openImages(in: dfd, folder: folder, create: true) } catch { close(dfd); throw error }
        let store = ImageStore(fd: ifd, root: dfd, folder: folder)
        afterOpen?()
        return store
    }

    /// "images" in the folder `dfd` has open, made if `create` and missing,
    /// opened with the kernel keeping the lookup beneath `dfd`: a folder,
    /// or a symbolic link to a folder inside `dfd`'s (not `dfd`'s itself).
    static func openImages(in dfd: Int32, folder: URL, create: Bool) throws -> Int32 {
        guard containment else { throw Failure.noContainment }
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

    /// The link to insert for `name` (published by this store):
    /// "images/<name>", encoded, once it is checked to lead to the file
    /// written. Throws `Failure.destinationChanged` when it doesn't.
    public func link(for name: String) throws -> String {
        guard let want = published[name],
              // The document's folder, looked up by its path again, is the pinned one.
              Beneath.FileID(path: folder.path, followLast: true) == Beneath.FileID(fd: root),
              // "images" in it, by the same rules as at open, is the pinned folder.
              let again = try? Self.openImages(in: root, folder: folder, create: false)
        else { throw Failure.destinationChanged }
        defer { close(again) }
        guard Beneath.FileID(fd: again) == Beneath.FileID(fd: fd),
              Beneath.FileID(at: again, name) == want else { throw Failure.destinationChanged }
        return MarkdownPaste.imagesPath(name)
    }

    /// Copies the bytes `source` holds (a symbolic link is followed and its
    /// target read) into "images" as `name` or the first free "name-2.ext"…
    /// Returns the name it got.
    public func copy(from source: URL, name: String) throws -> String {
        // O_NONBLOCK: opening a named pipe doesn't wait for a writer.
        let src = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard src >= 0 else { throw Self.posix(source.path) }
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
        guard Self.containment else { throw Failure.noContainment }
        guard let now = try? Self.openImages(in: root, folder: folder, create: false) else { throw Failure.destinationChanged }
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
        // Staged directly in the pinned document folder: never in an "images" that moved.
        let tmp = ".cedric-image-\(UUID().uuidString).tmp"
        let dst = openat(root, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard dst >= 0 else { throw Self.posix(tmp) }
        var published = false
        defer { if !published { unlinkat(root, tmp, 0) } }
        let filled = fill(dst)
        let err = errno
        guard filled, fsync(dst) == 0 else { close(dst); throw Self.posix(name, filled ? errno : err) }
        // The staged file's identity: a rename keeps it, so it names what was published.
        let id = Beneath.FileID(fd: dst)
        guard close(dst) == 0, let id else { throw Self.posix(name) }
        Self.beforePublish?()
        let out = try publish(tmp, as: name, hint: images)
        published = true
        self.published[out] = id
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

    static func posix(_ path: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
