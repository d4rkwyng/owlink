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
public struct RecoveryStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The file for a document path: a stable hash of the path (the record
    /// inside says which document it is).
    public func fileURL(forDocumentPath path: String) -> URL {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return directory.appendingPathComponent(String(format: "%016llx", h) + ".recovery")
    }

    public func write(_ record: RecoveryRecord, durable: Bool = true, failSync: Bool = false,
                      syncFolder: ((String) throws -> Void)? = nil) throws {
        try PrivateDirectory.make(directory, root: directory)
        PrivateDirectory.excludeFromBackup(directory)
        let data = try PropertyListEncoder().encode(record)
        try PrivateDirectory.writePrivateFile(data, to: fileURL(forDocumentPath: record.documentPath),
                                              durable: durable, failSync: failSync, syncFolder: syncFolder)
    }

    /// Moves an unreadable recovery file aside, next to it
    /// (`*.recovery.unreadable-<date>`), so a later launch can still look
    /// at the bytes and a new write can use the original name. Copied
    /// there if it can't be moved. Returns the new URL, or nil if there
    /// was no file or it couldn't be kept.
    @discardableResult
    public func setAsideDamaged(at url: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
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
                return fm.fileExists(atPath: url.path) ? nil : next
            } catch {
                return nil
            }
        }
    }

    /// A readable record from `url`, or nil. Unreadable recovery files
    /// are set aside, not deleted and not left under the live name.
    private func record(fromFile url: URL) -> RecoveryRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let r = try? PropertyListDecoder().decode(RecoveryRecord.self, from: data) { return r }
        _ = setAsideDamaged(at: url)
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

    public func clear(documentPath path: String) {
        try? FileManager.default.removeItem(at: fileURL(forDocumentPath: path))
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
