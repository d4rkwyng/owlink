import AppKit
import CedricCore

/// Hot close and File › Reopen Closed Tab (⇧⌘T). Closing a tab never
/// asks: a tab with unsaved text has that text written to its session
/// buffer first (synchronously, before the window goes), and the tab is
/// remembered in the session's closed-tabs list, so a crash right after
/// the close still keeps it. ⇧⌘T brings the newest one back, unsaved
/// changes and all. The list keeps `ClosedTabs.limit` tabs, dropping ones
/// without unsaved text first.
extension AppDelegate {
    private var sessionSaving: Bool { DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1" }

    /// Whether this tab's text must be kept to reopen it (unsaved edits,
    /// or an untitled tab with text).
    private func needsBuffer(_ t: EditorWindowController) -> Bool {
        t.doc.isDirty || t.doc.fileURL == nil && (t.textView.textStorage?.length ?? 0) > 0
    }

    /// Writes the tab's unsaved text to its buffer now (closing): false if
    /// that failed, and the caller asks the user as before.
    func keepTextForClose(_ t: EditorWindowController) -> Bool {
        guard needsBuffer(t) else { return true }
        let d = t.doc
        if !sessionSaving {
            closedTexts[d.id] = EditorDocument.bufferText(t.text, breaks: d.lineBreaks)
            return true
        }
        if d.sessionChangeCount == d.changeCount, FileManager.default.fileExists(atPath: store.bufferURL(d.id).path) { return true }
        let text = t.text, breaks = d.lineBreaks, id = d.id, store = self.store
        var failure: Error?
        sessionQueue.sync {
            do { try store.writeBuffer(id, text: EditorDocument.bufferText(text, breaks: breaks)) } catch { failure = error }
        }
        if let failure {
            FileHandle.standardError.write(Data("session: closing tab, buffer write failed: \(failure)\n".utf8))
            return false
        }
        d.sessionChangeCount = d.changeCount
        return true
    }

    /// The tab has closed (not by quitting): remember it, keep or delete
    /// its buffer, and save the session now.
    func rememberClosed(_ t: EditorWindowController, persist: Bool = true) {
        // Restored tabs not built yet (AppDelegate.restoreNextPending) are
        // built first, so the save below keeps them and their bookmarks.
        finishRestore()
        let d = t.doc
        let empty = (t.textView.textStorage?.length ?? 0) == 0
        // An empty untitled tab isn't worth remembering.
        if d.fileURL == nil && empty {
            store.removeBuffer(d.id)
            scheduleSessionSave()
            return
        }
        let keepText = needsBuffer(t)
        // A tab closed without windowShouldClose (programmatically): write now.
        if keepText, !keepTextForClose(t) {
            // Couldn't write it: keep it in memory at least, for this run.
            closedTexts[d.id] = EditorDocument.bufferText(t.text, breaks: d.lineBreaks)
        }
        if !keepText { store.removeBuffer(d.id) }
        // Kept for ⇧⌘T, but the file wasn't written: say so once (ClosedNotice.swift).
        if keepText, d.fileURL != nil, d.isDirty { noteClosedUnsaved(id: d.id, name: d.displayName) }
        let sel = t.primaryTextView.selectedRange()
        var entry = SessionTab(id: d.id, path: d.fileURL?.path, untitledName: d.fileURL == nil ? d.untitledName : nil,
                               hasBuffer: keepText, encoding: d.encoding, lineEnding: d.lineEnding,
                               language: d.languageIsManual ? d.language : nil,
                               selectionLocation: sel.location, selectionLength: sel.length, topLine: t.primaryTopLine,
                               fileModified: d.fileModified,
                               fileSize: d.diskStamp.size, fileID: d.diskStamp.identity,
                               bookmarks: t.editing.bookmarks.isEmpty ? nil : t.editing.bookmarks.lines,
                               indentation: d.indentation, folds: t.sessionFolds, split: t.sessionSplit,
                               writing: t.sessionWriting, wordGoal: d.fileURL == nil ? t.editing.wordGoal : nil)
        d.noteFormat(in: &entry)
        let r = ClosedTabs.push(entry, onto: closedTabs)
        closedTabs = r.list
        for gone in r.dropped {
            closedTexts[gone.id] = nil
            if gone.hasBuffer { store.removeBuffer(gone.id) }
        }
        // Now, not in 1.5 s: the closed list must name the buffer before a
        // later save could prune it.
        if persist { saveSession() }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let st = closedTabs.popLast() else { NSSound.beep(); return }
        if st.pdf != nil { reopenClosedPDF(st); return }
        if st.image != nil || st.office != nil || st.certificate != nil { reopenClosedViewer(st); return }
        // A restored tab for the same file may not be built yet: build them
        // all first, so the check below sees it and it isn't opened twice.
        finishRestore()
        var text: String? = closedTexts.removeValue(forKey: st.id) ?? (st.hasBuffer ? store.readBuffer(st.id) : nil)
        var url = st.path.map { URL(fileURLWithPath: $0) }
        if let u = url, let open = tabs.first(where: { $0.doc.fileURL?.standardizedFileURL == u.standardizedFileURL }) {
            guard text != nil else {
                // The file is open again already, nothing unsaved to bring back.
                open.window?.makeKeyAndOrderFront(nil)
                saveSession()
                return
            }
            // Open with other edits: bring the closed text back beside it, untitled, rather than drop either.
            url = nil
        }
        let openNames = tabs.filter { $0.doc.fileURL == nil }.map(\.doc.untitledName)
        var name = st.untitledName ?? st.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Untitled")
        if url == nil, openNames.contains(name) { name = UntitledNames.next(open: openNames, base: name) }
        let doc = EditorDocument(id: st.id, fileURL: url, untitledName: name)
        doc.indentation = st.indentation
        let fromBuffer = text != nil
        if text == nil, let url, let (d, mod) = try? EditorDocument.read(url, encoding: st.encoding) {
            doc.apply(d)
            doc.noteDisk(mod)
            text = d.text
        } else if text != nil {
            doc.encoding = st.encoding
            doc.lineEnding = st.lineEnding
            // A pre-0.5.4 date-only stamp through a link: unverified (⌘S asks).
            doc.noteDisk(url.map { DiskStamp.restored(st.diskStamp, for: $0) } ?? st.diskStamp)
        }
        if fromBuffer { text = doc.restoreFormat(st, buffer: text) } else { _ = doc.restoreFormat(st, buffer: nil) }
        guard let body = text else {
            // The file has gone and there was no unsaved text.
            NSSound.beep()
            saveSession()
            return
        }
        if let l = st.language {
            doc.languageChoice.choose(l)
        } else if let url {
            doc.languageChoice = .forFile(named: url.lastPathComponent, content: body)
        } else {
            doc.languageChoice = .untitled(content: body)
        }
        let tab = makeTab(doc, text: body)
        // Open again: journaled before anything else is written for it, so
        // a crash before the next commit can't leave it on the closed list
        // under its old closing date (SessionStore.noteReopened).
        if sessionSaving {
            let store = self.store, id = st.id
            sessionQueue.sync {
                do { try store.noteReopened(id) } catch {
                    FileHandle.standardError.write(Data("session: reopened tab not journaled: \(error)\n".utf8))
                }
            }
        }
        if let goal = st.wordGoal { tab.editing.wordGoal = goal }
        if let w = st.writing, !w.isOff { tab.setWriting(w) }
        if st.hasBuffer || url == nil && st.path != nil {
            doc.markDirtyFromSession()
            // The buffer on disk already holds this text.
            if sessionSaving, st.hasBuffer { doc.sessionChangeCount = doc.changeCount }
        }
        let len = (body as NSString).length
        let loc = min(st.selectionLocation, len)
        tab.textView.setSelectedRange(NSRange(location: loc, length: min(st.selectionLength, len - loc)))
        if let marks = st.bookmarks {
            tab.editing.bookmarks = Bookmarks(marks)
            tab.editing.bookmarks.clamp(lineCount: tab.lineIndex.lineCount)
        }
        tab.updateTitle()
        let top = st.topLine
        DispatchQueue.main.async { tab.scrollToLine(top, in: tab.primaryPane) }
        if let folds = st.folds { tab.restoreFolds(folds) }
        if let sp = st.split { tab.restoreSplit(sp) }
        saveSession()
    }
}
