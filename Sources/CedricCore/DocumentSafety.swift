import Foundation

/// Copies of a document's bytes that the iOS app keeps before anything
/// could replace them: the versions of an iCloud conflict, the text that
/// was unsaved when another app changed the file, and (once per session)
/// the file as it was before Owlink first wrote it. Private to the app
/// (0700 folder, 0600 files, kept out of backups and iCloud), each copy a
/// pair of files: the bytes, then a small record saying what they are.
public struct SafetyCopy: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// One version of an iCloud conflict (this device's or another's).
        case conflictVersion
        /// Unsaved text, kept before a reload from disk replaced it.
        case unsavedText
        /// The file on disk when another app changed it (theirs).
        case externalVersion
        /// The file before Owlink first wrote it this session.
        case original
    }

    public var id: String
    public var documentPath: String
    public var displayName: String
    public var kind: Kind
    /// When the copy was made.
    public var savedAt: Date
    /// When the bytes were last changed where they came from (a version's
    /// modification date), if known.
    public var sourceDate: Date?
    /// The device that saved them (a conflict version), if known.
    public var device: String?
    /// The encoding the bytes are in, when Owlink encoded them itself.
    public var encoding: TextEncoding?
    public var byteCount: Int

    public init(id: String = UUID().uuidString, documentPath: String, displayName: String, kind: Kind, savedAt: Date = Date(),
                sourceDate: Date? = nil, device: String? = nil, encoding: TextEncoding? = nil, byteCount: Int = 0) {
        self.id = id
        self.documentPath = documentPath
        self.displayName = displayName
        self.kind = kind
        self.savedAt = savedAt
        self.sourceDate = sourceDate
        self.device = device
        self.encoding = encoding
        self.byteCount = byteCount
    }
}

extension SafetyCopy {
    /// The copy's text: in the encoding Owlink wrote it in, or detected
    /// (a file's own bytes).
    public func decode(_ data: Data) -> DecodedText? {
        TextCodec.decode(data, as: encoding)
    }

    /// What it is, for Restore Previous Version.
    public var kindTitle: String {
        switch kind {
        case .original: return String(localized: "Before Owlink saved")
        case .conflictVersion:
            if let device { return String(localized: "Conflict version from \(device)") }
            return String(localized: "Conflict version")
        case .unsavedText: return String(localized: "Your unsaved text")
        case .externalVersion: return String(localized: "Changed elsewhere")
        }
    }
}

/// When the iOS app keeps the file as it is on disk before writing over
/// it: before the first write after each read (open, or a reload), so
/// every version Owlink replaces can be restored for 7 days.
public enum BackupPolicy {
    public static func shouldBackUp(needsWrite: Bool, backedUpSinceRead: Bool, haveBytes: Bool) -> Bool {
        needsWrite && !backedUpSinceRead && haveBytes
    }
}

public struct SafetyCopyStore: Sendable {
    /// How long copies are kept.
    public static let keepDays = 7
    /// Larger files are not copied (as `RevertStore`).
    public static let maxBytes = RevertStore.maxBytes

    public let directory: URL
    public let maxBytes: Int

    public init(directory: URL, maxBytes: Int = SafetyCopyStore.maxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public enum KeepError: Error, Equatable {
        case tooLarge(bytes: Int)
    }

    func dataURL(id: String) -> URL { directory.appendingPathComponent(id + ".bytes") }
    func recordURL(id: String) -> URL { directory.appendingPathComponent(id + ".copy") }

    /// Writes the bytes, then the record (a record never points at missing
    /// bytes). Throws if either write fails or the bytes are over the cap:
    /// callers that must not go on without a copy check for that.
    @discardableResult
    public func keep(_ data: Data, as copy: SafetyCopy) throws -> SafetyCopy {
        guard data.count <= maxBytes else { throw KeepError.tooLarge(bytes: data.count) }
        try PrivateDirectory.make(directory, root: directory)
        PrivateDirectory.excludeFromBackup(directory)
        var c = copy
        c.byteCount = data.count
        try PrivateDirectory.writePrivateFile(data, to: dataURL(id: c.id))
        try PrivateDirectory.writePrivateFile(try PropertyListEncoder().encode(c), to: recordURL(id: c.id))
        return c
    }

    public func data(for copy: SafetyCopy) -> Data? { try? Data(contentsOf: dataURL(id: copy.id)) }

    /// Every readable copy (with its bytes present), newest first.
    public func all() -> [SafetyCopy] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "copy" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? PropertyListDecoder().decode(SafetyCopy.self, from: $0) } }
            .filter { FileManager.default.fileExists(atPath: dataURL(id: $0.id).path) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func copies(forDocumentPath path: String) -> [SafetyCopy] { all().filter { $0.documentPath == path } }

    public func remove(_ copy: SafetyCopy) {
        try? FileManager.default.removeItem(at: recordURL(id: copy.id))
        try? FileManager.default.removeItem(at: dataURL(id: copy.id))
    }

    /// Removes copies older than `days`, and bytes or records left without
    /// their other half (a crash between the two writes).
    public func prune(now: Date = Date(), days: Int = SafetyCopyStore.keepDays) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for c in all() where c.savedAt < cutoff { remove(c) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        for id in ids {
            let hasData = FileManager.default.fileExists(atPath: dataURL(id: id).path)
            let hasRecord = FileManager.default.fileExists(atPath: recordURL(id: id).path)
            if hasData != hasRecord {
                try? FileManager.default.removeItem(at: dataURL(id: id))
                try? FileManager.default.removeItem(at: recordURL(id: id))
            }
        }
    }
}

/// An iCloud conflict: what each choice does, in Apple's documented order
/// ("Resolving Document Version Conflicts", Document-Based App
/// Programming Guide for iOS): replace the file with the chosen version,
/// remove the other versions, then mark the conflict versions resolved.
/// Every version's bytes are copied to the `SafetyCopyStore` before any of
/// these steps; if a copy fails, nothing is resolved.
public enum ConflictResolution {
    public enum Choice: Equatable, Sendable {
        /// The version open here (the file's current version) stays.
        case keepThis
        /// The other device's version (the newest of them) replaces it.
        case keepOther
        /// This one stays, and each other version is saved beside it as a copy.
        case keepBoth
    }

    public enum Step: Equatable, Sendable {
        /// Copy every version's bytes to the app's private store.
        case copyAllVersions
        /// Write the other version(s) beside the file as new files.
        case saveOthersAsCopies
        /// `NSFileVersion.replaceItem(at:)` with the other version.
        case replaceWithOther
        /// `NSFileVersion.removeOtherVersionsOfItem(at:)`.
        case removeOtherVersions
        /// `isResolved = true` on each unresolved conflict version.
        case markResolved
        /// Reload the document from disk.
        case reload
    }

    public static func steps(for choice: Choice) -> [Step] {
        switch choice {
        case .keepThis: return [.copyAllVersions, .removeOtherVersions, .markResolved]
        case .keepOther: return [.copyAllVersions, .replaceWithOther, .removeOtherVersions, .markResolved, .reload]
        case .keepBoth: return [.copyAllVersions, .saveOthersAsCopies, .removeOtherVersions, .markResolved]
        }
    }

    /// The file name for the other version kept beside the original:
    /// "notes (conflict 2026-11-20 10.23).md". `taken` says whether a name
    /// is already used; a number is added until one is free.
    public static func copyName(for name: String, date: Date, timeZone: TimeZone = .current,
                                taken: (String) -> Bool = { _ in false }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func make(_ n: Int) -> String {
            let stem = "\(base) (conflict \(f.string(from: date))\(n > 1 ? " \(n)" : ""))"
            return ext.isEmpty ? stem : stem + "." + ext
        }
        var n = 1
        while taken(make(n)) && n < 1000 { n += 1 }
        return make(n)
    }
}

/// Why the editor is read-only right now. Editing is allowed only with no
/// reason left.
///
/// Read mode: with "Open Read-Only" on (the default on iPhone), a document
/// opens read-only with an Edit button; Edit leaves read mode, Done goes
/// back to it. A file opened with "Open as Text anyway" (it looks binary)
/// is always read-only.
public struct EditGate: Equatable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// Opened read-only; Edit leaves it.
        case readMode
        /// Opened as text though it looks binary: never editable.
        case binary
        /// An iCloud conflict is waiting for a choice.
        case conflict
        /// Another app changed the file while there were unsaved edits:
        /// waiting for Keep Mine / Use Theirs.
        case externalChange
        /// UIDocument disabled editing (`disableEditing()`: a revert, a
        /// conflict, another writer).
        case documentLocked
    }

    public private(set) var reasons: Set<Reason> = []
    /// "Open Read-Only" was on when the document opened: Done returns to read mode.
    public let readModeSetting: Bool

    public init(readModeOnOpen: Bool = false, binary: Bool = false) {
        readModeSetting = readModeOnOpen
        if readModeOnOpen { reasons.insert(.readMode) }
        if binary { reasons.insert(.binary) }
    }

    public var isEditable: Bool { reasons.isEmpty }

    /// The button in the bar.
    public enum Button: Equatable, Sendable {
        /// Read mode isn't used (the setting is off).
        case none
        /// In read mode: Edit.
        case edit
        /// Editing, with read mode on: Done goes back.
        case done
        /// Never editable (a binary file): a disabled "Read Only".
        case readOnly
    }

    public var button: Button {
        if reasons.contains(.binary) { return .readOnly }
        if !readModeSetting { return .none }
        return reasons.contains(.readMode) ? .edit : .done
    }

    /// Edit: leaves read mode (a binary file stays read-only). Whether the
    /// text is editable now (another reason may still hold it).
    @discardableResult
    public mutating func beginEditing() -> Bool {
        guard !reasons.contains(.binary) else { return false }
        reasons.remove(.readMode)
        return isEditable
    }

    /// Done: back to read mode (only with the setting on).
    public mutating func endEditing() {
        if readModeSetting { reasons.insert(.readMode) }
    }

    /// An explicit, confirmed change to the whole text (Revert, Restore):
    /// allowed if only read mode stands in the way (it leaves read mode),
    /// not while the file is binary, locked or in a conflict.
    public mutating func allowExplicitChange() -> Bool {
        if reasons.subtracting([.readMode]).isEmpty {
            reasons.remove(.readMode)
            return true
        }
        return false
    }

    public mutating func set(_ reason: Reason, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

/// The file changed on disk (another app, another device) while open.
/// UIDocument then reverts, which "discard[s] all unsaved document
/// modifications"; with unsaved edits the app asks first instead.
public enum ExternalChange {
    public enum Action: Equatable, Sendable {
        /// Read the file now (nothing unsaved, or the person chose to).
        case reload
        /// Keep the unsaved text, copy both sides, and ask Keep Mine / Use Theirs.
        case askFirst
        /// Already asking: this change is covered by the same question.
        case ignore
    }

    public enum Choice: Equatable, Sendable {
        /// Keep the text here (saving replaces theirs; theirs is copied).
        case keepMine
        /// Load the file from disk (the text here is copied).
        case useTheirs
    }

    /// `chosen`: the app itself asked for this reload (Use Theirs, Keep
    /// Other Version). `asking`: the question is already up.
    public static func onRevert(hasUnsavedChanges: Bool, chosen: Bool, asking: Bool) -> Action {
        if chosen { return .reload }
        if asking { return .ignore }
        return hasUnsavedChanges ? .askFirst : .reload
    }
}

/// Which window has each document open, so one file is never open in two
/// windows (iPad): two `UIDocument`s on one file overwrite each other's
/// saves, and both key their recovery copy by its path. Opening it again
/// brings the window that has it forward instead.
public struct OpenDocumentRegistry: Sendable {
    public enum Registration: Equatable, Sendable {
        /// Now open in this window.
        case registered
        /// Already open in this window.
        case alreadyHere
        /// Open in another window: bring that one forward.
        case openElsewhere(window: String)
    }

    private var owners: [String: String] = [:]

    public init() {}

    /// One key per file however the path is spelled (/private/var and
    /// /var, "..", a trailing slash).
    public static func key(forPath path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func owner(ofPath path: String) -> String? { owners[Self.key(forPath: path)] }

    public func contains(path: String) -> Bool { owner(ofPath: path) != nil }

    public mutating func register(path: String, window: String) -> Registration {
        let k = Self.key(forPath: path)
        if let o = owners[k] { return o == window ? .alreadyHere : .openElsewhere(window: o) }
        owners[k] = window
        return .registered
    }

    /// Only the window that has it can let it go.
    public mutating func unregister(path: String, window: String) {
        let k = Self.key(forPath: path)
        if owners[k] == window { owners[k] = nil }
    }

    /// A window went away (closed, or discarded by the system).
    public mutating func removeAll(window: String) {
        owners = owners.filter { $0.value != window }
    }
}

/// A change of the file's encoding or line endings: it rewrites every
/// line when saved, so the app confirms it first and registers `undo`.
public struct FormatChange: Equatable, Sendable {
    public struct Format: Equatable, Sendable {
        public var encoding: TextEncoding
        public var lineEnding: LineEnding
        /// Each line keeps its own ending (a file that mixes them, until a
        /// line ending is chosen).
        public var mixedLineEndings: Bool
        public init(encoding: TextEncoding, lineEnding: LineEnding, mixedLineEndings: Bool = false) {
            self.encoding = encoding
            self.lineEnding = lineEnding
            self.mixedLineEndings = mixedLineEndings
        }
    }

    public var from: Format
    public var to: Format

    public init(from: Format, to: Format) {
        self.from = from
        self.to = to
    }

    public var undo: FormatChange { FormatChange(from: to, to: from) }

    /// Anything changes at all.
    public var changesEverything: Bool { from != to }
}

/// What a save would write, compared with what is on disk: a document
/// whose text and format are what was read (or last written) is not
/// written at all, so opening, reading, an edit undone, or a format
/// change undone never touches the file's bytes.
public struct DiskState: Equatable, Sendable {
    public static let cleanCheckMaxUTF16Length = 4_000_000

    public var text: String
    public var format: FormatChange.Format
    public var hasBOM: Bool

    public init(text: String, format: FormatChange.Format, hasBOM: Bool) {
        self.text = text
        self.format = format
        self.hasBOM = hasBOM
    }

    /// Whether a save has anything to write. No state on disk known (never
    /// read): write.
    public static func needsWrite(_ current: DiskState, onDisk: DiskState?) -> Bool {
        guard let onDisk else { return true }
        return current.format != onDisk.format || current.hasBOM != onDisk.hasBOM
            || !(current.text as NSString).isEqual(to: onDisk.text)
    }

    /// Compare an edit with disk without reading its text unless the length
    /// and format match. The disk length is cached when the state is set.
    public static func matchesDisk(textUTF16Length: Int, text: () -> String, format: FormatChange.Format,
                                   hasBOM: Bool, onDisk: DiskState?, onDiskUTF16Length: Int?) -> Bool {
        guard textUTF16Length <= cleanCheckMaxUTF16Length, let onDisk, let onDiskUTF16Length,
              textUTF16Length == onDiskUTF16Length,
              format == onDisk.format, hasBOM == onDisk.hasBOM else { return false }
        return (text() as NSString).isEqual(to: onDisk.text)
    }

    /// The BOM to write: the file's own while it keeps its encoding (UTF-16
    /// read without one gets none), the standard one for a new encoding.
    public static func includeBOM(encoding: TextEncoding, onDisk: DiskState?) -> Bool {
        guard let onDisk, onDisk.format.encoding == encoding else { return true }
        return onDisk.hasBOM
    }
}
