import Foundation

/// The ⌘S sheet for a file that changed on disk since the tab read or
/// saved it, in the read-only bar's voice. 0.5.4 said "was changed by
/// another app" even when Owlink had changed it (its own save that failed
/// part way, or a save from another of its tabs) and called the file on
/// disk "Theirs". Now the sheet says what Owlink knows, and no more.
public enum DiskConflict {
    /// What Owlink knows about the change.
    public enum Cause: Equatable, Sendable {
        /// Changed since this tab read the file (opened or reloaded it).
        case sinceOpened
        /// Changed since this tab saved it.
        case sinceSaved
        /// Owlink's own save from this tab failed part way and left the
        /// file as it is now.
        case ownFailedSave
        /// Saved from another Owlink tab or window since.
        case savedInAnotherTab
    }

    public static var keepTitle: String { String(localized: "Keep What’s in This Tab") }
    public static var reloadTitle: String { String(localized: "Reload from Disk") }
    public static var compareTitle: String { String(localized: "Compare") }

    /// What the sheet says Owlink knows. `known`: the stamp this tab last
    /// read or saved; `lastSaved`: the stamp its last save left (nil: not
    /// saved here); `failedSave`: the stamp a failed save of this tab left
    /// the file with; `otherTabsSaved`: the stamps saves from Owlink's
    /// other tabs on this file left; `current`: the file now.
    public static func cause(known: DiskStamp, lastSaved: DiskStamp?, failedSave: DiskStamp?,
                             otherTabsSaved: [DiskStamp], current: DiskStamp?) -> Cause {
        if let current {
            if let failedSave, failedSave == current { return .ownFailedSave }
            if otherTabsSaved.contains(current) { return .savedInAnotherTab }
        }
        if let lastSaved, lastSaved == known { return .sinceSaved }
        return .sinceOpened
    }

    /// The sheet's bold line.
    public static func message(name: String) -> String {
        String(localized: "“\(name)” changed on disk.")
    }

    /// The sheet's text: what changed, then what each button does.
    public static func detail(_ cause: Cause) -> String {
        let what: String
        switch cause {
        case .sinceOpened:
            what = String(localized: "The file on disk changed since you opened it.")
        case .sinceSaved:
            what = String(localized: "The file on disk changed since Owlink last saved it.")
        case .ownFailedSave:
            what = String(localized: "Owlink’s last save of it from this tab didn’t finish, so the file on disk may not match what you saved before.")
        case .savedInAnotherTab:
            what = String(localized: "It was saved from another Owlink tab or window since this tab last read or saved it.")
        }
        return what + " " + String(localized: "\(keepTitle) replaces the file with this tab’s text. \(reloadTitle) replaces this tab’s text with the file (Undo brings yours back). \(compareTitle) shows the two side by side.")
    }
}
