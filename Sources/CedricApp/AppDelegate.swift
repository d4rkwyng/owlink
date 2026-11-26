import AppKit
import CedricCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The key window when it can host a new document tab: never a panel
    /// (Ask Cedric, Find), Settings or any other window that doesn't tab.
    /// 0.1.1 (rc1 VM): a file opened while Ask Cedric was key became a tab
    /// inside the panel.
    static var documentKeyWindow: NSWindow? { documentWindow(for: NSApp.keyWindow) }

    /// `window` if a new tab can join it. A detached preview (key after
    /// Detach) stands for its tab's editor window: the new tab joins the
    /// window that owns the preview, never the preview itself.
    static func documentWindow(for window: NSWindow?) -> NSWindow? {
        guard let w = window, !(w is NSPanel) else { return nil }
        if w.tabbingMode != .disallowed { return w }
        let owner = (NSApp.delegate as? AppDelegate)?.tabs.first { $0.previewWindow?.window === w }
        return owner?.window
    }

    private(set) var tabs: [EditorWindowController] = []
    /// PDF viewer tabs (PDFTab.swift), in the same windows' tab groups.
    var pdfTabs: [PDFTabController] = []
    /// Image tabs (ImageTab.swift) and Office / iWork Quick Look tabs
    /// (OfficeTab.swift), likewise. `viewerTabs` is all three (ViewerTabs.swift).
    var imageTabs: [ImageTabController] = []
    var officeTabs: [OfficeTabController] = []
    var certificateTabs: [CertificateTabController] = []
    let store = SessionStore(directory: SessionStore.defaultDirectory())
    private let env = DevEnvironment.values
    private var sessionTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    /// Files handed over before launch finished (Finder, `open`).
    private var pendingOpen: [URL] = []
    private var launched = false
    /// Open Recent rebuild queued (EditorTools.swift).
    var recentRebuildScheduled = false
    /// Set once quitting: windows closed by termination keep their buffers.
    private(set) var terminating = false
    /// File › Reopen Closed Tab (ClosedTabs.swift): closed tabs, newest
    /// last, saved with the session; their unsaved text stays in their
    /// buffer files. `closedTexts` holds the text in memory instead when
    /// session saving is off (the checks).
    var closedTabs: [SessionTab] = []
    /// Files' word goals (the stats popover), from and to the session.
    var fileWordGoals: [FileWordGoal] = []
    /// Words written today, across documents (the stats popover's second ring).
    let dailyWords = DailyWordCounter()
    /// Window › Float on Top, per window (FloatOnTop.swift). The set, not
    /// the live level: full screen changes the level on its own.
    var floatingWindows = Set<ObjectIdentifier>()
    var closedTexts: [UUID: String] = [:]

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("will_finish")
        // A save past the file-size limit fails with an error the save
        // recovers from, instead of SIGXFSZ ending the app mid-write.
        // Caught, not ignored: git and other programs Owlink starts get
        // the default action back.
        DocumentWrite.catchFileSizeSignal()
        NSWindow.allowsAutomaticWindowTabbing = true
        dailyWords.onChange = { [weak self] in self?.refreshOpenStatsPopovers() }
        NotificationCenter.default.addObserver(self, selector: #selector(windowExitedFullScreen(_:)),
                                               name: NSWindow.didExitFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(noteWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        rotateCLIToken()
    }

    /// A fresh `cedric` script token every launch (the old one counts for
    /// CLIToken.rotationGrace more, for a script that started this launch).
    /// Not for a test run with its own session folder: that leaves the
    /// user's token alone.
    private func rotateCLIToken() {
        guard DevEnvironment.values["CEDRIC_SESSION_DIR"] == nil else { return }
        Self.previousCLIToken = CLIToken.read(CLIToken.defaultURL)
        Self.cliTokenRotated = Date()
        CLIToken.rotate()
        DispatchQueue.global(qos: .utility).async { CLIHandoff.sweepAuth() }
    }

    nonisolated(unsafe) static var previousCLIToken: String?
    nonisolated(unsafe) static var cliTokenRotated = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("did_finish")
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil) }
        }
        // The owl hub listens for Cedric › Show Cedric; it must exist
        // before the first toggle (it was created lazily, so with the owl
        // off and only untitled tabs the menu item did nothing). Not needed
        // for the first frame (a tab with the owl on creates it at once).
        AfterFirstFrame.run { _ = OwlHub.shared }
        // Replace in Files' undo copies past 7 days (or the newest 5) go
        // even when no replace follows: after the first frame, off the
        // main thread, on the queue the replaces use.
        AfterFirstFrame.run {
            let store = ReplaceInFiles.store
            ReplaceInFiles.queue.async { store.pruneAtLaunch() }
        }
        if env["CEDRIC_NO_RESTORE"] != "1" { restoreSession() }
        LaunchTrace.mark("restored")
        var toOpen = pendingOpen
        if let list = env["CEDRIC_OPEN"], !list.isEmpty {
            toOpen += list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        for url in toOpen { open(url, background: true) }
        pendingOpen = []
        // A big file still reading: its tab is the launch's window.
        if tabs.isEmpty && viewerTabs.isEmpty && backgroundOpens.isEmpty { newTab(nil) }
        schedulePendingRestore()
        LaunchTrace.mark("tabs_ready")
        recentMenu?.delegate = self
        scheduleRecentMenuRebuild()
        launched = true
        DevHooks.afterLaunch(self)
        LaunchTrace.afterLaunch(self)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingOpen += urls; return }
        for url in urls { open(url, background: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newTab(nil) }
        return true
    }

    /// AppKit asks once no window at all is left (Settings, About and the
    /// like included). Closing the last document tab quits on its own
    /// (`quitAfterLastClose`), whatever auxiliary windows are open; this
    /// covers, say, Settings closed last after the setting was turned on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        quitsOnLastClose && tabs.isEmpty && viewerTabs.isEmpty
    }

    /// No "save changes?" on quit: unsaved text is kept in the session and
    /// comes back as open tabs next launch, reopen on or off (with it off,
    /// only clean files go to Reopen Closed Tab: SessionReopenPolicy.plan).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Closing the last window already saved (quitAfterLastClose / a
        // last-window terminate started from windowShouldClose).
        if !terminating { prepareToQuit() }
        return .terminateNow
    }

    /// The quit path: the session (unsaved buffers included) written and
    /// waited for, `cedric -w` waiters released.
    /// An open stats popover follows today's count (the ring, not a recount
    /// of the document on the keystroke path).
    func refreshOpenStatsPopovers() {
        for tab in tabs where tab.editing.statsPopover?.popover.isShown == true {
            tab.editing.statsPopover?.refresh()
        }
    }

    private func prepareToQuit() {
        // Replace in Files' disk writes under way finish first.
        ReplaceInFiles.waitForWrites()
        // The last words of the day, if typing hadn't paused yet.
        tabs.forEach { $0.commitDailyWords() }
        // The whole session, whatever Reopen files from last session says:
        // launch decides what comes back (SessionReopenPolicy.plan; with it
        // off, files go to Reopen Closed Tab there and unsaved text reopens).
        saveSession()
        releaseAllWaiters()
        failPendingBackgroundOpens()
        terminating = true
        sessionTimer?.invalidate()
    }

    /// Settings › "Quit when the last window closes", once launch is done
    /// (an alert for a file that failed to open closes before any tab
    /// exists) and not while restored tabs are still to be built. The
    /// dev hooks drive tabs open and shut, so it is off under them unless
    /// CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1.
    var quitsOnLastClose: Bool {
        lastCloseMayQuit && DevHooks.allowsQuitOnLastClose && Settings.shared.quitWhenLastWindowCloses
    }

    /// Nothing still to come that a last close would throw away: launch
    /// done, restored tabs built, no big file reading in the background
    /// (its tab is on its way: closing the only other tab must not quit).
    var lastCloseMayQuit: Bool {
        launched && !terminating && pendingRestore.isEmpty && backgroundOpens.isEmpty
    }

    /// The document tabs' windows other than `window` (text and viewer tabs:
    /// PDF, image, Office;
    /// detached previews, Settings, panels and the owl don't count).
    private func otherDocumentWindows(than window: NSWindow?) -> Int {
        (tabs.compactMap(\.window) + viewerTabs.compactMap(\.window)).filter { $0 !== window }.count
    }

    /// A document tab is closing (its views still intact): whether it is
    /// the last one, so the app quits once it has closed. Ask before the
    /// tab leaves `tabs`/`viewerTabs`.
    func isClosingLastDocument(_ window: NSWindow?) -> Bool {
        quitsOnLastClose && otherDocumentWindows(than: window) == 0
    }

    /// The last document tab has closed: only a fallback (windowShouldClose
    /// / Close Window usually quit first, while the tabs were still open).
    func quitAfterLastClose() {
        prepareToQuit()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Close Window (⇧⌘W) and the traffic-light / last-tab close, when that
    /// close will quit the app: save the session while the tabs are still
    /// open, then terminate instead of tearing them down one by one. With
    /// reopen off too: launch then parks the files and reopens unsaved
    /// text (SessionReopenPolicy.plan), where hot-closing each tab would
    /// leave that text to the closed list's 30-day / 100-tab limits.
    /// Returns `false` when the close should be cancelled because quit is
    /// already under way.
    func shouldCloseDocumentWindow(_ window: NSWindow) -> Bool? {
        guard !terminating else { return false }
        guard quitsOnLastClose else { return nil }
        let onlyGroup = windowGroups().count == 1
        let lastTab = otherDocumentWindows(than: window) == 0
        if onlyGroup, lastTab || isClosingWholeWindow(window) {
            prepareToQuit()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        return nil
    }

    /// File › Close Window (⇧⌘W): every tab in this window. On a
    /// quit-causing last window, terminate with the session already saved.
    func closeDocumentWindows(in window: NSWindow) {
        if quitsOnLastClose, windowGroups().count == 1 {
            prepareToQuit()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        for win in window.tabbedWindows ?? [window] { win.performClose(nil) }
    }

    /// The red close button on a tabbed window closes the whole group;
    /// a tab's own close, or ⌘W, closes only that tab. AppKit closes the
    /// group only for a real click (performClick closes just the front
    /// tab), and every tab's windowShouldClose
    /// then sees that click as the current event (session-check step 8d).
    /// Known gap: if this ever missed it, the group's other tabs would be
    /// hot-closed onto the closed list before the last one quits.
    private func isClosingWholeWindow(_ window: NSWindow) -> Bool {
        let group = window.tabbedWindows ?? [window]
        guard group.count > 1 else { return false }
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              let btn = window.standardWindowButton(.closeButton) else { return false }
        return btn.bounds.contains(btn.convert(event.locationInWindow, from: nil))
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Left open across local midnight: today's ring starts at zero.
        dailyWords.rollToNow()
        tabs.forEach { $0.reloadIfChangedOnDisk() }
        viewerTabs.forEach { $0.reloadIfChangedOnDisk() }
        tabs.forEach { $0.gitState?.scheduleRefresh() }
    }

    /// `cedric://open?path=/abs/file&line=12` (the command-line launcher)
    /// and `cedric://open?untitled=<temp file>` (stdin: opened as a new
    /// untitled tab, then the temp file is deleted).
    ///
    /// Any app or web page can send a cedric:// URL, so (CLIHandoff,
    /// CLIToken in CedricCore): the `cedric` script adds `auth=`, a 0600
    /// temp file holding a secret only this user can read (rotated at
    /// every launch). Without it, `untitled=` and `wait=` are
    /// refused and `path=` asks first ("Open … requested by a link?", one
    /// question at a time). A file is deleted only if it is the script's
    /// own temp file (cedric-stdin.* / cedric-wait.* in the user's temp
    /// folder, checked after resolving `..` and symlinks, on an O_NOFOLLOW
    /// descriptor: regular, one link, this user's) and still the same
    /// inode when it is deleted.
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s), comps.scheme == "cedric" else { return }
        let q = Dictionary((comps.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        // The script's token comes in a hand-off file (`auth=`), read once
        // and deleted; never on the command line (`token=` is ignored).
        let given = q["auth"].flatMap { CLIHandoff.takeAuth($0) }
        let trusted = CLIToken.matches(given, CLIToken.ensure())
            || (Date().timeIntervalSince(Self.cliTokenRotated) < CLIToken.rotationGrace && CLIToken.matches(given, Self.previousCLIToken))
        if let raw = q["path"] {
            guard raw.hasPrefix("/") else { refuseURL("path isn’t absolute"); return }
            let path = (raw as NSString).standardizingPath
            if trusted {
                openFromURL(path, q)
            } else {
                askToOpenFromLink(path, q)
                return
            }
        } else if let tmp = q["untitled"] {
            guard trusted else { refuseURL("untitled= without the cedric script’s token"); return }
            guard let h = CLIHandoff.inspect(tmp, kind: .stdin, read: true), let data = h.data else {
                refuseURL("untitled= isn’t the cedric script’s temp file: \(tmp)")
                return
            }
            if let d = TextCodec.decode(data, as: nil) {
                let doc = newDocument()
                doc.apply(d)
                doc.languageChoice = .untitled(content: d.text)
                makeTab(doc, text: d.text)
                doc.markDirtyFromSession()
                tabs.last?.updateTitle()
            }
            CLIHandoff.remove(h)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refuseURL(_ why: String) {
        FileHandle.standardError.write(Data((CLIToken.refusal(why, secret: CLIToken.ensure()) + "\n").utf8))
    }

    /// A tokenless `path=` (a link, not the cedric script): ask, one at a time; never with `wait=`.
    private func askToOpenFromLink(_ path: String, _ q: [String: String]) {
        guard !Self.askingAboutLink else { refuseURL("a link is already being asked about"); return }
        if Self.linkAnswerForChecks == false { refuseURL("declined: \(path)"); return }
        Self.askingAboutLink = true
        defer { Self.askingAboutLink = false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        // The full path, so a link to ~/.ssh/config reads as exactly that;
        // bidi and control characters shown as escapes so they can't disguise it.
        let shown = PromptText.visible(path)
        a.messageText = String(localized: "Open “\(shown)” requested by a link?")
        a.informativeText = String(localized: "Another app or a web page asked Owlink to open this file. Open it only if you expected this.")
        a.addButton(withTitle: String(localized: "Open"))
        a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { refuseURL("declined: \(path)"); return }
        var q = q
        q["wait"] = nil
        openFromURL(path, q)
    }

    private static var askingAboutLink = false
    /// The checks' answer to the question (set in-process by DevChecks only; nil: ask).
    static var linkAnswerForChecks: Bool?

    private func openFromURL(_ path: String, _ q: [String: String]) {
        let url = URL(fileURLWithPath: path)
        // `cedric some/dir`: the folder sidebar. A folder has no tab to wait
        // for, so `cedric -w some/dir` returns at once: its marker goes now
        // (the script waits only for files, documented as "each file's tab").
        if Self.isFolder(url.standardizedFileURL) {
            open(url)
            if let marker = q["wait"], let h = CLIHandoff.inspect(marker, kind: .wait) { CLIHandoff.remove(h) }
            return
        }
        let line = q["line"].flatMap(Int.init).map { max(1, $0) }
        let col = q["col"].flatMap(Int.init).map { max(1, $0) } ?? 1
        // The file's tab, now or (a big file read in the background) when it is ready.
        let arrived: (EditorWindowController) -> Void = { [weak self] tab in
            if let line { tab.goToLine(line, column: col) }
            // `cedric -w`: the script waits until this marker file goes.
            if let marker = q["wait"] { self?.addWaiter(marker, for: tab) }
        }
        // No tab after all (unreadable, gone before it was read): the
        // script stops waiting rather than hang.
        let failed = {
            if let marker = q["wait"], let h = CLIHandoff.inspect(marker, kind: .wait) { CLIHandoff.remove(h) }
        }
        let pendingStd = url.standardizedFileURL
        // Already being read in the background (or open): that job's tab,
        // or its failure, even if the file is gone meanwhile. Gone, it used
        // to take the new-file branch below: an empty tab that saved over
        // a file put back there, while the read's text was thrown away.
        if backgroundOpens[pendingStd] != nil || FileManager.default.fileExists(atPath: path) {
            open(url, background: true, then: arrived, failed: failed)
        } else {
            // A new file: an empty tab that saves there.
            let doc = EditorDocument(fileURL: url, untitledName: url.lastPathComponent)
            doc.languageChoice = .forFile(named: url.lastPathComponent, content: "")
            let tab = makeTab(doc, text: "")
            doc.markDirtyFromSession()
            tab.updateTitle()
            arrived(tab)
        }
        let std = url.standardizedFileURL
        guard !tabs.contains(where: { $0.doc.fileURL?.standardizedFileURL == std }), backgroundOpens[std] == nil else { return }
        // A PDF: `cedric file.pdf:3` opens it at page 3; -w waits for its tab.
        if let pdf = pdfTab(for: url) {
            if let line { pdf.goToPage(OneBased.index(line, count: Int.max)) }
            if let marker = q["wait"] { addWaiter(marker, forID: pdf.id) }
        } else if let viewer = viewerTab(for: url), let marker = q["wait"] {
            // An image or Office tab: -w waits for it too.
            addWaiter(marker, forID: viewer.id)
        }
    }

    // MARK: Tabs

    private func newDocument() -> EditorDocument {
        // The lowest free number among the untitled tabs open now (not a
        // counter that only grows: that gave "Untitled 3" with none open).
        let open = tabs.filter { $0.doc.fileURL == nil }.map(\.doc.untitledName)
        let name = UntitledNames.next(open: open, base: String(localized: "Untitled"))
        return EditorDocument(untitledName: name)
    }

    @discardableResult
    func makeTab(_ doc: EditorDocument, text: String, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true,
                 tabIndex: Int? = nil, prepared: EditorWindowController.PreparedText? = nil) -> EditorWindowController {
        let tab = EditorWindowController(doc: doc, text: text, prepared: prepared)
        if let path = doc.fileURL?.path { tab.editing.wordGoal = FileWordGoals.goal(for: path, in: fileWordGoals) }
        tab.onChange = { [weak self] _ in self?.scheduleSessionSave() }
        tab.onClose = { [weak self] t in
            self?.releaseWaiters(for: t.doc.id)
            guard let self, !self.terminating else { return }
            let last = self.isClosingLastDocument(t.window)
            self.tabs.removeAll { $0 === t }
            // Hot close: remembered for Reopen Closed Tab, unsaved text and all.
            self.rememberClosed(t)
            // The last document window: quit. Only a fallback, for a close
            // that skipped windowShouldClose (shouldCloseDocumentWindow
            // already terminated with the tabs still open, reopen on or
            // off); this tab was hot-closed above and stays closed.
            if last { self.quitAfterLastClose() }
        }
        tabs.append(tab)
        // Checks: every tab as it is registered, before it is shown.
        if DevEnvironment.checksEnabled { Self.tabMadeForChecks?(tab) }
        guard let window = tab.window else { return tab }
        let host = newWindow ? nil : group ?? Self.documentKeyWindow ?? tabs.dropLast().last?.window
        if let tabIndex, let host = group, host !== window, let tg = host.tabGroup {
            // A restored tab built after launch: its saved place in the tab bar.
            tg.insertWindow(window, at: min(tabIndex, tg.windows.count))
            adoptFloat(of: host, for: window)
        } else if let host, host !== window, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
            adoptFloat(of: host, for: window)
        } else {
            window.center()
        }
        PerfTrace.mark("tab_built")
        if show {
            window.makeKeyAndOrderFront(nil)
            // A check (and a launch that never becomes key) still has this
            // tab current once it is ordered front. The bar was refreshed
            // earlier, while it was not, so its buttons stayed disabled.
            tab.contextBar?.refreshStates()
        }
        PerfTrace.mark("order_front")
        scheduleSessionSave()
        return tab
    }

    @objc func newTab(_ sender: Any?) {
        makeTab(newDocument(), text: "")
    }

    @objc func newWindow(_ sender: Any?) {
        makeTab(newDocument(), text: "", newWindow: true)
    }

    /// The "+" in the tab bar.
    @objc func newWindowForTab(_ sender: Any?) { newTab(sender) }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let dir = currentTab?.doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { open($0, background: true) }
    }

    /// Set while the command palette validates the whole menu in one go
    /// (nothing changes windows in between): the current tab and viewer
    /// tab are worked out once, not once per menu item. Without a key
    /// window that is a window-server round trip (orderedWindows) each.
    var validationPass: (tab: EditorWindowController?, viewer: (any ViewerTab)?)?

    func withValidationPass<T>(_ body: () -> T) -> T {
        let viewer = currentViewerTab
        let tab = currentTab
        validationPass = (tab, viewer)
        defer { validationPass = nil }
        return body()
    }

    var currentTab: EditorWindowController? {
        if let pass = validationPass { return pass.tab }
        // A detached preview's window: its tab (View › Attach Preview).
        if let key = NSApp.keyWindow, let t = tabs.first(where: { $0.previewWindow?.window === key }) { return t }
        // A viewer tab (PDF, image, Office) in front: no text tab is current (the editor's commands are off).
        if currentViewerTab != nil { return nil }
        if let t = tabs.first(where: { $0.window === NSApp.keyWindow }) { return t }
        if let t = tabs.first(where: { $0.window === NSApp.mainWindow }) { return t }
        // Not active (launched from a script, screen locked): the
        // frontmost tab. The owl check (CEDRIC_OWL_ASSUME_VISIBLE) may
        // run with no window ordered in; it falls back to the newest tab.
        let assumeVisible = OwlController.assumeVisible
        guard (NSApp.keyWindow == nil && NSApp.mainWindow == nil) || assumeVisible else { return nil }
        for w in NSApp.orderedWindows {
            if let t = tabs.first(where: { $0.window === w }) { return t }
        }
        return assumeVisible ? tabs.last : nil
    }

    /// Opens a file in a new tab, or focuses the tab that has it. An empty,
    /// untouched untitled tab is replaced, as in Notepad++.
    /// The last file refused as special (for checks).
    static var lastSpecialRefusal: String?

    func refuseSpecialFile(_ url: URL, _ kind: String) {
        let text = String(localized: "“\(url.lastPathComponent)” is \(kind), not a regular file, so Owlink won’t open it.")
        Self.lastSpecialRefusal = text
        if DevEnvironment.values["CEDRIC_CHECK"] != nil { print("check: note: \(text)"); return }
        let a = NSAlert()
        a.messageText = text
        if let w = NSApp.keyWindow, w.attachedSheet == nil { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// Opens a file. `background`: a text file of `backgroundOpenBytes`
    /// or more is read, decoded and indexed off the main thread, and its
    /// tab appears only when the text is ready (`then` runs with it), so
    /// there is never a half-loaded tab to edit, save or close; this
    /// returns nil for it. Otherwise the tab is made at once and returned
    /// (and `then` runs with it too). `failed` runs instead if the file
    /// can't be opened as text (now, or when read in the background).
    @discardableResult
    func open(_ url: URL, asText: Bool = false, background: Bool = false,
              then: ((EditorWindowController) -> Void)? = nil, failed: (() -> Void)? = nil) -> EditorWindowController? {
        let std = url.standardizedFileURL
        // A folder (dropped on the Dock icon, `owlink dir`): the folder sidebar.
        if Self.isFolder(std) { openFolder(std); return nil }
        // A pipe, device or socket: refused before a byte is read (a FIFO
        // would block forever, /dev/zero never ends).
        if let kind = SpecialFile.kind(atPath: std.path) {
            refuseSpecialFile(std, kind)
            return nil
        }
        restorePendingTab(for: std)
        if let existing = viewerTab(for: std) {
            existing.window?.makeKeyAndOrderFront(nil)
            return nil
        }
        if let existing = tabs.first(where: { $0.doc.fileURL?.standardizedFileURL == std }) {
            existing.window?.makeKeyAndOrderFront(nil)
            then?(existing)
            return existing
        }
        // Already being read in the background: one tab when it is ready.
        if let pending = backgroundOpens[std] {
            if let then { pending.thens.append(then) }
            if let failed { pending.failures.append(failed) }
            return nil
        }
        // A PDF (by its first bytes, or its name) opens in a viewer tab.
        if !asText {
            switch DocumentKind.detect(url: std) {
            case .pdf: openPDF(std); return nil
            // An image (by its signature, or its name) in an image tab; SVG stays text.
            case .image: openImage(std); return nil
            // Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTFD: Quick Look.
            case .office: openOffice(std); return nil
            // A binary (DER) certificate or PKCS#7 bundle: a read-only certificate tab.
            case .certificate: openCertificate(std); return nil
            case .text: break
            }
        }
        if background, let size = (try? std.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size >= Self.backgroundOpenBytes {
            openInBackground(std, then: then, failed: failed)
            return nil
        }
        do {
            // The text goes into the tab's storage (a copy) and is let go.
            let (d, mod) = try EditorDocument.read(std, shareBytes: true)
            PerfTrace.mark("read_decode")
            let language = LanguageChoice.forFile(named: std.lastPathComponent, content: d.text)
            PerfTrace.mark("detect_language")
            let certificate = Certificates.isCertificateText(d.text, fileName: std.lastPathComponent)
            let tab = showRead(std, d, mod, language: language, certificate: certificate, prepared: nil)
            then?(tab)
            return tab
        } catch {
            failed?()
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// A file read (on the main thread or off it): its tab.
    private func showRead(_ std: URL, _ d: DecodedText, _ mod: DiskStamp?, language: LanguageChoice, certificate: Bool,
                          prepared: EditorWindowController.PreparedText?) -> EditorWindowController {
        let doc = EditorDocument(fileURL: std, untitledName: std.lastPathComponent)
        doc.apply(d)
        doc.noteDisk(mod)
        doc.languageChoice = language
        let blank = tabs.count == 1 && tabs[0].doc.fileURL == nil && !tabs[0].doc.isDirty && tabs[0].text.isEmpty ? tabs[0] : nil
        // A binary file: nothing shown until Open Anyway (BinaryFile.swift).
        let tab = makeTab(doc, text: d.looksBinary ? "" : d.text, prepared: d.looksBinary ? nil : prepared)
        if d.looksBinary { tab.holdBinary(d.text) }
        blank?.window?.close()
        OwlHub.shared.activity(in: tab)
        tab.readQuarantineForOwl()
        noteRecent(std)
        // A certificate file (or PEM text): the Certificate panel beside it, a turn later.
        if certificate, !CertificatePanel.closedByUser {
            DispatchQueue.main.async { [weak tab] in
                guard let tab, tab.previewPane == nil, !tab.extrasPaused, tab.showsCertificatePanel else { return }
                tab.togglePreview()
            }
        }
        return tab
    }

    // MARK: Background open

    /// Text files this big (bytes) open in the background (`open`'s
    /// `background`): a 1 GB log took 2.8 s to decode on the main thread.
    static let backgroundOpenBytes = 16 * 1024 * 1024

    /// A file being read off the main thread (or waiting its turn), and
    /// what waits for its tab: `thens` with the tab, `failures` if none
    /// comes (unreadable, gone, quitting), e.g. a `cedric -w` marker.
    @MainActor final class BackgroundOpen {
        var thens: [(EditorWindowController) -> Void] = []
        var failures: [() -> Void] = []
    }

    /// Files being read in the background or waiting to be, by standardized URL.
    private(set) var backgroundOpens: [URL: BackgroundOpen] = [:]
    /// The files waiting their turn, first first. One is read at a time
    /// and the next starts only once its tab is made: a multi-file open
    /// of big logs never holds more than one decoded text waiting for
    /// the main thread (each is the size of its file).
    private var backgroundQueue: [URL] = []
    /// The one being read (or its text waiting for the main thread).
    private(set) var backgroundReading: URL?
    /// The most background reads ever under way or done-not-shown at once (checks).
    private(set) var mostBackgroundReadsForChecks = 0
    /// The line index the last background open made (check builds only:
    /// BigOpenCheck sees the tab use it rather than scan the text again).
    var lastBackgroundIndexForChecks: LineIndex?
    /// Checks only (DevEnvironment.checksEnabled): the next background
    /// read waits for this before it reads (BigOpenCheck holds it there to
    /// look at the app while the file can't be whole), and every tab made
    /// is passed to `tabMadeForChecks` as it is registered.
    static var backgroundReadGateForChecks: DispatchSemaphore?
    static var tabMadeForChecks: ((EditorWindowController) -> Void)?
    /// Run (once) when the last background open has finished (launch metrics).
    var whenBackgroundOpensDone: [() -> Void] = []

    /// Everything a background open makes before the tab.
    struct BackgroundRead: Sendable {
        let decoded: DecodedText
        let stamp: DiskStamp?
        let language: LanguageChoice
        let certificate: Bool
        let prepared: EditorWindowController.PreparedText?
    }

    private func openInBackground(_ std: URL, then: ((EditorWindowController) -> Void)?, failed: (() -> Void)?) {
        let job = BackgroundOpen()
        if let then { job.thens.append(then) }
        if let failed { job.failures.append(failed) }
        backgroundOpens[std] = job
        backgroundQueue.append(std)
        startNextBackgroundRead()
    }

    private func startNextBackgroundRead() {
        guard backgroundReading == nil, !terminating, !backgroundQueue.isEmpty else { return }
        let std = backgroundQueue.removeFirst()
        guard let job = backgroundOpens[std] else { startNextBackgroundRead(); return }
        backgroundReading = std
        // Counted as the reads are: under way, or done and not yet shown.
        backgroundReadsInFlight += 1
        mostBackgroundReadsForChecks = max(mostBackgroundReadsForChecks, backgroundReadsInFlight)
        let gate = DevEnvironment.checksEnabled ? Self.backgroundReadGateForChecks : nil
        Self.backgroundReadGateForChecks = nil
        DispatchQueue.global(qos: .userInitiated).async {
            gate?.wait()
            let result = Result { try Self.readInBackground(std) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishBackgroundOpen(std, job, result) }
            }
        }
    }

    private var backgroundReadsInFlight = 0

    /// Quitting: whoever waits on a file still to be read stops waiting
    /// (a `cedric -w` marker goes, as for a tab).
    func failPendingBackgroundOpens() {
        for job in backgroundOpens.values {
            let failures = job.failures
            job.failures = []
            failures.forEach { $0() }
        }
    }

    /// Off the main thread: read and decode, then (side by side) the line
    /// index, the saved-text fingerprint, the language and the certificate
    /// sniff. The text is immutable until the tab copies it.
    nonisolated static func readInBackground(_ std: URL) throws -> BackgroundRead {
        let (d, mod) = try EditorDocument.read(std, shareBytes: true)
        let name = std.lastPathComponent
        let text = d.text
        let ns = text as NSString
        nonisolated(unsafe) var index: LineIndex?
        nonisolated(unsafe) var print: TextFingerprint?
        nonisolated(unsafe) var language = LanguageChoice()
        nonisolated(unsafe) var certificate = false
        DispatchQueue.concurrentPerform(iterations: 3) { k in
            switch k {
            case 0: if !d.looksBinary { index = LineIndex(ns, expectedLineCount: d.newlineCount.map { $0 + 1 }) }
            case 1: if !d.looksBinary, ns.length > EditedState.snapshotLimit { print = TextFingerprint(ns) }
            default:
                language = LanguageChoice.forFile(named: name, content: text)
                certificate = Certificates.isCertificateText(text, fileName: name)
            }
        }
        return BackgroundRead(decoded: d, stamp: mod, language: language, certificate: certificate,
                              prepared: index.map { EditorWindowController.PreparedText(lineIndex: $0, fingerprint: print) })
    }

    private func finishBackgroundOpen(_ std: URL, _ job: BackgroundOpen, _ result: Result<BackgroundRead, Error>) {
        backgroundOpens[std] = nil
        defer {
            // Its tab is made (or it failed): the next file's turn, after
            // any alert, so no text waits on the main thread meanwhile.
            backgroundReadsInFlight -= 1
            backgroundReading = nil
            startNextBackgroundRead()
            if backgroundOpens.isEmpty {
                let done = whenBackgroundOpensDone
                whenBackgroundOpensDone = []
                done.forEach { $0() }
            }
        }
        // Quitting: nothing more to show (the session never had this tab).
        guard !terminating else { job.failures.forEach { $0() }; return }
        switch result {
        case .failure(let error):
            job.failures.forEach { $0() }
            NSAlert(error: error).runModal()
            // Opened at launch with nothing else: the usual new tab.
            if tabs.isEmpty && viewerTabs.isEmpty && backgroundOpens.isEmpty { newTab(nil) }
        case .success(let r):
            // Opened another way meanwhile (a check, a session tab): that tab.
            if let existing = tabs.first(where: { $0.doc.fileURL?.standardizedFileURL == std }) {
                existing.window?.makeKeyAndOrderFront(nil)
                job.thens.forEach { $0(existing) }
                return
            }
            let tab = showRead(std, r.decoded, r.stamp, language: r.language, certificate: r.certificate, prepared: r.prepared)
            if DevEnvironment.checksEnabled { lastBackgroundIndexForChecks = r.prepared?.lineIndex }
            job.thens.forEach { $0(tab) }
        }
    }

    func tabBecameKey(_ tab: EditorWindowController) {
        // The Find in Files panel follows the selected tab.
        if let p = findInFiles, p.isShown { tab.dockSidePanel(p) }
        folderSidebarFollow(tab)
    }

    /// Find in Files (one panel, docked in whichever tab is selected) and
    /// open Compare windows (EditorTools.swift).
    var findInFiles: FindInFilesPanel?
    var compareWindows: [CompareWindowController] = []

    // MARK: Session

    /// Saves soon after a change (coalesced): a crash loses at most ~1.5 s of typing.
    func scheduleSessionSave() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession(sync: false) }
        }
    }

    /// The windows in on-screen order, each with its tabs in tab-bar order.
    func tabGroups() -> [[EditorWindowController]] {
        windowGroups().map { $0.compactMap { win in tabs.first { $0.window === win } } }.filter { !$0.isEmpty }
    }

    /// The same, as windows: text and PDF tabs both.
    func windowGroups() -> [[NSWindow]] {
        var seen = Set<ObjectIdentifier>()
        var groups: [[NSWindow]] = []
        let ours = tabs.compactMap(\.window) + viewerTabs.compactMap(\.window)
        let isOurs = { (w: NSWindow) in ours.contains { $0 === w } }
        for w in NSApp.orderedWindows + ours {
            guard !seen.contains(ObjectIdentifier(w)), isOurs(w) else { continue }
            let members = (w.tabbedWindows ?? [w]).filter(isOurs)
            for m in members { seen.insert(ObjectIdentifier(m)) }
            if !members.isEmpty { groups.append(members) }
        }
        return groups
    }

    /// Session writes, in order, off the main thread (a 636 KB unsaved
    /// buffer is a few ms of disk work); quit waits for them.
    let sessionQueue = DispatchQueue(label: "cedric.session-save", qos: .utility)

    /// Snapshots the tabs on the main thread, then writes the changed
    /// buffers, the session and the prune on `sessionQueue`, in that order.
    /// `sync`: wait for it (quit).
    func saveSession(sync: Bool = true) {
        sessionTimer?.invalidate()
        guard env["CEDRIC_NO_SESSION_SAVE"] != "1" else { return }
        // Tabs not built yet would be dropped from the session (and their buffers pruned).
        finishRestore()
        var windows: [SessionWindow] = []
        var keep = Set<UUID>()
        var buffers: [(UUID, String, LineBreaks?)] = []
        var written: [UUID: (EditorDocument, Int)] = [:]
        for group in windowGroups() {
            var sessionTabs: [SessionTab] = []
            var selected = 0
            for win in group {
                if let p = viewerTab(for: win) {
                    sessionTabs.append(p.sessionTab)
                    if win === NSApp.keyWindow || win.tabGroup?.selectedWindow === win { selected = sessionTabs.count - 1 }
                    continue
                }
                guard let t = tabs.first(where: { $0.window === win }) else { continue }
                let d = t.doc
                let isEmpty = (t.textView.textStorage?.length ?? 0) == 0
                let needsBuffer = d.isDirty || d.fileURL == nil && !isEmpty
                if needsBuffer {
                    keep.insert(d.id)
                    if d.sessionChangeCount != d.changeCount, d.sessionWritingCount != d.changeCount {
                        // One copy of the text (the storage keeps changing).
                        // A mixed file's breaks go into the buffer with it (restoreFormat).
                        buffers.append((d.id, t.text, d.lineBreaks))
                        written[d.id] = (d, d.changeCount)
                        // sessionChangeCount moves only once the write has
                        // worked (finished, below): hot close skips its own
                        // write when it matches, so a failed write must not
                        // look done.
                        d.sessionWritingCount = d.changeCount
                    }
                } else {
                    d.sessionChangeCount = -1
                }
                // An untouched empty untitled tab isn't worth restoring.
                if d.fileURL == nil && isEmpty { continue }
                let sel = t.primaryTextView.selectedRange()
                // A docked Markdown preview (not a detached one: that has its own frame).
                let dockedPreview = d.language == .markdown && t.previewVisible && !t.previewDetached
                sessionTabs.append(SessionTab(id: d.id, path: d.fileURL?.path, untitledName: d.fileURL == nil ? d.untitledName : nil,
                                              hasBuffer: needsBuffer, encoding: d.encoding, lineEnding: d.lineEnding,
                                              language: d.languageIsManual ? d.language : nil,
                                              selectionLocation: sel.location, selectionLength: sel.length,
                                              topLine: t.primaryTopLine, fileModified: d.fileModified,
                                              fileSize: d.diskStamp.size, fileID: d.diskStamp.identity,
                                              bookmarks: t.editing.bookmarks.isEmpty ? nil : t.editing.bookmarks.lines,
                                              indentation: d.indentation,
                                              previewDetached: t.previewDetached ? true : nil,
                                              previewFrame: t.previewWindow?.window?.frameDescriptor,
                                              previewShown: dockedPreview ? true : nil,
                                              previewWidth: dockedPreview ? t.dockedPreviewWidth : nil,
                                              folds: t.sessionFolds, split: t.sessionSplit, writing: t.sessionWriting,
                                              wordGoal: d.fileURL == nil ? t.editing.wordGoal : nil,
                                              explicitText: d.fileURL.map { DocumentKind.hasPDFExtension($0.path) } == true ? true : nil))
                d.noteFormat(in: &sessionTabs[sessionTabs.count - 1])
                if t.window === NSApp.keyWindow || t.window?.tabGroup?.selectedWindow === t.window { selected = sessionTabs.count - 1 }
            }
            if !sessionTabs.isEmpty {
                // Any tab still in the set: the window was floating, including
                // one saved while full screen has the level at something else.
                let floats = group.contains { floatingWindows.contains(ObjectIdentifier($0)) }
                windows.append(SessionWindow(tabs: sessionTabs, selectedTab: selected, frame: group.first?.frameDescriptor,
                                              floatOnTop: floats ? true : nil))
            }
        }
        for c in closedTabs where c.hasBuffer { keep.insert(c.id) }
        let session = Session(windows: windows, closedTabs: closedTabs.isEmpty ? nil : closedTabs, folder: folderSessionState,
                              wordGoals: fileWordGoals.isEmpty ? nil : fileWordGoals)
        let store = self.store
        let toWrite = buffers, keeping = keep
        let write: @Sendable () -> Set<UUID> = {
            var ok = Set<UUID>()
            for (id, text, breaks) in toWrite {
                do {
                    try store.writeBuffer(id, text: EditorDocument.bufferText(text, breaks: breaks))
                    ok.insert(id)
                } catch {
                    FileHandle.standardError.write(Data("session: buffer write failed: \(error)\n".utf8))
                }
            }
            do {
                try store.save(session)
                store.pruneBuffers(keeping: keeping)
            } catch {
                FileHandle.standardError.write(Data("session: save failed: \(error)\n".utf8))
            }
            return ok
        }
        // Each written tab's count, once its write is done: advanced if it
        // worked, else left as it was so the next save (or a close) tries again.
        let finished: @MainActor (Set<UUID>) -> Void = { ok in
            for (id, (d, count)) in written {
                if d.sessionWritingCount == count { d.sessionWritingCount = -1 }
                if ok.contains(id) { d.sessionChangeCount = count }
            }
        }
        if sync {
            finished(sessionQueue.sync(execute: write))
        } else {
            sessionQueue.async {
                let ok = write()
                DispatchQueue.main.async { MainActor.assumeIsolated { finished(ok) } }
            }
        }
    }

    /// A restored tab not built yet: each window's selected tab is built
    /// during launch; the others are built after the first frame, one per
    /// run-loop turn (`restoreNextPending`), so a long session neither
    /// delays the window nor blocks the first keystrokes for long. Adding a
    /// window to a tab group costs AppKit ~10 ms per tab (~45 ms for the
    /// first, which creates the tab bar), whatever the tab holds.
    private struct PendingTab {
        let tab: SessionTab
        let group: RestoreGroup
        /// Its place in the saved window's tab bar.
        let index: Int
    }

    /// One saved window's tabs built so far, by their saved index.
    private final class RestoreGroup {
        var built: [(index: Int, window: NSWindow)] = []
        /// The saved window's frame, for a window rebuilt after its built
        /// tabs all closed.
        var frame: String?
        /// Window › Float on Top, kept for a tab rebuilt into its own window.
        var floatOnTop = false
    }

    private var pendingRestore: [PendingTab] = []
    /// Seconds after the first frame before the other tabs are built (about
    /// a human reaction time, so a keystroke right after the window shows
    /// doesn't wait behind them). CEDRIC_RESTORE_DELAY overrides it (session-check).
    static let pendingRestoreDelay: TimeInterval =
        DevEnvironment.values["CEDRIC_RESTORE_DELAY"].flatMap(Double.init) ?? 0.25

    private func restoreSession() {
        guard let session = store.load() else { return }
        // Closed tabs past ClosedTabs.keepDays go, with their unsaved text.
        let kept = ClosedTabs.expire(session.closedTabs ?? [])
        closedTabs = kept.list
        fileWordGoals = session.wordGoals ?? []
        for gone in kept.dropped where gone.hasBuffer { store.removeBuffer(gone.id) }
        // Closed tabs and word goals still load when the user turned reopen off
        // (⇧⌘T and the stats popover need them). Then the folder and files
        // do not come back: they are parked on the closed list. Tabs with
        // unsaved text always reopen (SessionReopenPolicy.plan), so that
        // text never falls under the closed list's 30-day / 100-tab limits.
        let reopen = Settings.shared.reopenFilesFromLastSession
        let plan = SessionReopenPolicy.plan(session.windows, reopen: reopen)
        if !plan.park.isEmpty {
            var closed = closedTabs
            for tab in plan.park {
                let r = ClosedTabs.push(tab, onto: closed)
                closed = r.list
                for gone in r.dropped where gone.hasBuffer { store.removeBuffer(gone.id) }
            }
            closedTabs = closed
        }
        if reopen { restoreFolder(session.folder) }
        for w in plan.windows {
            let openTabs = SessionRestoreList.openTabs(w.tabs) { FileManager.default.fileExists(atPath: $0) }
            let selectedID = w.tabs.indices.contains(w.selectedTab) ? w.tabs[w.selectedTab].id : nil
            let selectedTab = selectedID.flatMap { id in openTabs.firstIndex { $0.id == id } }
            // The selected tab first (it is what shows); if its file has
            // gone, the next one that still restores.
            let order: [Int]
            if let selectedTab {
                order = [selectedTab] + openTabs.indices.filter { $0 != selectedTab }
            } else {
                order = Array(openTabs.indices)
            }
            let group = RestoreGroup()
            group.frame = w.frame
            group.floatOnTop = w.floatOnTop == true
            var host: NSWindow?
            var rest: [Int] = []
            for i in order {
                if host != nil { rest.append(i); continue }
                guard let tab = restoreTab(openTabs[i], into: nil), let window = tab.window else { continue }
                host = window
                group.built.append((i, window))
                if let f = w.frame { window.setFrame(from: f) }
            }
            guard let host else { continue }
            if group.floatOnTop { setWindowFloats(true, host) }
            pendingRestore += rest.sorted().map { PendingTab(tab: openTabs[$0], group: group, index: $0) }
            host.makeKeyAndOrderFront(nil)
        }
    }

    /// Builds one saved tab; nil if its file has gone and it had no buffer.
    /// `place` nil: in a new window (not ordered in). Else into that
    /// window's tab group at that position.
    @discardableResult
    private func restoreTab(_ st: SessionTab, into place: (host: NSWindow, index: Int)?) -> NSWindowController? {
        // A PDF tab (or, from before PDF tabs, a .pdf file opened as text with nothing unsaved).
        if st.pdf != nil || st.explicitText != true && !st.hasBuffer && st.path.map(DocumentKind.hasPDFExtension) == true {
            return restorePDFTab(st, into: place)
        }
        if st.image != nil || st.office != nil || st.certificate != nil { return restoreViewerTab(st, into: place) }
        let doc = EditorDocument(id: st.id, fileURL: st.path.map { URL(fileURLWithPath: $0) },
                                 untitledName: st.untitledName ?? st.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Untitled"))
        doc.indentation = st.indentation
        var text: String?
        var binary = false
        if st.hasBuffer { text = store.readBuffer(st.id) }
        // The text goes into the tab's storage and is let go (shareBytes: no second copy of a big file).
        let fromBuffer = text != nil
        if text == nil, let url = doc.fileURL, let (d, mod) = try? EditorDocument.read(url, encoding: st.encoding, shareBytes: true) {
            doc.apply(d)
            doc.noteDisk(mod)
            text = d.text
            binary = d.looksBinary
        } else if text != nil {
            doc.encoding = st.encoding
            doc.lineEnding = st.lineEnding
            // A pre-0.5.4 date-only stamp through a link: unverified (⌘S asks).
            doc.noteDisk(doc.fileURL.map { DiskStamp.restored(st.diskStamp, for: $0) } ?? st.diskStamp)
        }
        if fromBuffer { text = doc.restoreFormat(st, buffer: text) } else { _ = doc.restoreFormat(st, buffer: nil) }
        guard let body = text else { return nil } // the file is gone and there was no buffer
        if let l = st.language {
            doc.languageChoice.choose(l)
        } else if let url = doc.fileURL {
            doc.languageChoice = .forFile(named: url.lastPathComponent, content: body)
        } else {
            doc.languageChoice = .untitled(content: body)
        }
        let tab = makeTab(doc, text: binary ? "" : body, in: place?.host, newWindow: place == nil, show: false, tabIndex: place?.index)
        if binary { tab.holdBinary(body) }
        if st.hasBuffer { doc.markDirtyFromSession(); doc.sessionChangeCount = doc.changeCount }
        tab.updateTitle()
        let len = (body as NSString).length
        tab.textView.setSelectedRange(NSRange(location: min(st.selectionLocation, len), length: min(st.selectionLength, max(0, len - st.selectionLocation))))
        if let goal = st.wordGoal { tab.editing.wordGoal = goal }
        if let w = st.writing, !w.isOff { tab.setWriting(w) }
        if let marks = st.bookmarks {
            tab.editing.bookmarks = Bookmarks(marks)
            tab.editing.bookmarks.clamp(lineCount: tab.lineIndex.lineCount)
        }
        let top = st.topLine
        DispatchQueue.main.async { tab.scrollToLine(top, in: tab.primaryPane) }
        // Folds come back after the first frame (Folding.swift).
        if let folds = st.folds { tab.restoreFolds(folds) }
        // So does a split (SplitEditor.swift).
        if let sp = st.split { tab.restoreSplit(sp) }
        // A detached preview comes back in its window, after the first
        // frame: no preview work on the launch path. A docked Markdown
        // preview comes back the same way, at the width it was left
        // (nil width: the usual half). Nil previewShown is an older
        // session, which stays closed.
        if st.previewDetached == true {
            let frame = st.previewFrame
            AfterFirstFrame.run { [weak tab] in tab?.detachPreview(frame: frame, activate: false) }
        } else if st.previewShown == true, tab.doc.language == .markdown {
            let width = st.previewWidth
            AfterFirstFrame.run { [weak tab] in tab?.restoreDockedPreview(width: width) }
        }
        return tab
    }

    /// Starts building the pending tabs once the first frame is on screen.
    private func schedulePendingRestore() {
        guard !pendingRestore.isEmpty else { return }
        AfterFirstFrame.run {
            Timer.scheduledTimer(withTimeInterval: Self.pendingRestoreDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreNextPending() }
            }
        }
    }

    /// One pending tab per run-loop turn (key events get through in between).
    private func restoreNextPending() {
        guard !pendingRestore.isEmpty else { return }
        restorePending(pendingRestore.removeFirst())
        if pendingRestore.isEmpty { scheduleSessionSave(); return }
        perform(#selector(restoreNextPendingLater), with: nil, afterDelay: 0)
    }

    @objc private func restoreNextPendingLater() { restoreNextPending() }

    private func restorePending(_ p: PendingTab) {
        // The saved window's tabs still open (the user may have closed some).
        let live = p.group.built.filter { b in tabs.contains { $0.window === b.window } || viewerTab(for: b.window) != nil }
        guard let anchor = live.first?.window, let tg = anchor.tabGroup else {
            // All of them closed before this one was built: it gets its own window.
            if let tab = restoreTab(p.tab, into: nil), let w = tab.window {
                // Where the saved window was, not a new default place.
                if let f = p.group.frame { w.setFrame(from: f) }
                if p.group.floatOnTop { setWindowFloats(true, w) }
                p.group.built.append((p.index, w))
                w.orderFront(nil)
            }
            return
        }
        // After the nearest tab saved before it, else first.
        let before = live.filter { $0.index < p.index }.max { $0.index < $1.index }
        let position = before.flatMap { b in tg.windows.firstIndex { $0 === b.window } }.map { $0 + 1 } ?? 0
        // Keep the user where they are: building a tab must not move the selection.
        let selected = tg.selectedWindow
        if let tab = restoreTab(p.tab, into: (anchor, position)), let w = tab.window { p.group.built.append((p.index, w)) }
        if let selected, tg.selectedWindow !== selected { tg.selectedWindow = selected }
    }

    /// Builds every pending tab now (save, quit, open, the dev hooks).
    func finishRestore() {
        while !pendingRestore.isEmpty { restorePending(pendingRestore.removeFirst()) }
    }

    /// A pending tab for this file, built now so it isn't opened twice.
    private func restorePendingTab(for url: URL) {
        let std = url.standardizedFileURL
        guard let i = pendingRestore.firstIndex(where: { $0.tab.path.map { URL(fileURLWithPath: $0).standardizedFileURL } == std }) else { return }
        restorePending(pendingRestore.remove(at: i))
    }

    // MARK: Menu actions routed to the current tab

    @objc func saveDocument(_ sender: Any?) { currentTab?.save() }
    @objc func saveDocumentAs(_ sender: Any?) { currentTab?.saveAs() }
    @objc func showFind(_ sender: Any?) { currentTab?.showFindBar(replace: false) }
    @objc func showReplace(_ sender: Any?) { currentTab?.showFindBar(replace: true) }
    @objc func findNextMatch(_ sender: Any?) { currentTab?.find(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { currentTab?.find(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let t = currentTab else { return }
        let sel = t.textView.selectedRange()
        guard sel.length > 0 else { return }
        t.findBar.findField.stringValue = (t.text as NSString).substring(with: sel)
    }
    @objc func goToLine(_ sender: Any?) { currentTab?.goToLinePrompt(sender) }
    @objc func togglePreview(_ sender: Any?) { currentTab?.togglePreview() }
    @objc func toggleOutlineMenu(_ sender: Any?) { currentTab?.toggleOutline() }
    @objc func toggleBacklinksMenu(_ sender: Any?) { currentTab?.toggleBacklinks() }
    @objc func toggleTagsMenu(_ sender: Any?) { currentTab?.toggleTags() }
    @objc func goToHeadingMenu(_ sender: Any?) { currentTab?.goToHeading() }
    @objc func exportHTMLMenu(_ sender: Any?) { currentTab?.exportHTML() }
    @objc func exportPDFMenu(_ sender: Any?) { currentTab?.exportPDF() }
    @objc func copyAsHTMLMenu(_ sender: Any?) { currentTab?.copyAsHTML() }
    @objc func copyAsRichTextMenu(_ sender: Any?) { currentTab?.copyAsRichText() }
    @objc func toggleDetachPreview(_ sender: Any?) { currentTab?.toggleDetachPreviewAction(sender) }
    @objc func togglePreviewJavaScript(_ sender: Any?) { currentTab.map { $0.previewAllowsJavaScript.toggle() } }
    @objc func togglePreviewNetwork(_ sender: Any?) { currentTab.map { $0.previewAllowsNetwork.toggle() } }
    @objc func refreshPreviewMenu(_ sender: Any?) { currentTab?.previewBarAction(.refresh) }
    @objc func togglePreviewSyncMenu(_ sender: Any?) { currentTab?.previewBarAction(.syncScroll) }
    @objc func previewZoomInMenu(_ sender: Any?) { currentTab?.previewBarAction(.zoomIn) }
    @objc func previewZoomOutMenu(_ sender: Any?) { currentTab?.previewBarAction(.zoomOut) }
    @objc func previewResetSortMenu(_ sender: Any?) { currentTab?.previewBarAction(.sortReset) }
    @objc func previewBackMenu(_ sender: Any?) { currentTab?.previewBarAction(.back) }
    @objc func previewForwardMenu(_ sender: Any?) { currentTab?.previewBarAction(.forward) }
    @objc func previewHomeMenu(_ sender: Any?) { currentTab?.previewBarAction(.home) }
    @objc func toggleWrap(_ sender: Any?) { Settings.shared.wrapLines.toggle() }
    @objc func toggleInvisibles(_ sender: Any?) { Settings.shared.showInvisibles.toggle() }
    @objc func toggleLineNumbers(_ sender: Any?) { Settings.shared.showLineNumbers.toggle() }
    @objc func toggleSpellingWhileTyping(_ sender: Any?) { Settings.shared.checkSpellingWhileTyping.toggle() }
    @objc func checkDocumentNow(_ sender: Any?) { currentTab?.spelling.selectNext() }
    @objc func fixTyposMenu(_ sender: Any?) { currentTab?.startSpellStep() }
    @objc func fixGrammarMenu(_ sender: Any?) { currentTab?.startGrammarStep() }
    @objc func toggleGrammar(_ sender: Any?) { Settings.shared.checkGrammar.toggle() }
    @objc func toggleOwl(_ sender: Any?) { Settings.shared.showOwl.toggle() }
    @objc func askCedricMenu(_ sender: Any?) { currentTab?.openAskCedric() }
    @objc func explainSelectionMenu(_ sender: Any?) { currentTab?.inlineAssist(.explain) }
    @objc func rewriteSelectionMenu(_ sender: Any?) { currentTab?.inlineAssist(.rewrite) }
    @objc func checkGrammarWithAIMenu(_ sender: Any?) { currentTab?.checkGrammarWithAI() }
    @objc func scriptSafetyMenu(_ sender: Any?) { currentTab?.checkScriptSafety() }
    @objc func pickOwlHintSource(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let src = OwlHintSource(rawValue: raw) { Settings.shared.owlHintSource = src }
    }
    @objc func zoomIn(_ sender: Any?) { Settings.shared.fontSize += 1 }
    @objc func zoomOut(_ sender: Any?) { Settings.shared.fontSize -= 1 }
    @objc func zoomReset(_ sender: Any?) { Settings.shared.fontSize = Settings.defaultFontSize }
    /// The status bar's 75–200 % (the percent in the item's tag).
    @objc func zoomToPercent(_ sender: Any?) {
        guard let p = (sender as? NSMenuItem)?.tag, p > 0 else { return }
        Settings.shared.fontSize = Settings.defaultFontSize * CGFloat(p) / 100
    }
    @objc func pickLanguageMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = Language(rawValue: raw) { currentTab?.setLanguage(l) }
    }
    @objc func pickLineEndingMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let le = LineEnding(rawValue: raw) { currentTab?.convertLineEndings(to: le) }
    }
    /// Format › Reopen with Encoding… (⌥⇧⌘R): the picker, under the status bar's encoding.
    @objc func reopenWithEncodingMenu(_ sender: Any?) {
        currentTab?.showReopenEncodingPicker()
    }

    @objc func pickEncodingMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let e = TextEncoding(rawValue: raw) { currentTab?.convertEncoding(to: e) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = currentTab
        let s = Settings.shared
        switch item.action {
        case #selector(toggleWrap(_:)): item.state = s.wrapLines ? .on : .off
        // View toggles say Show X / Hide X, no checkmark (UX review #7); attribute toggles keep theirs.
        case #selector(toggleInvisibles(_:)):
            setShowHide(item, shown: s.showInvisibles, show: String(localized: "Show Invisibles"), hide: String(localized: "Hide Invisibles"))
        case #selector(toggleLineNumbers(_:)):
            setShowHide(item, shown: s.showLineNumbers, show: String(localized: "Show Line Numbers"), hide: String(localized: "Hide Line Numbers"))
        case #selector(toggleSpellingWhileTyping(_:)): item.state = s.checkSpellingWhileTyping ? .on : .off
        case #selector(checkDocumentNow(_:)): return tab != nil
        case #selector(showStatisticsMenu(_:)): return tab?.statusBar.counts.onClick != nil && tab?.statusBar.counts.isHidden == false
        // Explain & tidy (OwlTools.swift): on a selection that is one.
        case #selector(explainRegexMenu(_:)): return tab?.canExplainRegex == true
        case #selector(decodeSelectionMenu(_:)): return tab?.canDecodeSelection == true
        case #selector(findTodosMenu(_:)): return tab != nil && tab?.isLargeDocument == false
        // Not in data files (JSON, YAML, INI, XML, CSV/TSV): nothing there is checked.
        case #selector(fixTyposMenu(_:)): return tab?.spellingChecksThisDocument == true
        // Plain Text and Markdown only, with grammar on, not in large mode.
        case #selector(fixGrammarMenu(_:)): return tab?.grammar.mayCheck == true
        case #selector(toggleGrammar(_:)): item.state = s.checkGrammar ? .on : .off
        case #selector(toggleOwl(_:)): setShowHide(item, shown: s.showOwl, show: String(localized: "Show Cedric"), hide: String(localized: "Hide Cedric"))
        // On for every tab; shown for the file types that have a set.
        case #selector(toggleContextBarMenu(_:)):
            setShowHide(item, shown: s.showContextBar, show: String(localized: "Show Context Bar"), hide: String(localized: "Hide Context Bar"))
        case #selector(askCedricMenu(_:)): return s.owlChat && tab?.canAskCedric == true
        case #selector(explainSelectionMenu(_:)): return tab?.canInlineAssist(.explain) == true
        case #selector(rewriteSelectionMenu(_:)): return tab?.canInlineAssist(.rewrite) == true
        case #selector(checkGrammarWithAIMenu(_:)): return s.owlChat && tab?.canCheckGrammarWithAI == true
        case #selector(scriptSafetyMenu(_:)): return tab?.canCheckScriptSafety == true
        case #selector(pickOwlHintSource(_:)):
            // "Rules + AI" stays off until an AI provider registers.
            let ai = OwlHub.shared.registry.hasAIProvider
            let effective = ai ? s.owlHintSource : .rules
            item.state = (item.representedObject as? String) == effective.rawValue ? .on : .off
            return s.showOwl && (item.representedObject as? String == OwlHintSource.rules.rawValue || ai)
        case #selector(toggleOutlineMenu(_:)):
            setShowHide(item, shown: tab?.outlineVisible == true, show: String(localized: "Show Outline"), hide: String(localized: "Hide Outline"))
            return tab?.doc.language.hasOutline == true
        case #selector(toggleBacklinksMenu(_:)):
            setShowHide(item, shown: tab?.backlinksVisible == true, show: String(localized: "Show Backlinks"), hide: String(localized: "Hide Backlinks"))
            return tab?.backlinksApply == true
        case #selector(toggleTagsMenu(_:)):
            setShowHide(item, shown: tab?.tagsVisible == true, show: String(localized: "Show Tags"), hide: String(localized: "Hide Tags"))
            return tab != nil
        case #selector(goToHeadingMenu(_:)):
            return tab?.doc.language.hasOutline == true
        case #selector(exportHTMLMenu(_:)), #selector(exportPDFMenu(_:)),
             #selector(copyAsHTMLMenu(_:)), #selector(copyAsRichTextMenu(_:)):
            return tab?.doc.language == .markdown
        case #selector(togglePreview(_:)):
            setShowHide(item, shown: tab?.previewVisible == true, show: String(localized: "Show Preview"), hide: String(localized: "Hide Preview"))
            return tab?.previewApplies == true
        case #selector(toggleDetachPreview(_:)):
            item.title = tab?.previewDetached == true ? String(localized: "Attach Preview") : String(localized: "Detach Preview")
            return tab?.previewApplies == true
        case #selector(togglePreviewJavaScript(_:)):
            item.state = tab?.previewAllowsJavaScript == true ? .on : .off
            return tab?.previewVisible == true && tab?.preview != nil
        case #selector(togglePreviewNetwork(_:)):
            item.state = tab?.previewAllowsNetwork == true ? .on : .off
            return tab?.previewVisible == true && tab?.preview != nil
        // The preview bar's buttons: shown in the bar and enabled there.
        case #selector(refreshPreviewMenu(_:)): return tab?.previewBarEnables(.refresh) == true
        case #selector(togglePreviewSyncMenu(_:)):
            item.state = tab?.previewVisible == true && tab?.previewSyncsScroll == true ? .on : .off
            return tab?.previewBarEnables(.syncScroll) == true
        case #selector(previewZoomInMenu(_:)): return tab?.previewBarEnables(.zoomIn) == true
        case #selector(previewZoomOutMenu(_:)): return tab?.previewBarEnables(.zoomOut) == true
        case #selector(previewResetSortMenu(_:)): return tab?.previewBarEnables(.sortReset) == true
        case #selector(previewBackMenu(_:)): return tab?.previewBarEnables(.back) == true
        case #selector(previewForwardMenu(_:)): return tab?.previewBarEnables(.forward) == true
        case #selector(previewHomeMenu(_:)): return tab?.previewBarEnables(.home) == true
        case #selector(pickLanguageMenu(_:)): item.state = (item.representedObject as? String) == tab?.doc.language.rawValue ? .on : .off
        case #selector(pickLineEndingMenu(_:)): item.state = (item.representedObject as? String) == tab?.doc.lineEnding.rawValue ? .on : .off
        case #selector(reopenWithEncodingMenu(_:)): return tab?.doc.fileURL != nil
        case #selector(pickEncodingMenu(_:)): item.state = (item.representedObject as? String) == tab?.doc.encoding.rawValue ? .on : .off
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(toggleFloatOnTop(_:)):
            // An attribute toggle: a checkmark, not Show/Hide. The palette
            // and a sheet can be key; the document window behind them is the one.
            let target = floatTargetWindow()
            item.state = target.map { windowFloats($0) } == true ? .on : .off
            return target != nil
        case #selector(goToLine(_:)):
            item.title = String(localized: "Go to Line…") // a PDF tab shows "Go to Page…"
            return tab != nil
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return tab != nil && tab?.binaryBlocksSave != true
        case #selector(showFind(_:)), #selector(showReplace(_:)),
             #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(useSelectionForFind(_:)),
             #selector(printDocument(_:)):
            return tab != nil
        default: return validateWritingItem(item) ?? validateSplitItem(item) ?? validateReplaceInFilesItem(item) ?? validateFolderItem(item) ?? validateMultiCaretItem(item) ?? validateFoldingItem(item) ?? validateGitItem(item) ?? validateMarkdownItem(item) ?? validateEditingItem(item) ?? validateIndentationItem(item) ?? validateFileItem(item) ?? validateFilterItem(item) ?? validateToolItem(item)
        }
        return true
    }
}

func trace(_ s: String) {
    if DevEnvironment.values["CEDRIC_TRACE"] == "1" { FileHandle.standardError.write(Data("trace: \(s)\n".utf8)) }
}
