import Foundation

/// What a file looked like on disk when Cedric last read or wrote it: its
/// modification date, size and identity (device and inode). Compared before ⌘S (so a save never
/// silently overwrites another app's changes) and when a window becomes
/// key (the "Changed on disk" bar).
public struct DiskStamp: Equatable, Sendable {
    /// Which file it is: its device and inode. Another file put in its
    /// place (an atomic replace, a link pointed elsewhere) has another,
    /// even with the same date and size.
    public struct FileID: Codable, Equatable, Sendable {
        public var device: UInt64
        public var inode: UInt64
        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    public var modified: Date?
    public var size: Int?
    public var identity: FileID?

    public init(modified: Date?, size: Int? = nil, identity: FileID? = nil) {
        self.modified = modified
        self.size = size
        self.identity = identity
    }

    /// The stamp of the file `st` describes (from `stat` or `fstat`).
    public init(_ st: stat) {
        let t = st.st_mtimespec
        self.init(modified: Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9),
                  size: Int(st.st_size),
                  identity: FileID(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino)))
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
    /// target has gone has no stamp (the file is missing). From `stat`,
    /// so it carries the target's identity: a link pointed at another
    /// file with the same date and size is still a change.
    public static func of(_ url: URL) -> DiskStamp? {
        var st = stat()
        guard stat(SafePaths.writeTarget(for: url).path, &st) == 0 else { return nil }
        return DiskStamp(st)
    }

    /// This stamp for a tab that shows only the file's first `bytes` bytes
    /// (Follow File, which holds back half a character or a trailing CR
    /// until the writer finishes it): with fewer bytes shown than the file
    /// has, the size no longer matches, so ⌘S asks (the conflict sheet)
    /// instead of writing the shorter text over the bytes never shown.
    /// Nil `bytes`: the shown text isn't the file's bytes at all; the
    /// size matches nothing.
    public func showing(_ bytes: UInt64?) -> DiskStamp {
        var s = self
        if let bytes, let size, UInt64(size) == bytes { return s }
        s.size = bytes.map { Int($0) } ?? -1
        return s
    }

    /// Dates round-trip through the session file as Doubles: anything
    /// closer than this is the same date.
    public static let tolerance: TimeInterval = 0.001

    /// Whether the file on disk (`current`) is no longer what `known`
    /// describes. Unknown on either side, or a file that has gone, is not
    /// a change (saving then just writes it). The size and the identity
    /// count only when both sides know them (a stamp from a session saved
    /// before 0.5.4 has neither): another file in its place, by an atomic
    /// replace or a retargeted link, is a change even with the same date
    /// and size.
    public static func changed(known: DiskStamp?, current: DiskStamp?) -> Bool {
        guard let known, let current, let k = known.modified, let c = current.modified else { return false }
        if abs(c.timeIntervalSince(k)) > tolerance { return true }
        if let ks = known.size, let cs = current.size, ks != cs { return true }
        if let ki = known.identity, let ci = current.identity, ki != ci { return true }
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
