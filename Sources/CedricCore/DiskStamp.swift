import Foundation

/// What a file looked like on disk when Cedric last read or wrote it: its
/// modification date and size. Compared before ⌘S (so a save never
/// silently overwrites another app's changes) and when a window becomes
/// key (the "Changed on disk" bar).
public struct DiskStamp: Equatable, Sendable {
    public var modified: Date?
    public var size: Int?

    public init(modified: Date?, size: Int? = nil) {
        self.modified = modified
        self.size = size
    }

    /// The file's stamp now; nil if it can't be read (gone, no access).
    /// A fresh URL each time: URL caches resource values, so asking the
    /// document's own URL again can return the date from before a write.
    ///
    /// Through a symbolic link this is the stamp of the file a save would
    /// write (its target, SafePaths.writeTarget, as DocumentWrite uses):
    /// Foundation reports the link's own date and size, so before 0.5.4's
    /// QA another app rewriting the target, or the link being pointed at
    /// another file, was never seen and ⌘S wrote over it. A link whose
    /// target has gone has no stamp (the file is missing).
    public static func of(_ url: URL) -> DiskStamp? {
        let fresh = URL(fileURLWithPath: SafePaths.writeTarget(for: url).path)
        guard let v = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return DiskStamp(modified: v.contentModificationDate, size: v.fileSize)
    }

    /// Dates round-trip through the session file as Doubles: anything
    /// closer than this is the same date.
    public static let tolerance: TimeInterval = 0.001

    /// Whether the file on disk (`current`) is no longer what `known`
    /// describes. Unknown on either side, or a file that has gone, is not
    /// a change (saving then just writes it). The size counts only when
    /// both sides know it (a stamp from a session file has no size).
    public static func changed(known: DiskStamp?, current: DiskStamp?) -> Bool {
        guard let known, let current, let k = known.modified, let c = current.modified else { return false }
        if abs(c.timeIntervalSince(k)) > tolerance { return true }
        if let ks = known.size, let cs = current.size, ks != cs { return true }
        return false
    }

    /// What happened to an open file since Cedric last read or wrote it.
    public enum Status: Equatable, Sendable {
        /// Still what Cedric last saw (or nothing is known to compare).
        case same
        /// Another app rewrote it.
        case changed
        /// Deleted, or moved or renamed away: nothing at its path any more.
        case missing
    }

    /// `changed`, plus a file that has gone. Missing needs a known date
    /// (the file was really on disk when read or saved; a path never
    /// written yet isn't "deleted") and `exists` false: a stamp that can't
    /// be read while the file is still there (no access) is not missing.
    public static func status(known: DiskStamp?, current: DiskStamp?, exists: Bool) -> Status {
        if !exists, current == nil, known?.modified != nil { return .missing }
        return changed(known: known, current: current) ? .changed : .same
    }

    /// `status` for the file at `url` now.
    public static func status(known: DiskStamp?, at url: URL) -> Status {
        status(known: known, current: of(url), exists: FileManager.default.fileExists(atPath: url.path))
    }
}
