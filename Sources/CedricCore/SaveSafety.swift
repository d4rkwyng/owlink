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
    /// (an I/O error), for reads and for write's look at the copy it replaces.
    public var checkFailRead = false
    /// Check builds only: setting a file aside fails (it stays where it is).
    public var checkFailSetAside = false

    public init(directory: URL, durableFrom: URL? = nil) {
        self.directory = directory
        self.durableFrom = durableFrom ?? directory.deletingLastPathComponent()
    }

    /// The state every store value on one folder shares: its lock, the
    /// folders made for it whose entry flush failed (flushed again before a
    /// write counts), and the live files that couldn't be read or kept.
    private final class Folder: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var unconfirmed = Set<String>()
        var ready = false
        /// Live names read as unreadable whose bytes couldn't be set aside:
        /// no write replaces them until they are.
        var held = Set<String>()

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
        f.lock.lock(); defer { f.lock.unlock() }
        return try body(f)
    }

    /// The file for a document path: a stable hash of the path (the record
    /// inside says which document it is).
    public func fileURL(forDocumentPath path: String) -> URL {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return directory.appendingPathComponent(String(format: "%016llx", h) + ".recovery")
    }

    /// Writes `record` durably. On first use the folder and any missing
    /// parents are made one at a time, each new entry flushed through its
    /// parent (from `durableFrom` down, as the session store does): a
    /// failed flush fails the write, and a retry flushes them again, so no
    /// write is acknowledged in a folder whose path may not be on the disk.
    /// A live file that is there but can't be read is set aside first; if
    /// its bytes can't be kept, the write fails rather than replace them.
    public func write(_ record: RecoveryRecord, durable: Bool = true, failSync: Bool = false,
                      syncFolder: ((String) throws -> Void)? = nil) throws {
        let sync = syncFolder ?? PrivateDirectory.syncFolder
        try locked { f in
            if !f.ready || !FileManager.default.fileExists(atPath: directory.path) {
                f.ready = false
                try PrivateDirectory.make(directory, root: directory, durableFrom: durableFrom,
                                          unconfirmed: &f.unconfirmed, syncParent: sync)
                f.ready = true
            }
            PrivateDirectory.excludeFromBackup(directory)
            let url = fileURL(forDocumentPath: record.documentPath)
            if f.held.contains(url.lastPathComponent) || !isReadable(url) {
                guard setAsideDamaged(at: url) != nil || !exists(url) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
                }
                f.held.remove(url.lastPathComponent)
            }
            let data = try PropertyListEncoder().encode(record)
            try PrivateDirectory.writePrivateFile(data, to: url, durable: durable, failSync: failSync, syncFolder: sync)
        }
    }

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// False only for a file that is there and can't be opened to read
    /// (missing counts as readable: nothing to keep).
    private func isReadable(_ url: URL) -> Bool {
        guard exists(url) else { return true }
        if checkFailRead, DevEnvironment.checksEnabled { return false }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Moves an unreadable recovery file aside, next to it
    /// (`*.recovery.unreadable-<date>`), so a later launch can still look
    /// at the bytes and a new write can use the original name. Copied
    /// there if it can't be moved. Returns the new URL, or nil if there
    /// was no file or it couldn't be kept.
    @discardableResult
    public func setAsideDamaged(at url: URL, now: Date = Date()) -> URL? {
        locked { _ in
            let fm = FileManager.default
            guard exists(url), !(checkFailSetAside && DevEnvironment.checksEnabled) else { return nil }
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
            func dest(_ tag: String) -> URL { url.appendingPathExtension("unreadable-\(tag)") }
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
                    return exists(url) ? nil : next
                } catch {
                    return nil
                }
            }
        }
    }

    /// A readable record from `url`, or nil. A file that is there but
    /// can't be read or decoded is set aside, not deleted and not left
    /// under the live name (if it can't be set aside, no write replaces it).
    private func record(fromFile url: URL) -> RecoveryRecord? {
        locked { f in
            let data: Data
            do {
                if checkFailRead, DevEnvironment.checksEnabled, exists(url) { throw CocoaError(.fileReadUnknown) }
                data = try Data(contentsOf: url)
            } catch {
                // Missing: nothing to keep.
                guard exists(url) else { return nil }
                if DevEnvironment.checksEnabled, let hook = checkBeforeSetAside { hook(url) }
                if setAsideDamaged(at: url) == nil, exists(url) { f.held.insert(url.lastPathComponent) }
                return nil
            }
            if let r = try? PropertyListDecoder().decode(RecoveryRecord.self, from: data) { return r }
            if DevEnvironment.checksEnabled, let hook = checkBeforeSetAside { hook(url) }
            if setAsideDamaged(at: url) == nil, exists(url) { f.held.insert(url.lastPathComponent) }
            return nil
        }
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

    public func clear(documentPath path: String) {
        locked { f in
            let url = fileURL(forDocumentPath: path)
            // An unreadable copy that couldn't be kept stays.
            guard !f.held.contains(url.lastPathComponent) else { return }
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
