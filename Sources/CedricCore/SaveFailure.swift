import Foundation

/// What a failed save says, in the read-only bar's voice: what went
/// wrong in plain words, that the text is still in the tab, and what to
/// do next (Save As…). 0.5.4's new in-place save failures (a file
/// replaced while saving: EBUSY; a pipe put in its place: ENXIO) showed
/// only Foundation's "The file “x” couldn’t be saved in the folder “y”."
/// with an empty body and a lone OK.
public enum SaveFailure {
    /// Why the save failed, as far as the alert is concerned.
    public enum Cause: Equatable, Sendable {
        /// The file was replaced, or changed, while Owlink was writing it (EBUSY).
        case changedWhileSaving
        /// Not a regular file: a pipe, a socket or a device (ENXIO, EOPNOTSUPP…).
        case notAFile
        /// The disk (or this user's quota) is full.
        case outOfSpace
        /// Bigger than the volume or the file-size limit allows (EFBIG).
        case tooBig
        /// The file itself is read-only (FileWriteAccess).
        case readOnly(FileWriteAccess.Blocked)
        /// On a volume mounted read-only (EROFS).
        case readOnlyVolume
        /// No permission to write in its folder (EACCES, EPERM).
        case noPermission
        /// Its folder isn't there any more (ENOENT, ENOTDIR).
        case folderMissing
        /// The file couldn't be put back after a failed write; a copy of
        /// it as it was is at `path`.
        case keptRecoveryCopy(path: String)
        /// Anything else: the system's own words.
        case other(String)
    }

    /// What the alert offers besides Cancel.
    public enum Offer: Sendable {
        /// The tab's own save (⌘S, Save As, Keep What’s in This Tab): Save As….
        case saveAs
        /// Save a Copy: choose another place for the copy.
        case saveCopy
        /// An export: OK only.
        case none
    }

    /// The alert's text: `message` (bold) and `detail`.
    public struct Text: Equatable, Sendable {
        public let message: String
        public let detail: String
    }

    /// The cause `error` describes.
    public static func cause(of error: Error) -> Cause {
        if let ro = error as? ReadOnlyFileError { return .readOnly(ro.reason) }
        let ns = error as NSError
        if let copy = ns.userInfo["OwlinkRecoveryCopy"] as? String { return .keptRecoveryCopy(path: copy) }
        if let code = posixCode(ns) { return cause(posix: code, ns) }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return .outOfSpace
            case NSFileWriteVolumeReadOnlyError: return .readOnlyVolume
            case NSFileWriteNoPermissionError: return .noPermission
            case NSFileNoSuchFileError: return .folderMissing
            default: break
            }
        }
        return .other(ns.localizedFailureReason ?? ns.localizedDescription)
    }

    /// The POSIX error under `ns` (itself, or its underlying error).
    private static func posixCode(_ ns: NSError) -> Int32? {
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
        return nil
    }

    private static func cause(posix code: Int32, _ ns: NSError) -> Cause {
        switch code {
        case EBUSY: return .changedWhileSaving
        case ENXIO, EOPNOTSUPP, ENOTSUP, ESPIPE, EISDIR, ENODEV: return .notAFile
        case ENOSPC, EDQUOT: return .outOfSpace
        case EFBIG: return .tooBig
        case EROFS: return .readOnlyVolume
        case EACCES, EPERM: return .noPermission
        case ENOENT, ENOTDIR: return .folderMissing
        default:
            return .other(String(localized: "The system said: “\(String(cString: strerror(code)))”."))
        }
    }

    /// The alert for a failed save of `url`.
    public static func text(for error: Error, saving url: URL, offer: Offer) -> Text {
        text(for: cause(of: error), saving: url, offer: offer)
    }

    public static func text(for cause: Cause, saving url: URL, offer: Offer) -> Text {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        if case .readOnly(let reason) = cause {
            // The same words as ⌘S on a file that is read-only already.
            return Text(message: String(localized: "“\(name)” is read-only."), detail: FileWriteAccess.notice(reason, name: name))
        }
        let reason: String
        switch cause {
        case .changedWhileSaving:
            reason = String(localized: "“\(name)” was replaced or changed while Owlink was saving it, so Owlink stopped rather than write over it.")
        case .notAFile:
            reason = String(localized: "“\(name)” is not a regular file any more (it is a pipe or a device), so Owlink can’t save into it.")
        case .outOfSpace:
            reason = String(localized: "There isn’t enough space on the disk to save “\(name)”.")
        case .tooBig:
            reason = String(localized: "“\(name)” would be bigger than this disk or the file-size limit allows.")
        case .readOnlyVolume:
            reason = String(localized: "“\(name)” is on a read-only volume.")
        case .noPermission:
            reason = String(localized: "You don’t have permission to save in the folder “\(folder)”.")
        case .folderMissing:
            reason = String(localized: "The folder “\(folder)” isn’t there any more (it may have been moved or deleted).")
        case .keptRecoveryCopy(let path):
            reason = String(localized: "Owlink couldn’t put “\(name)” back as it was before the save. A copy of it as it was is at \(path).")
        case .other(let said):
            reason = said
        case .readOnly:
            reason = ""
        }
        let next: String
        switch offer {
        case .saveAs: next = String(localized: "Your text is still in this tab; use Save As to keep it somewhere else.")
        case .saveCopy: next = String(localized: "Nothing was copied. Your text is still in this tab; choose another place for the copy.")
        case .none: next = String(localized: "Your text is still in this tab.")
        }
        return Text(message: String(localized: "Couldn’t save “\(name)”."), detail: reason + " " + next)
    }
}
