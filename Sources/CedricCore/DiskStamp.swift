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

    /// A stamp from a session saved before 0.5.4: a date and nothing else.
    public var isDateOnly: Bool { size == nil && identity == nil }

    /// The file exactly as one `stat` saw it: device, inode, size, and
    /// the modification and change times to the nanosecond. A DiskStamp
    /// keeps the date as a Double and compares it within `tolerance`, which
    /// suits a stamp that went through the session file; this is for the
    /// short hop from ⌘S's conflict check to the writer's own check
    /// (DocumentWrite `seen`), where any difference at all means the file
    /// was written in between. 0.5.4 QA before review 3 carried only the
    /// tolerant stamp there, so a same-size edit within a millisecond of
    /// the check passed the writer and then became its baseline.
    public struct Exact: Equatable, Sendable {
        public var device: Int32
        public var inode: UInt64
        public var size: Int64
        public var modifiedSec: Int, modifiedNsec: Int
        public var changedSec: Int, changedNsec: Int

        public init(_ st: stat) {
            device = st.st_dev
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            modifiedSec = st.st_mtimespec.tv_sec; modifiedNsec = st.st_mtimespec.tv_nsec
            changedSec = st.st_ctimespec.tv_sec; changedNsec = st.st_ctimespec.tv_nsec
        }

        /// The file a save through `url` would write (as `DiskStamp.of`),
        /// with the stamp from the same `stat`; nil if it can't be read.
        public static func of(_ url: URL) -> (exact: Exact, stamp: DiskStamp)? {
            var st = stat()
            guard stat(SafePaths.writeTarget(for: url).path, &st) == 0 else { return nil }
            return (Exact(st), DiskStamp(st))
        }

        /// Whether `st` is this very file, not written since: every field equal.
        public func matches(_ st: stat) -> Bool { Exact(st) == self }
    }

    /// The stamp a tab restored with unsaved text (a session buffer,
    /// Reopen Closed Tab) starts from, for its file at `url`. Through a
    /// symbolic link a date-only stamp (`isDateOnly`) can't be trusted:
    /// 0.5.3 took the link's own date, not its target's, so it could match
    /// a different file's date (⌘S then wrote over that file without
    /// asking) or never match. Such a stamp is unverified: it matches no
    /// file (size -1), so the first ⌘S asks before writing. Any other
    /// stamp is kept as it is.
    public static func restored(_ stamp: DiskStamp, for url: URL, fileManager fm: FileManager = .default) -> DiskStamp {
        guard stamp.isDateOnly, SafePaths.writeTarget(for: url, fileManager: fm) != url.standardizedFileURL else { return stamp }
        return DiskStamp(modified: stamp.modified ?? .distantPast, size: -1, identity: nil)
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
