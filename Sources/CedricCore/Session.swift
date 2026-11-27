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
    /// Held closed tabs that were reopened (⇧⌘T read the buffer and
    /// journaled it) but whose buffer the next launch couldn't read: the
    /// reopen is still owed. Each launch that can read the buffer opens
    /// the tab (`SessionStore.applyJournal`); until then its closed entry
    /// never expires (`ClosedTabs.expire(keeping:)`) and its buffer stays
    /// held, across any number of commits. Nil with none and in older
    /// sessions (which then keep it held and closed, as before).
    public var heldReopened: [UUID]?

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
///
/// Going back to an older build is not supported for a store with work
/// still pending (a journal, a held run's journal). The 0.5 releases have
/// no journal and prune every buffer their session doesn't name; the
/// unreleased 0.6 builds before the review (1bb8787) read only a bare
/// array in `pending-buffers.json`, so they can't express a reopened
/// tab's promotion or a commit number. What is kept for them: whenever
/// pending ids exist, `pending-buffers.json` exists too, in this format,
/// which those builds read as damaged, so they scan and reopen every
/// buffer their session doesn't name. A held run that found no journal
/// writes there itself (unnumbered) rather than beside it. A closed tab
/// reopened since the commit can still stay closed in those builds.
public final class SessionStore: @unchecked Sendable {
    /// The session folder this store was made for (`instances/` is in it).
    public let mainDirectory: URL
    /// Where the store reads and writes now: the session folder, or this
    /// run's own instance store in it (`instanceDirectory`).
    public var directory: URL {
        directoryLock.lock(); defer { directoryLock.unlock() }
        return currentDirectory
    }
    private var currentDirectory: URL
    /// Guards `currentDirectory` alone: it is read off the store's lock
    /// (`bufferURL` on the main thread) and changed under it.
    private let directoryLock = NSLock()
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
    /// A commit was renamed into place without its folder flush
    /// (`PrivateDirectory.Unconfirmed`): the journal on disk is numbered
    /// for the commit before, so the commit now on disk may have spent it.
    /// Its ids and reopens stay pending here, but none is relied on as
    /// journaled: the next journal call (a write, a reopen) writes them
    /// all again, numbered above the uncertain commit, first.
    private var journalStale = false
    /// The single-writer lock (`claimWriter`): an open `session.lock`
    /// with an exclusive flock, held for the life of the process (the
    /// kernel lets it go when the process ends, crash or kill included).
    /// In an instance store, that store's own `session.lock`.
    private var writerFD: Int32 = -1
    /// `claimWriter` was asked: from then on every write, removal and
    /// prune first checks that `writerFD` is still the file at the lock's
    /// path (`lockStillHeld`). A store never asked writes as before.
    private var claimed = false
    /// This run's own store, `instances/<uuid>/` in the session folder,
    /// once the session folder's lock is another Owlink's (taken at
    /// launch, or the lock file replaced since: `moveToInstance`).
    private var instanceDir: URL?
    /// Dead Owlinks' instance stores launch adopted (their locks held):
    /// removed once a commit here has named what was taken from them.
    private var orphansToRemove: [(dir: URL, fd: Int32)] = []
    private var adoptedCount = 0
    private var movedCount = 0
    /// Whether launch adopts dead instance stores (off for a run that
    /// saves no session: it would write their text here and never commit it).
    public var adoptsInstances = true
    /// Called (on the store's queue) when the store moves to an instance
    /// store after it had the session folder: the folder's lock file was
    /// replaced, so another Owlink may be writing there now.
    public var onMovedToInstance: (@Sendable (URL) -> Void)?
    /// Why this store may not write (`claimWriter` failed: another Owlink
    /// holds the lock, or the lock couldn't be taken). Then nothing is
    /// read for launch, written, removed or pruned for the rest of the run.
    public var notWriter: String? {
        lock.lock(); defer { lock.unlock() }
        return notWriterReason
    }
    private var notWriterReason: String?
    /// Buffers launch couldn't read: never pruned, saved in the session.
    private var held = Set<UUID>()
    /// Held closed tabs whose reopen is still owed (`Session.heldReopened`):
    /// saved in every commit while they stay held.
    private var heldReopen = Set<UUID>()
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
    /// Held runs' journals launch read: adopted (named in
    /// `adoptedJournals`) and removed by the next commit.
    private var heldJournalsSeen: [URL] = []
    /// Held runs' journals adopted by a commit whose removal didn't
    /// happen: named again in each commit until they are gone.
    private var adoptedLeft = Set<String>()
    /// Launch found no journal at all (`lstat`: no such file). A held run
    /// then journals in the main journal itself, unnumbered (pending until
    /// a commit removes it): there is nothing there to keep, and an older
    /// build, which reads only that file, still sees every pending id.
    private var journalAbsentAtLaunch = false
    /// The newest write sequence (the caller's number for each buffer
    /// write it queues) that succeeded, per buffer. Kept here, on the
    /// serial writer, so a commit can tell a write an earlier snapshot
    /// queued has really landed (`BufferNeed.written`).
    private var writtenSequence: [UUID: Int] = [:]

    /// What a commit needs of a buffer it names (`save(_:requiring:)`).
    public enum BufferNeed: Equatable, Sendable {
        /// The write with this sequence number (or a later one) succeeded.
        case written(Int)
        /// It is on disk already (read back, or written earlier and verified).
        case onDisk
    }

    /// Check builds only (inert otherwise): every write fails, as on a
    /// full disk (`CEDRIC_TEST_SESSION_WRITE_FAIL`, the quitfail check).
    public var checkFailWrites = false
    /// Check builds only: every journal write fails, nothing else (the
    /// quitjournalfail check: a quit whose final save needs a journal entry).
    public var checkFailJournal = false
    /// Check builds only: every write's flush to disk fails (the bytes
    /// were written, the disk didn't confirm them; quitsyncfail).
    public var checkFailSync = false
    /// Check builds only: every folder flush fails (a new folder's entry,
    /// and a replaced file's rename: the rename is done, its flush isn't).
    public var checkFailFolderSync = false
    /// Check builds only: the folders flushed successfully, in order (a
    /// flush that failed, injected or not, isn't listed).
    public private(set) var checkSyncedFolders: [String] = []

    /// Every store file (buffers, the journals, session.json) is written
    /// durably (PrivateDirectory.writePrivateFile), on the session queue:
    /// a buffer and its journal entry are on the disk before the session
    /// naming them is written, and the session before the journal is
    /// removed or anything pruned.
    private func writeDurably(_ data: Data, to url: URL) throws {
        try PrivateDirectory.writePrivateFile(data, to: url, durable: true, failSync: checkFailSync,
                                              syncFolder: { [unowned self] in try self.syncFolder($0) })
    }
    /// Check builds only: runs just before a session is committed while
    /// journaled buffers or reopened tabs wait for it (crash-check kills
    /// the app there).
    public var checkBeforeCommit: (@Sendable () -> Void)?

    /// `durableFrom`: the outermost folder on the store's path whose entry
    /// first use flushes even if it was there already (default: the
    /// store's parent, Cedric, which the CLI token may have made first).
    public init(directory: URL, durableFrom: URL? = nil) {
        self.mainDirectory = directory
        self.currentDirectory = directory
        self.durableFrom = durableFrom ?? directory.deletingLastPathComponent()
    }
    deinit {
        if writerFD >= 0 { close(writerFD) }
        for o in orphansToRemove { close(o.fd) }
    }
    private let durableFrom: URL
    /// Folders on the store's path made here whose entry flush failed:
    /// flushed again before anything counts as written (`ensureDirectory`).
    private var unconfirmedFolders = Set<String>()

    /// ~/Library/Application Support/Cedric/Session (or `CEDRIC_SESSION_DIR`).
    public static func defaultDirectory(environment: [String: String] = DevEnvironment.values) -> URL {
        if let custom = environment["CEDRIC_SESSION_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Cedric/Session", isDirectory: true)
    }

    var sessionFile: URL { directory.appendingPathComponent("session.json") }
    var lockFile: URL { directory.appendingPathComponent("session.lock") }

    /// What `claimWriter` found.
    public enum WriterClaim: Equatable, Sendable {
        /// This store is the session folder's only writer.
        case claimed
        /// Another process (another Owlink) holds the session folder's
        /// lock: this store reads nothing for launch and writes its own
        /// recoverable store, this folder (`instances/<uuid>` in it).
        case instance(URL)
        /// Another Owlink holds the lock and no instance store could be
        /// made: nothing is written this run.
        case inUse
        /// The lock couldn't be taken (the folder or the lock file
        /// couldn't be made or opened): why.
        case failed(String)
    }

    /// Makes this process the store's only writer: two Owlinks on one
    /// session folder would each commit and prune against their own
    /// snapshot, and one could delete the other's newest buffers. Takes
    /// an exclusive advisory lock (flock, LOCK_NB) on `session.lock` in
    /// the folder, kept until the process ends, and checks that the file
    /// it locked is still the one at that path. If another process holds
    /// it, the store moves to an instance store of its own
    /// (`instances/<uuid>/`, owner-only, its own lock held the same way):
    /// it restores nothing and writes, removes and prunes only there, so
    /// its text survives its crash, and the session folder's next writer
    /// adopts it (`loadForLaunch`). Only if that can't be made either is
    /// `notWriter` set and nothing written for the rest of the run.
    /// Asked again, it checks the lock again (never `.claimed` on the
    /// descriptor alone). A store never asked (tests, tools) writes as before.
    public func claimWriter() -> WriterClaim {
        lock.lock(); defer { lock.unlock() }
        claimed = true
        if writerFD >= 0 {
            if lockStillHeld() { return instanceDir.map { .instance($0) } ?? .claimed }
            return moveToInstance(lost: true)
        }
        if let notWriterReason { return notWriterReason == Self.inUseReason ? .inUse : .failed(notWriterReason) }
        // The folder, if new: plain here (owner-only); the first write
        // still flushes it and its parents (`ensureDirectory`).
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Replaced between the open and the lock: the lock is on a file
        // no one else will open. Tried again; then counted as lost.
        for _ in 0..<3 {
            let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                let why = "its lock file couldn’t be opened: \(String(cString: strerror(errno)))"
                notWriterReason = why
                return .failed(why)
            }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let e = errno
                if e == EINTR { continue }
                close(fd)
                if e == EWOULDBLOCK { return moveToInstance(lost: false) }
                let why = "its lock file couldn’t be locked: \(String(cString: strerror(e)))"
                notWriterReason = why
                return .failed(why)
            }
            if Self.sameFile(fd, lockFile.path) {
                writerFD = fd
                return .claimed
            }
            close(fd)
        }
        return moveToInstance(lost: false)
    }

    /// The instance store, if this store writes one (`claimWriter`).
    public var instanceDirectory: URL? {
        lock.lock(); defer { lock.unlock() }
        return instanceDir
    }
    /// Unsaved texts launch adopted from dead Owlinks' instance stores.
    public var adoptedFromInstances: Int {
        lock.lock(); defer { lock.unlock() }
        return adoptedCount
    }
    /// Goes up each time the store moves to an instance store after it
    /// had the session folder: the caller writes every buffer again.
    public var moves: Int {
        lock.lock(); defer { lock.unlock() }
        return movedCount
    }

    static let instancesFolder = "instances"
    var instancesRoot: URL { mainDirectory.appendingPathComponent(Self.instancesFolder, isDirectory: true) }

    /// Whether `fd` is the file at `path` now (fstat against lstat, no
    /// link followed): device and inode.
    static func sameFile(_ fd: Int32, _ path: String) -> Bool {
        var a = stat(), b = stat()
        guard fd >= 0, fstat(fd, &a) == 0, lstat(path, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// The lock this store took is still the file at the lock's path:
    /// not replaced (a restore, a sync) or removed since.
    private func lockStillHeld() -> Bool { Self.sameFile(writerFD, lockFile.path) }

    /// Before anything that writes, removes or prunes: with the lock
    /// lost, the store moves to an instance store first (or, if it
    /// can't, refuses). Never a write to a folder whose lock isn't ours.
    private func ensureWriter() throws {
        if let notWriterReason { throw SessionStoreError.held(notWriterReason) }
        guard claimed, !lockStillHeld() else { return }
        if case .instance = moveToInstance(lost: true) { return }
        throw SessionStoreError.held(notWriterReason ?? Self.lostReason)
    }

    /// Starts this run's own instance store and writes there from now on.
    /// `lost`: the store had a lock (the session folder's, or an instance
    /// store's) that is no longer the file at its path. The buffers it had
    /// committed or journaled are copied there and journaled, so a crash
    /// keeps them; `moves` goes up so the caller writes every open tab's
    /// text again from memory. Held buffers stay where they are (named as
    /// held, never pruned). If the store can't be made: `notWriter`.
    private func moveToInstance(lost: Bool) -> WriterClaim {
        let old = directory
        if writerFD >= 0 { close(writerFD); writerFD = -1 }
        for o in orphansToRemove { close(o.fd) }
        orphansToRemove = []
        let made: (dir: URL, fd: Int32)
        do {
            made = try makeInstance()
        } catch {
            let why = lost ? "\(Self.lostReason), and no store of its own could be made: \(error.localizedDescription)" : Self.inUseReason
            notWriterReason = why
            return lost ? .failed(why) : .inUse
        }
        var carry: [(UUID, Data)] = []
        var seen = Set<UUID>()
        for id in committed.sorted(by: { $0.uuidString < $1.uuidString }) + pending where !held.contains(id) && seen.insert(id).inserted {
            if let data = Self.readRegularFile(old.appendingPathComponent("\(id.uuidString).txt").path) { carry.append((id, data)) }
        }
        directoryLock.lock(); currentDirectory = made.dir; directoryLock.unlock()
        instanceDir = made.dir
        writerFD = made.fd
        directoryReady = false
        committed = []
        pending = []
        committedClosed = []
        pendingReopened = []
        committedGeneration = 0
        journalStale = false
        hold = nil
        heldJournalsSeen = []
        adoptedLeft = []
        journalAbsentAtLaunch = false
        var kept = [UUID: Int]()
        for (id, data) in carry {
            do {
                try ensureDirectory()
                try journal(id, reopened: false)
                try writeDurably(data, to: bufferURL(id))
                if let n = writtenSequence[id] { kept[id] = n }
            } catch {
                FileHandle.standardError.write(Data("session: copying \(id) to the instance store failed: \(error)\n".utf8))
            }
        }
        writtenSequence = kept
        if lost {
            movedCount += 1
            onMovedToInstance?(made.dir)
        }
        return .instance(made.dir)
    }

    /// `instances/<uuid>/`, owner-only, with its `session.lock` made and
    /// locked before it gets its name (made as `.new-<uuid>`, then
    /// renamed), so a launch scanning for dead ones never takes a new one
    /// for dead.
    private func makeInstance() throws -> (dir: URL, fd: Int32) {
        let name = UUID().uuidString
        let making = instancesRoot.appendingPathComponent(".new-\(name)", isDirectory: true)
        let dir = instancesRoot.appendingPathComponent(name, isDirectory: true)
        try PrivateDirectory.make(making, durableFrom: durableFrom, unconfirmed: &unconfirmedFolders,
                                  syncParent: { [unowned self] in try self.syncFolder($0) })
        let lockPath = making.appendingPathComponent("session.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            if e == EINTR { continue }
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        guard rename(making.path, dir.path) == 0 else {
            let e = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        return (dir, fd)
    }

    /// A regular file's bytes (no link followed, never blocking), or nil.
    static func readRegularFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    public static let lostReason = "its lock file was replaced, so another Owlink may be using it"
    public static let inUseReason = "another Owlink is using it"
    var journalFile: URL { directory.appendingPathComponent("pending-buffers.json") }

    public func bufferURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).txt") }

    /// Owner-only (0700), like the Cedric folder it is in; checked once
    /// per store, not on every save.
    private var directoryReady = false
    private func ensureDirectory() throws {
        if directoryReady, fm.fileExists(atPath: directory.path) { return }
        // Every folder made for the store (Cedric, Session on first use),
        // and the store's own entry, flushed through its parent: a failed
        // flush fails the write, so quit never counts text as kept in a
        // folder whose path may not be on the disk.
        // A retry after a failed flush flushes again every folder from
        // `durableFrom` down, so it never acknowledges a write in a
        // folder whose own entry (or a parent's) isn't on the disk.
        try PrivateDirectory.make(directory, durableFrom: durableFrom, unconfirmed: &unconfirmedFolders,
                                  syncParent: { [unowned self] in try self.syncFolder($0) })
        // Unsaved tab text: recoverable state on this Mac, not backed up.
        PrivateDirectory.excludeFromBackup(directory)
        directoryReady = true
    }

    /// A folder's entries on the disk (`PrivateDirectory.syncFolder`), or
    /// the failure check builds inject (`checkFailFolderSync`).
    private func syncFolder(_ path: String) throws {
        if DevEnvironment.checksEnabled, checkFailFolderSync { throw CocoaError(.fileWriteUnknown) }
        try PrivateDirectory.syncFolder(path)
        if DevEnvironment.checksEnabled { checkSyncedFolders.append(path) }
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

    /// The session, its commit number (0: saved before commits were
    /// numbered; nil: a number no commit can have, so which journals are
    /// spent is unknown) and the held runs' journals it adopted.
    private func loadManifest() -> (session: Session, generation: Int?, adopted: Set<String>)? {
        guard let data = try? Data(contentsOf: sessionFile),
              let s = try? JSONDecoder().decode(Session.self, from: data),
              s.version <= Session.currentVersion else { return nil }
        let g = try? JSONDecoder().decode(Generation.self, from: data)
        let n = g?.generation ?? 0
        return (s, (0...Self.maxGeneration).contains(n) ? n : nil, Set(g?.adoptedJournals ?? []))
    }

    /// Commit numbers go up by one per commit: far below this. A number
    /// outside 0...this (a journal's: 1...this + 1, the one waiting for a
    /// commit after one numbered this) is damaged bookkeeping, never
    /// trusted, and never near overflow.
    ///
    /// Rollover: numbering stops at this + 1 (`nextGeneration`). Every
    /// commit after the one numbered this is numbered this + 1, which
    /// `loadManifest` reads as unknown (no journal counts as spent), and
    /// every journal after it is numbered this + 1 too (never this + 2,
    /// which would read as damaged). So past the end a leftover journal
    /// is applied once more, never skipped: conservative, never lossy.
    static let maxGeneration = 1 << 52

    /// The number after `n`, saturating at `maxGeneration + 1` (rollover).
    static func nextGeneration(_ n: Int) -> Int { min(n, maxGeneration) + 1 }

    /// `session.json`'s commit number and the held runs' journals the
    /// commit adopted (`adoptedJournals`), beside the session's own keys
    /// (older versions ignore them). Not part of `Session`: they are the
    /// store's bookkeeping, not what the user had open.
    private struct Generation: Codable {
        var generation: Int?
        var adoptedJournals: [String]?
    }
    private struct Manifest: Encodable {
        let session: Session
        let generation: Int
        let adopted: [String]
        func encode(to encoder: Encoder) throws {
            try session.encode(to: encoder)
            try Generation(generation: generation, adoptedJournals: adopted.isEmpty ? nil : adopted).encode(to: encoder)
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
    ///
    /// The session folder's writer then adopts dead Owlinks' instance
    /// stores (`instances/*` whose lock it can take), before the caller
    /// expires or prunes anything: their unsaved texts are written here,
    /// journaled, and returned with the rest (their tabs in a window of
    /// their own, their closed tabs on the closed list, loose texts in
    /// `recovered`). Each is removed only after a commit here (`save`);
    /// one that couldn't be read whole is kept. A live one (its lock
    /// held) is left alone.
    public func loadForLaunch(now: Date = Date()) -> LaunchLoad {
        lock.lock(); defer { lock.unlock() }
        // Not the writer: the other Owlink's session is its own to restore.
        if notWriterReason != nil || instanceDir != nil { return .none }
        // Lost since the claim: no session folder of ours to read or adopt into.
        if claimed, !lockStillHeld() {
            _ = try? ensureWriter()
            return .none
        }
        let load = loadForLaunchUnlocked(now: now)
        guard claimed, writerFD >= 0, instanceDir == nil, adoptsInstances, hold == nil else { return load }
        return adoptInstances(into: load)
    }

    private func loadForLaunchUnlocked(now: Date) -> LaunchLoad {
        var journal = readJournal(journalFile)
        var st = stat()
        journalAbsentAtLaunch = lstat(journalFile.path, &st) != 0 && errno == ENOENT
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
        if let (s, generation, adopted) = loadManifest() {
            // An impossible number: no journal counts as spent, and the
            // next commit is numbered from the journals (a journal at or
            // above it is applied once more, then removed by it).
            if let generation { committedGeneration = max(committedGeneration, generation) }
            // Spent: the commit it waited for is in session.json already.
            if let g = journal.generation, let generation, g <= generation, !journal.damaged { journal = ([], [], g, false) }
            pending = journal.ids
            pendingReopened = journal.reopened
            committed = s.bufferIDs
            committedClosed = Set((s.closedTabs ?? []).map(\.id))
            held = Set(s.heldBuffers ?? [])
            var candidates = journal.ids
            var reopened = Set(journal.reopened)
            // Reopens of held tabs an earlier launch couldn't apply: owed
            // whatever the journal says (a commit since may have cleared it).
            let owed = Set(s.heldReopened ?? [])
            var damaged = journal.damaged
            // A held run's journal is applied whatever its number: that run
            // couldn't read the commit it would have waited for, so its
            // number proves nothing. Only a commit that names it as
            // adopted (made by a launch that applied it) spends it.
            for (url, j) in zip(heldJournalsSeen, heldJournals) where !adopted.contains(url.lastPathComponent) {
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
            reopened.formUnion(owed)
            // What launch replays is what the journal says from now on: a
            // journal written before the next commit (a new tab's first
            // text) carries every id and reopen this launch found, from a
            // scan or a held run's journal too, so a second crash brings
            // back the same buffers and reopens the same closed tabs.
            pending = candidates
            pendingReopened = reopened.filter(committedClosed.contains).sorted { $0.uuidString < $1.uuidString }
            let r = Self.applyJournal(s, journal: candidates, reopened: reopened,
                                      bufferReadable: { [self] in if case .text = readBufferResult($0) { true } else { false } }) {
                // lstat (bufferExists): a dangling link in a buffer's place
                // is there, so it is held by the reader, not skipped here and
                // then pruned.
                bufferExists($0)
            }
            held = Set(r.session.heldBuffers ?? [])
            // A reopen of a held tab that stays held and closed (its buffer
            // still unreadable): recorded in the session from now on, so a
            // commit that clears the journal doesn't lose it.
            let closedNow = Set((r.session.closedTabs ?? []).map(\.id))
            heldReopen = reopened.filter { held.contains($0) && closedNow.contains($0) }
            var out = r.session
            out.heldReopened = heldReopen.isEmpty ? nil : heldReopen.sorted { $0.uuidString < $1.uuidString }
            return .session(out, recovered: r.recovered)
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
    ///
    /// A held buffer (one an earlier launch couldn't read) is left alone,
    /// unless it was reopened since (⇧⌘T read it, and journaled that) and
    /// `bufferReadable` says it can be read now: then the reopen counts as
    /// for any other tab, and it is no longer held. Else its closed entry,
    /// under its old closing date, could expire it with that text.
    public static func applyJournal(_ session: Session, journal: [UUID], reopened: Set<UUID> = [],
                                    bufferReadable: (UUID) -> Bool = { _ in false }, bufferExists: (UUID) -> Bool)
        -> (session: Session, recovered: [UUID]) {
        var s = session
        var recovered: [UUID] = []
        var reopenedTabs: [SessionTab] = []
        var held = Set(s.heldBuffers ?? [])
        var seen = Set<UUID>()
        let order = journal + reopened.sorted { $0.uuidString < $1.uuidString }.filter { !journal.contains($0) }
        for id in order where seen.insert(id).inserted && bufferExists(id) {
            if held.contains(id) {
                guard reopened.contains(id), bufferReadable(id) else { continue }
                held.remove(id)
                s.heldBuffers = held.isEmpty ? nil : s.heldBuffers?.filter { $0 != id }
            }
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
        // A number no commit waits for (0, negative, past maxGeneration + 1):
        // which commit it waited for is unknown, as for an unreadable one.
        if let g = j.generation, !(1...Self.maxGeneration + 1).contains(g) { return ([], [], nil, true) }
        let ids = j.ids.compactMap(UUID.init(uuidString:))
        let reopened = (j.reopened ?? []).compactMap(UUID.init(uuidString:))
        guard ids.count == j.ids.count, reopened.count == (j.reopened ?? []).count else { return ([], [], j.generation, true) }
        return (ids, reopened, j.generation, false)
    }

    private func encodeJournal(_ ids: [UUID], reopened: [UUID], numbered: Bool = true) throws -> Data {
        try JSONEncoder().encode(Journal(generation: numbered ? Self.nextGeneration(committedGeneration) : nil, ids: ids.map(\.uuidString),
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
    /// cleared. Throws, writing nothing, while `hold` is set, and unless
    /// every buffer in `needs` is there as needed (a write it depends on
    /// failed or hasn't landed: the older commit and the journal stay,
    /// and the caller prunes nothing).
    public func save(_ session: Session, requiring needs: [UUID: BufferNeed] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWriter()
        if let hold { throw SessionStoreError.held(hold) }
        let missing = needs.filter { id, need in
            if held.contains(id) { return false }
            var st = stat()
            guard lstat(bufferURL(id).path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return true }
            // A regular file this user can't read is no copy of the text
            // either: the caller holds it (never pruned, never expired).
            if access(bufferURL(id).path, R_OK) != 0 { return true }
            if case .written(let seq) = need { return (writtenSequence[id] ?? Int.min) < seq }
            return false
        }.keys.sorted { $0.uuidString < $1.uuidString }
        guard missing.isEmpty else { throw SessionStoreError.buffersMissing(missing) }
        try ensureDirectory()
        try injectedFailure()
        var s = session
        s.heldBuffers = held.isEmpty ? nil : held.sorted { $0.uuidString < $1.uuidString }
        let owed = heldReopen.intersection(held)
        s.heldReopened = owed.isEmpty ? nil : owed.sorted { $0.uuidString < $1.uuidString }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if DevEnvironment.checksEnabled, !pending.isEmpty || !pendingReopened.isEmpty, let hook = checkBeforeCommit { hook() }
        let generation = Self.nextGeneration(committedGeneration)
        // The held runs' journals launch applied: this commit names what
        // they listed (or let it go), so it says it adopted them.
        let adopting = adoptedLeft.union(heldJournalsSeen.map(\.lastPathComponent)).sorted()
        do {
            try writeDurably(enc.encode(Manifest(session: s, generation: generation, adopted: adopting)), to: sessionFile)
        } catch let e as PrivateDirectory.Unconfirmed {
            // Renamed into place, not confirmed on the disk: session.json
            // is this commit now and may be the one before after a power
            // loss. Either way the next journal must outrank it, so it
            // counts as committed for numbering (a journal numbered above
            // the commit on disk is always applied). For the rest, what
            // either commit could be: a buffer counts as named only if
            // both name it, a tab as closed if either lists it. The
            // journal stays (it may still be needed), and nothing is pruned.
            committedGeneration = generation
            committed.formIntersection(s.bufferIDs)
            committedClosed.formUnion((s.closedTabs ?? []).map(\.id))
            journalStale = true
            throw e
        }
        committedGeneration = generation
        committed = s.bufferIDs
        committedClosed = Set((s.closedTabs ?? []).map(\.id))
        journalStale = false
        // Every buffer written before this session's snapshot is named in
        // it or was let go (writes are serialized with saves). If the app
        // dies before this, or it fails, the journal is spent anyway: it
        // waited for this commit.
        if !pending.isEmpty || !pendingReopened.isEmpty || fm.fileExists(atPath: journalFile.path) {
            pending = []
            pendingReopened = []
            try? fm.removeItem(at: journalFile)
        }
        // Held runs' journals: adopted by this commit, so they can go. One
        // that stays (removing it failed) is named again by the next.
        for url in heldJournalsSeen { try? fm.removeItem(at: url) }
        heldJournalsSeen = []
        adoptedLeft = Set(adopting.filter { name in
            var st = stat()
            return lstat(directory.appendingPathComponent(name).path, &st) == 0 || errno != ENOENT
        })
        // Dead Owlinks' instance stores launch adopted: what was taken
        // from them is named in this commit (or the user let it go since),
        // and on the disk, so they can go. Only while their lock is still
        // the file at its path (else left for the next launch).
        for o in orphansToRemove {
            if Self.sameFile(o.fd, o.dir.appendingPathComponent("session.lock").path) { try? fm.removeItem(at: o.dir) }
            close(o.fd)
        }
        orphansToRemove = []
    }

    /// Writes tab `id`'s unsaved text. `open`: the tab is open (false: a
    /// closed tab's text kept in memory since its close couldn't write it).
    /// `sequence`: the caller's number for this write, noted once it has
    /// succeeded (`BufferNeed.written`).
    public func writeBuffer(_ id: UUID, text: String, open: Bool = true, sequence: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWriter()
        try writeBufferUnlocked(id, data: Data(text.utf8), open: open)
        if let sequence { writtenSequence[id] = max(writtenSequence[id] ?? Int.min, sequence) }
    }

    private func writeBufferUnlocked(_ id: UUID, data: Data, open: Bool) throws {
        try ensureDirectory()
        try injectedFailure()
        // Journaled before the buffer exists, so a buffer is never on
        // disk unnamed by both the session and the journal, nor written
        // for a reopened tab the session still lists as closed.
        try journal(id, reopened: open)
        try writeDurably(data, to: bufferURL(id))
    }

    /// File › Reopen Closed Tab brought `id` back: journaled at once, so
    /// it reopens after a crash even if nothing is written for it before
    /// the next commit (its closing date could expire it meanwhile).
    public func noteReopened(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWriter()
        guard committedClosed.contains(id), journalStale || !pendingReopened.contains(id) else { return }
        try ensureDirectory()
        try injectedFailure()
        try journal(id, reopened: true)
    }

    private func journal(_ id: UUID, reopened: Bool) throws {
        let fresh = !committed.contains(id) && !pending.contains(id)
        let reopening = reopened && committedClosed.contains(id) && !pendingReopened.contains(id)
        // After an unconfirmed commit, nothing pending counts as journaled
        // until the journal is written again above it (`journalStale`).
        guard fresh || reopening || journalStale else { return }
        let ids = fresh ? pending + [id] : pending, again = reopening ? pendingReopened + [id] : pendingReopened
        // Held: never over the journal launch found (it may be all that
        // says which buffers are pending), but beside it. With none found,
        // in the main journal, unnumbered (`journalAbsentAtLaunch`).
        let main = hold == nil || journalAbsentAtLaunch
        if DevEnvironment.checksEnabled, checkFailJournal { throw CocoaError(.fileWriteNoPermission) }
        try writeDurably(encodeJournal(ids, reopened: again, numbered: hold == nil), to: main ? journalFile : heldJournalFile)
        pending = ids
        pendingReopened = again
        journalStale = false
    }

    /// What reading a buffer found.
    public enum BufferRead: Equatable, Sendable {
        case text(String)
        /// No such file.
        case missing
        /// It is there but couldn't be read: keep it (`holdBuffer`).
        case unreadable(String)
    }

    /// Reads only a regular file, never following a link, opened without
    /// blocking (O_NONBLOCK): a FIFO, a device or a folder in a buffer's
    /// place is unreadable, never waited on, so this is safe on the main
    /// thread (⇧⌘T, a save's completion).
    public func readBufferResult(_ id: UUID) -> BufferRead {
        let path = bufferURL(id).path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return errno == ENOENT ? .missing : .unreadable(String(cString: strerror(errno)))
        }
        guard st.st_mode & S_IFMT == S_IFREG else { return .unreadable("not a regular file") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unreadable(String(cString: strerror(errno))) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, fst.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return .unreadable("not a regular file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            return .text(String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Whether a buffer file is there at all (lstat only: never opens it).
    public func bufferExists(_ id: UUID) -> Bool {
        var st = stat()
        return lstat(bufferURL(id).path, &st) == 0 || errno != ENOENT
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
        heldReopen.remove(id)
    }

    /// Launch's second try at the buffers `loadForLaunch` left held, on the
    /// session it returned. One read now that is a closed tab whose reopen
    /// is owed (`Session.heldReopened`) opens again, in a window of its own
    /// with no closing date, as a reopen `loadForLaunch` could read does:
    /// its reopen is never let go with the tab still closed (a later commit
    /// would list it closed, unprotected, under the old date that expires
    /// it). One read now that no tab lists is returned in `recovered`; one
    /// that still can't be read, or isn't there at all, in `unreadable`
    /// (the caller says so; it stays held, and an owed reopen stays owed,
    /// until the tab is recovered or the user lets it go).
    public struct HeldRetry {
        public var session: Session
        public var recovered: [UUID]
        public var unreadable: [(id: UUID, why: String)]
    }

    public func retryHeldBuffers(_ session: Session) -> HeldRetry {
        var s = session
        var recovered: [UUID] = []
        var unreadable: [(id: UUID, why: String)] = []
        var promoted: [SessionTab] = []
        let owed = Set(s.heldReopened ?? [])
        for id in s.heldBuffers ?? [] {
            switch readBufferResult(id) {
            case .text:
                if let c = s.closedTabs?.firstIndex(where: { $0.id == id }) {
                    if owed.contains(id), var tab = s.closedTabs?.remove(at: c) {
                        tab.hasBuffer = true
                        tab.closed = nil
                        promoted.append(tab)
                    }
                } else if !s.windows.contains(where: { $0.tabs.contains { $0.id == id } }) {
                    recovered.append(id)
                }
                releaseBuffer(id)
            // Not there now (a sync or restore may be replacing it): it
            // stays held, and an owed reopen owed, as for an unreadable
            // one. Let go here, the buffer could be back before launch's
            // expiry or a later prune and be deleted with its text.
            case .missing: unreadable.append((id, "it isn’t there right now"))
            case .unreadable(let why): unreadable.append((id, why))
            }
        }
        let still = heldBuffers, stillOwed = heldReopened
        s.heldBuffers = s.heldBuffers?.filter(still.contains)
        if s.heldBuffers?.isEmpty == true { s.heldBuffers = nil }
        s.heldReopened = s.heldReopened?.filter(stillOwed.contains)
        if s.heldReopened?.isEmpty == true { s.heldReopened = nil }
        if s.closedTabs?.isEmpty == true { s.closedTabs = nil }
        if !promoted.isEmpty { s.windows.append(SessionWindow(tabs: promoted)) }
        return HeldRetry(session: s, recovered: recovered, unreadable: unreadable)
    }

    /// Held closed tabs whose reopen is still owed (`Session.heldReopened`):
    /// their closed entries must not expire or be dropped.
    public var heldReopened: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return heldReopen.intersection(held)
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
        guard (try? ensureWriter()) != nil, hold == nil, !held.contains(id) else { return }
        try? fm.removeItem(at: bufferURL(id))
    }

    /// Deletes buffer files no tab refers to (called right after a
    /// commit). Never held ones, and nothing at all while `hold` is set.
    public func pruneBuffers(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        // Never the session folder without its lock verified just now.
        guard (try? ensureWriter()) != nil, hold == nil else { return }
        let keep = ids.union(held)
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "txt" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !keep.contains(id) {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// What launch took from dead Owlinks' instance stores.
    private struct Adopted {
        var open: [SessionTab] = []
        var closed: [SessionTab] = []
        var loose: [UUID] = []
        var isEmpty: Bool { open.isEmpty && closed.isEmpty && loose.isEmpty }
    }

    /// `load` with the dead instance stores' unsaved texts added
    /// (`loadForLaunch`).
    private func adoptInstances(into load: LaunchLoad) -> LaunchLoad {
        var taken = Set(pending).union(held)
        switch load {
        case .none: break
        case .session(let s, let r):
            taken.formUnion(s.allTabs.map(\.id) + (s.closedTabs ?? []).map(\.id) + (s.heldBuffers ?? []) + r)
        case .recover(_, let b): taken.formUnion(b)
        }
        let found = adoptOrphans(taken: &taken)
        guard !found.isEmpty else { return load }
        switch load {
        case .none:
            return .session(Session(windows: found.open.isEmpty ? [] : [SessionWindow(tabs: found.open)],
                                    closedTabs: found.closed.isEmpty ? nil : found.closed), recovered: found.loose)
        case .session(var s, let r):
            if !found.open.isEmpty { s.windows.append(SessionWindow(tabs: found.open)) }
            if !found.closed.isEmpty { s.closedTabs = (s.closedTabs ?? []) + found.closed }
            return .session(s, recovered: r + found.loose)
        case .recover(let aside, let b):
            return .recover(setAside: aside, buffers: b + found.open.map(\.id) + found.closed.map(\.id) + found.loose)
        }
    }

    /// Every instance store in `instances/` whose lock this store can take
    /// (its Owlink has ended): its session read as a launch would (its
    /// journal applied), and each unsaved text in it written here,
    /// journaled, under its own id (a new one if that id is taken here by
    /// other text; skipped if the same text is here already). A store
    /// whose texts were all taken is kept locked for removal after the
    /// next commit; one with a text that couldn't be read or written, or
    /// a session that couldn't be read, is left as it is.
    private func adoptOrphans(taken: inout Set<UUID>) -> Adopted {
        var out = Adopted()
        guard let names = try? fm.contentsOfDirectory(atPath: instancesRoot.path) else { return out }
        for name in names.sorted() where UUID(uuidString: name) != nil {
            let dir = instancesRoot.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let lockPath = dir.appendingPathComponent("session.lock").path
            let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            var r: Int32
            repeat { r = flock(fd, LOCK_EX | LOCK_NB) } while r != 0 && errno == EINTR
            // Held: that Owlink is running. Left alone.
            guard r == 0, Self.sameFile(fd, lockPath) else { close(fd); continue }
            let orphan = SessionStore(directory: dir, durableFrom: durableFrom)
            var whole = true
            var items: [(tab: SessionTab?, id: UUID, closed: Bool)] = []
            switch orphan.loadForLaunch() {
            case .none: break
            case .session(let s, let rec):
                items = s.allTabs.filter(\.hasBuffer).map { ($0, $0.id, false) }
                    + (s.closedTabs ?? []).filter(\.hasBuffer).map { ($0, $0.id, true) } + rec.map { (nil, $0, false) }
                let named = Set(items.map(\.id))
                // Its held ids: text it couldn't read (kept there), or the
                // session folder's own held buffers it carried the names of.
                items += (s.heldBuffers ?? []).filter { !named.contains($0) && orphan.bufferExists($0) }.map { (nil, $0, false) }
            case .recover(let aside, let bufs):
                // Its session couldn't be read: its texts are taken, it stays.
                if aside != nil { whole = false }
                items = bufs.map { (nil, $0, false) }
            }
            if orphan.hold != nil { whole = false }
            for item in items {
                switch orphan.readBufferResult(item.id) {
                case .text(let text):
                    var id = item.id
                    if taken.contains(id) || bufferExists(id) {
                        if taken.contains(id), case .text(let mine) = readBufferResult(id), mine == text { continue }
                        id = UUID()
                    }
                    do {
                        try writeBufferUnlocked(id, data: Data(text.utf8), open: !item.closed)
                    } catch {
                        FileHandle.standardError.write(Data("session: adopting \(item.id) from \(dir.path) failed: \(error)\n".utf8))
                        whole = false
                        continue
                    }
                    taken.insert(id)
                    adoptedCount += 1
                    if var tab = item.tab {
                        tab.id = id
                        tab.hasBuffer = true
                        if item.closed { out.closed.append(tab) } else { out.open.append(tab) }
                    } else {
                        out.loose.append(id)
                    }
                case .missing: continue
                case .unreadable: whole = false
                }
            }
            if whole { orphansToRemove.append((dir, fd)) } else { close(fd) }
        }
        return out
    }
}

public enum SessionStoreError: Error, LocalizedError, Equatable {
    /// `SessionStore.hold`: the session isn't written this run.
    case held(String)
    /// A commit's buffers that aren't on disk as it needs (`save(_:requiring:)`).
    case buffersMissing([UUID])

    public var errorDescription: String? {
        switch self {
        case .held(let why): return "Owlink isn’t saving its session this run: \(why)."
        case .buffersMissing(let ids): return "\(ids.count) unsaved text(s) aren’t on disk yet, so the session wasn’t updated."
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
    /// `keepDays` after this version first sees it. A tab in `keeping` (a
    /// held tab whose reopen is owed, `Session.heldReopened`) never goes.
    public static func expire(_ list: [SessionTab], now: Date = Date(), keeping: Set<UUID> = []) -> (list: [SessionTab], dropped: [SessionTab]) {
        var kept: [SessionTab] = []
        var dropped: [SessionTab] = []
        for var t in list {
            let closed = t.closed ?? now
            if now.timeIntervalSince(closed) > Double(keepDays) * 86_400, !keeping.contains(t.id) { dropped.append(t); continue }
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
    /// Tabs in `keeping` (`expire`) are never dropped, by date or count,
    /// and don't count toward `unsavedLimit`; nor is `tab` ever dropped.
    public static func push(_ tab: SessionTab, onto list: [SessionTab], limit: Int = ClosedTabs.limit, keeping: Set<UUID> = [])
        -> (list: [SessionTab], dropped: [SessionTab]) {
        push(tab, onto: list, limit: limit, now: Date(), keeping: keeping)
    }

    public static func push(_ tab: SessionTab, onto list: [SessionTab], limit: Int = ClosedTabs.limit, unsavedLimit: Int = ClosedTabs.unsavedLimit,
                            now: Date, keeping: Set<UUID> = []) -> (list: [SessionTab], dropped: [SessionTab]) {
        // Reopening and closing the same tab again: one entry.
        // Tabs past `keepDays` go now too, as at launch, so a session that
        // runs for weeks doesn't keep them until the next launch.
        let fresh = expire(list.filter { $0.id != tab.id }, now: now, keeping: keeping)
        var out = fresh.list
        var tab = tab
        tab.closed = now
        out.append(tab)
        var dropped: [SessionTab] = fresh.dropped
        // The tab being closed is never dropped (its text would go with
        // it, the moment it was kept).
        while out.count > max(1, limit), let i = out.firstIndex(where: { !$0.hasBuffer && $0.id != tab.id }) {
            dropped.append(out.remove(at: i))
        }
        // Unsaved text is kept, but not without end: past `unsavedLimit`
        // the oldest goes (and then `keepDays`, see `expire`). Only
        // ordinary entries count: one in `keeping` is never dropped, so
        // counting it would only make room for fewer of the others (and,
        // with `unsavedLimit` of them, none: not even this one).
        var unsaved = out.filter { $0.hasBuffer && !keeping.contains($0.id) }.count
        while unsaved > max(1, unsavedLimit),
              let i = out.firstIndex(where: { $0.hasBuffer && !keeping.contains($0.id) && $0.id != tab.id }) {
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
