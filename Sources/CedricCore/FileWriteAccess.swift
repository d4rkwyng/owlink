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
        if access(path, W_OK) != 0 {
            switch errno {
            case EROFS: return .readOnlyVolume
            case EPERM: return .locked
            default: return .permissions
            }
        }
        return nil
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
    /// The link is resolved once, and that target is both checked and
    /// written. Resolving it again for the write (0.5.3) let a link
    /// retargeted in between have a writable file checked and a
    /// read-only one replaced.
    public static func write(_ data: Data, to url: URL, fileManager fm: FileManager = .default) throws {
        try write(data, to: url, fileManager: fm, afterCheck: nil)
    }

    /// `afterCheck`: tests only, runs between the check and the write.
    static func write(_ data: Data, to url: URL, fileManager fm: FileManager, afterCheck: (() -> Void)?) throws {
        let target = SafePaths.writeTarget(for: url, fileManager: fm)
        if let reason = FileWriteAccess.blocked(target: target) {
            throw ReadOnlyFileError(url: url, reason: reason)
        }
        afterCheck?()
        try data.write(to: target, options: .atomic)
    }
}
