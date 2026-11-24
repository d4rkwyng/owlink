import AppKit
import CedricCore

/// A value passed into a @Sendable callback that is only used back on the
/// main queue.
struct MainBox<T>: @unchecked Sendable { let value: T }

/// A weak reference for a @Sendable callback delivered on the main queue.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

// MARK: - App: Open Recent, text tools, Find in Files, Compare, Follow

extension AppDelegate: NSMenuDelegate {
    // MARK: Open Recent

    static let recentMenuTitle = String(localized: "Open Recent")

    /// The recent-documents list (NSDocumentController's: the same list
    /// the Dock menu and Finder show), files that still exist.
    var recentURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func noteRecent(_ url: URL) {
        guard AfterFirstFrame.passed else {
            // Opening a file at launch: not on the way to the first frame.
            AfterFirstFrame.run { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            scheduleRecentMenuRebuild()
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        rebuildRecentMenu()
    }

    /// At launch: rebuilds the menu once, after the first frame (each item
    /// asks LaunchServices for an icon). Later: now.
    func scheduleRecentMenuRebuild() {
        guard !AfterFirstFrame.passed else { rebuildRecentMenu(); return }
        guard !recentRebuildScheduled else { return }
        recentRebuildScheduled = true
        AfterFirstFrame.run { [weak self] in
            self?.recentRebuildScheduled = false
            self?.rebuildRecentMenu()
        }
    }

    var recentMenu: NSMenu? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == String(localized: "File") }?
            .submenu?.items.first { $0.title == Self.recentMenuTitle }?.submenu
    }

    /// Rebuilt whenever the list changes (and before the menu opens), so
    /// the ⌥⌘1…⌥⌘9 key equivalents always match the list.
    func rebuildRecentMenu() {
        guard let menu = recentMenu else { return }
        menu.delegate = self
        menu.removeAllItems()
        let urls = recentURLs
        for (i, url) in urls.enumerated() {
            let it = item(url.lastPathComponent, #selector(openRecentItem(_:)), i < 9 ? "\(i + 1)" : "", [.command, .option],
                          represented: url)
            it.toolTip = url.path
            it.image = NSWorkspace.shared.icon(forFile: url.path)
            it.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(it)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item(String(localized: "Clear Menu"), #selector(clearRecentMenu(_:))))
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu { rebuildRecentMenu() }
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url, background: true)
    }

    @objc func clearRecentMenu(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
        rebuildRecentMenu()
    }

    // MARK: Text tools

    @objc func explainRegexMenu(_ sender: Any?) { currentTab?.explainRegexSelection() }
    @objc func decodeSelectionMenu(_ sender: Any?) { currentTab?.decodeSelection() }
    @objc func findTodosMenu(_ sender: Any?) { currentTab?.showTodos() }

    @objc func textToolMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = TextTool(rawValue: raw) else { return }
        currentTab?.applyTextTool(tool)
    }

    // MARK: Find in Files

    @objc func findInFilesMenu(_ sender: Any?) {
        showFindInFiles(replace: false)
    }

    /// Opens (or moves here) the Find in Files panel; `replace`: in replace
    /// mode (Edit › Replace in Files…), else it keeps its mode.
    func showFindInFiles(replace: Bool) {
        let panel = findInFiles ?? FindInFilesPanel()
        findInFiles = panel
        panel.onOpen = { [weak self] result in self?.openResult(result) }
        panel.onClose = { [weak self] in self?.hideFindInFiles() }
        panel.onReplace = { [weak self] plan, progress, done in
            guard let self else { done(""); return }
            self.applyReplace(plan, progress: progress, done: done)
        }
        panel.onUndo = { [weak self] progress, done in
            guard let self else { done(""); return }
            self.undoLastReplace(progress: progress, done: done)
        }
        panel.canUndo = { ReplaceInFiles.last != nil && !ReplaceInFiles.writing }
        panel.buffers = { [weak self] urls in self?.openBuffers(for: urls) ?? [:] }
        if replace { panel.replaceMode = true }
        guard let tab = currentTab ?? tabs.last else { return }
        // A replace preview keeps the fields it was made from.
        if !panel.previewing {
            // The open folder (sidebar), else the tab's file's folder.
            if let dir = FolderSidebar.shared?.rootURL ?? tab.doc.fileURL?.deletingLastPathComponent() {
                panel.folderField.stringValue = dir.path
            } else if panel.folderField.stringValue.isEmpty {
                panel.folderField.stringValue = FileManager.default.homeDirectoryForCurrentUser.path
            }
            let sel = tab.textView.selectedRange()
            if sel.length > 0, sel.length < 200 {
                panel.queryField.stringValue = (tab.text as NSString).substring(with: sel)
            }
        }
        panel.updateReplaceControls()
        panel.isShown = true
        tab.dockSidePanel(panel)
        tab.window?.makeFirstResponder(panel.queryField)
        panel.queryField.selectText(nil)
    }

    func hideFindInFiles() {
        guard let p = findInFiles else { return }
        p.cancel()
        p.isShown = false
        let split = p.superview as? NSSplitView
        p.removeFromSuperview()
        // The editor gets the panel's room back, not the folder sidebar.
        FolderSidebar.keepWidth(in: split)
        if let t = currentTab { t.window?.makeFirstResponder(t.textView) }
    }

    func openResult(_ r: FileSearchResult) {
        guard let tab = open(r.url) else { return }
        // Keep the results beside the file they lead to.
        if let p = findInFiles, p.isShown { tab.dockSidePanel(p) }
        tab.goToLine(r.line, column: r.column)
        if let first = r.ranges.first {
            let start = tab.lineIndex.starts[max(0, min(r.line - 1, tab.lineIndex.lineCount - 1))]
            let range = NSRange(location: start + r.column - 1, length: first.length)
            if NSMaxRange(range) <= tab.lineIndex.length {
                tab.textView.setSelectedRange(range)
                tab.textView.showFindIndicator(for: range)
            }
        }
        tab.window?.makeFirstResponder(tab.textView)
    }

    // MARK: Compare

    @objc func compareWithMenu(_ sender: Any?) {
        guard let tab = currentTab, let window = tab.window else { return }
        let others = tabs.filter { $0 !== tab }
        guard !others.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = String(localized: "Compare “\(tab.doc.displayName)” With")
        a.informativeText = String(localized: "Shows the two tabs side by side, line by line. Read-only.")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for t in others {
            pop.addItem(withTitle: t.doc.displayName)
            pop.lastItem?.representedObject = t
            pop.lastItem?.toolTip = t.doc.fileURL?.path
        }
        // Default: the tab that was selected before this one.
        let previous = NSApp.orderedWindows.lazy.compactMap { w in others.first { $0.window === w } }.first
        if let previous, let i = others.firstIndex(where: { $0 === previous }) { pop.selectItem(at: i) }
        a.accessoryView = pop
        a.addButton(withTitle: String(localized: "Compare"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let other = pop.selectedItem?.representedObject as? EditorWindowController else { return }
            self?.showCompare(tab, other)
        }
    }

    func showCompare(_ left: EditorWindowController, _ right: EditorWindowController) {
        showCompare(host: left, leftName: left.doc.displayName, leftText: left.text,
                    rightName: right.doc.displayName, rightText: right.text)
    }

    // MARK: Follow

    @objc func followFileMenu(_ sender: Any?) { currentTab?.toggleFollow() }

    func validateToolItem(_ item: NSMenuItem) -> Bool {
        let tab = currentTab
        switch item.action {
        case #selector(textToolMenu(_:)): return tab != nil && tab?.tail == nil
        case #selector(compareWithMenu(_:)): return tab != nil && tabs.count > 1
        case #selector(followFileMenu(_:)):
            item.state = tab?.tail != nil ? .on : .off
            return tab?.doc.fileURL != nil
        case #selector(clearRecentMenu(_:)): return !NSDocumentController.shared.recentDocumentURLs.isEmpty
        default: return true
        }
    }
}

// MARK: - Tab: text tools, side panel, follow

extension EditorWindowController {
    /// Applies a text tool to the selection, or the whole document if
    /// nothing is selected, as one undo step. Line tools widen a partial
    /// selection to whole lines.
    func applyTextTool(_ tool: TextTool) {
        guard textView.textStorage != nil, textView.isEditable else { NSSound.beep(); return }
        let ns = textView.string as NSString
        var range = textView.selectedRange()
        // `ns` bridges the live storage string: take the length now, before the edit.
        let wholeDocument = range.length == 0 || range.length == ns.length
        if range.length == 0 {
            range = NSRange(location: 0, length: ns.length)
        } else if tool.isLineBased {
            range = ns.lineRange(for: range)
        }
        let input = ns.substring(with: range)
        let output: String
        do {
            output = try TextTools.apply(tool, to: input)
        } catch {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = String(localized: "\(tool.displayName) failed")
            a.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let window { a.beginSheetModal(for: window) } else { a.runModal() }
            return
        }
        guard output != input else { return }
        replaceAsOneStep(range, with: output, actionName: tool.displayName)
        let newRange = NSRange(location: range.location, length: (output as NSString).length)
        textView.setSelectedRange(wholeDocument ? NSRange(location: 0, length: 0) : newRange)
        colorizer.scheduleViewport()
    }

    /// Puts the Find in Files panel at the right of this tab's split view.
    func dockSidePanel(_ panel: NSView) {
        guard panel.superview !== split else { return }
        panel.removeFromSuperview()
        split.addArrangedSubview(panel)
        split.adjustSubviews()
        // A folder sidebar keeps its width; the panes right of it share the rest.
        FolderSidebar.keepWidth(in: split)
        // The divider just before the panel (found by identity: other panes
        // may dock in the split too), placed in the room right of the pane
        // before it, so a sidebar on the left doesn't leave the editor 0 wide.
        let w = split.bounds.width
        if w > 0, let i = split.arrangedSubviews.firstIndex(of: panel), i > 0 {
            let left = split.arrangedSubviews[i - 1].frame.minX
            let room = w - left
            split.setPosition(left + max(room * 0.45, room - 460), ofDividerAt: i - 1)
        }
    }

    // MARK: Follow File

    var isFollowing: Bool { tail != nil }

    func toggleFollow() {
        if let t = tail {
            t.stop()
            tail = nil
            setEditable(true)
            window?.subtitle = ""
            recheckWriteAccess()
            // The tab's stamp counts only the bytes Follow showed: bytes it
            // held back (half a character, a trailing CR) or never got to
            // show differ from it. Catch up now (a clean tab reloads; a
            // file that can't be read shows the "Changed on disk" bar),
            // and ⌘S asks rather than writing over them.
            reloadIfChangedOnDisk()
            return
        }
        guard let url = doc.fileURL else { NSSound.beep(); return }
        if doc.isDirty {
            let a = NSAlert()
            a.messageText = String(localized: "Follow “\(doc.displayName)”?")
            a.informativeText = String(localized: "Following shows the file as it is on disk; your unsaved changes in this tab will be lost.")
            a.addButton(withTitle: String(localized: "Follow"))
            a.addButton(withTitle: String(localized: "Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { showError(error); return }
        // The tail's own decode: a UTF-16 character cut in half at the end
        // (the writer still busy) is left for the first append, which
        // starts from `used`. Not text: the tab, its edits and its stamp
        // stay as they were and Follow doesn't start.
        guard let (d, used) = FileTail.decodeWhole(data, as: doc.encoding) else {
            showError(EditorDocument.LoadError.notText(url))
            return
        }
        doc.apply(d)
        setText(d.text)
        doc.markSaved()
        // Stamped as the bytes shown, not the whole file: a half character
        // left for the first append isn't in this tab's text.
        doc.noteDisk(DiskStamp.of(url)?.showing(UInt64(used)))
        updateTitle()
        setEditable(false)
        // setText dropped the cards proposed against the editable buffer;
        // refresh any still up so none shows Apply on a read-only tab.
        if owlChat?.hasProposals == true { owlChat?.refreshCards() }
        window?.subtitle = String(localized: "Following")
        scrollToBottom()
        let me = WeakRef(self)
        let t = FileTail(url: url, encoding: doc.encoding, offset: UInt64(used)) { e, shown in
            MainActor.assumeIsolated { me.value?.tailEvent(e, shown: shown) }
        }
        tail = t
        t.start()
        onChange?(self)
    }

    var isScrolledToBottom: Bool {
        let clip = scrollView.contentView
        let lineHeight = editorFont.boundingRectForFont.height
        return clip.bounds.maxY >= textView.frame.maxY - lineHeight
    }

    /// `shown`: how many of the file's bytes the text now stands for
    /// (FileTail's count); the tab is stamped with that size.
    func tailEvent(_ e: FileTail.Event, shown: UInt64?) {
        guard tail != nil, let storage = textView.textStorage else { return }
        let atBottom = isScrolledToBottom
        switch e {
        case .appended(let s):
            // Not a user edit (no didChangeText): the tab stays clean, the
            // line index and colouring update from the storage edit.
            storage.beginEditing()
            storage.append(NSAttributedString(string: s, attributes: baseAttributes()))
            storage.endEditing()
            // A followed log can grow past the auto-review cap.
            updateAutoReviewCap(newText: false)
        case .reset(let s):
            setText(s)
        }
        // A reset drops cards inside setText. An append is not a user edit,
        // so nothing else refreshes them: Apply would stay enabled on a
        // read-only tab until the next keystroke.
        if owlChat?.hasProposals == true { owlChat?.refreshCards() }
        textView.undoManager?.removeAllActions()
        doc.markSaved()
        doc.noteDisk(doc.fileURL.flatMap { DiskStamp.of($0) }?.showing(shown))
        setGuttersNeedDisplay()
        updateStatus()
        if atBottom {
            scrollToBottom()
            // Once more after TextKit 2 has re-estimated the heights.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                if self?.tail != nil { self?.scrollToBottom() }
            }
        }
        trace("tail: \(e) atBottom=\(atBottom)")
    }

    /// Scrolls to the last line; repeats while TextKit 2 refines its
    /// height estimates (as `reveal` does).
    func scrollToBottom() {
        let len = (textView.string as NSString).length
        guard let tlm = textView.textLayoutManager, let r = textView.textRange(for: NSRange(location: len, length: 0)) else {
            textView.scrollToEndOfDocument(nil)
            return
        }
        for _ in 0..<10 {
            tlm.ensureLayout(for: r)
            let y = max(0, textView.frame.height - scrollView.contentView.bounds.height)
            if abs(scrollView.contentView.bounds.minY - y) < 1 { break }
            textView.scroll(NSPoint(x: 0, y: y))
            tlm.textViewportLayoutController.layoutViewport()
        }
        colorizer.scheduleViewport()
        setGuttersNeedDisplay()
    }
}

// MARK: - Tab: left panel (folder sidebar)

extension EditorWindowController {
    /// Puts a panel (the folder sidebar) at the left of this tab's split
    /// view, at index 0, `width` wide. It holds its width when the window
    /// resizes; the editor (and a docked preview) take the change.
    func dockLeftPanel(_ panel: NSView, width: CGFloat) {
        guard panel.superview !== split else { return }
        panel.removeFromSuperview()
        split.insertArrangedSubview(panel, at: 0)
        split.adjustSubviews()
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        let w = split.bounds.width
        if w > 0 { split.setPosition(min(width, w * 0.5), ofDividerAt: 0) }
    }
}
