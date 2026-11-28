import Foundation

/// The iOS app's save rules ("Save automatically" on or off), as pure
/// decisions the app and the tests share.
public enum SavePolicy {
    /// UIDocument's autosave (its timer, going to the background, closing)
    /// saves only with the setting on and something to save, and not again
    /// after a save failed for a reason that can't change until the text or
    /// the encoding does (a character the encoding can't hold): it would
    /// only fail again.
    public static func shouldAutosave(saveAutomatically: Bool, hasUnsavedChanges: Bool,
                                      blockedUntilEdited: Bool = false) -> Bool {
        saveAutomatically && hasUnsavedChanges && !blockedUntilEdited
    }

    public enum CloseAction: Equatable, Sendable {
        /// Close at once (autosave saves first when it is on).
        case close
        /// Ask Save / Don't Save / Cancel.
        case ask
    }

    public static func onClose(saveAutomatically: Bool, hasUnsavedChanges: Bool) -> CloseAction {
        !saveAutomatically && hasUnsavedChanges ? .ask : .close
    }

    /// The explicit Save button in the bar: only with autosave off.
    public static func showsSaveButton(saveAutomatically: Bool) -> Bool { !saveAutomatically }
}

/// When the next recovery write may happen: at most one every `interval`
/// seconds, and at once if the last was longer ago than that.
public enum RecoveryThrottle {
    public static let interval: TimeInterval = 3

    /// Seconds to wait before writing, given the time since the last write
    /// (nil: none yet).
    public static func delay(sinceLastWrite: TimeInterval?, interval: TimeInterval = interval) -> TimeInterval {
        guard let s = sinceLastWrite, s >= 0, s < interval else { return 0 }
        return interval - s
    }
}

/// One document's unsaved text, written while it has unsaved changes so a
/// crash or a forced quit doesn't lose it.
public struct RecoveryRecord: Codable, Equatable, Sendable {
    public var documentPath: String
    public var displayName: String
    /// A bookmark to the document, to find it again after a relaunch.
    public var bookmark: Data?
    public var savedAt: Date
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding

    public init(documentPath: String, displayName: String, bookmark: Data?, savedAt: Date, text: String,
                encoding: TextEncoding, lineEnding: LineEnding) {
        self.documentPath = documentPath
        self.displayName = displayName
        self.bookmark = bookmark
        self.savedAt = savedAt
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    /// Worth offering: written after the document was last changed on disk
    /// (a document saved since, here or elsewhere, wins). No date for the
    /// document (it is gone or unreadable): offer it.
    public func isNewer(thanDocumentModified modified: Date?) -> Bool {
        guard let modified else { return true }
        return savedAt > modified
    }
}

/// The recovery files: one per document, in a private folder (0700, kept
/// out of backups), each written atomically (a 0600 temp file renamed over
/// the old one), so a crash mid-write leaves the previous copy intact.
///
/// Every store value on the same folder shares one lock: a read that sets
/// an unreadable file aside, a write and a clear of that folder run one at
/// a time, so a set-aside never moves (or unlinks) a copy a writer has
/// just put under the live name.
public struct RecoveryStore: Sendable {
    public let directory: URL
    /// The outermost folder on the store's path whose entry first use
    /// flushes even if it was there already (default: the store's parent).
    public let durableFrom: URL

    /// Check builds only: runs with the folder locked, after a file's bytes
    /// were read and found unreadable and before they are set aside.
    public var checkBeforeSetAside: (@Sendable (URL) -> Void)?
    /// Check builds only: reading a recovery file fails though it is there
    /// (an I/O error).
    public var checkFailRead = false
    /// Check builds only: setting a file aside fails (it stays where it is).
    public var checkFailSetAside = false
    /// Check builds only: lstat of a recovery file fails with this errno
    /// (ENOENT: it is missing; anything else: an error, not absence).
    public var checkStatErrno: Int32?
    /// Check builds only: runs when this value finds the folder locked by
    /// another thread, just before it waits for the lock.
    public var checkLockContended: (@Sendable () -> Void)?

    public init(directory: URL, durableFrom: URL? = nil) {
        self.directory = directory
        self.durableFrom = durableFrom ?? directory.deletingLastPathComponent()
    }

    /// The state every store value on one folder shares: its lock, and the
    /// folders made for it whose entry flush failed (flushed again before a
    /// write counts).
    private final class Folder: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var unconfirmed = Set<String>()

        private static let registryLock = NSLock()
        nonisolated(unsafe) private static var registry: [String: Folder] = [:]

        static func of(_ dir: URL) -> Folder {
            let key = dir.standardizedFileURL.path
            registryLock.lock(); defer { registryLock.unlock() }
            if let f = registry[key] { return f }
            let f = Folder()
            registry[key] = f
            return f
        }
    }

    private var folder: Folder { Folder.of(directory) }

    private func locked<T>(_ body: (Folder) throws -> T) rethrows -> T {
        let f = folder
        if !f.lock.try() {
            if DevEnvironment.checksEnabled, let hook = checkLockContended { hook() }
            f.lock.lock()
        }
        defer { f.lock.unlock() }
        return try body(f)
    }

    /// The file for a document path: a stable hash of the path (the record
    /// inside says which document it is).
    public func fileURL(forDocumentPath path: String) -> URL {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return directory.appendingPathComponent(String(format: "%016llx", h) + ".recovery")
    }

    /// Writes `record` durably. The folder and any missing parents are made
    /// one at a time, each new entry flushed through its parent (from
    /// `durableFrom` down, as the session store does): a failed flush fails
    /// the write, and a retry flushes them again, so no write is acknowledged
    /// in a folder whose path may not be on the disk. `make` runs on every
    /// write, so a replacement at the folder path is checked again.
    /// A live copy is read first, as a reader would: one that is there but
    /// can't be read or decoded is set aside before the new one replaces
    /// it, and if it can't be, the write fails and leaves it. A readable
    /// record of another document under this name (the name is a hash)
    /// is kept the same way, set aside as `foreign-`.
    public func write(_ record: RecoveryRecord, durable: Bool = true, failSync: Bool = false,
                      syncFolder: ((String) throws -> Void)? = nil) throws {
        let sync = syncFolder ?? PrivateDirectory.syncFolder
        try locked { f in
            try PrivateDirectory.make(directory, root: directory, durableFrom: durableFrom,
                                      unconfirmed: &f.unconfirmed, syncParent: sync)
            PrivateDirectory.excludeFromBackup(directory)
            let url = fileURL(forDocumentPath: record.documentPath)
            let kept: Bool
            switch live(url) {
            case .kept: kept = true
            case .record(let r) where r.documentPath != record.documentPath:
                kept = setAsideDamaged(at: url, kind: "foreign") == nil && entry(url) != .absent
            case .record, .none: kept = false
            }
            if kept {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            let data = try PropertyListEncoder().encode(record)
            try PrivateDirectory.writePrivateFile(data, to: url, durable: durable, failSync: failSync, syncFolder: sync)
        }
    }

    /// Absent only for a confirmed ENOENT; any other lstat error is not
    /// absence (the entry may be there).
    private enum Entry { case absent, present, unknown }

    private func entry(_ url: URL) -> Entry {
        var st = stat()
        let err: Int32
        if DevEnvironment.checksEnabled, let e = checkStatErrno {
            err = e
        } else if lstat(url.path, &st) == 0 {
            return .present
        } else {
            err = errno
        }
        return err == ENOENT ? .absent : .unknown
    }

    /// The file's bytes, read (not only opened).
    private func bytes(of url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Opened, then the read fails (a dying disk).
        if checkFailRead, DevEnvironment.checksEnabled { throw POSIXError(.EIO) }
        return try handle.readToEnd() ?? Data()
    }

    /// Moves an unreadable recovery file aside, next to it
    /// (`*.recovery.unreadable-<date>`; another document's record:
    /// `kind` "foreign"), so a later launch can still look at the bytes
    /// and a new write can use the original name. Copied there if it
    /// can't be moved. Returns the new URL, or nil if there was no file
    /// or it couldn't be kept.
    @discardableResult
    public func setAsideDamaged(at url: URL, kind: String = "unreadable", now: Date = Date()) -> URL? {
        locked { _ in
            let fm = FileManager.default
            guard entry(url) != .absent, !(checkFailSetAside && DevEnvironment.checksEnabled) else { return nil }
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
            func dest(_ tag: String) -> URL { url.appendingPathExtension("\(kind)-\(tag)") }
            var next = dest(stamp)
            var n = 0
            while fm.fileExists(atPath: next.path) {
                n += 1
                next = dest("\(stamp)-\(n)")
            }
            do {
                try fm.moveItem(at: url, to: next)
                return next
            } catch {
                do {
                    try fm.copyItem(at: url, to: next)
                    try? fm.removeItem(at: url)
                    return entry(url) == .absent ? next : nil
                } catch {
                    return nil
                }
            }
        }
    }

    private enum Live {
        /// Nothing under the live name (a confirmed ENOENT), or it was set aside.
        case none
        case record(RecoveryRecord)
        /// Unreadable, and it couldn't be set aside: still under the live name.
        case kept
    }

    /// The live file at `url`, with the folder locked: read and decoded, or
    /// (there, or not confirmed missing, but unreadable or undecodable) set
    /// aside. Readers, write and clear all go through this.
    private func live(_ url: URL) -> Live {
        locked { _ in
            switch entry(url) {
            case .absent: return .none
            case .present:
                if let data = try? bytes(of: url),
                   let r = try? PropertyListDecoder().decode(RecoveryRecord.self, from: data) { return .record(r) }
                // Gone since (ENOENT on open): nothing to keep.
                if entry(url) == .absent { return .none }
            case .unknown: break
            }
            if DevEnvironment.checksEnabled, let hook = checkBeforeSetAside { hook(url) }
            return setAsideDamaged(at: url) != nil || entry(url) == .absent ? .none : .kept
        }
    }

    /// A readable record from `url`, or nil. A file that is there but
    /// can't be read or decoded is set aside, not deleted and not left
    /// under the live name.
    private func record(fromFile url: URL) -> RecoveryRecord? {
        if case .record(let r) = live(url) { return r }
        return nil
    }

    public func read(documentPath path: String) -> RecoveryRecord? {
        guard let r = record(fromFile: fileURL(forDocumentPath: path)), r.documentPath == path else { return nil }
        return r
    }

    /// The record for `path` if it is newer than the document on disk.
    public func pending(documentPath path: String, documentModified: Date?) -> RecoveryRecord? {
        guard let r = read(documentPath: path), r.isNewer(thanDocumentModified: documentModified) else { return nil }
        return r
    }

    /// Every readable record, newest first.
    public func all() -> [RecoveryRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "recovery" }
            .compactMap { record(fromFile: $0) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// Deletes the copy for `path` once it has been read: one that can't
    /// be read is set aside instead (or, if it can't be, left), never
    /// deleted unseen. Another document's record under this name is left.
    public func clear(documentPath path: String) {
        locked { _ in
            let url = fileURL(forDocumentPath: path)
            guard case .record(let r) = live(url), r.documentPath == path else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A private copy of a document's bytes as opened, for Revert to Opened
/// Version. Kept in Caches (kept out of backups too), deleted when the
/// document closes, and not kept for files over `maxBytes`.
public struct RevertStore: Sendable {
    public static let maxBytes = 20 * 1024 * 1024

    public enum Kept: Equatable, Sendable {
        case kept
        /// Over the cap: nothing written.
        case tooLarge(bytes: Int)
        case failed
    }

    public let directory: URL
    public let maxBytes: Int

    public init(directory: URL, maxBytes: Int = RevertStore.maxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public func fileURL(id: String) -> URL { directory.appendingPathComponent(id + ".opened") }

    @discardableResult
    public func keep(_ data: Data, id: String) -> Kept {
        guard data.count <= maxBytes else { return .tooLarge(bytes: data.count) }
        do {
            try PrivateDirectory.make(directory, root: directory)
            PrivateDirectory.excludeFromBackup(directory)
            try PrivateDirectory.writePrivateFile(data, to: fileURL(id: id))
            return .kept
        } catch {
            return .failed
        }
    }

    public func load(id: String) -> Data? { try? Data(contentsOf: fileURL(id: id)) }

    public func clear(id: String) { try? FileManager.default.removeItem(at: fileURL(id: id)) }

    /// At launch no document is open: copies left by a crash go.
    public func clearAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opened" { try? FileManager.default.removeItem(at: f) }
    }
}
