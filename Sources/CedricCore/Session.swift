import Foundation

/// One tab as it was when the session was saved.
public struct SessionTab: Codable, Equatable, Sendable {
    public var id: UUID
    /// The file, or nil for an untitled tab.
    public var path: String?
    /// "Untitled 3": kept so a restored tab keeps its name.
    public var untitledName: String?
    /// Unsaved changes, kept in the session's buffer file `<id>.txt`.
    public var hasBuffer: Bool
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// A language the user picked by hand (nil: detect again).
    public var language: Language?
    public var selectionLocation: Int
    public var selectionLength: Int
    /// The first visible line, to scroll back to.
    public var topLine: Int
    /// The file's modification date when its buffer was saved; if the
    /// file changed on disk since, the buffer still wins (it is the
    /// user's unsaved work) but the tab says so.
    public var fileModified: Date?
    /// The file's size and identity with `fileModified` (DiskStamp); nil
    /// in sessions saved before 0.5.4, which then compare the date only.
    public var fileSize: Int?
    public var fileID: DiskStamp.FileID?
    /// What the file looked like when the buffer was saved.
    public var diskStamp: DiskStamp { DiskStamp(modified: fileModified, size: fileSize, identity: fileID) }
    /// Bookmarked lines (0-based); nil in sessions saved before bookmarks.
    public var bookmarks: [Int]?
    /// Indentation picked for this tab (nil: the file's own or the default).
    public var indentation: Indentation?
    /// Folded regions, by header line (0-based); nil when none is folded
    /// and in sessions saved before folding.
    public var folds: [Int]?
    /// View › Split Editor: the second pane (nil unsplit and in sessions
    /// saved before 0.3.0).
    public var split: SplitEditorState?
    /// The preview was in its own window (View › Detach Preview), and
    /// that window's frame (NSWindow's frame descriptor). Nil otherwise.
    public var previewDetached: Bool?
    public var previewFrame: String?
    /// The preview was docked beside the text (View › Show Preview).
    /// Nil when it wasn't, and in sessions saved before a docked preview
    /// was remembered: nil means not shown, so those sessions still open
    /// with the preview closed. Only `true` reopens it.
    public var previewShown: Bool?
    /// The docked preview's width in points (the pane, as laid out). Nil
    /// with none shown, or when the split had no size yet; restore then
    /// uses the usual half. The dock is a vertical split with the preview
    /// always to the right of the editor, so there is no side to store.
    public var previewWidth: Double?
    /// A PDF tab (a read-only viewer, never written): its page and zoom.
    /// Nil for text tabs and in sessions saved before PDF tabs.
    public var pdf: PDFTabState?
    /// An image tab (read-only): its zoom and scroll. Nil otherwise.
    public var image: ImageTabState?
    /// An Office / iWork document in a Quick Look tab. Nil otherwise.
    public var office: OfficeTabState?
    /// A binary (DER) certificate or PKCS#7 bundle in a certificate tab. Nil otherwise.
    public var certificate: OfficeTabState?
    /// A text tab whose name looks like a PDF; older sessions omit this.
    public var explicitText: Bool?
    /// The encoding was Owlink's guess (not valid UTF-8) and the user
    /// hadn't kept it or picked one. Only `true` is stored.
    public var encodingGuessed: Bool?
    /// The file mixed line endings and saving kept each one (LineBreaks):
    /// the buffer holds the text with those breaks written in, read back
    /// against `lineEnding` (the most common kind), never from the file.
    /// Only `true` is stored.
    public var mixedLineEndings: Bool?

    /// View › Writing Mode's switches for this tab (nil: both off, and in
    /// sessions saved before 0.4.0).
    public var writing: WritingModeState?
    /// The stats popover's word goal for an untitled tab (a file's goal is
    /// in `Session.wordGoals`, by path). Never written into the text.
    public var wordGoal: Int?

    /// When it was closed (closed tabs only; nil in 0.2.0 sessions).
    public var closed: Date?

    /// A read-only viewer tab (PDF, image, Office, certificate): no text, no buffer.
    public var isViewer: Bool { pdf != nil || image != nil || office != nil || certificate != nil }

    public init(id: UUID = UUID(), path: String? = nil, untitledName: String? = nil, hasBuffer: Bool = false,
                encoding: TextEncoding = .utf8, lineEnding: LineEnding = .lf, language: Language? = nil,
                selectionLocation: Int = 0, selectionLength: Int = 0, topLine: Int = 0, fileModified: Date? = nil,
                fileSize: Int? = nil, fileID: DiskStamp.FileID? = nil,
                bookmarks: [Int]? = nil, indentation: Indentation? = nil, previewDetached: Bool? = nil, previewFrame: String? = nil,
                previewShown: Bool? = nil, previewWidth: Double? = nil, pdf: PDFTabState? = nil,
                image: ImageTabState? = nil, office: OfficeTabState? = nil, certificate: OfficeTabState? = nil, folds: [Int]? = nil,
                split: SplitEditorState? = nil, writing: WritingModeState? = nil, wordGoal: Int? = nil, explicitText: Bool? = nil) {
        self.id = id
        self.path = path
        self.untitledName = untitledName
        self.hasBuffer = hasBuffer
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.language = language
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.topLine = topLine
        self.fileModified = fileModified
        self.fileSize = fileSize
        self.fileID = fileID
        self.bookmarks = bookmarks
        self.indentation = indentation
        self.previewDetached = previewDetached
        self.previewFrame = previewFrame
        self.previewShown = previewShown
        self.previewWidth = previewWidth
        self.pdf = pdf
        self.image = image
        self.office = office
        self.certificate = certificate
        self.folds = folds
        self.split = split
        self.writing = writing
        self.wordGoal = wordGoal
        self.explicitText = explicitText
    }
}

/// One window's tabs, in order.
public struct SessionWindow: Codable, Equatable, Sendable {
    public var tabs: [SessionTab]
    public var selectedTab: Int
    /// NSWindow's frame descriptor string.
    public var frame: String?
    /// Window › Float on Top. Only `true` is stored; nil (and a session
    /// saved before the key) is off. The app keeps this apart from the
    /// live window level, which full screen changes on its own.
    public var floatOnTop: Bool?

    public init(tabs: [SessionTab], selectedTab: Int = 0, frame: String? = nil, floatOnTop: Bool? = nil) {
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.frame = frame
        self.floatOnTop = floatOnTop
    }
}

public struct Session: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = Session.currentVersion
    public var windows: [SessionWindow]
    /// Unused since untitled names reuse the lowest free number (kept so
    /// older session files still decode).
    public var untitledCounter: Int
    /// Tabs the user closed, oldest first, for File › Reopen Closed Tab.
    /// One with `hasBuffer` keeps its text in its buffer file, so closing
    /// a tab with unsaved changes never loses them. Nil in older sessions.
    public var closedTabs: [SessionTab]?
    /// The folder open in the folder sidebar (File › Open Folder…). Nil
    /// with none open and in sessions saved before 0.2.0.
    public var folder: SessionFolder?
    /// Files' word goals (the stats popover), by path, most recently set
    /// last (`FileWordGoals`). Nil with none and in sessions before 0.4.0.
    public var wordGoals: [FileWordGoal]?
    /// Buffers launch found but couldn't read (permissions, an I/O
    /// error): kept, never pruned, and tried again at the next launch
    /// (`SessionStore.holdBuffer`). Nil with none and in older sessions.
    public var heldBuffers: [UUID]?

    public init(windows: [SessionWindow], untitledCounter: Int = 0, closedTabs: [SessionTab]? = nil, folder: SessionFolder? = nil,
                wordGoals: [FileWordGoal]? = nil) {
        self.windows = windows
        self.untitledCounter = untitledCounter
        self.closedTabs = closedTabs
        self.folder = folder
        self.wordGoals = wordGoals
    }

    public var allTabs: [SessionTab] { windows.flatMap(\.tabs) }

    /// Every tab id whose unsaved text this session keeps in a buffer
    /// file: open and closed tabs with `hasBuffer`, and held buffers.
    public var bufferIDs: Set<UUID> {
        Set(allTabs.filter(\.hasBuffer).map(\.id) + (closedTabs ?? []).filter(\.hasBuffer).map(\.id) + (heldBuffers ?? []))
    }
}

/// Whether the last session's open tabs should be restored at launch.
public enum SessionReopenPolicy {
    /// The preference's defaults key (Settings › General › Reopen files
    /// from last session).
    public static let key = "reopenFilesFromLastSession"

    /// Owlink's own preference, on until the user turns it off. (0.5.1
    /// followed macOS's global NSQuitAlwaysKeepsWindows while it was unset:
    /// anyone with that set to false had their whole session, unsaved text
    /// included, parked in Reopen Closed Tab without choosing it.)
    public static func shouldReopen(explicit: Bool?) -> Bool {
        explicit ?? true
    }

    /// The preference as stored in `defaults`: nil when unset. Read with
    /// `bool(forKey:)`, so a `-reopenFilesFromLastSession NO` launch
    /// argument (a string) counts as well as a stored Bool.
    public static func explicitPreference(in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    public static func shouldReopen(in defaults: UserDefaults) -> Bool {
        shouldReopen(explicit: explicitPreference(in: defaults))
    }

    /// What launch does with the last session's windows. With reopen on,
    /// all of them come back. With it off, only tabs with unsaved text come
    /// back as open tabs (that text is nowhere else, and on the closed
    /// list it would fall under `ClosedTabs.keepDays` / `unsavedLimit`);
    /// every other tab goes to `park`, for File › Reopen Closed Tab. The
    /// selected tab stays selected when it comes back, else the first one.
    public static func plan(_ windows: [SessionWindow], reopen: Bool) -> (windows: [SessionWindow], park: [SessionTab]) {
        guard !reopen else { return (windows, []) }
        var kept: [SessionWindow] = []
        var park: [SessionTab] = []
        for w in windows {
            let selectedID = w.tabs.indices.contains(w.selectedTab) ? w.tabs[w.selectedTab].id : nil
            let unsaved = w.tabs.filter(\.hasBuffer)
            park += w.tabs.filter { !$0.hasBuffer }
            guard !unsaved.isEmpty else { continue }
            var nw = w
            nw.tabs = unsaved
            nw.selectedTab = unsaved.firstIndex { $0.id == selectedID } ?? 0
            kept.append(nw)
        }
        return (kept, park)
    }
}

/// Filters tabs that cannot be restored because their file was moved or
/// deleted. Unsaved buffers and untitled tabs remain eligible.
public enum SessionRestoreList {
    public static func openTabs(_ tabs: [SessionTab], fileExists: (String) -> Bool) -> [SessionTab] {
        tabs.filter { tab in
            guard let path = tab.path, !tab.hasBuffer else { return true }
            return fileExists(path)
        }
    }
}

/// The folder sidebar as it was: its folder, whether it showed, its width
/// and the folders expanded in it (paths relative to the folder, parents
/// first, at most `expandedLimit`).
public struct SessionFolder: Codable, Equatable, Sendable {
    public static let expandedLimit = 200
    public var path: String
    public var visible: Bool
    public var width: Double?
    public var expanded: [String]?
    public var showHidden: Bool?

    public init(path: String, visible: Bool = true, width: Double? = nil, expanded: [String]? = nil, showHidden: Bool? = nil) {
        self.path = path
        self.visible = visible
        self.width = width
        self.expanded = expanded.map { Array($0.prefix(Self.expandedLimit)) }
        self.showHidden = showHidden
    }
}

/// Saves and restores the session: `session.json` plus one UTF-8 buffer
/// file per tab with unsaved changes, in a directory under Application
/// Support. Every write is atomic (temp file + rename), so a crash
/// mid-write leaves the previous version intact; buffers are written
/// before the session that refers to them.
///
/// A buffer the committed `session.json` doesn't name yet (a new tab's
/// first text, a file's first edit) is first listed in the journal
/// `pending-buffers.json`, then written. Committing a session clears
/// the journal. If the app dies in between, the older session still
/// reads fine, but launch (`loadForLaunch`) finds the journaled buffers
/// and brings them back instead of leaving them for the next prune.
/// A buffer that was deliberately let go (its tab saved, discarded or
/// closed empty) is not in the journal once a session without it has
/// been committed, so it never comes back.
///
/// A closed tab reopened since the commit (File › Reopen Closed Tab) is
/// journaled too, as `reopened`, before its buffer is written again:
/// launch then opens it, whether or not its closed entry kept a buffer,
/// before closed tabs past `ClosedTabs.keepDays` are let go, so newer
/// text written under an old closing date isn't deleted with it.
///
/// Each commit is numbered (`generation` in `session.json`), and the
/// journal says which commit it waits for. A journal whose commit is
/// already in `session.json` (the app died after the commit, before the
/// journal was removed, or removing it failed) is spent: launch ignores
/// it, so a buffer that commit let go can't come back from it.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    /// Buffer ids the last committed (or launched) session names.
    private var committed = Set<UUID>()
    /// Buffer ids written (or being written) since: the journal, in order.
    private var pending: [UUID] = []
    /// Closed tabs the last commit lists, and those of them reopened
    /// since (journaled as `reopened`).
    private var committedClosed = Set<UUID>()
    private var pendingReopened: [UUID] = []
    /// The number of the last commit (`session.json`'s `generation`, or
    /// above any journal launch found); the next commit is this + 1.
    private var committedGeneration = 0
    /// Buffers launch couldn't read: never pruned, saved in the session.
    private var held = Set<UUID>()
    /// Set when launch couldn't make the store safe to write (an unreadable
    /// session it couldn't keep a copy of, a folder it couldn't list):
    /// for the rest of the run `save` refuses to replace `session.json`,
    /// nothing is pruned or removed (`removeBuffer`), and the journal on
    /// disk is never replaced: it may be the only record of buffers launch
    /// couldn't account for. Buffers are still written, journaled in a
    /// file of this run's own (`heldJournalFile`), which the next launch
    /// reads beside the journal and the next commit removes.
    public private(set) var hold: String?
    /// This run's journal while `hold` is set.
    private lazy var heldJournalFile = directory.appendingPathComponent("\(Self.heldJournalPrefix)\(UUID().uuidString).json")
    static let heldJournalPrefix = "pending-buffers.held-"
    /// Held runs' journals launch read: removed by the next commit.
    private var heldJournalsSeen: [URL] = []

    /// Check builds only (inert otherwise): every write fails, as on a
    /// full disk (`CEDRIC_TEST_SESSION_WRITE_FAIL`, the quitfail check).
    public var checkFailWrites = false
    /// Check builds only: runs just before a session is committed while
    /// journaled buffers or reopened tabs wait for it (crash-check kills
    /// the app there).
    public var checkBeforeCommit: (@Sendable () -> Void)?

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/Cedric/Session (or `CEDRIC_SESSION_DIR`).
    public static func defaultDirectory(environment: [String: String] = DevEnvironment.values) -> URL {
        if let custom = environment["CEDRIC_SESSION_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Cedric/Session", isDirectory: true)
    }

    var sessionFile: URL { directory.appendingPathComponent("session.json") }
    var journalFile: URL { directory.appendingPathComponent("pending-buffers.json") }

    public func bufferURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).txt") }

    /// Owner-only (0700), like the Cedric folder it is in; checked once
    /// per store, not on every save.
    private var directoryReady = false
    private func ensureDirectory() throws {
        if directoryReady, fm.fileExists(atPath: directory.path) { return }
        try PrivateDirectory.make(directory)
        // Unsaved tab text: recoverable state on this Mac, not backed up.
        PrivateDirectory.excludeFromBackup(directory)
        directoryReady = true
    }

    private func injectedFailure() throws {
        if DevEnvironment.checksEnabled, checkFailWrites { throw CocoaError(.fileWriteOutOfSpace) }
    }

    /// The saved session, or nil if there is none or it can't be read.
    public func load() -> Session? {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> Session? { loadManifest()?.session }

    /// The session and its commit number (0: saved before commits were numbered).
    private func loadManifest() -> (session: Session, generation: Int)? {
        guard let data = try? Data(contentsOf: sessionFile),
              let s = try? JSONDecoder().decode(Session.self, from: data),
              s.version <= Session.currentVersion else { return nil }
        return (s, (try? JSONDecoder().decode(Generation.self, from: data))?.generation ?? 0)
    }

    /// `session.json`'s commit number, beside the session's own keys
    /// (older versions ignore it). Not part of `Session`: it is the
    /// store's bookkeeping, not what the user had open.
    private struct Generation: Codable { var generation: Int? }
    private struct Manifest: Encodable {
        let session: Session
        let generation: Int
        func encode(to encoder: Encoder) throws {
            try session.encode(to: encoder)
            try Generation(generation: generation).encode(to: encoder)
        }
    }

    /// The journal: buffer ids written since commit `generation` - 1, in
    /// order. 0.6 before review wrote a bare array of ids (no number:
    /// always pending).
    struct Journal: Codable, Equatable {
        var generation: Int?
        var ids: [String]
        /// Closed tabs the commit lists that were reopened since.
        var reopened: [String]?
    }

    /// What launch finds in the store (`loadForLaunch`).
    public enum LaunchLoad: Equatable, Sendable {
        /// No session and no unsaved text: a first launch.
        case none
        /// The session, with any journaled buffer it already names as a
        /// tab marked `hasBuffer`, and `recovered`: journaled buffers it
        /// doesn't name at all (written, then the app died before the
        /// session listing them was committed), oldest first. The caller
        /// opens those as tabs; else the next save's prune deletes them.
        case session(Session, recovered: [UUID])
        /// No session to restore, but unsaved text in the store that no
        /// session now refers to: the session file couldn't be read
        /// (truncated, not JSON, from a newer version) and was moved aside
        /// to `setAside` (nil: there was none, or it couldn't be moved or
        /// copied: then `hold` is set), or the app died between writing
        /// its first buffers and the session that lists them. `buffers`:
        /// those buffers' tab ids, oldest first. The caller opens them as
        /// tabs; else the next save's prune deletes them.
        case recover(setAside: URL?, buffers: [UUID])
    }

    /// The saved session for launch. Unlike `load()`, a session file that
    /// can't be read is never left for the next save to overwrite, and
    /// its unsaved text is never left for the prune to delete: the file
    /// is renamed `session.unreadable-<date>.json` (kept, beside the
    /// buffers; copied there if it can't be moved) and the buffers are
    /// returned for the caller to reopen. When neither works, or the
    /// folder can't be listed, `hold` says why and the store neither
    /// replaces the session file nor prunes until the next launch.
    public func loadForLaunch(now: Date = Date()) -> LaunchLoad {
        lock.lock(); defer { lock.unlock() }
        var journal = readJournal(journalFile)
        committedGeneration = max(0, (journal.generation ?? 0) - 1)
        // Journals of runs that were held (heldJournalFile): listed, so a
        // folder that can't be listed holds this run too.
        do {
            heldJournalsSeen = try heldJournalFiles()
        } catch {
            hold = "the session folder couldn’t be listed: \(error.localizedDescription)"
        }
        let heldJournals = heldJournalsSeen.map(readJournal)
        for j in heldJournals { committedGeneration = max(committedGeneration, (j.generation ?? 0) - 1) }
        if let (s, generation) = loadManifest() {
            committedGeneration = max(committedGeneration, generation)
            // Spent: the commit it waited for is in session.json already.
            if let g = journal.generation, g <= generation, !journal.damaged { journal = ([], [], g, false) }
            pending = journal.ids
            pendingReopened = journal.reopened
            committed = s.bufferIDs
            committedClosed = Set((s.closedTabs ?? []).map(\.id))
            held = Set(s.heldBuffers ?? [])
            var candidates = journal.ids
            var reopened = Set(journal.reopened)
            var damaged = journal.damaged
            for j in heldJournals where !(j.generation.map { $0 <= generation } ?? false) || j.damaged {
                damaged = damaged || j.damaged
                candidates += j.ids.filter { !candidates.contains($0) }
                reopened.formUnion(j.reopened)
            }
            // A journal that can't be read: every buffer the session
            // doesn't name could be one it listed, and every closed tab
            // with a buffer could have been reopened. Bringing back one
            // that was let go beats deleting one that wasn't.
            if damaged {
                do { candidates = try bufferFiles() } catch { hold = "the session folder couldn’t be listed: \(error.localizedDescription)" }
                reopened = Set(candidates)
            }
            let r = Self.applyJournal(s, journal: candidates, reopened: reopened) { fm.fileExists(atPath: bufferURL($0).path) }
            return .session(r.session, recovered: r.recovered)
        }
        pending = journal.ids
        let listed: [UUID]
        do {
            listed = try bufferFiles()
        } catch {
            // Which buffers are here is unknown: keep the session file
            // where it is and every buffer, and write neither over.
            hold = "the session folder couldn’t be listed: \(error.localizedDescription)"
            return .recover(setAside: nil, buffers: [])
        }
        var aside: URL?
        if fm.fileExists(atPath: sessionFile.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let stem = "session.unreadable-\(f.string(from: now))"
            var failure: Error?
            for n in 1...100 {
                let url = directory.appendingPathComponent(n == 1 ? "\(stem).json" : "\(stem)-\(n).json")
                if fm.fileExists(atPath: url.path) { continue }
                do {
                    try fm.moveItem(at: sessionFile, to: url)
                    aside = url
                } catch {
                    // Not movable (a locked file): a copy keeps it as well.
                    do { try fm.copyItem(at: sessionFile, to: url); aside = url } catch let e { failure = e }
                }
                break
            }
            if aside == nil {
                hold = "the unreadable session file couldn’t be kept aside"
                    + (failure.map { ": \($0.localizedDescription)" } ?? "")
            }
        }
        guard aside != nil || hold != nil || !listed.isEmpty else { return .none }
        return .recover(setAside: aside, buffers: listed)
    }

    /// `session` with the journaled ids in `journal` (whose buffer files
    /// exist) put back: an open tab gets `hasBuffer`; a closed tab
    /// reopened since (in `reopened`, or without a buffer of its own:
    /// reopened and edited) opens again, in a window of its own, with no
    /// closing date left to expire; any other id is returned in
    /// `recovered`. Ids only in `reopened` count as journaled.
    public static func applyJournal(_ session: Session, journal: [UUID], reopened: Set<UUID> = [], bufferExists: (UUID) -> Bool)
        -> (session: Session, recovered: [UUID]) {
        var s = session
        var recovered: [UUID] = []
        var reopenedTabs: [SessionTab] = []
        let held = Set(s.heldBuffers ?? [])
        var seen = Set<UUID>()
        let order = journal + reopened.sorted { $0.uuidString < $1.uuidString }.filter { !journal.contains($0) }
        for id in order where seen.insert(id).inserted && bufferExists(id) && !held.contains(id) {
            if let w = s.windows.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
               let t = s.windows[w].tabs.firstIndex(where: { $0.id == id }) {
                s.windows[w].tabs[t].hasBuffer = true
                continue
            }
            if let c = s.closedTabs?.firstIndex(where: { $0.id == id }) {
                guard s.closedTabs?[c].hasBuffer == false || reopened.contains(id), var tab = s.closedTabs?.remove(at: c) else { continue }
                tab.hasBuffer = true
                tab.closed = nil
                reopenedTabs.append(tab)
                continue
            }
            recovered.append(id)
        }
        if s.closedTabs?.isEmpty == true { s.closedTabs = nil }
        if !reopenedTabs.isEmpty { s.windows.append(SessionWindow(tabs: reopenedTabs)) }
        return (s, recovered)
    }

    /// The journal's ids, reopened closed tabs and commit number;
    /// `damaged` if the file is there but can't be read, or names
    /// something that isn't an id (then which buffers it listed is
    /// unknown: the caller scans).
    private func readJournal(_ url: URL) -> (ids: [UUID], reopened: [UUID], generation: Int?, damaged: Bool) {
        guard fm.fileExists(atPath: url.path) else { return ([], [], nil, false) }
        guard let data = try? Data(contentsOf: url) else { return ([], [], nil, true) }
        let j: Journal
        if let object = try? JSONDecoder().decode(Journal.self, from: data) {
            j = object
        } else if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            j = Journal(generation: nil, ids: legacy)
        } else {
            return ([], [], nil, true)
        }
        let ids = j.ids.compactMap(UUID.init(uuidString:))
        let reopened = (j.reopened ?? []).compactMap(UUID.init(uuidString:))
        guard ids.count == j.ids.count, reopened.count == (j.reopened ?? []).count else { return ([], [], j.generation, true) }
        return (ids, reopened, j.generation, false)
    }

    private func encodeJournal(_ ids: [UUID], reopened: [UUID]) throws -> Data {
        try JSONEncoder().encode(Journal(generation: committedGeneration + 1, ids: ids.map(\.uuidString),
                                         reopened: reopened.isEmpty ? nil : reopened.map(\.uuidString)))
    }

    /// Held runs' journals in the store, by name. Throws if the folder is
    /// there but can't be listed (none at all: none).
    private func heldJournalFiles() throws -> [URL] {
        do {
            return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(Self.heldJournalPrefix) && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return []
        }
    }

    /// The buffer files in the store, oldest first. Throws if the folder
    /// is there but can't be listed (none at all: no buffers).
    private func bufferFiles() throws -> [UUID] {
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return []
        }
        let found: [(UUID, Date)] = files.compactMap { f in
            guard f.pathExtension == "txt", let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { return nil }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (id, date)
        }
        return found.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.uuidString < $1.0.uuidString }.map(\.0)
    }

    /// Commits `session` (with the held buffers): then the journal is
    /// cleared. Throws, writing nothing, while `hold` is set.
    public func save(_ session: Session) throws {
        lock.lock(); defer { lock.unlock() }
        if let hold { throw SessionStoreError.held(hold) }
        try ensureDirectory()
        try injectedFailure()
        var s = session
        s.heldBuffers = held.isEmpty ? nil : held.sorted { $0.uuidString < $1.uuidString }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if DevEnvironment.checksEnabled, !pending.isEmpty || !pendingReopened.isEmpty, let hook = checkBeforeCommit { hook() }
        let generation = committedGeneration + 1
        try PrivateDirectory.writePrivateFile(enc.encode(Manifest(session: s, generation: generation)), to: sessionFile)
        committedGeneration = generation
        committed = s.bufferIDs
        committedClosed = Set((s.closedTabs ?? []).map(\.id))
        // Every buffer written before this session's snapshot is named in
        // it or was let go (writes are serialized with saves). If the app
        // dies before this, or it fails, the journal is spent anyway: it
        // waited for this commit.
        if !pending.isEmpty || !pendingReopened.isEmpty || fm.fileExists(atPath: journalFile.path) {
            pending = []
            pendingReopened = []
            try? fm.removeItem(at: journalFile)
        }
        // Held runs' journals: launch applied them, so this commit names
        // what they listed or let it go.
        for url in heldJournalsSeen { try? fm.removeItem(at: url) }
        heldJournalsSeen = []
    }

    /// Writes tab `id`'s unsaved text. `open`: the tab is open (false: a
    /// closed tab's text kept in memory since its close couldn't write it).
    public func writeBuffer(_ id: UUID, text: String, open: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        try injectedFailure()
        // Journaled before the buffer exists, so a buffer is never on
        // disk unnamed by both the session and the journal, nor written
        // for a reopened tab the session still lists as closed.
        try journal(id, reopened: open)
        try PrivateDirectory.writePrivateFile(Data(text.utf8), to: bufferURL(id))
    }

    /// File › Reopen Closed Tab brought `id` back: journaled at once, so
    /// it reopens after a crash even if nothing is written for it before
    /// the next commit (its closing date could expire it meanwhile).
    public func noteReopened(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard committedClosed.contains(id), !pendingReopened.contains(id) else { return }
        try ensureDirectory()
        try injectedFailure()
        try journal(id, reopened: true)
    }

    private func journal(_ id: UUID, reopened: Bool) throws {
        let fresh = !committed.contains(id) && !pending.contains(id)
        let reopening = reopened && committedClosed.contains(id) && !pendingReopened.contains(id)
        guard fresh || reopening else { return }
        let ids = fresh ? pending + [id] : pending, again = reopening ? pendingReopened + [id] : pendingReopened
        // Held: never over the journal launch found (it may be all that
        // says which buffers are pending), but beside it.
        try PrivateDirectory.writePrivateFile(encodeJournal(ids, reopened: again), to: hold == nil ? journalFile : heldJournalFile)
        pending = ids
        pendingReopened = again
    }

    /// What reading a buffer found.
    public enum BufferRead: Equatable, Sendable {
        case text(String)
        /// No such file.
        case missing
        /// It is there but couldn't be read: keep it (`holdBuffer`).
        case unreadable(String)
    }

    public func readBufferResult(_ id: UUID) -> BufferRead {
        do {
            return .text(String(decoding: try Data(contentsOf: bufferURL(id)), as: UTF8.self))
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func readBuffer(_ id: UUID) -> String? {
        if case .text(let t) = readBufferResult(id) { return t }
        return nil
    }

    /// Keeps a buffer that couldn't be read: never pruned, named in every
    /// session saved from now on, tried again at the next launch.
    public func holdBuffer(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        held.insert(id)
    }

    /// A held buffer was read after all (or has gone): an ordinary one again.
    public func releaseBuffer(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        held.remove(id)
    }

    public var heldBuffers: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    /// Deletes a buffer the app let go (its tab saved, discarded, or a
    /// closed tab expired). Never a held one, and nothing while `hold` is
    /// set: launch couldn't tell which buffers are pending then.
    public func removeBuffer(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard hold == nil, !held.contains(id) else { return }
        try? fm.removeItem(at: bufferURL(id))
    }

    /// Deletes buffer files no tab refers to (called right after a
    /// commit). Never held ones, and nothing at all while `hold` is set.
    public func pruneBuffers(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard hold == nil else { return }
        let keep = ids.union(held)
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "txt" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !keep.contains(id) {
                try? fm.removeItem(at: f)
            }
        }
    }
}

public enum SessionStoreError: Error, LocalizedError, Equatable {
    /// `SessionStore.hold`: the session isn't written this run.
    case held(String)

    public var errorDescription: String? {
        switch self {
        case .held(let why): return "Owlink isn’t saving its session this run: \(why)."
        }
    }
}

/// The closed-tabs list behind File › Reopen Closed Tab.
public enum ClosedTabs {
    /// How many closed tabs are remembered.
    public static let limit = 50
    /// Closed tabs with unsaved text: at most this many (the oldest go
    /// first) and for at most `keepDays` days after closing.
    public static let unsavedLimit = 100
    public static let keepDays = 30

    /// `list` without the tabs closed more than `keepDays` before `now`
    /// (and their unsaved text, which the caller deletes). A tab with no
    /// closing date (saved by 0.2.0 or older) gets `now`, so it goes
    /// `keepDays` after this version first sees it.
    public static func expire(_ list: [SessionTab], now: Date = Date()) -> (list: [SessionTab], dropped: [SessionTab]) {
        var kept: [SessionTab] = []
        var dropped: [SessionTab] = []
        for var t in list {
            let closed = t.closed ?? now
            if now.timeIntervalSince(closed) > Double(keepDays) * 86_400 { dropped.append(t); continue }
            t.closed = closed
            kept.append(t)
        }
        return (kept, dropped)
    }

    /// `tab` pushed on `list` (newest last). Past `limit`, the oldest tabs
    /// without unsaved text go. A tab with unsaved text is never dropped
    /// (its buffer would be deleted, and that text is nowhere else): when
    /// they alone pass the limit, the list grows past it. Returns the new
    /// list and what was dropped (whose buffers the caller deletes).
    public static func push(_ tab: SessionTab, onto list: [SessionTab], limit: Int = ClosedTabs.limit)
        -> (list: [SessionTab], dropped: [SessionTab]) {
        push(tab, onto: list, limit: limit, now: Date())
    }

    public static func push(_ tab: SessionTab, onto list: [SessionTab], limit: Int = ClosedTabs.limit, unsavedLimit: Int = ClosedTabs.unsavedLimit,
                            now: Date) -> (list: [SessionTab], dropped: [SessionTab]) {
        // Reopening and closing the same tab again: one entry.
        // Tabs past `keepDays` go now too, as at launch, so a session that
        // runs for weeks doesn't keep them until the next launch.
        let fresh = expire(list.filter { $0.id != tab.id }, now: now)
        var out = fresh.list
        var tab = tab
        tab.closed = now
        out.append(tab)
        var dropped: [SessionTab] = fresh.dropped
        while out.count > max(1, limit), let i = out.firstIndex(where: { !$0.hasBuffer }) {
            dropped.append(out.remove(at: i))
        }
        // Unsaved text is kept, but not without end: past `unsavedLimit`
        // the oldest goes (and then `keepDays`, see `expire`).
        var unsaved = out.filter(\.hasBuffer).count
        while unsaved > max(1, unsavedLimit), let i = out.firstIndex(where: { $0.hasBuffer }) {
            dropped.append(out.remove(at: i))
            unsaved -= 1
        }
        return (out, dropped)
    }
}

/// Untitled tab names, as TextEdit numbers them: the first is "Untitled",
/// then the lowest free "Untitled N" (N ≥ 2) among the untitled tabs open
/// now, so numbers are reused once their tabs close.
public enum UntitledNames {
    public static func next(open: [String], base: String = "Untitled") -> String {
        let taken = Set(open)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
