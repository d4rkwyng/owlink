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
        guard fstatat(dir, name, &st, 0) == 0 else { return nil }
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
    /// a read-only file of the same name.
    public static func write(_ data: Data, to url: URL, fileManager fm: FileManager = .default) throws {
        try write(data, to: url, fileManager: fm, afterCheck: nil)
    }

    /// `afterCheck`: tests only, runs between the check and the write.
    static func write(_ data: Data, to url: URL, fileManager fm: FileManager, afterCheck: (() -> Void)?) throws {
        // Again only if the target became a link while it was resolved.
        for _ in 0..<3 {
            let target = SafePaths.writeTarget(for: url, fileManager: fm)
            let dirPath = target.deletingLastPathComponent().path
            let name = target.lastPathComponent
            let dir = open(dirPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dir >= 0 else {
                let code = errno
                // A folder this user may write in but not read. Without a
                // handle on it the check and the write go by path, which is
                // only safe when no link is on the way to it.
                guard code == EACCES || code == EPERM, !hasLink(dirPath) else { throw writeError(code, url) }
                if let reason = FileWriteAccess.blocked(target: target) {
                    throw ReadOnlyFileError(url: url, reason: reason)
                }
                afterCheck?()
                try data.write(to: target, options: .atomic)
                return
            }
            defer { close(dir) }
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFLNK { continue }
            if let reason = FileWriteAccess.blocked(in: dir, name: name) {
                throw ReadOnlyFileError(url: url, reason: reason)
            }
            afterCheck?()
            try replace(name, in: dir, with: data, url: url)
            return
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
    }

    /// Writes `data` to a new file in `dir` and renames it over `name`.
    private static func replace(_ name: String, in dir: Int32, with data: Data, url: URL) throws {
        let temp = ".owlink-save-\(UUID().uuidString)"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw writeError(errno, url) }
        var renamed = false
        defer { if !renamed { _ = unlinkat(dir, temp, 0) } }
        do {
            // What an atomic save keeps of the file it replaces.
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                _ = fchmod(fd, st.st_mode & 0o7777)
                let old = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if old >= 0 {
                    _ = fcopyfile(old, fd, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
                    close(old)
                }
            }
            try writeAll(data, to: fd, url: url)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw writeError(errno, url) }
        guard renameat(dir, temp, dir, name) == 0 else { throw writeError(errno, url) }
        renamed = true
    }

    private static func writeAll(_ data: Data, to fd: Int32, url: URL) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var done = 0
            while done < buf.count {
                let n = Darwin.write(fd, base + done, buf.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw writeError(errno, url)
                }
                done += n
            }
        }
    }

    /// Some folder on `path` is a symbolic link.
    private static func hasLink(_ path: String) -> Bool {
        guard let real = realpath(path, nil) else { return true }
        defer { free(real) }
        return String(cString: real) != (path as NSString).standardizingPath
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
