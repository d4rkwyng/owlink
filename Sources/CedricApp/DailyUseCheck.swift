import AppKit
import CedricCore

/// CEDRIC_CHECK=dailyuse (Scripts/daily-use.sh, docs/daily-use.md): the
/// daily-use pass. Builds a fixture tree in its temp folder (never real
/// files) and drives what a person does all day, with real mouse and key
/// events where the DevChecks helpers allow, snapshotting the window
/// after every step as NN-flow-step.png in CEDRIC_CHECK_OUT:
///
///   1 outside   a folder opened in the sidebar, then a file from outside
///               it through application(_:open:) (Finder, Open With, a Dock
///               drop) and File › Open's path: the sidebar should follow
///   2 click     20 files of a mixed folder clicked in the sidebar: tab,
///               title, text shown, no second tab, the row selected,
///               binary held (an encoding-guess bar on .pcap/.bin is correct)
///   3 preview   Markdown preview on and off, twice: width, no overlap,
///               the heading rendered, the editor's width back; then a
///               local link followed in the preview (its history entry),
///               a two-finger swipe back, and the bar's Back button
///   4 recent    File › Open Recent lists the fixture files; choosing one
///               opens it (and from outside the folder: the sidebar)
///   5 folders   switching folders B → A: root, rows, selection, the
///               docked width, the tabs; then File › Up One Folder from
///               A/sub and File › Go to Folder… to B: the resulting root
///   6 settings  every Settings pane opened with ⌘,: at most 700 pt tall,
///               nothing cut off, truncated or overlapping
///   7 longline  a 5 MB one-line (base64-like) file in long-line mode:
///               Wrap ON keeps fragments in the view width; Wrap OFF
///               scrolls horizontally
///   8 markdown  an untitled tab, `**bold**` typed on line 1, switches
///               to Markdown at the next typing pause
///
/// Known bugs (expected failures; strict: a marker whose assertions pass
/// fails the run until it is removed):
///   sidebar-follow        fixed on fix/0.6.1-sidebar-speed
///   settings-cedric-tall  fixed on fix/cedric-settings-compact (draft PR #26)
///   longline-wrap         fixed on fix/0.6.1-longline-wrap
///   md-detect             fixed on fix/0.6.1-md-detect
///   open-folder-select    File › Open Folder does not select the front tab's
///                         file when that file is in the opened folder (no
///                         fix branch yet). Open Enclosing Folder does, via
///                         reveal:.
///   folder-up             no Up One Folder: fixed on feat/sidebar-folder-browsing
///   folder-goto           no Go to Folder…: fixed on feat/sidebar-folder-browsing
///   preview-swipe-back    no swipe back in the preview: fixed on
///                         feat/sidebar-folder-browsing
///
/// Every marker's inputs are checked by plain assertions outside it (the
/// file opened, the folder listed immediately before, the keystrokes
/// arrived), so a broken flow is a FAIL and not a "known bug".
///
/// CEDRIC_DAILYUSE_FAULT (comma separated) breaks the flow on purpose, to
/// prove those plain assertions:
///   drop-typing           the Markdown flow's keystrokes are not sent
///   first-open-follows    after the Finder-style open the sidebar is moved
///                         to folder B, as a build with sidebar-follow fixed
///                         would leave it
@MainActor
extension DevChecks {
    /// The fixture: folder A (a mixed set) and folder B elsewhere in the temp folder.
    struct DailyUseFixture {
        let a: URL, b: URL
        /// A's top-level files, in the order the pass clicks them.
        let files: [URL]
        let readme: URL, log: URL, pcap: URL, gpx: URL, binary: URL
        let huge: URL
        let bFiles: [URL]
    }

    static func dailyUseFixture() -> DailyUseFixture {
        let fm = FileManager.default
        let a = dir.appendingPathComponent("A", isDirectory: true)
        let b = dir.appendingPathComponent("elsewhere/B", isDirectory: true)
        try? fm.createDirectory(at: a, withIntermediateDirectories: true)
        try? fm.createDirectory(at: b, withIntermediateDirectories: true)
        func put(_ base: URL, _ name: String, _ data: Data) -> URL {
            let u = base.appendingPathComponent(name)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u)
            return u
        }
        func text(_ base: URL, _ name: String, _ s: String) -> URL { put(base, name, Data(s.utf8)) }
        let readme = text(a, "readme.md", """
            # Daily Use Readme

            Some notes with a [link](https://example.com) and a [local link](notes.md).

            ## Code

            ```swift
            let owl = "hoot"
            print(owl)
            ```

            - one
            - two

            """)
        var md = [readme]
        for (n, s) in [("notes.md", "# Notes\n\nShort note.\n"), ("todo.md", "# To do\n\n- [ ] one\n- [x] two\n"),
                       ("journal.md", "# Journal\n\n" + String(repeating: "A day of writing.\n\n", count: 40)),
                       ("ideas.md", "## Ideas\n\n*Bold* ideas.\n"), ("changelog.md", "# Changes\n\n## 1.0\n\n- First.\n")] {
            md.append(text(a, n, s))
        }
        // ~5 MB of ordinary log lines.
        var log = ""
        log.reserveCapacity(5_300_000)
        var i = 0
        while log.utf8.count < 5_000_000 {
            log += "2026-11-27 10:\(String(format: "%02d:%02d", (i / 60) % 60, i % 60)).\(String(format: "%03d", i % 1000)) INFO [worker-\(i % 8)] request \(i) completed in \(i % 997) ms\n"
            i += 1
        }
        let logURL = text(a, "server.log", log)
        // A valid minimal pcap: the global header (little endian, Ethernet) and one 60-byte frame.
        var pcap = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { pcap.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { pcap.append(contentsOf: $0) } }
        le32(0xA1B2_C3D4); le16(2); le16(4); le32(0); le32(0); le32(65535); le32(1)
        le32(1_764_000_000); le32(0); le32(60); le32(60)
        pcap.append(contentsOf: [UInt8](repeating: 0xFF, count: 6) + [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x08, 0x06])
        pcap.append(contentsOf: (0..<46).map { UInt8($0) })
        let pcapURL = put(a, "capture.pcap", pcap)
        let gpx = text(a, "ride.gpx", """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="cedric-dailyuse" xmlns="http://www.topografix.com/GPX/1/1">
              <trk><name>Ride</name><trkseg>
                <trkpt lat="45.5231" lon="-122.6765"><ele>15.0</ele><time>2026-11-27T10:00:00Z</time></trkpt>
                <trkpt lat="45.5240" lon="-122.6750"><ele>16.2</ele><time>2026-11-27T10:00:10Z</time></trkpt>
                <trkpt lat="45.5252" lon="-122.6731"><ele>17.9</ele><time>2026-11-27T10:00:20Z</time></trkpt>
              </trkseg></trk>
            </gpx>

            """)
        let binary = put(a, "blob.bin", Data((0..<8).flatMap { _ in (0...255).map { UInt8($0) } }))
        var others: [URL] = []
        for (n, s) in [
            ("main.swift", "import Foundation\n\nprint(\"hello\")\n"),
            ("model.swift", "struct Owl {\n    var name: String\n}\n"),
            ("view.swift", "final class View {\n    func draw() {}\n}\n"),
            ("config.json", "{\n  \"name\": \"owlink\",\n  \"version\": 6\n}\n"),
            ("data.json", "[1, 2, 3]\n"),
            ("package.json", "{ \"scripts\": { \"test\": \"true\" } }\n"),
            ("readme.txt", "Plain text.\n"),
            ("hosts.txt", "127.0.0.1 localhost\n"),
            ("words.txt", "alpha\nbeta\ngamma\n"),
            ("people.csv", "name,age\nzoe,31\namy,47\n"),
            ("sales.csv", "month,total\njan,10\nfeb,12\n"),
        ] { others.append(text(a, n, s)) }
        _ = text(a, "sub/inner.md", "# Inner\n")
        _ = text(a, "sub/deep/leaf.txt", "leaf\n")
        let bFiles = [text(b, "outside.md", "# Outside\n\nFrom folder B.\n"), text(b, "other.txt", "other\n"),
                      text(b, "list.csv", "a,b\n1,2\n")]
        // One enormous line (~5 MB, base64-like, no newline). Not in the
        // 20 click-through files: it is opened on its own in the long-line
        // wrap step.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var raw = [UInt8]()
        raw.reserveCapacity(5_000_000)
        while raw.count < 5_000_000 { raw.append(alphabet[raw.count % alphabet.count]) }
        let huge = put(a, "huge-line.txt", Data(raw))
        // 20 to click: the mixed set (one .txt left over).
        let files = Array((md + [logURL, pcapURL, gpx, binary] + others).prefix(20))
        return DailyUseFixture(a: a, b: b, files: files, readme: readme, log: logURL, pcap: pcapURL, gpx: gpx, binary: binary, huge: huge, bFiles: bFiles)
    }

    // MARK: Helpers shared with the perf check

    static var dailySidebar: FolderSidebar? { FolderSidebar.shared }

    static func dailyNode(_ url: URL) -> FolderNode? {
        guard let s = FolderSidebar.shared, let rel = FolderTree.relativePath(of: url.standardizedFileURL, in: s.rootURL), !rel.isEmpty else { return nil }
        return s.root.descendant(rel)
    }

    static func dailyRow(_ url: URL) -> Int {
        guard let s = FolderSidebar.shared, let n = dailyNode(url) else { return -1 }
        return s.outline.row(forItem: n)
    }

    /// Notes once that a synthetic click was not taken (inactive app).
    static var dailyNotedClick = false

    /// A real left click on the row's name (FolderCheck's clickRow). When
    /// the inactive outline doesn't take the synthetic click, the row is
    /// selected and opened as the click would (noted once).
    static func dailyClickRow(_ url: URL) {
        guard let s = FolderSidebar.shared else { return }
        let r = dailyRow(url)
        guard r >= 0 else { return }
        let o = s.outline
        let rect = o.frameOfCell(atColumn: 0, row: r)
        o.scrollRowToVisible(r)
        // A row already selected (left from before) shows no change when
        // the inactive outline drops the click: open it as the click would.
        let wasSelected = o.selectedRow == r
        click(o, at: NSPoint(x: rect.minX + 30, y: rect.midY))
        if o.selectedRow != r || (wasSelected && !NSApp.isActive) {
            if !dailyNotedClick {
                dailyNotedClick = true
                DailyUseHarness.main.note("synthetic click not taken by the inactive outline; selecting the row and opening as the click would")
            }
            o.selectRowIndexes([r], byExtendingSelection: false)
            s.activateSelection()
        }
    }

    /// Notes once that key-window changes are emulated (inactive app).
    static var dailyNotedKey = false

    /// What the system does when the front tab's window becomes key
    /// (windowDidBecomeKey → AppDelegate.tabBecameKey: the sidebar follows
    /// it). An inactive app (a locked screen, a background launch) gets no
    /// key windows, so the check sends it, as a click in the window would.
    static func dailyBecomeKey(_ app: AppDelegate) {
        guard !NSApp.isActive, let t = app.currentTab, let w = t.window else { return }
        if !dailyNotedKey {
            dailyNotedKey = true
            DailyUseHarness.main.note("app inactive: sending windowDidBecomeKey for the front tab after opens, as the system would when it becomes key")
        }
        t.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: w))
    }

    /// The open tab of `url`: a text tab or a viewer tab's window.
    static func dailyTab(_ app: AppDelegate, _ url: URL) -> EditorWindowController? {
        let std = url.standardizedFileURL
        return app.tabs.first { $0.doc.fileURL?.standardizedFileURL == std }
    }

    static func dailyWindow(_ app: AppDelegate, _ url: URL) -> NSWindow? {
        dailyTab(app, url)?.window ?? app.viewerTab(for: url.standardizedFileURL)?.window
    }

    static func dailyTabCount(_ app: AppDelegate) -> Int { app.tabs.count + app.viewerTabs.count }

    /// The tab's text is in and laid out where it shows (or, held as
    /// binary, the bar shows).
    static func dailyLoaded(_ tab: EditorWindowController, bytes: Int) -> Bool {
        if tab.binary != nil { return tab.binaryBar?.isHidden == false }
        guard !tab.loading, tab.textView.window != nil, !tab.textView.isHiddenOrHasHiddenAncestor else { return false }
        return bytes == 0 || (tab.textView.textStorage?.length ?? 0) > 0
    }

    /// The notice bars showing in a tab, as "kind: text".
    static func dailyNotices(_ tab: EditorWindowController) -> [String] {
        let bars: [(String, NSView?, String?)] = [
            ("binary", tab.binaryBar, tab.binaryBar?.label.stringValue),
            ("read-only", tab.readOnlyBar, tab.readOnlyBar?.label.stringValue),
            ("encoding", tab.encodingBar, tab.encodingBar?.label.stringValue),
            ("line-ending", tab.lineEndingBar, tab.lineEndingBar?.label.stringValue),
            ("backup", tab.backupBar, tab.backupBar?.label.stringValue),
            ("disk", tab.diskBar, tab.diskBar?.label.stringValue),
            ("notice", tab.noticeBar, tab.noticeBar?.label.stringValue),
        ]
        return bars.compactMap { kind, v, text in
            guard let v, v.window != nil, !v.isHiddenOrHasHiddenAncestor else { return nil }
            return "\(kind): \(text ?? "")"
        }
    }

    static func dailyNames(_ parent: FolderNode? = nil) -> [String] {
        guard let o = FolderSidebar.shared?.outline else { return [] }
        return (0..<o.numberOfChildren(ofItem: parent)).compactMap { (o.child($0, ofItem: parent) as? FolderNode)?.name }
    }

    /// TextKit 2 rows of the first `fragments` layout fragments (laid
    /// out), in text container coordinates.
    struct DailyWrapRows {
        var rows: [(maxX: CGFloat, width: CGFloat, lastInFragment: Bool)] = []
        var fragments = 0
        var container: CGFloat = 0, visible: CGFloat = 0, originX: CGFloat = 0
        var scroller = false
    }

    static func dailyWrapRows(_ tab: EditorWindowController, fragments limit: Int) -> DailyWrapRows {
        let tv = tab.textView
        tab.window?.layoutIfNeeded()
        tab.window?.displayIfNeeded()
        var m = DailyWrapRows()
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager, let container = tv.textContainer else { return m }
        m.container = container.size.width
        m.visible = tab.scrollView.contentView.bounds.width
        m.originX = tv.textContainerOrigin.x
        m.scroller = tab.scrollView.hasHorizontalScroller
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { f in
            m.fragments += 1
            let lines = f.textLineFragments
            let last = lines.lastIndex { $0.characterRange.length > 0 }
            for (i, line) in lines.enumerated() where line.characterRange.length > 0 {
                m.rows.append((f.layoutFragmentFrame.minX + line.typographicBounds.maxX, line.typographicBounds.width, i == last))
            }
            return m.fragments < limit
        }
        return m
    }

    /// A main-menu item by its action's name or its title (the folder
    /// commands are looked up at run time: main does not have them yet).
    static func dailyMenuItem(actions: [String], titles: [String]) -> NSMenuItem? {
        func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items {
                if let a = i.action, actions.contains(NSStringFromSelector(a)) { return i }
                if titles.contains(i.title) { return i }
                if let sub = i.submenu, let f = find(sub) { return f }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    /// Chooses a menu item as a user would: the menu validates it, then
    /// its action goes where AppKit sends it. False when it is disabled.
    static func dailyChoose(_ item: NSMenuItem) -> Bool {
        guard let menu = item.menu else { return false }
        menu.update()
        guard item.isEnabled else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    /// Two fingers swiped right over `view`, as the trackpad reports it:
    /// scroll-wheel events with gesture phases (began, changed…, ended),
    /// posted to the app's event queue so they pass the app's event
    /// monitors and reach the view under them. Says what it sent. These
    /// are synthesized events, not a live gesture from the window server
    /// (the caller reports that gap): on a build with
    /// feat/sidebar-folder-browsing merged they are not taken as a swipe
    /// (checked 2026-11-28).
    static func dailySwipeRight(over view: NSView) -> String {
        guard let w = view.window, let primary = NSScreen.screens.first else { return "not sent: the view has no window" }
        let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let onScreen = w.convertPoint(toScreen: inWindow)
        func event(_ dx: Int32, _ phase: Int64) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) else { return nil }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
            // The window an event made in process belongs to (the window
            // server's own event field, 51: not in the public headers).
            if let field = CGEventField(rawValue: 51) { cg.setIntegerValueField(field, value: Int64(w.windowNumber)) }
            cg.location = CGPoint(x: onScreen.x, y: primary.frame.height - onScreen.y)
            return NSEvent(cgEvent: cg)
        }
        // CGScrollPhase: 1 began, 2 changed, 4 ended.
        guard let first = event(1, 1) else { return "not sent: no scroll event could be made" }
        // Fingers moving right: a positive delta with Natural Scrolling
        // (the event says which it is), a negative one without.
        let sign: Int32 = first.isDirectionInvertedFromDevice ? 1 : -1
        let events = [event(sign * 6, 1)] + (0..<14).map { _ in event(sign * 40, 2) } + [event(0, 4)]
        let made = events.compactMap { $0 }
        let what = "\(made.count) scroll events (\(sign > 0 ? "+" : "-")x, phases began/changed/ended\(first.phase == .began ? "" : ", the phase not read back"))"
        if first.window === w {
            // 50 ms apart (what takes a swipe may ask the page something
            // between the first event and the next).
            for (i, e) in made.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) { NSApp.postEvent(e, atStart: false) }
            }
            return "posted \(what), 50 ms apart, to the app's event queue for the preview's window "
                + "(System Settings › Trackpad › Swipe between pages is \(NSEvent.isSwipeTrackingFromScrollEventsEnabled ? "on" : "OFF: no build swipes then"))"
        }
        // An event made in process carries no window, so the app's queue
        // has nowhere to send it: handed to the view, as its window would
        // (the app's event monitors do not see these).
        for e in made { view.scrollWheel(with: e) }
        return "handed \(what) to the web view itself: an event made in process carries no window, so the app's event queue and its event monitors are passed by"
    }

    static func dailyLoad() -> DailyUseLoad {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return DailyUseLoad(oneMinute: l[0], cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: The pass

    static func dailyUseFlows(_ app: AppDelegate) {
        let h = DailyUseHarness.main
        startHangWatchdog()
        let t0 = CFAbsoluteTimeGetCurrent()
        let fx = dailyUseFixture()
        h.note("fixture in \(dir.path) (\(fx.files.count) files to click; \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms to write)")
        h.note("app active=\(NSApp.isActive) key window=\(NSApp.keyWindow != nil) bundle=\(Bundle.main.bundleIdentifier ?? "-")")
        let faults = Set((DevEnvironment.values["CEDRIC_DAILYUSE_FAULT"] ?? "").split(separator: ",").map(String.init))
        if !faults.isEmpty { h.note("FAULTS injected on purpose (CEDRIC_DAILYUSE_FAULT): \(faults.sorted())") }
        // Local wrappers: a `let step = DailyUseHarness.step` function
        // value drops argument labels and default values, so
        // `step(name, snapshot: false) { … }` does not compile.
        func step(_ name: String, snapshot: Bool = true, _ body: @escaping (@escaping () -> Void) -> Void) -> DailyUseHarness.Step {
            DailyUseHarness.step(name, snapshot: snapshot, body)
        }
        func sync(_ name: String, snapshot: Bool = true, _ f: @escaping () -> Void) -> DailyUseHarness.Step {
            DailyUseHarness.sync(name, snapshot: snapshot, f)
        }
        var s: FolderSidebar? { FolderSidebar.shared }
        func waitListed(_ root: URL, _ name: String) -> DailyUseHarness.Step {
            step(name, snapshot: false) { next in
                DailyUseHarness.poll(8, { s?.rootURL.standardizedFileURL == root.standardizedFileURL && s?.root.isLoaded == true }) { ok in
                    h.check(ok, "\(name): \(root.lastPathComponent) is listed in the sidebar", "root=\(s?.rootURL.path ?? "none") loaded=\(s?.root.isLoaded ?? false)")
                    next()
                }
            }
        }

        var steps: [DailyUseHarness.Step] = []

        // 1. A file from outside the loaded folder.
        steps += [
            sync("outside-open-folder-a") {
                for t in app.tabs { sized(t) }
                // A folder dropped on the Dock icon, or `owlink dir`, arrives here.
                app.application(NSApp, open: [fx.a])
            },
            waitListed(fx.a, "outside-listed"),
            step("outside-open-file-b") { next in
                let file = fx.bFiles[0]
                h.check(s?.rootURL.standardizedFileURL == fx.a.standardizedFileURL, "outside: the sidebar shows folder A before")
                // Finder's Open, Open With, a drop on the Dock icon: application(_:open:).
                app.application(NSApp, open: [file])
                DailyUseHarness.poll(2, { dailyTab(app, file) != nil }) { opened in
                    h.check(opened, "outside: application(_:open:) opens outside.md from folder B in a tab")
                    if let t = dailyTab(app, file) { sized(t) }
                    dailyBecomeKey(app)
                    // Give the sidebar the chance to follow (listing B).
                    DailyUseHarness.poll(3, { s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL && s?.root.isLoaded == true }) { _ in
                        // KNOWN BUG on main, fixed on fix/0.6.1-sidebar-speed: the
                        // sidebar stays on folder A. Remove this marker when that merges.
                        h.knownBug(id: "sidebar-follow", note: "a file opened from outside the sidebar's folder (application(_:open:)) leaves the sidebar on the old folder") {
                            let root = s?.rootURL.standardizedFileURL
                            h.check(root == fx.b.standardizedFileURL, "outside: the sidebar's root becomes folder B", "root is still \(root?.lastPathComponent ?? "none")")
                            h.check(s?.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "outside: outside.md is selected in the sidebar",
                                    "selected: \(s?.selectedNode?.name ?? "nothing")")
                        }
                        next()
                    }
                }
            },
            // The File › Open case does not lean on the case before: whatever
            // the sidebar did there (fixed, it is on folder B by now), it
            // goes back to folder A, and A listed is asserted right before
            // the open, so the file is from outside the sidebar's folder.
            step("outside-file-open-reset", snapshot: false) { next in
                guard faults.contains("first-open-follows") else { next(); return }
                h.note("fault first-open-follows: moving the sidebar to folder B, as a build with sidebar-follow fixed leaves it")
                app.openFolder(fx.b)
                DailyUseHarness.poll(5, { s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL && s?.root.isLoaded == true }) { _ in next() }
            },
            sync("outside-file-open-to-a", snapshot: false) {
                if s?.rootURL.standardizedFileURL != fx.a.standardizedFileURL { app.openFolder(fx.a) }
            },
            waitListed(fx.a, "outside-file-open-a-listed"),
            step("outside-file-open-path") { next in
                // File › Open…'s code path after its panel (openDocument: open(url, background: true)).
                let file = fx.bFiles[1]
                h.check(s?.rootURL.standardizedFileURL == fx.a.standardizedFileURL && s?.root.isLoaded == true && dailyRow(fx.readme) >= 0,
                        "outside (File › Open): folder A is listed in the sidebar immediately before the open",
                        "root=\(s?.rootURL.path ?? "none") loaded=\(s?.root.isLoaded ?? false)")
                h.check(dailyTab(app, file) == nil && FolderTree.relativePath(of: file.standardizedFileURL, in: fx.a.standardizedFileURL) == nil,
                        "outside (File › Open): other.txt is not open yet and is outside folder A")
                app.open(file, background: true)
                h.check(dailyTab(app, file) != nil, "outside: File › Open's path (open(_:background:)) opens other.txt from B")
                if let t = dailyTab(app, file) { sized(t) }
                dailyBecomeKey(app)
                DailyUseHarness.poll(3, { s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL && s?.root.isLoaded == true }) { _ in
                    // KNOWN BUG on main, fixed on fix/0.6.1-sidebar-speed.
                    h.knownBug(id: "sidebar-follow", note: "File › Open of a file outside the sidebar's folder leaves the sidebar on the old folder") {
                        h.check(s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL, "outside (File › Open): the sidebar's root becomes folder B",
                                "root is still \(s?.rootURL.lastPathComponent ?? "none")")
                        h.check(s?.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "outside (File › Open): other.txt is selected",
                                "selected: \(s?.selectedNode?.name ?? "nothing")")
                    }
                    next()
                }
            },
            // The rest of the pass starts from folder A, whatever the sidebar did.
            sync("outside-back-to-a", snapshot: false) {
                if s?.rootURL.standardizedFileURL != fx.a.standardizedFileURL { app.openFolder(fx.a) }
            },
            waitListed(fx.a, "outside-relisted-a"),
        ]

        // 2. Click through 20 files.
        for (n, file) in fx.files.enumerated() {
            let name = file.lastPathComponent
            let label = String(format: "click-%02d-%@", n + 1, name.replacingOccurrences(of: ".", with: "_"))
            steps.append(step(label) { next in
                guard let s, dailyRow(file) >= 0 else {
                    h.check(false, "click \(name): its row is in the sidebar", "row \(dailyRow(file)) root=\(s?.rootURL.lastPathComponent ?? "none")")
                    next(); return
                }
                let before = dailyTabCount(app)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let start = CFAbsoluteTimeGetCurrent()
                dailyClickRow(file)
                DailyUseHarness.poll(10, every: 0.005, {
                    if let t = dailyTab(app, file) { return dailyLoaded(t, bytes: size) }
                    return app.viewerTab(for: file.standardizedFileURL) != nil
                }) { loaded in
                    let w = dailyWindow(app, file)
                    w?.displayIfNeeded()
                    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    h.note(String(format: "click %@ (%d bytes): %.1f ms to its text shown", name, size, ms))
                    h.check(loaded, "click \(name): its tab opens and shows within 10 s")
                    guard let w else { next(); return }
                    let t = dailyTab(app, file)
                    if let t { sized(t) }
                    h.check(dailyTabCount(app) == before + 1, "click \(name): one new tab", "\(before) → \(dailyTabCount(app))")
                    let front = app.currentTab?.window ?? app.currentViewerTab?.window
                    h.check(w.isKeyWindow || front === w || w.tabGroup?.selectedWindow === w, "click \(name): its tab is the selected one",
                            "key=\(NSApp.keyWindow?.title ?? "-") front=\(front?.title ?? "-") selected=\(w.tabGroup?.selectedWindow?.title ?? "-")")
                    h.check(w.title.contains(name), "click \(name): the window title names it", "title “\(w.title)”")
                    h.check(s.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "click \(name): the sidebar's selected row is the tab's file",
                            "selected: \(s.selectedNode?.name ?? "nothing")")
                    h.check(s.superview != nil && s.window === w, "click \(name): the sidebar is docked in its tab")
                    if let t {
                        let notices = dailyNotices(t)
                        if file == fx.binary || file == fx.pcap {
                            h.check(t.binary != nil && t.text.isEmpty && t.binaryBar?.isHidden == false,
                                    "click \(name): held as binary, the bar showing (\(t.binaryBar?.label.stringValue ?? "no bar"))",
                                    "binary=\(String(describing: t.binary).prefix(20)) text=\(t.text.count)")
                            // Binary files that aren't valid UTF-8 also show
                            // the encoding-guess bar (Latin-1 / Mac Roman).
                            // That is correct; only unexpected kinds fail.
                            h.check(notices.allSatisfy { $0.hasPrefix("binary:") || $0.hasPrefix("encoding:") },
                                    "click \(name): no other notice", "\(notices)")
                        } else {
                            h.check(t.binary == nil, "click \(name): opened as text, not held as binary")
                            h.check(notices.isEmpty, "click \(name): no notice bar", "\(notices)")
                            h.check(t.text.utf8.count == size, "click \(name): all of its text is in the editor", "\(t.text.utf8.count) of \(size) bytes")
                            let visible = t.textView.visibleRect
                            h.check(visible.height > 50 && visible.width > 50, "click \(name): the text view shows", "visible \(visible)")
                        }
                    }
                    // A second click on the same row: no new tab.
                    let count = dailyTabCount(app)
                    dailyClickRow(file)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        h.check(dailyTabCount(app) == count, "click \(name) again: no second tab", "\(count) → \(dailyTabCount(app))")
                        h.check(s.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "click \(name) again: still selected")
                        next()
                    }
                }
            })
        }

        // 3. Markdown preview on and off, twice.
        var editorWidth: CGFloat = 0
        var readmeTab: EditorWindowController? { dailyTab(app, fx.readme) }
        steps.append(sync("preview-select-readme") {
            dailyClickRow(fx.readme)
            if let t = readmeTab { sized(t); t.window?.layoutIfNeeded(); editorWidth = t.editorArea.frame.width }
            h.check(readmeTab != nil && app.currentTab === readmeTab, "preview: readme.md's tab is selected again from the sidebar")
        })
        for round in 1...2 {
            steps.append(step("preview-on-\(round)") { next in
                guard let t = readmeTab else { h.check(false, "preview \(round): readme.md is open"); next(); return }
                focus(t)
                key("p", [.command, .option])
                DailyUseHarness.poll(5, { t.previewVisible && (t.preview?.pageLoads ?? 0) + (t.preview?.bodySwaps ?? 0) > 0 }) { shown in
                    h.check(shown, "preview \(round): ⌥⌘P shows the preview and it renders")
                    t.window?.layoutIfNeeded()
                    guard let pane = t.previewPane else { next(); return }
                    let p = pane.convert(pane.bounds, to: t.split), e = t.editorArea.convert(t.editorArea.bounds, to: t.split)
                    h.check(p.width > 100, "preview \(round): the pane has width", "\(p)")
                    h.check(e.width > 100, "preview \(round): the editor keeps width", "\(e)")
                    h.check(!p.insetBy(dx: 1, dy: 1).intersects(e), "preview \(round): editor and preview don't overlap", "editor \(e) preview \(p)")
                    var tries = 0
                    @MainActor func heading() {
                        previewJS(t, "(document.querySelector('h1') || {}).textContent || ''") { v in
                            let text = v as? String ?? ""
                            tries += 1
                            if text.contains("Daily Use Readme") || tries > 50 {
                                h.check(text.contains("Daily Use Readme"), "preview \(round): the heading is rendered", "h1 “\(text)”")
                                previewJS(t, "document.querySelectorAll('pre code').length + ',' + document.querySelectorAll('a[href]').length") { v in
                                    let raw = (v as? String) ?? "nil"
                                    let parts = raw.split(separator: ",").compactMap { Int($0) }
                                    h.check(parts.count == 2 && parts[0] >= 1 && parts[1] >= 2,
                                            "preview \(round): the code block and links are rendered", "code,links = \(raw)")
                                    next()
                                }
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { heading() } }
                            }
                        }
                    }
                    heading()
                }
            })
            steps.append(sync("preview-off-\(round)") {
                guard let t = readmeTab else { return }
                key("p", [.command, .option])
                t.window?.layoutIfNeeded()
                h.check(!t.previewVisible && t.previewPane == nil, "preview \(round): ⌥⌘P again hides it")
                let w = t.editorArea.frame.width
                h.check(abs(w - editorWidth) <= 2, "preview \(round): the editor's width is back", "\(w) vs \(editorWidth) before")
            })
        }

        // 3b. A link followed in the preview, a swipe back, the Back button.
        steps.append(step("preview-nav-on") { next in
            guard let t = readmeTab else { h.check(false, "preview nav: readme.md is open"); next(); return }
            focus(t)
            key("p", [.command, .option])
            dailyPreviewRendered(since: CFAbsoluteTimeGetCurrent(), web: { t.previewVisible ? t.preview?.webView : nil }, heading: "Daily Use Readme",
                                 timeout: 5, window: { t.window }) { ms in
                h.check(ms != nil, "preview nav: the preview shows readme.md's heading")
                h.check(t.preview?.isHome == true && t.preview?.canGoBack == false, "preview nav: it starts on the document, with nothing to go back to")
                next()
            }
        })
        steps.append(step("preview-follow-link") { next in
            guard let t = readmeTab, let p = t.preview else { h.check(false, "preview nav: the preview is showing"); next(); return }
            let tabs = dailyTabCount(app)
            // A real click where the link is drawn; an inactive web view may
            // not take it, then the link is activated in the page (noted).
            previewJS(t, "(() => { const a = document.querySelector('a[href=\"notes.md\"]'); if (!a) return null; const r = a.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()") { v in
                let xy = (v as? [NSNumber])?.map(\.doubleValue) ?? []
                h.check(xy.count == 2, "preview nav: the local link to notes.md is in the page", "\(String(describing: v))")
                if xy.count == 2 {
                    let web = p.webView
                    let scale = Double(web.pageZoom * web.magnification)
                    click(web, at: NSPoint(x: xy[0] * scale, y: web.isFlipped ? xy[1] * scale : Double(web.bounds.height) - xy[1] * scale))
                }
                DailyUseHarness.poll(1, { !p.isHome }) { taken in
                    if !taken {
                        h.note("synthetic click not taken by the inactive web view; activating the link in the page as the click would")
                        previewJS(t, "document.querySelector('a[href=\"notes.md\"]').click(); 1") { _ in }
                    }
                    dailyPreviewRendered(since: CFAbsoluteTimeGetCurrent(), web: { p.webView }, heading: "Notes", timeout: 5, window: { t.window }) { ms in
                        h.check(ms != nil, "preview nav: following the link shows notes.md's heading in the preview")
                        h.check(!p.isHome && p.navigationTitle == "notes.md" && p.canGoBack && !p.canGoForward,
                                "preview nav: the preview's history entry is notes.md, with Back available",
                                "home=\(p.isHome) title=\(p.navigationTitle) back=\(p.canGoBack) forward=\(p.canGoForward)")
                        h.check(dailyTabCount(app) == tabs && app.currentTab === t, "preview nav: the link opened in the preview, not in a tab",
                                "\(tabs) → \(dailyTabCount(app)) tabs")
                        next()
                    }
                }
            }
        })
        steps.append(step("preview-swipe-back") { next in
            guard let t = readmeTab, let p = t.preview, !p.isHome, p.canGoBack else {
                h.check(false, "preview swipe: the linked page is showing, with a page to go back to, before the swipe"); next(); return
            }
            let sent = dailySwipeRight(over: p.webView)
            h.note("preview swipe: \(sent)")
            DailyUseHarness.poll(2, { p.isHome }) { _ in
                // The coverage gap, said out loud in every run: what was sent
                // is not a live gesture.
                h.skip("preview swipe (live trackpad gesture)", "not covered: the pass \(sent). "
                       + "A live two-finger swipe comes from the window server and is followed by AppKit's swipe tracking, "
                       + "which takes an active session and a trackpad: a build with the swipe (feat/sidebar-folder-browsing merged, checked 2026-11-28) "
                       + "does not take these synthesized events, so preview-swipe-back stays KNOWN-BUG there too. "
                       + "Swipe by hand on a build that has it; CEDRIC_CHECK=previewswipe on that branch drives its handlers")
                // KNOWN BUG on main, fixed on feat/sidebar-folder-browsing
                // (PreviewSwipe): nothing in the preview takes a swipe.
                // This marker does NOT flip by itself when that merges (the
                // synthesized gesture is not taken, see the SKIP above):
                // whoever merges it replaces the gesture here with
                // PreviewSwipe's handlers, as CEDRIC_CHECK=previewswipe
                // drives them, and removes the marker.
                h.knownBug(id: "preview-swipe-back", note: "two fingers swiped right over a linked page in the preview do not go back (no swipe in the preview)") {
                    h.check(p.isHome, "preview swipe: the swipe goes back to the document", "still on \(p.navigationTitle); \(sent)")
                }
                next()
            }
        })
        steps.append(step("preview-back-button") { next in
            guard let t = readmeTab, let p = t.preview else { h.check(false, "preview back: the preview is showing"); next(); return }
            if p.isHome {
                h.note("preview back: the swipe went back already; the Back button is not pressed")
            } else {
                // The route main has: the preview bar's Back button.
                let back = t.previewPane?.bar.buttons[.back]
                h.check(back?.isEnabled == true && back?.isHiddenOrHasHiddenAncestor == false, "preview back: the bar's Back button is showing and on")
                back?.performClick(nil)
            }
            // (The page before is notes.md, whose heading is another: no mark needed.)
            dailyPreviewRendered(since: CFAbsoluteTimeGetCurrent(), web: { p.webView }, heading: "Daily Use Readme", timeout: 5, window: { t.window }) { ms in
                h.check(ms != nil, "preview back: the document's heading is back in the preview")
                h.check(p.isHome && !p.canGoBack && p.canGoForward && p.navigationTitle != "notes.md",
                        "preview back: the preview's history entry is the document again, with Forward to notes.md",
                        "home=\(p.isHome) title=\(p.navigationTitle) back=\(p.canGoBack) forward=\(p.canGoForward)")
                next()
            }
        })
        steps.append(sync("preview-nav-off") {
            guard let t = readmeTab else { return }
            key("p", [.command, .option])
            t.window?.layoutIfNeeded()
            h.check(!t.previewVisible && t.previewPane == nil, "preview nav: ⌥⌘P hides the preview again")
            let w = t.editorArea.frame.width
            h.check(abs(w - editorWidth) <= 2, "preview nav: the editor's width is back", "\(w) vs \(editorWidth) before")
        })

        // 4. Open Recent (the copy's own list: dailyUseRequireIsolation).
        steps.append(sync("recent-menu") {
            app.rebuildRecentMenu()
            let titles = app.recentMenu?.items.map(\.title) ?? []
            h.note("recent menu: \(titles)")
            // The newest opens first: the last clicked files (at most the list's length).
            let max = NSDocumentController.shared.maximumRecentDocumentCount
            let want = fx.files.suffix(min(5, max)).reversed().map(\.lastPathComponent)
            h.check(want.allSatisfy { titles.contains($0) }, "recent: File › Open Recent lists the recently opened fixture files", "want \(want), menu \(titles)")
            h.check(titles.first == fx.files.last?.lastPathComponent,
                    "recent: the newest (the last file clicked) is first", "first “\(titles.first ?? "-")”")
        })
        steps.append(step("recent-choose") { next in
            // Close a fixture file's tab, then choose it in the menu.
            let file = fx.files[fx.files.count - 2]
            dailyWindow(app, file)?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                h.check(dailyTab(app, file) == nil, "recent: \(file.lastPathComponent)'s tab is closed")
                app.rebuildRecentMenu()
                guard let m = app.recentMenu, let i = m.items.firstIndex(where: { ($0.representedObject as? URL)?.standardizedFileURL == file.standardizedFileURL }) else {
                    h.check(false, "recent: \(file.lastPathComponent) is in Open Recent", "\(app.recentMenu?.items.map(\.title) ?? [])"); next(); return
                }
                m.performActionForItem(at: i)
                DailyUseHarness.poll(3, { dailyTab(app, file) != nil }) { ok in
                    h.check(ok, "recent: choosing \(file.lastPathComponent) in Open Recent opens it")
                    if let t = dailyTab(app, file) { sized(t) }
                    h.check(app.currentTab === dailyTab(app, file), "recent: …in the selected tab")
                    dailyBecomeKey(app)
                    // Let the sidebar settle a turn, as a user would see it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        h.check(s?.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "recent: …and its row is selected in the sidebar",
                                "selected: \(s?.selectedNode?.name ?? "nothing")")
                        next()
                    }
                }
            }
        })
        steps.append(step("recent-outside") { next in
            // A recent file from outside the sidebar's folder (B): opened
            // once (the outside step's file fell off the list since), closed,
            // chosen in Open Recent.
            let file = fx.bFiles[2]
            app.open(file, background: true)
            dailyWindow(app, file)?.close()
            // (Fixed, that open moved the sidebar to B: back to A, so the
            // assertion below is about Open Recent's own path.)
            if s?.rootURL.standardizedFileURL != fx.a.standardizedFileURL { app.openFolder(fx.a) }
            DailyUseHarness.poll(5, { s?.rootURL.standardizedFileURL == fx.a.standardizedFileURL && s?.root.isLoaded == true }) { listed in
                h.check(listed && dailyTab(app, file) == nil, "recent (outside): folder A is listed and list.csv is closed immediately before it is chosen",
                        "root=\(s?.rootURL.path ?? "none") loaded=\(s?.root.isLoaded ?? false) open=\(dailyTab(app, file) != nil)")
                app.rebuildRecentMenu()
                guard let m = app.recentMenu, let i = m.items.firstIndex(where: { ($0.representedObject as? URL)?.standardizedFileURL == file.standardizedFileURL }) else {
                    h.check(false, "recent: list.csv (folder B) is in Open Recent", "\(app.recentMenu?.items.map(\.title) ?? [])"); next(); return
                }
                m.performActionForItem(at: i)
                DispatchQueue.main.async { MainActor.assumeIsolated { dailyBecomeKey(app) } }
                DailyUseHarness.poll(3, { dailyTab(app, file) != nil && s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL && s?.root.isLoaded == true }) { _ in
                    h.check(dailyTab(app, file) != nil, "recent: choosing list.csv (folder B) opens it")
                    if let t = dailyTab(app, file) { sized(t) }
                    // KNOWN BUG on main, fixed on fix/0.6.1-sidebar-speed (the
                    // same follow-the-folder bug, through Open Recent).
                    h.knownBug(id: "sidebar-follow", note: "a recent file from outside the sidebar's folder leaves the sidebar on the old folder") {
                        h.check(s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL, "recent (outside): the sidebar's root becomes folder B",
                                "root is still \(s?.rootURL.lastPathComponent ?? "none")")
                        h.check(s?.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "recent (outside): list.csv is selected",
                                "selected: \(s?.selectedNode?.name ?? "nothing")")
                    }
                    next()
                }
            }
        })

        // 5. Switch folders: B, then A again (File › Open Folder…'s path after its panel).
        var tabsBefore: [String] = []
        var widthBefore: CGFloat = 0
        var current: EditorWindowController?
        func tabList() -> [String] {
            (app.tabs.compactMap { $0.doc.fileURL?.path } + app.viewerTabs.map(\.fileURL.path)).sorted()
        }
        steps += [
            sync("folders-ensure-a", snapshot: false) {
                if s?.rootURL.standardizedFileURL != fx.a.standardizedFileURL { app.openFolder(fx.a) }
            },
            waitListed(fx.a, "folders-a-first"),
            sync("folders-prepare") {
                // A file of A in front.
                dailyClickRow(fx.readme)
                current = readmeTab
                h.check(app.currentTab === current, "folders: readme.md's tab is in front before switching",
                        "front: \(app.currentTab?.doc.fileURL?.lastPathComponent ?? app.currentViewerTab?.fileURL.lastPathComponent ?? "none")")
                if let t = current, let side = s {
                    t.window?.layoutIfNeeded()
                    widthBefore = side.frame.width
                    // Not dragged: a synthetic divider drag is not taken by an
                    // inactive app's split view (tried: the frame moved, the
                    // width was not kept), so the saved width is the reference.
                    h.note("folders: docked sidebar \(Int(widthBefore)) pt (saved width \(Int(side.width))); divider drag not covered (inactive app)")
                }
                tabsBefore = tabList()
            },
            sync("folders-open-b", snapshot: false) { app.openFolder(fx.b) },
            waitListed(fx.b, "folders-b-listed"),
            sync("folders-b") {
                h.check(s?.rootURL.standardizedFileURL == fx.b.standardizedFileURL, "folders: the root is B")
                h.check(dailyNames() == ["list.csv", "other.txt", "outside.md"], "folders: B's rows are listed", "\(dailyNames())")
                h.check(s?.outline.selectedRow == -1, "folders: nothing selected in B (the tab's file is in A)", "selected: \(s?.selectedNode?.name ?? "nothing")")
                h.check(tabList() == tabsBefore, "folders: opening B leaves the tabs alone", "\(tabsBefore.count) → \(tabList().count)")
                let w = s?.frame.width ?? 0
                h.check(abs(w - widthBefore) <= 2, "folders: the docked sidebar keeps its width opening B", "\(Int(w)) pt, was \(Int(widthBefore))")
                h.check(app.currentTab === current, "folders: the same tab is still selected",
                        "before \(current?.doc.fileURL?.lastPathComponent ?? "none"), now \(app.currentTab?.doc.fileURL?.lastPathComponent ?? app.currentViewerTab?.fileURL.lastPathComponent ?? "none")")
            },
            sync("folders-open-a", snapshot: false) { app.openFolder(fx.a) },
            waitListed(fx.a, "folders-a-listed"),
            step("folders-a") { next in
                // Selection: let the sidebar settle a turn, as a user would see it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    h.check(s?.rootURL.standardizedFileURL == fx.a.standardizedFileURL, "folders: the root is A again")
                    let names = dailyNames()
                    let files = ((try? FileManager.default.contentsOfDirectory(atPath: fx.a.path)) ?? []).filter { $0 != "sub" && !$0.hasPrefix(".") }
                    h.check(names.first == "sub" && Set(names.dropFirst()) == Set(files) && names.count == files.count + 1,
                            "folders: A's rows are listed (sub, then its \(files.count) files)", "\(names.count): \(names)")
                    // Real app bug, not a harness miss: File › Open Folder
                    // (openFolder(_:) with reveal == nil) lists the folder
                    // but does not select the front tab's file, even when
                    // that file is in the folder. folderSidebarFollow only
                    // runs when a tab becomes key, which does not fire when
                    // the same tab stays in front. Open Enclosing Folder
                    // passes reveal: and does select. Evidence: flows-5
                    // shot 34-folders-a.png (readme.md tab in front, A listed,
                    // no sidebar row highlighted); selectedNode is nil after
                    // a 0.3 s settle. s is FolderSidebar.shared (computed).
                    h.knownBug(id: "open-folder-select", note: "File › Open Folder of the folder that holds the selected tab's file lists the folder but does not select that file (Open Enclosing Folder does, via reveal:)") {
                        h.check(s?.selectedNode?.url.standardizedFileURL == fx.readme.standardizedFileURL,
                                "folders: back on A, the selected tab's file (readme.md) is selected, as on a tab switch", "selected: \(s?.selectedNode?.name ?? "nothing")")
                    }
                    h.check(tabList() == tabsBefore, "folders: opening A again leaves the tabs alone", "\(tabsBefore.count) → \(tabList().count)")
                    let w = s?.frame.width ?? 0
                    h.check(abs(w - widthBefore) <= 2, "folders: the docked sidebar keeps its width opening A", "\(Int(w)) pt, was \(Int(widthBefore))")
                    next()
                }
            },
        ]

        // 5b. Up a folder and Go to Folder, through the File menu. Main has
        // neither command (they are looked up by action and title at run
        // time), so both are known bugs until feat/sidebar-folder-browsing
        // merges; with it, the commands are chosen and the root asserted.
        let sub = fx.a.appendingPathComponent("sub", isDirectory: true)
        func listed(_ root: URL) -> Bool { s?.rootURL.standardizedFileURL == root.standardizedFileURL && s?.root.isLoaded == true }
        steps += [
            sync("folders-open-sub", snapshot: false) { app.openFolder(sub) },
            waitListed(sub, "folders-sub-listed"),
            step("folders-up") { next in
                h.check(listed(sub) && dailyNames() == ["deep", "inner.md"], "folders up: A/sub is listed immediately before (deep, inner.md)", "root=\(s?.rootURL.path ?? "none") rows=\(dailyNames())")
                // The sidebar focused, as after a click in it.
                if let side = s { side.window?.makeFirstResponder(side.outline) }
                let item = dailyMenuItem(actions: ["upOneFolderMenu:"], titles: ["Up One Folder", "Up a Folder", "Go Up One Folder"])
                let chosen = item.map { dailyChoose($0) } ?? false
                h.note("folders up: menu item \(item.map { "“\($0.title)” \(chosen ? "chosen" : "disabled")" } ?? "not in the menus")")
                DailyUseHarness.poll(chosen ? 3 : 0, { listed(fx.a) }) { _ in
                    // KNOWN BUG on main, fixed on feat/sidebar-folder-browsing
                    // (File › Up One Folder, ⌘↑). Remove this marker when that merges.
                    h.knownBug(id: "folder-up", note: "there is no way to go up a folder from the sidebar's folder (no File › Up One Folder)") {
                        h.check(item != nil, "folders up: the menus have an Up One Folder command")
                        h.check(chosen, "folders up: the command is enabled with A/sub in the sidebar")
                        h.check(listed(fx.a), "folders up: the sidebar's root becomes the folder above, A", "root is \(s?.rootURL.lastPathComponent ?? "none")")
                    }
                    next()
                }
            },
            sync("folders-goto-to-a", snapshot: false) { if !listed(fx.a) { app.openFolder(fx.a) } },
            waitListed(fx.a, "folders-goto-a-listed"),
            step("folders-goto") { next in
                h.check(listed(fx.a), "folders go to: folder A is listed immediately before", "root=\(s?.rootURL.path ?? "none")")
                let item = dailyMenuItem(actions: ["goToFolderMenu:"], titles: ["Go to Folder…", "Go to Folder..."])
                let chosen = item.map { dailyChoose($0) } ?? false
                h.note("folders go to: menu item \(item.map { "“\($0.title)” \(chosen ? "chosen" : "disabled")" } ?? "not in the menus")")
                @MainActor func sheet() -> NSWindow? {
                    let front = app.currentTab?.window ?? app.currentViewerTab?.window
                    return front?.attachedSheet ?? NSApp.windows.first { $0.isVisible && $0.title == "Go to Folder" }
                }
                @MainActor func field(_ w: NSWindow) -> NSTextField? {
                    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                    return w.contentView.map(all)?.compactMap { $0 as? NSTextField }.first { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
                }
                DailyUseHarness.poll(chosen ? 3 : 0, { sheet().flatMap(field) != nil }) { shown in
                    let panel = sheet()
                    if shown, let panel, let f = field(panel) {
                        // The path typed over what the field holds, then Return (Go).
                        panel.makeFirstResponder(f)
                        if let editor = f.currentEditor() as? NSTextView {
                            editor.selectAll(nil)
                            editor.insertText(fx.b.path, replacementRange: editor.selectedRange())
                        } else {
                            f.stringValue = fx.b.path
                        }
                        // Return. A key sheet takes it as its default button's key
                        // equivalent; the sheet of an inactive app is not key, so
                        // the key goes to the path field, as typed there. (Not a
                        // synthetic click on the button: its tracking loop never
                        // ends in a sheet of an inactive app.)
                        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                        var how = "Return could not be made"
                        if let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                      isARepeat: false, keyCode: 36) {
                            if panel.performKeyEquivalent(with: ret) {
                                how = "Return taken as the sheet's key equivalent"
                            } else {
                                panel.makeFirstResponder(f)
                                panel.sendEvent(ret)
                                how = "Return typed in the path field"
                            }
                        }
                        let labels = panel.contentView.map(all)?.compactMap { $0 as? NSTextField }
                            .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }.map(\.stringValue) ?? []
                        h.note("folders go to: the field holds “\(f.stringValue)”; \(how); the sheet says \(labels)")
                    }
                    DailyUseHarness.poll(shown ? 3 : 0, { listed(fx.b) }) { _ in
                        // KNOWN BUG on main, fixed on feat/sidebar-folder-browsing
                        // (File › Go to Folder…, ⌥⌘G). Remove this marker when that merges.
                        h.knownBug(id: "folder-goto", note: "there is no way to type a folder's path to show it in the sidebar (no File › Go to Folder…)") {
                            h.check(item != nil, "folders go to: the menus have a Go to Folder… command")
                            h.check(shown, "folders go to: choosing it shows a sheet with a path field")
                            h.check(listed(fx.b), "folders go to: typing B's path and Return makes B the sidebar's root", "root is \(s?.rootURL.lastPathComponent ?? "none")")
                        }
                        // A sheet left open would block the rest of the pass.
                        if let left = sheet() { left.sheetParent?.endSheet(left); left.orderOut(nil) }
                        next()
                    }
                }
            },
            // The rest of the pass starts from folder A.
            sync("folders-nav-back-to-a", snapshot: false) { if !listed(fx.a) { app.openFolder(fx.a) } },
            waitListed(fx.a, "folders-nav-a-listed"),
        ]


        // 7. Long-line wrap (known bug longline-wrap, fix/0.6.1-longline-wrap).
        let restoreWrap = keepDefaults(["wrapLines"])
        steps.append(step("longline-open") { next in
            Settings.shared.wrapLines = true
            _ = app.open(fx.huge)
            DailyUseHarness.poll(20, { dailyTab(app, fx.huge)?.largeReason != nil || (dailyTab(app, fx.huge)?.textView.string.count ?? 0) > 1_000_000 }) { ok in
                let tab = dailyTab(app, fx.huge)
                h.check(ok && tab != nil, "longline: the 5 MB one-line file opened", "tab=\(tab != nil) reason=\(tab?.largeReason.map { String(describing: $0) } ?? "none")")
                if let tab, let reason = tab.largeReason {
                    h.check(reason == .longLine || reason == .size, "longline: large / long-line mode is on", "reason=\(reason)")
                } else {
                    h.check(false, "longline: large / long-line mode is on", "reason=none")
                }
                next()
            }
        })
        steps.append(step("longline-wrap-on") { next in
            Settings.shared.wrapLines = true
            guard let tab = dailyTab(app, fx.huge) else { h.check(false, "longline wrap-on: tab still open"); next(); return }
            // TextKit 2 rows (never textView.layoutManager: asking for it
            // drops the view to TextKit 1), the first ~200 layout
            // fragments, as CEDRIC_CHECK=longwrap on fix/0.6.1-longline-wrap.
            let m = dailyWrapRows(tab, fragments: 200)
            let padding = tab.textView.textContainer?.lineFragmentPadding ?? 0
            let available = m.container - 2 * padding
            let advance = ("0" as NSString).size(withAttributes: [.font: tab.textView.font ?? Settings.shared.font]).width
            let over = m.rows.filter { $0.maxX > m.container + 0.5 || m.originX + $0.maxX > m.visible + 0.5 }
            h.note(String(format: "longline wrap-on: %d rows in %d fragments, widest ends at %.1f, container %.1f, visible %.1f, scroller %@",
                          m.rows.count, m.fragments, m.rows.map(\.maxX).max() ?? 0, m.container, m.visible, m.scroller ? "y" : "n"))
            h.check(!m.rows.isEmpty && over.isEmpty, "longline: Wrap ON, no row ends past the wrapping width or the view's edge",
                    "\(over.count) of \(m.rows.count) rows over")
            h.check(!m.scroller, "longline: Wrap ON, no horizontal scroller")
            // Rows inside a fragment but its last (a chunk ends there): each
            // should reach the wrapping width within 1.5 characters.
            let inner = m.rows.filter { !$0.lastInFragment }
            let short = inner.filter { $0.width < available - 1.5 * advance }
            // The marker's input: the line was laid out in wrapped rows at all.
            h.check(tab.text.utf8.count == 5_000_000 && !inner.isEmpty && available > 100, "longline: Wrap ON, the 5 MB line is laid out in wrapped rows",
                    "\(tab.text.utf8.count) bytes, \(inner.count) inner rows, \(Int(available)) pt wide")
            // KNOWN BUG on main, fixed on fix/0.6.1-longline-wrap: a run
            // without spaces wraps only after '/', leaving ragged rows.
            // Remove this marker when that merges.
            h.knownBug(id: "longline-wrap", note: "Wrap ON on a 5 MB base64-like line breaks only after '/', rows end early (ragged)") {
                h.check(short.isEmpty, "longline: Wrap ON, each row of the line without spaces fills the wrapping width",
                        String(format: "%d of %d rows end early; first is %.1f of %.1f pt", short.count, inner.count, short.first?.width ?? 0, available))
            }
            next()
        })
        steps.append(step("longline-wrap-off") { next in
            Settings.shared.wrapLines = false
            guard let tab = dailyTab(app, fx.huge) else { h.check(false, "longline wrap-off: tab still open"); restoreWrap(); next(); return }
            _ = dailyWrapRows(tab, fragments: 50)
            guard let scroll = tab.textView.enclosingScrollView else { h.check(false, "longline wrap-off: has a scroll view"); restoreWrap(); next(); return }
            scroll.layout()
            let docW = scroll.documentView?.bounds.width ?? 0
            let visW = scroll.contentView.bounds.width
            h.check(scroll.hasHorizontalScroller, "longline: Wrap OFF shows a horizontal scroller")
            h.check(docW > visW + 1, "longline: Wrap OFF the document is wider than the view", String(format: "doc=%.1f vis=%.1f", docW, visW))
            let before = scroll.documentVisibleRect.origin.x
            scroll.contentView.scroll(to: NSPoint(x: min(docW - visW, 400), y: scroll.documentVisibleRect.origin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
            let after = scroll.documentVisibleRect.origin.x
            h.check(after > before + 1, "longline: Wrap OFF a programmed scroll actually moves horizontally", String(format: "x %.1f → %.1f", before, after))
            restoreWrap()
            next()
        })

        // 8. Untitled Markdown detect (known bug md-detect, fix/0.6.1-md-detect).
        steps.append(sync("md-detect-new") {
            app.newTab(nil)
        })
        steps.append(step("md-detect-type") { next in
            guard let tab = app.tabs.last, tab.doc.fileURL == nil else {
                h.check(false, "md-detect: a new untitled tab is front"); next(); return
            }
            focus(tab)
            tab.window?.makeFirstResponder(tab.textView)
            h.check(tab.doc.languageChoice.isAuto && (tab.doc.language == .plain || tab.statusBar.languageButton.title == "Plain Text"),
                    "md-detect: untitled starts auto/plain", "language=\(tab.doc.language) title=\(tab.statusBar.languageButton.title)")
            // Character by character so the 0.4 s sniff timer runs (a paste sniffs at once).
            if faults.contains("drop-typing") { h.note("fault drop-typing: the keystrokes are not sent") } else { type("**bold**") }
            DailyUseHarness.poll(1.2, every: 0.05, { tab.doc.language == .markdown }) { _ in
                // The marker's inputs, plainly: the keystrokes arrived in
                // this untitled tab and nobody chose a language by hand.
                // Dropped or misdirected typing is a FAIL, not the known bug.
                let arrived = tab.text == "**bold**" && tab.doc.fileURL == nil && app.tabs.last === tab
                h.check(arrived, "md-detect: the keystrokes arrived: line 1 of the untitled tab is **bold**",
                        "text “\(tab.text.prefix(40))” (\(tab.text.count) characters), first responder \(tab.window?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none")")
                h.check(tab.doc.languageChoice.isAuto, "md-detect: the language is still chosen automatically", "manual=\(tab.doc.languageIsManual)")
                guard arrived else {
                    h.note("md-detect: the known-bug marker is not evaluated (its input did not arrive; the FAIL above stands)")
                    next(); return
                }
                // LanguageDetector.MarkdownSignals.score is 0 for a single kind
                // (bold alone), so on main this stays Plain Text. That's the bug.
                h.knownBug(id: "md-detect", note: "typing **bold** on line 1 of an untitled tab does not switch to Markdown at the pause (fix/0.6.1-md-detect)") {
                    h.check(tab.doc.language == .markdown,
                            "md-detect: after a pause, **bold** on line 1 is Markdown (auto)",
                            "language=\(tab.doc.language) title=\(tab.statusBar.languageButton.title) manual=\(tab.doc.languageIsManual)")
                }
                next()
            }
        })

        // 6. Every Settings pane.
        steps.append(sync("settings-open", snapshot: false) {
            if let t = readmeTab { focus(t) }
            key(",", [.command])
            h.check(SettingsWindowController.shared?.window?.isVisible == true, "settings: ⌘, opens Settings")
        })
        // Settings › Cedric's height depends on where the AI runs (the
        // built-in model adds its download and launch rows): measured once
        // per engine this Mac offers, the tallest is what the marker checks.
        // The engine choice is written to CEDRIC_AI_DEFAULTS (a scratch
        // suite Scripts/daily-use.sh sets), so it is swept only then.
        var cedricHeights: [(engine: String, height: CGFloat, detail: String)] = []
        let sweepEngines = DevEnvironment.values["CEDRIC_AI_DEFAULTS"] != nil
        func shoot(_ w: NSWindow, _ name: String, _ next: @escaping () -> Void) {
            let path = out.appendingPathComponent(name).path
            DevHooks.write(window: w, to: path) {
                print("check: snapshot \(path)")
                next()
            }
        }
        for pane in SettingsPane.allCases {
            let n = 90 + (SettingsPane.allCases.firstIndex(of: pane) ?? 0)
            steps.append(DailyUseHarness.Step(name: "settings-\(pane.rawValue)", snapshot: false) { next in
                guard let sw = SettingsWindowController.shared, let w = sw.window else { next(); return }
                // Settings › Cedric lists the built-in models from
                // CEDRIC_MODELS_DIR, else from the real Application Support.
                if pane == .cedric && DevEnvironment.values["CEDRIC_MODELS_DIR"] == nil {
                    h.skip("settings Cedric", "no CEDRIC_MODELS_DIR (it would read the real ~/Library/Application Support/Cedric/Models); run Scripts/daily-use.sh")
                    next(); return
                }
                sw.select(pane)
                w.layoutIfNeeded()
                w.contentView?.layoutSubtreeIfNeeded()
                if pane == .cedric {
                    cedricHeights.append(dailySettingsPane(pane, sw, w, engine: sw.ai?.presetPopup.titleOfSelectedItem))
                } else {
                    _ = dailySettingsPane(pane, sw, w)
                }
                shoot(w, String(format: "%02d-settings-%@.png", n, pane.rawValue), next)
            })
        }
        steps.append(DailyUseHarness.Step(name: "settings-cedric-engines", snapshot: false) { next in
            guard let sw = SettingsWindowController.shared, let w = sw.window, let popup = sw.ai?.presetPopup, !cedricHeights.isEmpty else { next(); return }
            guard sweepEngines else {
                h.note("settings Cedric: one engine measured (no CEDRIC_AI_DEFAULTS scratch suite to sweep the others in)")
                next(); return
            }
            sw.select(.cedric)
            let original = popup.indexOfSelectedItem
            let others = popup.itemArray.indices.filter { $0 != original && popup.item(at: $0)?.isEnabled == true }
            h.note("settings Cedric: engines \(popup.itemArray.map { "\($0.title)\($0.isEnabled ? "" : " (unavailable)")" })")
            var k = 0
            @MainActor func one() {
                guard k < others.count else {
                    popup.selectItem(at: original)
                    popup.sendAction(popup.action, to: popup.target)
                    next(); return
                }
                let i = others[k]
                k += 1
                // As a click on the menu item: select, then the popup's action.
                popup.selectItem(at: i)
                popup.sendAction(popup.action, to: popup.target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    w.layoutIfNeeded()
                    w.contentView?.layoutSubtreeIfNeeded()
                    cedricHeights.append(dailySettingsPane(.cedric, sw, w, engine: popup.titleOfSelectedItem))
                    shoot(w, String(format: "%02d-settings-cedric-engine-%d.png", 93, i)) { one() }
                }
            }
            one()
        })
        steps.append(sync("settings-cedric-height", snapshot: false) {
            // The marker's input: the pane was measured.
            h.check(!cedricHeights.isEmpty && cedricHeights.allSatisfy { $0.height > 100 }, "settings Cedric: the pane was shown and measured for at least one engine",
                    "\(cedricHeights.map { "\($0.engine) \(Int($0.height))" })")
            guard !cedricHeights.isEmpty else { return }
            for c in cedricHeights { h.note(String(format: "settings Cedric with %@: window %.0f pt tall", c.engine, c.height)) }
            // KNOWN BUG on main, fixed on fix/cedric-settings-compact: the
            // Cedric pane is far too tall. Remove this marker when that merges.
            h.knownBug(id: "settings-cedric-tall", note: "Settings › Cedric is taller than 700 pt") {
                for c in cedricHeights {
                    h.check(c.height <= 700, "settings Cedric (\(c.engine)): the window is at most 700 pt tall", c.detail)
                }
            }
        })
        steps.append(sync("settings-close", snapshot: false) { SettingsWindowController.shared?.window?.close() })

        steps.append(sync("done", snapshot: false) {
            NSDocumentController.shared.clearRecentDocuments(nil)
            h.note(String(format: "pass wall time %.1f s", CFAbsoluteTimeGetCurrent() - t0))
            if DevEnvironment.values["CEDRIC_CHECK_OUT"] != nil { try? FileManager.default.removeItem(at: dir) }
        })
        h.run(steps, window: { app.currentTab?.window ?? app.currentViewerTab?.window ?? DevChecks.frontWindow })
    }

    /// One Settings pane: its height, and nothing cut off, truncated or
    /// overlapping.
    /// The Cedric pane's height is not asserted here but handed back (the
    /// caller asserts it inside its known-bug marker, for every engine).
    @discardableResult
    static func dailySettingsPane(_ pane: SettingsPane, _ sw: SettingsWindowController, _ w: NSWindow,
                                  engine: String? = nil) -> (engine: String, height: CGFloat, detail: String) {
        let h = DailyUseHarness.main
        let name = SettingsWindowController.paneTitle(pane) + (engine.map { " (\($0))" } ?? "")
        guard let content = w.contentView else { return ("", 0, "no content view") }
        let frameH = w.frame.height, contentH = w.contentRect(forFrameRect: w.frame).height
        let fit = sw.panes[pane]?.fittingContentSize ?? .zero
        h.note(String(format: "settings %@: window %.0f × %.0f pt (content %.0f tall), pane fittingSize %.0f × %.0f, screen visible height %.0f",
                      name, w.frame.width, frameH, contentH, fit.width, fit.height, w.screen?.visibleFrame.height ?? 0))
        let tallDetail = String(format: "%.0f pt (content %.0f, pane fits %.0f)", frameH, contentH, fit.height)
        if pane != .cedric {
            h.check(frameH <= 700, "settings \(name): the window is at most 700 pt tall", tallDetail)
        }
        func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(all) }
        let views = all(content).filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }
        func scrolls(_ v: NSView) -> Bool {
            guard let sv = v.enclosingScrollView, let doc = sv.documentView else { return false }
            return doc.frame.height > sv.contentSize.height + 1 || doc.frame.width > sv.contentSize.width + 1
        }
        let controls = views.compactMap { $0 as? NSControl }.filter { !scrolls($0) }
        func label(_ c: NSControl) -> String {
            let t = (c as? NSButton)?.title ?? (c as? NSTextField)?.stringValue ?? (c as? NSPopUpButton)?.titleOfSelectedItem ?? ""
            return "\(Swift.type(of: c))“\(t.prefix(40))”"
        }
        let bounds = content.bounds.insetBy(dx: -0.5, dy: -0.5)
        let outside = controls.filter { !NSContainsRect(bounds, $0.convert($0.bounds, to: content)) }
        h.check(outside.isEmpty, "settings \(name): every control lies inside the window",
                outside.map { "\(label($0)) at \(NSStringFromRect($0.convert($0.bounds, to: content)))" }.joined(separator: "; "))
        // Truncated text: a single-line label, button or popup narrower than its content.
        let truncated = controls.filter { c in
            guard let cell = c.cell, c.frame.width > 0 else { return false }
            if let f = c as? NSTextField {
                guard !f.isEditable, !f.stringValue.isEmpty, !cell.wraps || f.maximumNumberOfLines == 1 else { return false }
            } else if let p = c as? NSPopUpButton {
                // A popup's cellSize is its widest menu item's: compare the
                // shown title with the room the cell draws it in.
                guard let pc = p.cell as? NSPopUpButtonCell, let title = p.titleOfSelectedItem, !title.isEmpty else { return false }
                let need = (title as NSString).size(withAttributes: [.font: p.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
                return need > pc.titleRect(forBounds: p.bounds).width + 1
            } else if let b = c as? NSButton {
                guard !b.title.isEmpty else { return false }
            } else {
                return false
            }
            return cell.cellSize.width > c.bounds.width + 1
        }
        h.check(truncated.isEmpty, "settings \(name): no single-line text cut short",
                truncated.map { "\(label($0)) needs \(Int($0.cell!.cellSize.width)) pt, has \(Int($0.bounds.width))" }.joined(separator: "; "))
        // Overlapping sibling controls.
        var overlaps: [String] = []
        for parent in [content] + views {
            let kids = parent.subviews.compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 && !scrolls($0) }
            for (i, x) in kids.enumerated() {
                for y in kids[(i + 1)...] where x.frame.insetBy(dx: 1, dy: 1).intersects(y.frame.insetBy(dx: 1, dy: 1)) {
                    overlaps.append("\(label(x)) \(NSStringFromRect(x.frame)) and \(label(y)) \(NSStringFromRect(y.frame))")
                }
            }
        }
        h.check(overlaps.isEmpty, "settings \(name): no two controls overlap", overlaps.joined(separator: "; "))
        return (engine ?? name, frameH, tallDetail)
    }
}
