import AppKit
import CedricCore

/// The last Replace in Files, for Edit › Undo Replace in Files (kept
/// until the app quits, or until it is undone).
@MainActor
enum ReplaceInFiles {
    struct TabEdit {
        weak var tab: EditorWindowController?
        let url: URL
        let before: String
        let after: String
    }

    struct Operation {
        var diskOperation: UUID?
        var tabEdits: [TabEdit]
    }

    static var last: Operation?
    /// Replace All's disk writes (or an undo's) are under way (on `queue`):
    /// no undo, no second Replace All until they land.
    static var writing = false
    /// Where Replace All reads, backs up and writes the files: off the main
    /// thread, one operation at a time.
    nonisolated static let queue = DispatchQueue(label: "owlink.replace-in-files.write", qos: .userInitiated)
    /// The checks slow each file of each stage down, to see the app while it writes.
    static var writeDelayForChecks: TimeInterval = 0
    /// Whether the last Replace All wrote on the main thread (the checks).
    static var lastWriteOnMain: Bool?
    /// Whether the last undo read and wrote on the main thread (the checks).
    static var lastUndoOnMain: Bool?

    /// Quitting: the writes under way finish first (each is atomic, but
    /// the undo manifest is saved once they are done).
    static func waitForWrites() { queue.sync {} }
    /// Where originals go before a write. The check points it at its temp folder.
    static var store = ReplaceUndoStore(root: DevEnvironment.values["CEDRIC_REPLACE_UNDO_DIR"].map { URL(fileURLWithPath: $0) }
        ?? ReplaceUndoStore.defaultRoot)
    static let actionName = String(localized: "Replace in Files")

    /// "a, b and 2 more".
    static func names(_ urls: [URL]) -> String {
        let n = urls.map(\.lastPathComponent)
        return n.count <= 3 ? n.joined(separator: ", ") : n.prefix(2).joined(separator: ", ") + String(localized: " and \(n.count - 2) more")
    }

    static func skippedText(_ s: [SkippedFile]) -> String {
        guard !s.isEmpty else { return "" }
        let parts = s.prefix(4).map { "\($0.relativePath) (\($0.why))" }
        return " " + String(localized: "Skipped: \(parts.joined(separator: ", "))\(s.count > 4 ? "…" : "").")
    }
}

/// Replace in Files (0.2.0): Edit › Replace in Files… (⌥⇧⌘F) opens the
/// Find in Files panel in replace mode; Edit › Undo Replace in Files puts
/// back the last operation's files (plan-0.2.0.md §2).
extension AppDelegate {
    @objc func replaceInFilesMenu(_ sender: Any?) {
        showFindInFiles(replace: true)
    }

    @objc func undoReplaceInFilesMenu(_ sender: Any?) {
        // The panel shows the undo's progress and locks its controls, as for Replace All.
        if let p = findInFiles, p.isShown {
            p.undoReplace()
            return
        }
        // Panel hidden: a notice bar in the front tab shows the progress,
        // then the result (with Dismiss), so the undo is never silent.
        guard let tab = currentTab ?? tabs.last else {
            undoLastReplace { message in
                guard !message.isEmpty, DevEnvironment.values["CEDRIC_CHECK"] == nil else { return }
                let a = NSAlert()
                a.messageText = ReplaceInFiles.actionName
                a.informativeText = message
                if let w = NSApp.keyWindow, w.attachedSheet == nil { a.beginSheetModal(for: w) } else { a.runModal() }
            }
            return
        }
        weak var notified = tab
        tab.showNotice(String(localized: "Undoing Replace in Files…"), buttons: [])
        undoLastReplace(progress: { p in
            guard p.total > 0, let bar = notified?.noticeBar, !bar.isHidden else { return }
            bar.label.stringValue = String(localized: "Undoing Replace in Files… \(p.done) of \(p.total) files")
        }, done: { message in
            guard let t = notified else { return }
            if message.isEmpty { t.noticeBar?.isHidden = true; return }
            t.showNotice(message, buttons: [])
            NSAccessibility.post(element: t.noticeBar as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        })
    }

    func validateReplaceInFilesItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        // Not in a viewer tab (PDF, image…), like Find in Files.
        case #selector(replaceInFilesMenu(_:)): return currentViewerTab == nil && !tabs.isEmpty
        case #selector(undoReplaceInFilesMenu(_:)): return ReplaceInFiles.last != nil && !ReplaceInFiles.writing
        default: return nil
        }
    }

    /// The open text tab at `url`'s file, if any (see `tabFinder`).
    func tab(showing url: URL) -> EditorWindowController? { tabFinder()(url)?.tab }

    /// An open tab found for a planned file, the identity of the file at
    /// that path when it was looked up, and the identity of the file the
    /// tab's own URL led to then.
    struct OpenTab {
        let tab: EditorWindowController
        let fileIDNow: DiskStamp.FileID?
        let tabURLFileIDNow: DiskStamp.FileID?
    }

    /// Finds the open text tab for a file, for many files in a row (the
    /// tabs as they are now). The same file is decided only by file-system
    /// identity: the file the URL leads to now (device and inode) against
    /// the identity each tab recorded when it read or saved its file (its
    /// DiskStamp), not the tab's path alone; a tab found through another
    /// name is also checked against the file its own URL leads to now (see
    /// below). So a tab opened under another spelling of the file, or a
    /// hard link to it, is found
    /// (Astra batch 17v), and a tab at the same path that holds the text of
    /// a file replaced there since (a sync client, a restore) is not taken
    /// for it (Sol 21v-3). The resolved paths' exact bytes only pick which
    /// tab to try first; a tab at the same path whose recorded file isn't
    /// the one there now (or none is) is still returned, not current, so
    /// that file is refused rather than written behind it.
    ///
    /// Not every tab records an identity. A text open or a save takes one
    /// from the file it read or wrote. A tab brought back with unsaved text
    /// (a session restore, Reopen Closed Tab) from an entry saved before
    /// 0.5.4 keeps a date-only stamp with none, and so does a restored tab
    /// whose link stamp is unverified. Such a tab is found only on an exact
    /// match of the resolved path, and then it is not taken for its file:
    /// a preview plans neither it nor the disk, and Replace All skips it
    /// (out of date). Through a distinct hard-link name such a tab cannot
    /// match (it has no identity to compare), so that name has no open tab
    /// and is planned from disk.
    ///
    /// A tab found through another name (an alias hit) is taken only when
    /// three agree: the file at the asked URL now, the file the tab's own
    /// URL leads to now, and the file the tab recorded. Hard links A and B,
    /// a dirty tab on A, then a sync client replaces A: B still names the
    /// file the tab recorded, but the tab is A's, and A is another file
    /// now. That tab is not B's (Astra batch 23v), so B has no open tab: a
    /// plan made from the tab's text is skipped, and a new preview reads B
    /// from disk.
    func tabFinder() -> (URL) -> OpenTab? {
        let open: [(tab: EditorWindowController, url: URL, path: String, id: DiskStamp.FileID?)] = tabs.compactMap { t in
            t.doc.fileURL.map { (t, $0, $0.standardizedFileURL.resolvingSymlinksInPath().path, t.doc.diskStamp.identity) }
        }
        return { url in
            guard !open.isEmpty else { return nil }
            let want = url.standardizedFileURL.resolvingSymlinksInPath().path
            let now = DiskStamp.of(url)?.identity
            let byBytes = open.first { FolderTree.sameBytes($0.path, want) }
            // At the same path, the tab's URL leads where `url` does.
            if let now {
                if let b = byBytes, b.id == now { return OpenTab(tab: b.tab, fileIDNow: now, tabURLFileIDNow: now) }
                for t in open where t.id == now && !FolderTree.sameBytes(t.path, want) {
                    // The tab's own URL must still lead to the file it recorded.
                    let tabNow = DiskStamp.of(t.url)?.identity
                    if tabNow == now { return OpenTab(tab: t.tab, fileIDNow: now, tabURLFileIDNow: tabNow) }
                }
            }
            return byBytes.map { OpenTab(tab: $0.tab, fileIDNow: now, tabURLFileIDNow: now) }
        }
    }

    /// The text of the files in `urls` that are open in a tab, by
    /// standardized path, with the identity of the file each tab recorded.
    func openBuffers(for urls: [URL]) -> [String: OpenBuffer] {
        // Tabs restored lazily from the session are built first, so none is missed.
        finishRestore()
        let find = tabFinder()
        var out: [String: OpenBuffer] = [:]
        for u in urls {
            if let o = find(u) { out[u.standardizedFileURL.path] = OpenBuffer(text: o.tab.text, fileID: o.tab.doc.diskStamp.identity) }
        }
        return out
    }

    /// Replace All on the checked matches: open tabs get one undoable edit
    /// each (not saved), here on the main thread; the other files are
    /// written by FileReplace.apply on `ReplaceInFiles.queue`, with
    /// `progress` on the main thread. `done` gets what the panel shows,
    /// once every write has landed.
    func applyReplace(_ plan: ReplacePlan, progress: @escaping @MainActor (ReplaceProgress) -> Void = { _ in },
                      done: @escaping @MainActor (String) -> Void) {
        guard !ReplaceInFiles.writing else { done(String(localized: "The last replace is still being written.")); return }
        finishRestore()
        var tabEdits: [ReplaceInFiles.TabEdit] = []
        var diskFiles: [ReplaceFile] = []
        var skipped: [SkippedFile] = []
        var tabReplacements = 0
        let find = tabFinder()
        for f in plan.files where !f.edits.isEmpty {
            // No tab by bytes or by identity: only then is the file closed.
            guard let open = find(f.url) else {
                if f.disk != nil { diskFiles.append(f) } else {
                    // Planned from a tab that has closed since: its file wasn't checked on disk.
                    skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .changedSincePreview))
                }
                continue
            }
            // Open now (or opened since the preview): edit the buffer, never the file behind it.
            // Only a tab that read or saved the file there now, the file
            // the plan was made for (by identity), with exactly the planned
            // text (UTF-16 units, not Swift's canonical equality), so the
            // planned ranges land on the planned characters.
            let tab = open.tab, before = tab.text
            if let refusal = FileReplace.tabRefusal(f, tabText: before, tabFileID: tab.doc.diskStamp.identity,
                                                           tabURLFileIDNow: open.tabURLFileIDNow, fileIDNow: open.fileIDNow) {
                skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: refusal)); continue
            }
            guard tab.textView.isEditable, tab.tail == nil, let (span, new) = FileReplace.span(f.edits, in: before) else {
                skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .readOnlyTab)); continue
            }
            guard tab.replaceAsOneStep(span, with: new, actionName: ReplaceInFiles.actionName) else {
                skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: .readOnlyTab)); continue
            }
            tab.colorizer.scheduleViewport()
            tabEdits.append(.init(tab: tab, url: f.url, before: before, after: tab.text))
            tabReplacements += f.edits.count
        }
        let finish: @MainActor (ReplaceReport) -> Void = { report in
            skipped += report.skipped
            if report.operation != nil || !tabEdits.isEmpty {
                ReplaceInFiles.last = .init(diskOperation: report.operation, tabEdits: tabEdits)
            }
            let total = report.replacements + tabReplacements
            let files = report.written.count + tabEdits.count
            var s = total == 1 ? String(localized: "Replaced 1 match in \(files) file.") : String(localized: "Replaced \(total) matches in \(files) files.")
            if !tabEdits.isEmpty {
                s += " " + String(localized: "In open tabs, not saved: \(ReplaceInFiles.names(tabEdits.map(\.url))).")
            }
            s += ReplaceInFiles.skippedText(skipped)
            trace("replace in files: \(s)")
            done(s)
        }
        guard !diskFiles.isEmpty else { finish(ReplaceReport()); return }
        // The disk writes: reading, hashing, backing up and writing every
        // file is I/O, so it runs on a background queue; nothing is
        // decided there that the main thread could change (the files were
        // taken out of the plan above, open tabs excluded).
        ReplaceInFiles.writing = true
        let query = plan.query, root = plan.root, store = ReplaceInFiles.store
        let delay = ReplaceInFiles.writeDelayForChecks
        let input = MainBox(value: diskFiles)
        let throttle = ProgressThrottle()
        ReplaceInFiles.queue.async {
            let onMain = Thread.isMainThread
            let report = FileReplace.apply(input.value, query: query, root: root, store: store) { p in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                // At most ~20 updates a second, and always the last of a stage.
                guard throttle.due(last: p.done == p.total) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(p) } }
            }
            let out = MainBox(value: report)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ReplaceInFiles.writing = false
                    ReplaceInFiles.lastWriteOnMain = onMain
                    finish(out.value)
                }
            }
        }
    }

    /// Undo Replace in Files: restores the written files still holding what
    /// was written (reading, hashing and writing them on
    /// `ReplaceInFiles.queue`, with `progress` on the main thread), and
    /// undoes the tab edits still on top of their tab's undo stack. `done`
    /// gets what to show. Files it couldn't put back yet (read-only now)
    /// keep the operation, so Undo can be tried again.
    func undoLastReplace(progress: @escaping @MainActor (ReplaceProgress) -> Void = { _ in },
                         done: @escaping @MainActor (String) -> Void) {
        guard !ReplaceInFiles.writing, let op = ReplaceInFiles.last else { done(""); return }
        guard let id = op.diskOperation else { finishUndo(op, disk: nil, done: done); return }
        ReplaceInFiles.writing = true
        let store = ReplaceInFiles.store
        let delay = ReplaceInFiles.writeDelayForChecks
        let throttle = ProgressThrottle()
        ReplaceInFiles.queue.async {
            let onMain = Thread.isMainThread
            let r = store.undo(id) { n, total in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                guard throttle.due(last: n == total) else { return }
                let p = ReplaceProgress(stage: .restoring, done: n, total: total)
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(p) } }
            }
            let out = MainBox(value: r)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ReplaceInFiles.writing = false
                    ReplaceInFiles.lastUndoOnMain = onMain
                    self.finishUndo(op, disk: out.value, done: done)
                }
            }
        }
    }

    /// The tab edits (here, on the main thread) and the message, once the
    /// disk files are done.
    private func finishUndo(_ op: ReplaceInFiles.Operation, disk: ReplaceUndoStore.UndoReport?,
                            done: @MainActor (String) -> Void) {
        var restored: [URL] = []
        var skipped: [SkippedFile] = []
        if let r = disk {
            restored += r.restored
            skipped += r.skipped
        }
        // Kept for another try (the tab edits are done now either way).
        ReplaceInFiles.last = disk?.remaining == true ? .init(diskOperation: op.diskOperation, tabEdits: []) : nil
        for e in op.tabEdits {
            func skip() { skipped.append(SkippedFile(url: e.url, relativePath: e.url.lastPathComponent, reason: .changedSinceReplace)) }
            guard let tab = e.tab, tabs.contains(where: { $0 === tab }), let um = tab.textView.undoManager else { skip(); continue }
            // Only our own edit, still the last thing done in that tab.
            guard tab.text == e.after, um.canUndo, um.undoActionName == ReplaceInFiles.actionName else { skip(); continue }
            um.undo()
            if tab.text == e.before { restored.append(e.url) } else { skip() }
        }
        var s = restored.count == 1 ? String(localized: "Undid Replace in Files in 1 file.")
            : String(localized: "Undid Replace in Files in \(restored.count) files.")
        s += ReplaceInFiles.skippedText(skipped)
        if ReplaceInFiles.last != nil {
            s += " " + (skipped.contains { $0.reason == .backupUnreadable }
                ? String(localized: "Those files are unchanged; Undo Replace in Files stays available to try again.")
                : String(localized: "Undo again once those files can be written."))
        }
        trace("replace in files: \(s)")
        done(s)
    }
}

/// Rate-limits progress updates from a background thread.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPost = 0.0

    func due(last: Bool, interval: Double = 0.05) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard last || now - lastPost >= interval else { return false }
        lastPost = now
        return true
    }
}
