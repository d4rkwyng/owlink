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
///               binary held, .pcap/.gpx without wrong notices
///   3 preview   Markdown preview on and off, twice: width, no overlap,
///               the heading rendered, the editor's width back
///   4 recent    File › Open Recent lists the fixture files; choosing one
///               opens it (and from outside the folder: the sidebar)
///   5 folders   switching folders B → A: root, rows, selection, the
///               docked width, the tabs
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
///   settings-cedric-tall  fixed on fix/cedric-settings-compact
///   longline-wrap         fixed on fix/0.6.1-longline-wrap
///   md-detect             fixed on fix/0.6.1-md-detect
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
        click(o, at: NSPoint(x: rect.minX + 30, y: rect.midY))
        if o.selectedRow != r {
            if !dailyNotedClick {
                dailyNotedClick = true
                DailyUseHarness.main.note("synthetic click not taken by the inactive outline; selecting the row and opening as the click would")
            }
            o.selectRowIndexes([r], byExtendingSelection: false)
            s.activateSelection()
        }
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
            step("outside-file-open-path") { next in
                // File › Open…'s code path after its panel (openDocument: open(url, background: true)).
                let file = fx.bFiles[1]
                app.open(file, background: true)
                h.check(dailyTab(app, file) != nil, "outside: File › Open's path (open(_:background:)) opens other.txt from B")
                if let t = dailyTab(app, file) { sized(t) }
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
                            h.check(notices.allSatisfy { $0.hasPrefix("binary:") }, "click \(name): no other notice", "\(notices)")
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

        // 4. Open Recent.
        let ownRecents = Bundle.main.bundleIdentifier == "net.mindtricks.cedric.dailyuse"
        steps.append(sync("recent-menu") {
            guard ownRecents else {
                h.skip("recent", "this build shares the user's recent-documents list (bundle \(Bundle.main.bundleIdentifier ?? "-")); Scripts/daily-use.sh runs a copy with its own")
                return
            }
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
            guard ownRecents else { next(); return }
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
                    h.check(s?.selectedNode?.url.standardizedFileURL == file.standardizedFileURL, "recent: …and its row is selected in the sidebar",
                            "selected: \(s?.selectedNode?.name ?? "nothing")")
                    next()
                }
            }
        })
        steps.append(step("recent-outside") { next in
            guard ownRecents else { next(); return }
            // A recent file from outside the sidebar's folder (B): opened
            // once (the outside step's file fell off the list since), closed,
            // chosen in Open Recent.
            let file = fx.bFiles[2]
            app.open(file, background: true)
            dailyWindow(app, file)?.close()
            // (Fixed, that open moved the sidebar to B: back to A, so the
            // assertion below is about Open Recent's own path.)
            if s?.rootURL.standardizedFileURL != fx.a.standardizedFileURL { app.openFolder(fx.a) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                app.rebuildRecentMenu()
                guard let m = app.recentMenu, let i = m.items.firstIndex(where: { ($0.representedObject as? URL)?.standardizedFileURL == file.standardizedFileURL }) else {
                    h.check(false, "recent: list.csv (folder B) is in Open Recent", "\(app.recentMenu?.items.map(\.title) ?? [])"); next(); return
                }
                m.performActionForItem(at: i)
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
                // A file of A in front, the sidebar dragged wider as a user would.
                dailyClickRow(fx.readme)
                current = readmeTab
                if let t = current, let side = s {
                    t.window?.layoutIfNeeded()
                    t.split.setPosition(300, ofDividerAt: 0)
                    t.window?.layoutIfNeeded()
                    widthBefore = side.frame.width
                    h.note("folders: sidebar dragged to \(Int(widthBefore)) pt (saved width \(Int(side.width)))")
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
                h.check(app.currentTab === current, "folders: the same tab is still selected")
            },
            sync("folders-open-a", snapshot: false) { app.openFolder(fx.a) },
            waitListed(fx.a, "folders-a-listed"),
            step("folders-a") { next in
                // Selection: let the sidebar settle a turn, as a user would see it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    h.check(s?.rootURL.standardizedFileURL == fx.a.standardizedFileURL, "folders: the root is A again")
                    let names = dailyNames()
                    h.check(names.first == "sub" && names.contains("readme.md") && names.contains("server.log") && names.count == 22,
                            "folders: A's rows are listed (sub, then 21 files)", "\(names.count): \(names)")
                    h.check(s?.selectedNode?.url.standardizedFileURL == fx.readme.standardizedFileURL,
                            "folders: back on A, the selected tab's file (readme.md) is selected, as on a tab switch", "selected: \(s?.selectedNode?.name ?? "nothing")")
                    h.check(tabList() == tabsBefore, "folders: opening A again leaves the tabs alone", "\(tabsBefore.count) → \(tabList().count)")
                    let w = s?.frame.width ?? 0
                    h.check(abs(w - widthBefore) <= 2, "folders: the docked sidebar keeps its width opening A", "\(Int(w)) pt, was \(Int(widthBefore))")
                    next()
                }
            },
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
            tab.window?.layoutIfNeeded()
            tab.textView.layoutManager?.ensureLayout(for: tab.textView.textContainer ?? NSTextContainer())
            tab.textView.enclosingScrollView?.layout()
            let inset = tab.textView.textContainerInset.width
            let visible = tab.textView.visibleRect.width - inset * 2
            var maxUsed: CGFloat = 0
            var fragments = 0
            if let lm = tab.textView.layoutManager, let container = tab.textView.textContainer {
                let glyphEnd = lm.glyphRange(for: container)
                lm.enumerateLineFragments(forGlyphRange: glyphEnd) { _, used, _, _, _ in
                    fragments += 1
                    maxUsed = max(maxUsed, used.width)
                }
            }
            h.note(String(format: "longline wrap-on: %d fragments, max used %.1f pt, visible %.1f pt", fragments, maxUsed, visible))
            // known bug: on main, Wrap ON still lets the long line overflow the view.
            h.knownBug(id: "longline-wrap", note: "Wrap ON on a 5 MB one-line file leaves a fragment wider than the view (fix/0.6.1-longline-wrap)") {
                h.check(fragments > 1 && visible > 0 && maxUsed <= visible + 2, "longline: Wrap ON keeps every fragment within the view width", String(format: "fragments=%d maxUsed=%.1f visible=%.1f", fragments, maxUsed, visible))
            }
            next()
        })
        steps.append(step("longline-wrap-off") { next in
            Settings.shared.wrapLines = false
            guard let tab = dailyTab(app, fx.huge) else { h.check(false, "longline wrap-off: tab still open"); restoreWrap(); next(); return }
            tab.window?.layoutIfNeeded()
            tab.textView.layoutManager?.ensureLayout(for: tab.textView.textContainer ?? NSTextContainer())
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
            type("**bold**")
            DailyUseHarness.poll(1.2, every: 0.05, { tab.doc.language == .markdown }) { _ in
                // LanguageDetector.MarkdownSignals.score is 0 for a single kind
                // (bold alone), so on main this stays Plain Text. That's the bug.
                h.knownBug(id: "md-detect", note: "typing **bold** on line 1 of an untitled tab does not switch to Markdown at the pause (fix/0.6.1-md-detect)") {
                    h.check(tab.doc.language == .markdown && tab.doc.languageChoice.isAuto,
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
        for pane in SettingsPane.allCases {
            steps.append(DailyUseHarness.Step(name: "settings-\(pane.rawValue)", snapshot: false) { next in
                guard let sw = SettingsWindowController.shared, let w = sw.window else { next(); return }
                sw.select(pane)
                w.layoutIfNeeded()
                w.contentView?.layoutSubtreeIfNeeded()
                dailySettingsPane(pane, sw, w)
                let file = String(format: "%02d-settings-%@.png", 90 + (SettingsPane.allCases.firstIndex(of: pane) ?? 0), pane.rawValue)
                let path = out.appendingPathComponent(file).path
                DevHooks.write(window: w, to: path) {
                    print("check: snapshot \(path)")
                    next()
                }
            })
        }
        steps.append(sync("settings-close", snapshot: false) { SettingsWindowController.shared?.window?.close() })

        steps.append(sync("done", snapshot: false) {
            if ownRecents { NSDocumentController.shared.clearRecentDocuments(nil) }
            h.note(String(format: "pass wall time %.1f s", CFAbsoluteTimeGetCurrent() - t0))
            if DevEnvironment.values["CEDRIC_CHECK_OUT"] != nil { try? FileManager.default.removeItem(at: dir) }
        })
        h.run(steps, window: { app.currentTab?.window ?? app.currentViewerTab?.window ?? DevChecks.frontWindow })
    }

    /// One Settings pane: its height, and nothing cut off, truncated or
    /// overlapping.
    static func dailySettingsPane(_ pane: SettingsPane, _ sw: SettingsWindowController, _ w: NSWindow) {
        let h = DailyUseHarness.main
        let name = SettingsWindowController.paneTitle(pane)
        guard let content = w.contentView else { return }
        let frameH = w.frame.height, contentH = w.contentRect(forFrameRect: w.frame).height
        let fit = sw.panes[pane]?.fittingContentSize ?? .zero
        h.note(String(format: "settings %@: window %.0f × %.0f pt (content %.0f tall), pane fittingSize %.0f × %.0f, screen visible height %.0f",
                      name, w.frame.width, frameH, contentH, fit.width, fit.height, w.screen?.visibleFrame.height ?? 0))
        let tallCheck = {
            h.check(frameH <= 700, "settings \(name): the window is at most 700 pt tall", String(format: "%.0f pt (content %.0f, pane fits %.0f)", frameH, contentH, fit.height))
        }
        if pane == .cedric {
            // KNOWN BUG on main, fixed on fix/cedric-settings-compact: the
            // Cedric pane is far too tall. Remove this marker when that merges.
            h.knownBug(id: "settings-cedric-tall", note: "Settings › Cedric is taller than 700 pt", tallCheck)
        } else {
            tallCheck()
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
            } else if let b = c as? NSButton {
                guard !b.title.isEmpty || b is NSPopUpButton else { return false }
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
    }
}
