import Foundation

/// Whether a save may replace a file on disk. A save writes a new file
/// and renames it over the old one (an atomic write), which only needs a
/// writable folder: without this check a `chmod 444` file, a Finder-locked
/// file or a file on a read-only volume the user can still rename in was
/// silently replaced (0.5.2). Replace in Files already honours the file's
/// own permission (FileReplace.refusal); this is the same rule for a tab.
///
/// A tab on such a file is read-only (the manual: "A read-only document
/// never applies"): typing is off until Allow Editing, Cedric's Apply is
/// off, and Save offers Save As instead of writing over it. The check
/// runs again on save, when the window becomes key and before Apply, so a
/// `chmod 644` (or 444) while the file is open takes effect.
public enum FileWriteAccess {
    /// Why a file can't be written.
    public enum Blocked: String, Sendable, Equatable {
        /// No write permission for this user (mode bits or ACL), e.g. 0444.
        case permissions
        /// Locked in Finder (the user or system immutable flag).
        case locked
        /// On a volume mounted read-only.
        case readOnlyVolume
    }

    /// Why the file a save through `url` would replace (a symbolic link's
    /// target, SafePaths.writeTarget) can't be written; nil when it can,
    /// or when it doesn't exist (a save creates it; the folder decides).
    public static func blocked(at url: URL, fileManager fm: FileManager = .default) -> Blocked? {
        blocked(target: SafePaths.writeTarget(for: url, fileManager: fm))
    }

    /// Why `target`, a path `SafePaths.writeTarget` already resolved,
    /// can't be written; nil as for `blocked(at:)`.
    static func blocked(target: URL) -> Blocked? {
        let path = target.path
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .locked }
        var fs = statfs()
        if statfs(path, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnlyVolume }
        if access(path, W_OK) != 0 { return accessRefusal(errno) }
        return nil
    }

    /// Why the entry `name` in the open folder `dir` can't be written;
    /// nil as for `blocked(at:)`. The folder is the handle a save then
    /// writes through (DocumentWrite), so a link on the way to it can't
    /// be retargeted between the check and the write.
    static func blocked(in dir: Int32, name: String) -> Blocked? {
        var st = stat()
        return blocked(in: dir, name: name, checked: &st)
    }

    /// As `blocked(in:name:)`; `checked` gets the file the check looked
    /// at (`st_ino` 0 when there is none), so a write can make sure it
    /// opened that same file.
    static func blocked(in dir: Int32, name: String, checked st: inout stat) -> Blocked? {
        st = stat()
        guard fstatat(dir, name, &st, 0) == 0 else { st = stat(); return nil }
        if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .locked }
        var fs = statfs()
        if fstatfs(dir, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnlyVolume }
        if faccessat(dir, name, W_OK, 0) != 0 { return accessRefusal(errno) }
        return nil
    }

    private static func accessRefusal(_ code: Int32) -> Blocked {
        switch code {
        case EROFS: return .readOnlyVolume
        case EPERM: return .locked
        default: return .permissions
        }
    }

    /// The tab's bar: what is read-only and why.
    public static func notice(_ reason: Blocked, name: String) -> String {
        switch reason {
        case .permissions:
            return String(localized: "“\(name)” is read-only: you don’t have permission to change it. Owlink won’t save over it; use Save As to keep your edits.")
        case .locked:
            return String(localized: "“\(name)” is locked. Owlink won’t save over it; unlock it in the Finder’s Get Info, or use Save As to keep your edits.")
        case .readOnlyVolume:
            return String(localized: "“\(name)” is on a read-only volume. Owlink won’t save over it; use Save As to keep your edits.")
        }
    }

    /// The window (and tab) title of a read-only file's tab (before the
    /// unsaved mark, EditedIndicator).
    public static func windowTitle(_ title: String, readOnly: Bool) -> String {
        readOnly ? title + " — " + String(localized: "Read-Only") : title
    }
}

/// Save refused: the file is read-only (FileWriteAccess).
public struct ReadOnlyFileError: LocalizedError, Equatable {
    public let url: URL
    public let reason: FileWriteAccess.Blocked
    public init(url: URL, reason: FileWriteAccess.Blocked) {
        self.url = url
        self.reason = reason
    }
    public var errorDescription: String? {
        String(localized: "Couldn’t save “\(url.lastPathComponent)”: it is read-only.")
    }
    public var recoverySuggestion: String? {
        FileWriteAccess.notice(reason, name: url.lastPathComponent)
    }
}

/// The one way a document save writes its bytes (Mac tabs, Save a Copy,
/// export; shared with iOS): through a symbolic link to its target, an
/// atomic replacement, and never over a read-only file.
public enum DocumentWrite {
    /// Writes `data` to the file a save through `url` replaces. Throws
    /// ReadOnlyFileError, leaving the file untouched, when it is read-only.
    ///
    /// The link is resolved once, its target's folder is opened, and the
    /// check and the atomic write both go through that open folder: a new
    /// file is written next to the target and renamed over it
    /// (`renameat`), keeping the target's mode, ACL and extended
    /// attributes. Resolving the link again for the write (0.5.3) let a
    /// link retargeted in between have a writable file checked and a
    /// read-only one replaced; writing by path (0.5.4 before review) still
    /// let a link to a folder on the way be retargeted at a folder holding
    /// a read-only file of the same name. A folder that refuses the new
    /// file (0555) gets the checked file written in place instead, still
    /// through the open folder (`overwrite`).
    public static func write(_ data: Data, to url: URL, fileManager fm: FileManager = .default) throws {
        try write(data, to: url, fileManager: fm, afterCheck: nil)
    }

    /// Failures the tests inject into the in-place save (`overwrite`).
    struct Faults {
        /// Write this many bytes of the new text, then fail with EIO.
        var failWriteAfter: Int?
        /// Fail putting the file back with EIO.
        var failRestore = false
        /// Skip the file-size limit check, so the kernel's limit is hit
        /// part way through the write.
        var skipSizeLimit = false
    }

    /// `afterCheck`: tests only, runs between the check and the write.
    static func write(_ data: Data, to url: URL, fileManager fm: FileManager, afterCheck: (() -> Void)?,
                      faults: Faults? = nil) throws {
        // Again only if the target became a link while it was resolved.
        for _ in 0..<3 {
            let target = SafePaths.writeTarget(for: url, fileManager: fm)
            let name = target.lastPathComponent
            let dir = try openFolder(target.deletingLastPathComponent().path, url: url)
            defer { close(dir) }
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFLNK { continue }
            var checked = stat()
            if let reason = FileWriteAccess.blocked(in: dir, name: name, checked: &checked) {
                throw ReadOnlyFileError(url: url, reason: reason)
            }
            afterCheck?()
            if try replace(name, in: dir, with: data, url: url) { return }
            // The folder refuses a new file (0555, or search-only 0100):
            // write the checked file in place, through the same folder.
            guard checked.st_ino != 0 else { throw writeError(EACCES, url) }
            try overwrite(name, in: dir, checked: checked, with: data, url: url, faults: faults)
            return
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
    }

    /// The folder a save checks and writes through. One this user may
    /// write in but not read (0300) is opened for search only
    /// (`O_SEARCH`), which is all `fstatat`, `openat` and `renameat`
    /// need; so is one this user may only search (0100). A folder that
    /// can't be opened even for search can't be passed through to reach
    /// the file either, so the save fails with that error. 0.5.4 before
    /// review then checked and wrote by path, and a folder on that path
    /// replaced by a link in between had the check pass on a writable
    /// file and the rename replace a read-only one elsewhere.
    private static func openFolder(_ path: String, url: URL) throws -> Int32 {
        var dir = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dir < 0, errno == EACCES || errno == EPERM {
            dir = open(path, O_EXEC | O_DIRECTORY | O_CLOEXEC)
        }
        guard dir >= 0 else { throw writeError(errno, url) }
        return dir
    }

    /// Writes `data` to a new file in `dir` and renames it over `name`.
    /// False, with nothing written, when the folder refuses a new file
    /// (`overwrite` then writes the checked file in place).
    private static func replace(_ name: String, in dir: Int32, with data: Data, url: URL) throws -> Bool {
        let temp = ".owlink-save-\(UUID().uuidString)"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM { return false }
            throw writeError(code, url)
        }
        var renamed = false
        defer { if !renamed { _ = unlinkat(dir, temp, 0) } }
        do {
            // What an atomic save keeps of the file it replaces.
            // Only a regular file's, and never a blocking open: a FIFO
            // put there in between would stall a plain read open.
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG {
                _ = fchmod(fd, st.st_mode & 0o7777)
                let old = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if old >= 0 {
                    _ = fcopyfile(old, fd, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
                    close(old)
                }
            }
            try writeAll(data, to: fd, at: 0, url: url)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw writeError(errno, url) }
        guard renameat(dir, temp, dir, name) == 0 else { throw writeError(errno, url) }
        renamed = true
        return true
    }

    /// The save into a folder that refuses a new file (a writable file
    /// in a 0555 folder): not atomic, but bound to the checked file. It
    /// is opened through the same open folder, never through a link
    /// (`O_NOFOLLOW`), and only if it is still the file the check looked
    /// at (device and inode) is it written. Opening for writing is itself
    /// the kernel's permission check on that very file, so a read-only
    /// file put in its place can't be opened, and a different writable
    /// one fails the identity match: either way the save fails with an
    /// error and nothing else is touched. The open doesn't block
    /// (`O_NONBLOCK`): a FIFO put there fails the regular-file check
    /// instead of stalling the save. (0.5.3 fell back to Foundation's
    /// atomic write by path here.)
    ///
    /// A failed write never leaves the file destroyed. 0.5.4 before QA
    /// truncated it to nothing first, so a full disk (ENOSPC), a quota or
    /// a file-size limit part way through left it empty or holding the
    /// start of the new text. Now:
    ///
    /// - The save is refused before anything is written when the new text
    ///   is larger than the process's file-size limit (RLIMIT_FSIZE; the
    ///   app ignores SIGXFSZ, `ignoreFileSizeSignal`, so a limit hit
    ///   anyway is an EFBIG error, not a crash), when the volume has less
    ///   free space than the new text, or can't preallocate the growth.
    /// - The file as it is is copied to a recovery copy in a private
    ///   temporary folder (`makeRecoveryCopy`, 64 KB at a time) and the
    ///   copy is flushed to disk. If the copy can't be made, or the file
    ///   is shorter than it was or changed while it was copied, nothing is
    ///   written.
    /// - The new bytes are written over the old ones, the file is cut to
    ///   the new length and flushed; then the recovery copy is deleted.
    /// - If any of that fails, the file is put back from the recovery copy
    ///   (bytes and length) and the error is thrown. If putting it back
    ///   fails too, the recovery copy is kept and the error's recovery
    ///   suggestion says where it is.
    ///
    /// Not covered (0.6): another program writing the file during the
    /// save; its changes can be lost, as with any in-place write.
    private static func overwrite(_ name: String, in dir: Int32, checked: stat, with data: Data, url: URL,
                                  faults: Faults?) throws {
        let fd = openat(dir, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw writeError(errno, url) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw writeError(errno, url) }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_dev == checked.st_dev, st.st_ino == checked.st_ino else {
            throw writeError(EBUSY, url)
        }
        // The checked regular file: back to ordinary blocking I/O.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw writeError(errno, url) }
        if faults?.skipSizeLimit != true, !withinFileSizeLimit(data.count) { throw writeError(EFBIG, url) }
        var fs = statfs()
        if fstatfs(fd, &fs) == 0, !enoughSpace(for: data.count, in: fs) { throw writeError(ENOSPC, url) }
        let oldCount = Int(st.st_size)
        if data.count > oldCount {
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(data.count - oldCount), fst_bytesalloc: 0)
            if fcntl(fd, F_PREALLOCATE, &store) == -1, errno == ENOSPC || errno == EDQUOT || errno == EFBIG {
                throw writeError(errno, url)
            }
        }
        // Changed while it was copied (another program writing it): the
        // copy may not be the file, so nothing is written. (The baseline
        // is taken after preallocating, which can touch the times.)
        var before = stat(), now = stat()
        guard fstat(fd, &before) == 0, before.st_size == st.st_size else { throw writeError(EBUSY, url) }
        let recovery = try makeRecoveryCopy(of: fd, count: oldCount, name: name, url: url)
        guard fstat(fd, &now) == 0, now.st_size == before.st_size,
              now.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, now.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              now.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, now.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            removeRecoveryCopy(recovery)
            throw writeError(EBUSY, url)
        }
        do {
            if let n = faults?.failWriteAfter {
                try writeAll(data.prefix(n), to: fd, at: 0, url: url)
                throw writeError(EIO, url)
            }
            try writeAll(data, to: fd, at: 0, url: url)
            if data.count < oldCount, ftruncate(fd, off_t(data.count)) != 0 { throw writeError(errno, url) }
            guard fsync(fd) == 0 else { throw writeError(errno, url) }
        } catch {
            do {
                if faults?.failRestore == true { throw writeError(EIO, url) }
                try restore(fd, from: recovery, count: oldCount, url: url)
            } catch {
                throw keptRecoveryCopy(recovery, after: error, url: url)
            }
            removeRecoveryCopy(recovery)
            throw error
        }
        removeRecoveryCopy(recovery)
    }

    /// For the app to call once at launch: a write past the file-size
    /// limit (RLIMIT_FSIZE) then fails with EFBIG, which a save can
    /// recover from, instead of SIGXFSZ ending the app.
    public static func ignoreFileSizeSignal() {
        signal(SIGXFSZ, SIG_IGN)
    }

    /// Whether a `count`-byte file is within this process's file-size limit.
    static func withinFileSizeLimit(_ count: Int) -> Bool {
        var lim = rlimit()
        // RLIM_INFINITY, a macro Swift doesn't import.
        let infinity = (rlim_t(1) << 63) - 1
        guard getrlimit(RLIMIT_FSIZE, &lim) == 0, lim.rlim_cur < infinity else { return true }
        return UInt64(count) <= UInt64(lim.rlim_cur)
    }

    /// Copies the first `count` bytes of `fd` to a new file named `name`
    /// in a new private (0700) folder in this user's temporary folder,
    /// and flushes it to disk. Throws, leaving nothing behind, if the copy
    /// fails or `fd` holds fewer than `count` bytes.
    static func makeRecoveryCopy(of fd: Int32, count: Int, name: String, url: URL) throws -> URL {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("owlink-recovery-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw writeError(errno, url) }
        let folder = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        do {
            let out = open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw writeError(errno, url) }
            defer { close(out) }
            let copied = try copyBytes(from: fd, to: out, count: count, url: url)
            guard copied == count else { throw writeError(EBUSY, url) }
            guard fsync(out) == 0 else { throw writeError(errno, url) }
        } catch {
            removeRecoveryCopy(copy)
            throw error
        }
        return copy
    }

    /// Puts the file back from its recovery copy: its bytes, its length, flushed.
    private static func restore(_ fd: Int32, from recovery: URL, count: Int, url: URL) throws {
        let src = open(recovery.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard src >= 0 else { throw writeError(errno, url) }
        defer { close(src) }
        guard try copyBytes(from: src, to: fd, count: count, url: url) == count else { throw writeError(EIO, url) }
        guard ftruncate(fd, off_t(count)) == 0, fsync(fd) == 0 else { throw writeError(errno, url) }
    }

    private static func removeRecoveryCopy(_ copy: URL) {
        _ = unlink(copy.path)
        _ = rmdir(copy.deletingLastPathComponent().path)
    }

    /// The save's error, saying where the recovery copy is: the file
    /// couldn't be put back, so the copy is the only whole one left.
    private static func keptRecoveryCopy(_ copy: URL, after error: Error, url: URL) -> Error {
        let ns = error as NSError
        var info = ns.userInfo
        info[NSURLErrorKey] = url
        info[NSFilePathErrorKey] = url.path
        info[NSLocalizedRecoverySuggestionErrorKey] = String(localized: """
            Owlink couldn’t put “\(url.lastPathComponent)” back as it was before the save. \
            A copy of it as it was is at \(copy.path). Your text is still in the tab.
            """)
        info["OwlinkRecoveryCopy"] = copy.path
        return CocoaError(CocoaError.Code(rawValue: ns.domain == NSCocoaErrorDomain ? ns.code : CocoaError.fileWriteUnknown.rawValue),
                          userInfo: info)
    }

    /// Whether the volume `fs` describes has room for a `count`-byte
    /// save. The whole new text must fit in the space this user may use
    /// (`f_bavail`), as it must for the usual replace: a copy-on-write
    /// volume (APFS) needs new blocks even to write over old ones.
    static func enoughSpace(for count: Int, in fs: statfs) -> Bool {
        let free = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_bsize))
        return free.overflow || free.partialValue >= UInt64(count)
    }

    /// Copies up to `count` bytes from the start of `src` to the start of
    /// `dst`, 64 KB at a time; how many it copied (fewer if `src` ends).
    private static func copyBytes(from src: Int32, to dst: Int32, count: Int, url: URL) throws -> Int {
        var buffer = Data(count: min(count, 1 << 16))
        var done = 0
        while done < count {
            let want = min(buffer.count, count - done)
            let n = buffer.withUnsafeMutableBytes { pread(src, $0.baseAddress, want, off_t(done)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw writeError(errno, url)
            }
            if n == 0 { break }
            try writeAll(buffer.prefix(n), to: dst, at: off_t(done), url: url)
            done += n
        }
        return done
    }

    private static func writeAll(_ data: Data, to fd: Int32, at offset: off_t, url: URL) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var done = 0
            while done < buf.count {
                let n = pwrite(fd, base + done, buf.count - done, offset + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw writeError(errno, url)
                }
                // No progress and no error: fail rather than loop forever.
                if n == 0 { throw writeError(EIO, url) }
                done += n
            }
        }
    }

    private static func writeError(_ code: Int32, _ url: URL) -> Error {
        let kind: CocoaError.Code
        switch code {
        case EACCES, EPERM: kind = .fileWriteNoPermission
        case ENOSPC, EDQUOT: kind = .fileWriteOutOfSpace
        case EROFS: kind = .fileWriteVolumeReadOnly
        case ENOENT, ENOTDIR: kind = .fileNoSuchFile
        default: kind = .fileWriteUnknown
        }
        let underlying = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) as NSError
        return CocoaError(kind, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: underlying])
    }
}
