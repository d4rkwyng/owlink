import Foundation
import Darwin

/// The "images" folder next to a Markdown document, where pasted, dropped
/// and picked images are copied. Every step goes through file descriptors
/// so that what was checked is what gets written (Astra review, 0.6):
///
/// - The document's folder is opened once and pinned. "images" is opened
///   relative to it with `O_NOFOLLOW | O_DIRECTORY` (made with `mkdirat`
///   if missing). An "images" that is a symbolic link is only taken when
///   the folder it opens is inside the document's folder, judged from the
///   opened descriptor (`F_GETPATH`), not from a path looked up again.
/// - A copy reads the source through one descriptor that must be a
///   regular file (`fstat`): a symbolic link's target's bytes are copied,
///   never the link; a folder, pipe or device is refused.
/// - The bytes go to a hidden staging file in "images" (`O_EXCL`), are
///   flushed, then published under the wanted name with an exclusive
///   rename (`renameatx_np` with `RENAME_EXCL`): a name already taken is
///   never overwritten and the next free suffix is tried; a failure
///   removes the staging file. A partial copy never has the final name.
public final class ImageStore {
    public enum Failure: Error, Equatable {
        /// "images" resolves outside the document's folder.
        case outside
        /// The source isn't a regular file (a folder named x.png, a pipe).
        case notRegularFile
    }

    /// The pinned "images" folder.
    public let fd: Int32
    /// Called after "images" is opened and checked (tests swap folders here).
    nonisolated(unsafe) public static var afterOpen: (() -> Void)?

    private init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    /// Opens (making it if needed) "images" in `folder`; throws
    /// `Failure.outside` when it leads out of `folder`.
    public static func open(in folder: URL) throws -> ImageStore {
        let dfd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { throw posix(folder.path) }
        defer { close(dfd) }
        var ifd = openat(dfd, "images", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if ifd < 0, errno == ENOENT {
            guard mkdirat(dfd, "images", 0o777) == 0 || errno == EEXIST else { throw posix(folder.appendingPathComponent("images").path) }
            ifd = openat(dfd, "images", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if ifd < 0, errno == ELOOP || errno == ENOTDIR {
            // A symbolic link: open what it leads to, then judge the opened folder.
            var st = stat()
            guard fstatat(dfd, "images", &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFLNK else {
                throw posix(folder.appendingPathComponent("images").path, ENOTDIR)
            }
            ifd = openat(dfd, "images", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard ifd >= 0 else { throw Failure.outside }
            guard let inner = path(of: ifd), let outer = path(of: dfd),
                  inner != outer, inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/") else {
                close(ifd)
                throw Failure.outside
            }
        }
        guard ifd >= 0 else { throw posix(folder.appendingPathComponent("images").path) }
        let store = ImageStore(fd: ifd)
        afterOpen?()
        return store
    }

    /// The folder a descriptor has open (symbolic links resolved).
    static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
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

    private func stage(_ name: String, fill: (Int32) -> Bool) throws -> String {
        let tmp = ".cedric-image-\(UUID().uuidString).tmp"
        let dst = openat(fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard dst >= 0 else { throw Self.posix(tmp) }
        var published = false
        defer { if !published { unlinkat(fd, tmp, 0) } }
        let filled = fill(dst)
        let err = errno
        guard filled, fsync(dst) == 0 else { close(dst); throw Self.posix(name, filled ? errno : err) }
        guard close(dst) == 0 else { throw Self.posix(name) }
        let out = try publish(tmp, as: name)
        published = true
        return out
    }

    /// Renames the staged file to the first free name; never replaces one.
    private func publish(_ tmp: String, as name: String) throws -> String {
        for _ in 0..<10_000 {
            let candidate = MarkdownPaste.uniqueName(name) { n in
                var st = stat()
                return fstatat(fd, n, &st, AT_SYMLINK_NOFOLLOW) == 0
            }
            if renameatx_np(fd, tmp, fd, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw Self.posix(candidate) }
        }
        throw Self.posix(name, EEXIST)
    }

    static func posix(_ path: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
