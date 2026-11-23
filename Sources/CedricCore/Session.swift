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

    public init(windows: [SessionWindow], untitledCounter: Int = 0, closedTabs: [SessionTab]? = nil, folder: SessionFolder? = nil,
                wordGoals: [FileWordGoal]? = nil) {
        self.windows = windows
        self.untitledCounter = untitledCounter
        self.closedTabs = closedTabs
        self.folder = folder
        self.wordGoals = wordGoals
    }

    public var allTabs: [SessionTab] { windows.flatMap(\.tabs) }
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
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default
    private let lock = NSLock()

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

    /// The saved session, or nil if there is none or it can't be read.
    public func load() -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: sessionFile),
              let s = try? JSONDecoder().decode(Session.self, from: data),
              s.version <= Session.currentVersion else { return nil }
        return s
    }

    public func save(_ session: Session) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateDirectory.writePrivateFile(enc.encode(session), to: sessionFile)
    }

    public func writeBuffer(_ id: UUID, text: String) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        try PrivateDirectory.writePrivateFile(Data(text.utf8), to: bufferURL(id))
    }

    public func readBuffer(_ id: UUID) -> String? {
        guard let data = try? Data(contentsOf: bufferURL(id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func removeBuffer(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: bufferURL(id))
    }

    /// Deletes buffer files no tab refers to.
    public func pruneBuffers(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "txt" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                try? fm.removeItem(at: f)
            }
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
