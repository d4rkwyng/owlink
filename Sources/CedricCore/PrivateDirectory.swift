import Foundation

/// Cedric's folder in Application Support (~/Library/Application
/// Support/Cedric) holds the CLI token and the session's unsaved buffers,
/// so it and the folders Cedric makes in it are owner-only (0700). The
/// `cedric` script makes it the same way (mkdir -p -m 700).
public enum PrivateDirectory {
    /// ~/Library/Application Support/Cedric
    public static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Cedric", isDirectory: true)
    }

    public enum Failure: Error, Equatable {
        /// `path` can't be used as a private folder: `why` says what it is.
        case notPrivate(path: String, why: String)
    }

    /// Makes `dir` and any missing parents 0700. `dir`, and `root` when
    /// `dir` is inside it, are tightened to 0700 if they already exist
    /// wider (made by an older version); only this user's own real folders,
    /// never through a symbolic link. Then each must be a real folder (not
    /// a link), owned by this user, exactly 0700, or this throws.
    public static func make(_ dir: URL, root: URL = supportRoot) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        tighten(dir.path)
        try verify(dir.path)
        let r = root.standardizedFileURL.path, d = dir.standardizedFileURL.path
        if d != r, d.hasPrefix(r.hasSuffix("/") ? r : r + "/") {
            tighten(r)
            try verify(r)
        }
    }

    /// Keeps `dir` out of Time Machine (and other backups that honour the
    /// flag): the session's unsaved text and Replace in Files' originals
    /// are working state on this Mac, not documents to keep copies of.
    /// Best effort: a volume that can't hold the flag is left as it is.
    public static func excludeFromBackup(_ dir: URL) {
        var url = dir
        if (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Throws unless `path` (not followed if it is a link) is this user's
    /// own folder with mode 0700.
    static func verify(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Failure.notPrivate(path: path, why: "missing") }
        if st.st_mode & S_IFMT == S_IFLNK { throw Failure.notPrivate(path: path, why: "a symbolic link") }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw Failure.notPrivate(path: path, why: "not a folder") }
        guard st.st_uid == getuid() else { throw Failure.notPrivate(path: path, why: "owned by another user") }
        guard st.st_mode & 0o7777 == 0o700 else {
            throw Failure.notPrivate(path: path, why: "mode \(String(st.st_mode & 0o7777, radix: 8))")
        }
    }

    /// Writes `data` to `url` as a 0600 file, replacing it atomically: a
    /// temp file made 0600 by mkstemp in the same folder, then renamed over
    /// `url`, so the contents are never readable by others, even briefly.
    ///
    /// `durable`: also on the disk itself, not just in caches, before this
    /// returns (power loss): the temp file is flushed (F_FULLFSYNC, or
    /// fsync where the file system has no full flush) before the rename,
    /// and the folder after it, so the new name and the bytes it points to
    /// are both there. Writes made durable one after another reach the
    /// disk in that order. A failed flush or close throws, and the old file
    /// stays. `failSync` (check builds): the flush fails, as on a dying disk.
    public static func writePrivateFile(_ data: Data, to url: URL, durable: Bool = false, failSync: Bool = false) throws {
        let dir = url.deletingLastPathComponent().path
        var template = Array((dir + "/." + url.lastPathComponent + ".XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw failure(errno) }
        let tmp = String(cString: template)
        var code: Int32 = fchmod(fd, 0o600) == 0 ? 0 : errno
        if code == 0 {
            code = data.withUnsafeBytes { buf -> Int32 in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; return errno }
                    off += n
                }
                return 0
            }
        }
        if code == 0, durable { code = (failSync && DevEnvironment.checksEnabled) ? EIO : flush(fd) }
        if close(fd) != 0, code == 0 { code = errno }
        if code == 0, rename(tmp, url.path) != 0 { code = errno }
        guard code == 0 else {
            unlink(tmp)
            throw failure(code)
        }
        if durable { try syncFolder(dir) }
    }

    /// The folder's entries (a rename, an unlink) on the disk itself.
    public static func syncFolder(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        var code = flush(fd)
        if close(fd) != 0, code == 0 { code = errno }
        if code != 0 { throw failure(code) }
    }

    /// F_FULLFSYNC (through the drive's own cache), else fsync on file
    /// systems that don't support it; 0 or the error.
    static func flush(_ fd: Int32) -> Int32 {
        while true {
            if fcntl(fd, F_FULLFSYNC) == 0 { return 0 }
            let e = errno
            if e == EINTR { continue }
            guard e == ENOTSUP || e == EOPNOTSUPP || e == EINVAL || e == ENOTTY else { return e }
            while true {
                if fsync(fd) == 0 { return 0 }
                if errno != EINTR { return errno }
            }
        }
    }

    private static func failure(_ code: Int32) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }

    /// chmod 0700 if `path` is this user's own folder (not a link) that
    /// others can reach. True if it is (now) owner-only.
    @discardableResult
    static func tighten(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o7777 == 0o700 { return true }
        return chmod(path, 0o700) == 0
    }
}
