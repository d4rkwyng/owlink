import AppKit
import CedricCore
import CedricAI
import WebKit

/// Launch-time switches for screenshots, perf measurement and the launch
/// check. All off unless the variable is set; none is saved.
///
///   CEDRIC_SESSION_DIR=/path      session store location (keeps tests off the real session)
///   CEDRIC_NO_RESTORE=1           don't restore the saved session
///   CEDRIC_NO_SESSION_SAVE=1      don't write the session
///   CEDRIC_OPEN=a.md:b.swift      open these files at launch
///   CEDRIC_RESTORE_DELAY=0.25     seconds after the first frame before the unselected restored tabs are built
///   CEDRIC_LAUNCH_TRACE=1         print launch phase timings, type one key, quit (LaunchTrace.swift)
///   CEDRIC_THEME=dark             theme for this run (system/light/dark/tankard/dracula)
///   CEDRIC_PREVIEW=1              show the preview in the frontmost tab
///   CEDRIC_PREVIEW_JS=1           and allow JavaScript in it
///   CEDRIC_FIND=text              open the find bar with this text (CEDRIC_REPLACE=1: replace too,
///                                 CEDRIC_FIND_REGEX=1: as a regular expression)
///   CEDRIC_GOTO=12                put the caret on this line
///   CEDRIC_INVISIBLES=1           show invisibles for this run
///   CEDRIC_SNAPSHOT=/out.png      write the front window as a PNG (drawn with
///                                 cacheDisplay, so it works with the screen locked)
///   CEDRIC_SNAPSHOT_DELAY=2       seconds after launch (default 2)
///   CEDRIC_SNAPSHOT_SIZE=1100x700 window content size first
///   CEDRIC_SNAPSHOT_QUIT=1        quit after writing
///   CEDRIC_TEST_ZOOM_MENU=3       open the front tab's status-bar zoom pop-up after 3 s (screenshots)
///   CEDRIC_TEST_TYPE=text         type this at the end of the frontmost tab (session tests)
///   CEDRIC_TEST_TYPE_UNTITLED=t   open a new untitled tab and type this
///   CEDRIC_TEST_DETACH_PREVIEW=x,y,w,h  detach the front tab's preview to this frame (session tests)
///   CEDRIC_TEST_DOCK_PREVIEW=width  dock the front tab's Markdown preview at this width (session tests)
///   CEDRIC_TEST_CLOSE_LAST=1      then close the newest tab (as ⌘W does; session tests)
///   CEDRIC_TEST_SPLIT=line        split the front tab side by side, the second pane scrolled to `line` (session tests)
///   CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1  let closing the last window quit (off under the other test hooks)
///   CEDRIC_TEST_SHOW_SETTINGS=1   open the Settings window (session tests: it mustn't keep the app alive)
///   CEDRIC_TEST_WAIT_MARKER=/tmp/cedric-wait.x  `cedric -w` on the front tab (session tests)
///   CEDRIC_TEST_CLOSE_ALL=1       0.5 s in, close every tab one by one, as ⌘W does (session tests)
///   CEDRIC_TEST_CLOSE_WINDOW=1    0.5 s in, File › Close Window (⇧⌘W) on the newest tab's window (session tests)
///   CEDRIC_TEST_CLOSE_BUTTON=1    0.5 s in, click the red close button of the newest tab's window: a
///                                 mouse-down/up posted to this app only, not the real pointer (session tests)
///   CEDRIC_TEST_REOPEN_CLOSED=1   then reopen the newest closed tab (as ⇧⌘T does)
///   CEDRIC_TEST_EARLY_CLOSE=1     close the selected tab 0.5 s in, before deferred tabs are built
///   CEDRIC_TEST_EARLY_REOPEN=1    reopen the newest closed tab 0.5 s in, likewise
///   CEDRIC_SESSION_DUMP=1         print the restored tabs and closed tabs, and quit
///   CEDRIC_TEST_SAVE_AS_DIR=dir   with the dump: Save As each mixed-endings tab into dir (its name), the real write
///   CEDRIC_TYPE_CHECK=1           run the typing check (TypingCheck.swift), print results, quit
///   CEDRIC_LAUNCH_METRICS=1       print "metric launch_ms=…" (process start → first window drawn), and
///                                 "metric doc_ready_ms=…" when a file opened in the background has its tab drawn
///   CEDRIC_QUIT_AFTER_LAUNCH=1    quit right after that
///   CEDRIC_PERF_OPEN=/big.json    time open + colour + jump to end + typing, print metrics, quit
///   CEDRIC_PERF_TYPE=200          keystrokes for the typing measurement (default 200)
///   CEDRIC_PERF_LANGUAGE=shell    force a language for the perf file
///   CEDRIC_PERF_BIG=/long.txt     long-line / large-file measurement (LargeDocPerf.swift)
///   CEDRIC_OWL=1                  show the owl for this run (CEDRIC_OWL=0: hide it)
///   CEDRIC_OWL_PAUSE=3            seconds of no typing before the owl asks for hints
///   CEDRIC_OWL_INTERVAL=30        at most one hint query per this many seconds
///   CEDRIC_OWL_SLEEP_AFTER=300    seconds without typing before the owl dozes off
///   CEDRIC_OWL_RESET=1            forget "Don't show again" choices
///   CEDRIC_OWL_LOG=1              print each hint shown
///   CEDRIC_OWL_ASSUME_VISIBLE=1   treat windows as visible and the app as active (screen locked)
///   CEDRIC_OWL_CHECK=/out/dir     run the owl's in-process check (OwlCheck.swift) and quit
///   CEDRIC_OWL_SOURCE=rulesAndAI  the owl's hint source for this run, not saved
///   CEDRIC_AI_CHECK=/out/dir      run the local-AI check (AICheck.swift) and quit; with
///                                 CEDRIC_AI_FAKE=1.5 (fake provider) or CEDRIC_AI_CHECK_MODEL=id (live)
///   CEDRIC_BUILTIN_CHECK=/out/dir the built-in engine's download rows (BuiltInCheck.swift); pair
///                                 with CEDRIC_MODELS_DIR=<temp dir>
///   CEDRIC_AI*                    run-only AI settings: see AIStore in Owl/OwlAISettings.swift
///   CEDRIC_LLAMA_CHECK=1          print "dev hooks: on|off" (whether these switches are compiled in),
///                                 load the built-in engine's llama.framework (dlopen), print "llama: ok", quit
///   CEDRIC_DUMP_SHORTCUTS=1       print every menu shortcut, exit 1 on a clash
///   CEDRIC_LAYER_DUMP=/out/dir    dump the view/layer tree and render it three ways (RenderDump.swift);
///                                 CEDRIC_LAYER_DUMP_OWL=1 turns the owl on first via the menu action
///   CEDRIC_RENDER_CHECK=/out/dir  whole-window render check, every theme (Scripts/render-check.sh)
///   CEDRIC_CHECK=name             in-process checks of the editor tools (DevChecks.swift;
///                                 Scripts/tools-check.sh runs them all)
@MainActor
enum DevHooks {
    static let env = DevEnvironment.values

    static func metric(_ name: String, _ value: Double) {
        print(String(format: "metric %@=%.1f", name, value))
        fflush(stdout)
    }

    /// Process start time, from the kernel.
    static func processStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }

    static func now() -> Double {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    /// Variables that don't inspect or drive the tabs after launch.
    static let launchOnly: Set<String> = ["CEDRIC_SESSION_DIR", "CEDRIC_NO_SESSION_SAVE", "CEDRIC_NO_RESTORE", "CEDRIC_OPEN",
                                          "CEDRIC_THEME", "CEDRIC_LAUNCH_TRACE", "CEDRIC_RESTORE_DELAY",
                                          "CEDRIC_TEST_EARLY_CLOSE", "CEDRIC_TEST_EARLY_REOPEN"]

    /// Closing the last window quits only in a plain run (the hooks open
    /// and close tabs freely), or when a session test asks for it.
    static let allowsQuitOnLastClose = env["CEDRIC_TEST_QUIT_ON_LAST_CLOSE"] == "1"
        || !env.keys.contains { $0.hasPrefix("CEDRIC_") && !launchOnly.contains($0) }

    static func afterLaunch(_ app: AppDelegate) {
        // The hooks below expect every restored tab to exist now, not
        // after the first frame (AppDelegate.restoreNextPending).
        if env.keys.contains(where: { $0.hasPrefix("CEDRIC_") && !launchOnly.contains($0) }) { app.finishRestore() }
        // Session check: close the selected tab, or reopen the newest closed
        // one, half a second in, while the other restored tabs are still
        // waiting to be built (run with a long CEDRIC_RESTORE_DELAY).
        if env["CEDRIC_TEST_EARLY_CLOSE"] == "1" || env["CEDRIC_TEST_EARLY_REOPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if env["CEDRIC_TEST_EARLY_CLOSE"] == "1", let tab = app.currentTab ?? app.tabs.last {
                    // Keep the closed tab's window and views and draw them
                    // after close, while the deferred tabs are built (a
                    // closed controller's views drawing once aborted the app).
                    let views: [NSView?] = [tab.window?.contentView, tab.gutter, tab.textView]
                    let window = tab.window
                    window?.performClose(nil)
                    for k in 1...5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(k)) {
                            window?.display()
                            for v in views { v?.needsDisplay = true; v?.display() }
                        }
                    }
                }
                if env["CEDRIC_TEST_EARLY_REOPEN"] == "1" { app.reopenClosedTab(nil) }
            }
        }
        if let s = env["CEDRIC_SNAPSHOT_SIZE"]?.split(separator: "x"), s.count == 2, let w = Double(s[0]), let h = Double(s[1]) {
            for t in app.tabs { t.window?.setContentSize(NSSize(width: w, height: h)) }
        }
        if let tab = app.currentTab ?? app.tabs.last {
            if env["CEDRIC_PREVIEW"] == "1" { tab.togglePreview() }
            if env["CEDRIC_PREVIEW_JS"] == "1" { tab.previewAllowsJavaScript = true }
            if let line = env["CEDRIC_GOTO"].flatMap(Int.init) { tab.goToLine(line) }
            if let f = env["CEDRIC_FIND"] {
                tab.showFindBar(replace: env["CEDRIC_REPLACE"] == "1")
                tab.findBar.findField.stringValue = f
                if env["CEDRIC_FIND_REGEX"] == "1" { tab.findBar.regexBox.state = .on }
                tab.findBar.onChange?()
            }
        }
        // Session tests: type into the frontmost tab and/or a new untitled
        // tab through the normal editing path, or print what was restored.
        if let t = env["CEDRIC_TEST_TYPE"], let tab = app.currentTab ?? app.tabs.last {
            tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
            tab.textView.insertText(t, replacementRange: tab.textView.selectedRange())
        }
        if let t = env["CEDRIC_TEST_TYPE_UNTITLED"] {
            app.newTab(nil)
            if let tab = app.tabs.last { tab.textView.insertText(t, replacementRange: NSRange(location: 0, length: 0)) }
        }
        // Session check: detach the front tab's preview to this frame ("x,y,w,h").
        if let f = env["CEDRIC_TEST_DETACH_PREVIEW"]?.split(separator: ",").compactMap({ Double($0) }), f.count == 4,
           let tab = app.currentTab ?? app.tabs.last {
            tab.detachPreview()
            tab.previewWindow?.window?.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true)
        }
        // Session check: dock the front tab's Markdown preview at this width (points).
        // Once now and again after the first frame, so a split that has no
        // size yet still ends at that width before the test quits.
        if let w = env["CEDRIC_TEST_DOCK_PREVIEW"].flatMap(Double.init), w > 0,
           let tab = app.currentTab ?? app.tabs.last, tab.doc.language == .markdown {
            tab.window?.setContentSize(NSSize(width: 1000, height: 640))
            let apply: @MainActor (EditorWindowController) -> Void = { tab in
                tab.window?.layoutIfNeeded()
                if tab.previewPane == nil { tab.togglePreview() }
                tab.applyDockedPreviewWidth(w)
            }
            apply(tab)
            AfterFirstFrame.run { [weak tab] in
                guard let tab else { return }
                apply(tab)
                DispatchQueue.main.async { [weak tab] in
                    guard let tab else { return }
                    apply(tab)
                }
            }
        }
        if let delay = env["CEDRIC_TEST_ZOOM_MENU"].flatMap(Double.init), let tab = app.currentTab ?? app.tabs.last {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tab] in tab?.statusBar.zoom.performClick(nil) }
        }
        if let l = env["CEDRIC_TEST_SPLIT"].flatMap(Int.init), let tab = app.currentTab ?? app.tabs.last {
            // Once the window is on screen and the panes have their size.
            AfterFirstFrame.run { [weak tab] in
                guard let tab else { return }
                tab.splitPanes(sideBySide: true, ratio: 0.4, focusSecond: true)
                DispatchQueue.main.async { [weak tab] in
                    guard let tab, let s = tab.splitEditor else { return }
                    tab.scrollToLine(l, in: s.second)
                    s.second.anchorLine = l
                    tab.onChange?(tab)
                }
            }
        }
        if env["CEDRIC_TEST_CLOSE_LAST"] == "1", let tab = app.tabs.last { tab.window?.performClose(nil) }
        if env["CEDRIC_TEST_SHOW_SETTINGS"] == "1" { SettingsWindowController.show() }
        if let marker = env["CEDRIC_TEST_WAIT_MARKER"], let tab = app.currentTab ?? app.tabs.last { app.addWaiter(marker, for: tab) }
        if env["CEDRIC_TEST_CLOSE_ALL"] == "1" {
            // One at a time, a run-loop turn apart, as a user's ⌘W presses.
            func closeNext() {
                let docs = app.tabs.compactMap(\.window) + app.viewerTabs.compactMap(\.window)
                guard let w = docs.first else { return }
                w.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { closeNext() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { closeNext() }
        }
        if env["CEDRIC_TEST_CLOSE_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let w = app.tabs.last?.window { app.closeDocumentWindows(in: w) }
            }
        }
        if env["CEDRIC_TEST_CLOSE_BUTTON"] == "1" {
            // AppKit closes the whole tab group only for a real click on the
            // button (performClick closes one tab), so post the click itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let w = app.tabs.last?.window, let btn = w.standardWindowButton(.closeButton) else { return }
                let p = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: nil)
                // Read on the main actor here: Swift 6.1 doesn't infer the
                // closure's isolation for the nested func below.
                let number = w.windowNumber
                func click(_ type: NSEvent.EventType, _ n: Int) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: number, context: nil, eventNumber: n, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                }
                guard let down = click(.leftMouseDown, 1), let up = click(.leftMouseUp, 2) else { return }
                NSApp.postEvent(up, atStart: false)
                NSApp.postEvent(down, atStart: true)
            }
        }
        if env["CEDRIC_TEST_REOPEN_CLOSED"] == "1" { app.reopenClosedTab(nil) }
        if env["CEDRIC_SESSION_DUMP"] == "1" {
            // A preview (detached or docked) is restored after the first frame: none may exist yet.
            let earlyPreviews = app.tabs.filter { $0.previewPane != nil }.count
            let earlyFolder = FolderSidebar.shared != nil ? 1 : 0
            let earlySplits = app.tabs.filter(\.isSplit).count
            AfterFirstFrame.run { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Windows in on-screen order, tabs in tab-bar order.
                for t in app.tabGroups().joined() {
                    let body = t.text.replacingOccurrences(of: "\n", with: "\\n")
                    print("tab: name=\(t.doc.displayName) file=\(t.doc.fileURL?.path ?? "-") dirty=\(t.doc.isDirty) language=\(t.doc.language.rawValue) text=\(body.prefix(60))")
                    // Whether ⌘S would ask first (the file differs from the tab's stamp).
                    if let url = t.doc.fileURL { print("stamp: name=\(t.doc.displayName) asks=\(t.fileChangedOnDisk(url))") }
                    // A mixed file's own breaks: the bytes ⌘S would write (LineBreaks).
                    if t.doc.lineBreaks != nil, let data = t.doc.encoded(t.text) {
                        print("breaks: name=\(t.doc.displayName) saves=\(String(decoding: data, as: UTF8.self).debugDescription)")
                        // The bytes Save As really writes, for the script to read back.
                        if let dir = env["CEDRIC_TEST_SAVE_AS_DIR"] {
                            let target = URL(fileURLWithPath: dir).appendingPathComponent(t.doc.displayName)
                            EditorWindowController.checkSaveAsURL = target
                            print("savedas: name=\(t.doc.displayName) ok=\(t.saveAs()) path=\(target.path)")
                        }
                    }
                }
                for v in app.viewerTabs { print("viewer: file=\(v.fileURL.path)") }
                if let f = app.folderSessionState {
                    print("folder: path=\(f.path) built=\(FolderSidebar.shared != nil) shown=\(FolderSidebar.shared?.isShown ?? false) "
                          + "expanded=\((f.expanded ?? []).joined(separator: ",")) width=\(Int(f.width ?? 0)) before-first-frame=\(earlyFolder)")
                }
                for c in app.closedTabs {
                    let body = (c.hasBuffer ? app.store.readBuffer(c.id) ?? "<missing buffer>" : "-").replacingOccurrences(of: "\n", with: "\\n")
                    print("closed: name=\(c.untitledName ?? "-") file=\(c.path ?? "-") unsaved=\(c.hasBuffer) text=\(body.prefix(60))")
                }
                for t in app.tabs {
                    guard let s = t.splitEditor else { continue }
                    print("split: name=\(t.doc.displayName) sideBySide=\(s.sideBySide) ratio=\(String(format: "%.2f", s.ratio)) "
                          + "top2=\(t.topLine(in: s.second)) secondActive=\(t.textView === s.second.textView) "
                          + "layoutManagers=\(t.primaryTextView.contentStorage?.textLayoutManagers.count ?? 0) before-first-frame=\(earlySplits)")
                }
                for t in app.tabs where t.previewPane != nil {
                    let f = t.previewWindow?.window?.frame ?? .zero
                    let docked = t.previewPane?.superview === t.split
                    if docked { t.split.layoutSubtreeIfNeeded() }
                    let width = docked ? Int((t.previewPane?.frame.width ?? 0).rounded()) : 0
                    print("preview: name=\(t.doc.displayName) detached=\(t.previewDetached) visible=\(t.previewWindow?.window?.isVisible ?? false) "
                          + "title=\(t.previewWindow?.window?.title ?? "-") frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)) "
                          + "before-first-frame=\(earlyPreviews) docked=\(docked) width=\(width)")
                }
                exit(0)
            } }
        }
        if env["CEDRIC_LAUNCH_METRICS"] == "1" {
            // The window has been ordered front; measure when it has drawn.
            DispatchQueue.main.async {
                NSApp.windows.filter(\.isVisible).forEach { $0.displayIfNeeded() }
                metric("launch_ms", (now() - processStart()) * 1000)
                let quit = { if env["CEDRIC_QUIT_AFTER_LAUNCH"] == "1" { exit(0) } }
                guard !app.backgroundOpens.isEmpty else { quit(); return }
                // A big file opened at launch reads in the background: also
                // when its tab has drawn, editable ("doc_ready_ms"), then quit.
                app.whenBackgroundOpensDone.append {
                    DispatchQueue.main.async {
                        NSApp.windows.filter(\.isVisible).forEach { $0.displayIfNeeded() }
                        metric("doc_ready_ms", (now() - processStart()) * 1000)
                        quit()
                    }
                }
            }
        }
        if env["CEDRIC_TYPE_CHECK"] == "1" {
            // From a timer, not a main-queue block: the check spins the run
            // loop, and main-queue work (deferred colouring) can't run
            // inside a main-queue block.
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in MainActor.assumeIsolated { TypingCheck.run(app) } }
        }
        if let path = env["CEDRIC_PERF_OPEN"] { DispatchQueue.main.async { perfOpen(app, path) } }
        if let path = env["CEDRIC_PERF_BIG"] {
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in MainActor.assumeIsolated { LargeDocPerf.run(app, path) } }
        }
        if env["CEDRIC_OWL_ASSUME_VISIBLE"] == "1" {
            OwlController.assumeVisible = true
            for t in app.tabs { t.owl?.updateTimer() }
            OwlHub.shared.schedule()
        }
        if env["CEDRIC_OWL_LOG"] == "1" {
            OwlHub.shared.onPresent = { _, h in print("owl: shown \(h.id): \(h.title)"); fflush(stdout) }
        }
        if let out = env["CEDRIC_OWL_CHECK"], !out.isEmpty { OwlCheck.run(app, out: out) }
        if let out = env["CEDRIC_AI_CHECK"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { AICheck.run(app, out: out) } }
        }
        if let out = env["CEDRIC_BUILTIN_CHECK"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { BuiltInCheck.run(app, out: out) } }
        }
        if let out = env["CEDRIC_SNAPSHOT"], !out.isEmpty { scheduleSnapshot(out) }
        if env["CEDRIC_LLAMA_CHECK"] == "1" {
            // Whether this build has the dev/check switches compiled in:
            // launch-check.sh --release fails unless "off" (a check build
            // must never ship).
            print("dev hooks: \(DevEnvironment.checksEnabled ? "on" : "off")")
            let problem = LlamaRuntime.loadCheck()
            print(problem.map { "llama: FAIL \($0)" } ?? "llama: ok")
            fflush(stdout)
            exit(problem == nil ? 0 : 1)
        }
        if env["CEDRIC_DUMP_SHORTCUTS"] == "1" { exit(DevChecks.dumpShortcuts() ? 0 : 1) }
        if let check = env["CEDRIC_CHECK"] { DevChecks.start(check, app) }
        if let out = env["CEDRIC_LAYER_DUMP"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { RenderDump.run(app, out: out) } }
        }
        if let out = env["CEDRIC_RENDER_CHECK"], !out.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { RenderDump.check(app, out: out) } }
        }
    }

    // MARK: Perf

    static func perfOpen(_ app: AppDelegate, _ path: String) {
        let url = URL(fileURLWithPath: path)
        let t0 = now()
        guard let (d, _) = try? EditorDocument.read(url) else { print("perf: can't read \(path)"); exit(1) }
        let t1 = now()
        metric("read_decode_ms", (t1 - t0) * 1000)
        let doc = EditorDocument(fileURL: url, untitledName: url.lastPathComponent)
        doc.apply(d)
        doc.languageChoice = .forFile(named: url.lastPathComponent, content: d.text)
        if let l = env["CEDRIC_PERF_LANGUAGE"].flatMap(Language.init(rawValue:)) { doc.languageChoice.choose(l) }
        let tab = app.makeTab(doc, text: d.text)
        let t2 = now()
        metric("load_text_ms", (t2 - t1) * 1000)
        tab.window?.displayIfNeeded()
        let colored = tab.colorizer.colorViewport()
        tab.window?.displayIfNeeded()
        let t3 = now()
        metric("first_paint_ms", (t3 - t2) * 1000)
        metric("open_total_ms", (t3 - t0) * 1000)
        print("perf: language=\(doc.language.rawValue) lines=\(tab.lineIndex.lineCount) utf16=\(tab.lineIndex.length) first_colored_lines=\(colored)")

        // Jump to the end and colour there (stateful languages scan the whole file once).
        let t4 = now()
        tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.length, length: 0))
        tab.reveal(NSRange(location: tab.lineIndex.length, length: 0))
        tab.window?.displayIfNeeded()
        tab.colorizer.colorViewport()
        tab.window?.displayIfNeeded()
        metric("jump_to_end_ms", (now() - t4) * 1000)

        // Typing: keystrokes in the middle of the file, each followed by
        // the work a keystroke triggers before the next frame (index
        // update, recolour, layout and display).
        let mid = tab.lineIndex.starts[tab.lineIndex.lineCount / 2]
        tab.textView.setSelectedRange(NSRange(location: mid, length: 0))
        tab.reveal(NSRange(location: mid, length: 0))
        tab.window?.displayIfNeeded()
        tab.colorizer.colorViewport()
        let n = env["CEDRIC_PERF_TYPE"].flatMap(Int.init) ?? 200
        var samples: [Double] = []
        let keys = Array("let value = 42 // typing\n")
        for k in 0..<n {
            let s = now()
            tab.textView.insertText(String(keys[k % keys.count]), replacementRange: tab.textView.selectedRange())
            tab.colorizer.colorViewport()
            tab.window?.displayIfNeeded()
            samples.append((now() - s) * 1000)
        }
        samples.sort()
        metric("type_median_ms", samples[samples.count / 2])
        metric("type_p95_ms", samples[Int(Double(samples.count) * 0.95)])
        metric("type_max_ms", samples.last ?? 0)
        print("perf: textkit2=\(tab.textView.textLayoutManager != nil)")
        exit(0)
    }

    // MARK: Snapshot

    static func dump(_ v: NSView, _ depth: Int) {
        guard depth < 7 else { return }
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
        v.subviews.forEach { dump($0, depth + 1) }
    }

    static func scheduleSnapshot(_ out: String) {
        let delay = env["CEDRIC_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                print("snapshot: no window"); exit(1)
            }
            if env["CEDRIC_SNAPSHOT_LAYOUT"] == "1" {
                dump(window.contentView!, 0)
            }
            write(window: window, to: out) {
                print("snapshot: wrote \(out); textkit2=\(((window.windowController as? EditorWindowController)?.textView.textLayoutManager) != nil)")
                if env["CEDRIC_SNAPSHOT_QUIT"] == "1" { exit(0) }
            }
        }
    }

    /// Renders part of a view at 2x (also when the screen is locked and
    /// reports 1x).
    static func render(_ v: NSView, _ rect: NSRect, ignoringOpacity: Bool = false) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        if ignoringOpacity, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            v.displayIgnoringOpacity(rect, in: ctx)
        } else {
            v.cacheDisplay(in: rect, to: rep)
        }
        return rep
    }

    /// Draws the window (title bar and tabs included) into a PNG, whole:
    /// one cacheDisplay of the frame view, so a view painting over another
    /// shows up as it does on screen. (It used to render the text view,
    /// gutter and owl on their own and paste them on top, which hid the
    /// status bar painting over the whole editor in test build 2.) Web
    /// views draw out of process and are captured with takeSnapshot.
    static func write(window: NSWindow, to path: String, done: @escaping @MainActor () -> Void) {
        guard let content = window.contentView, let root = content.superview ?? window.contentView else { done(); return }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        guard let base = render(root, root.bounds) else { done(); return }
        var overlays: [(NSRect, NSImageRep, CGFloat)] = []
        var webs: [WKWebView] = []
        func collect(_ v: NSView) {
            guard !v.isHidden else { return }
            if let w = v as? WKWebView { webs.append(w); return }
            v.subviews.forEach(collect)
        }
        collect(content)
        var remaining = webs.count
        func finish() {
            let out = NSImage(size: root.bounds.size)
            out.lockFocus()
            base.draw(in: root.bounds)
            for (frame, rep, alpha) in overlays { rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil) }
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            done()
        }
        if webs.isEmpty { finish(); return }
        for w in webs {
            let frame = w.convert(w.bounds, to: root)
            w.takeSnapshot(with: nil) { img, _ in
                MainActor.assumeIsolated {
                    if let img, let rep = img.representations.first { overlays.append((frame, rep, 1)) }
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
        }
    }
}
