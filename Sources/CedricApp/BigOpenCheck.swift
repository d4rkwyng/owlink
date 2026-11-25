import AppKit
import CedricCore

/// CEDRIC_CHECK=bigopen: a big log (CEDRIC_BIGFILE, else one written
/// here, 40 MB) opened as Finder, the Open panel and `owlink file` open it:
/// in the background (AppDelegate.open's `background`). No tab exists
/// until the text is whole (nothing half-loaded to edit or save); a second
/// open while it reads makes no second tab; closing another tab while it
/// reads is safe. Then the tab: the whole file, clean, its saved text kept
/// as chunk hashes rather than a copy (EditedState), and the dirty flag
/// right through typing, undo, a same-length change and its reversal, a
/// save (the file on disk has the edit) and Revert to Saved. Closing the
/// only other tab while it reads, with Quit when the last window closes
/// on, doesn't quit. Then two more at once: read one at a time, and a
/// `cedric -w` on one that is gone before its turn returns.
/// Scripts/bigfile-check.sh runs it after the bigfile check.
extension DevChecks {
    static func bigOpenCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "bigopen" else { return false }
        let url: URL
        if let path = DevEnvironment.values["CEDRIC_BIGFILE"] {
            // A copy: the check saves into it.
            url = dir.appendingPathComponent("bigopen.log")
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        } else {
            url = dir.appendingPathComponent("bigopen.log")
            var s = ""
            var i = 0
            while s.utf8.count < 40_000_000 {
                s += "2026-11-24T01:36:37Z INFO worker-\(i % 32) request id=\(i) status=200 path=/api/v1/items/\(i % 977)\n"
                i += 1
            }
            try? s.write(to: url, atomically: false, encoding: .utf8)
        }
        let std = url.standardizedFileURL
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        expect(size >= AppDelegate.backgroundOpenBytes, "the log is big enough to open in the background", "\(size) bytes")
        let other = app.open(write("other.txt", "another tab\n"))
        var arrived: [EditorWindowController] = []
        // The read is held at a gate until the steps below have looked at
        // the app over several turns of the main loop (no tab for the file
        // can exist while its text can't be whole); and the tab, when it
        // is registered (before it is shown), must already hold all of it.
        let gate = DispatchSemaphore(value: 0)
        AppDelegate.backgroundReadGateForChecks = gate
        let originalBytes = (try? Data(contentsOf: url)) ?? Data()
        var registered: [(tab: EditorWindowController, length: Int, whole: Bool)] = []
        AppDelegate.tabMadeForChecks = { t in
            guard t.doc.fileURL?.standardizedFileURL == std else { return }
            // The text itself, not its length: same-length corruption
            // (a chunk read twice, one dropped) passed a length check.
            registered.append((t, (t.text as NSString).length, Data(t.text.utf8) == originalBytes))
        }
        let t0 = DevHooks.now()
        let first = app.open(url, background: true) { arrived.append($0) }
        expect(first == nil, "a big file returns no tab at once")
        expect(app.backgroundOpens[std] != nil, "…it is read in the background")
        expect(!app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == std }, "…and has no tab while it reads")
        let second = app.open(url, background: true) { arrived.append($0) }
        expect(second == nil && app.backgroundOpens.count == 1, "opening it again while it reads starts nothing new")
        expect(!app.lastCloseMayQuit, "closing the last other tab while it reads doesn't quit (quit on last close)")
        // Closing the only other tab while it reads, with Quit when the last
        // window closes on (bigfile-check.sh): it closes, and the app stays.
        expect(DevHooks.allowsQuitOnLastClose && Settings.shared.quitWhenLastWindowCloses,
               "quit on last close is on for this check")
        expect(app.tabs.count == 1 && app.tabs.first === other && app.viewerTabs.isEmpty, "the other tab is the only one",
               "\(app.tabs.count)")
        other?.doc.markSaved()
        other?.window?.performClose(nil)
        expect(app.tabs.isEmpty && !app.terminating, "…it closes, and the app doesn't quit while the file reads",
               "\(app.tabs.count) tabs, terminating \(app.terminating)")
        var tab: EditorWindowController!
        let url2 = dir.appendingPathComponent("bigopen-2.log")
        let url3 = dir.appendingPathComponent("bigopen-3.log")
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-wait.bigopen\(getpid())").path
        let marker2 = marker + "again"
        var arrived2: [EditorWindowController] = []
        var alerts = 0
        var dismissTimer: Timer?
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let originalLength = (original as NSString).length

        func waitForTab(_ next: @escaping () -> Void) {
            let deadline = DevHooks.now() + 60
            @MainActor func poll() {
                if !arrived.isEmpty || DevHooks.now() > deadline { next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
            }
            poll()
        }

        func waitForAll(_ next: @escaping () -> Void) {
            let deadline = DevHooks.now() + 60
            @MainActor func poll() {
                if app.backgroundOpens.isEmpty || DevHooks.now() > deadline { next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
            }
            poll()
        }

        func heldTurn(_ n: Int) -> (@escaping () -> Void) -> Void {
            { next in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    expect(app.backgroundOpens[std] != nil && registered.isEmpty
                           && !app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == std },
                           "held read, turn \(n): no tab for the file, nothing registered")
                    next()
                }
            }
        }
        run([
            heldTurn(1),
            sync {
                // Typing and ⌘S while it is held: no tab takes them, the
                // file isn't written, no tool has a document.
                type("typed while reading")
                key("s", [.command])
                expect(!app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == std } && registered.isEmpty,
                       "held read: typing and ⌘S reach no tab for the file")
                expect(app.currentTab == nil || app.currentTab?.doc.fileURL?.standardizedFileURL != std,
                       "held read: no current tab for tools to act on")
            },
            heldTurn(2),
            sync {
                expect((try? Data(contentsOf: url)) == originalBytes, "held read: the file on disk is untouched")
                gate.signal()
            },
            { next in waitForTab(next) },
            sync {
                AppDelegate.tabMadeForChecks = nil
                expect(registered.count == 1, "the file's tab was registered once", "\(registered.count)")
                expect(registered.first?.whole == true && registered.first?.length == originalLength,
                       "…already holding the whole file when registered (before it was shown)",
                       "\(registered.first?.length ?? -1) of \(originalLength)")
                expect(registered.first?.tab === arrived.first, "…and it is the tab the opens got")
            },
            sync {
                print(String(format: "check: note: background open ready in %.0f ms", (DevHooks.now() - t0) * 1000))
                expect(arrived.count == 2 && arrived[0] === arrived[1], "both opens get the one tab", "\(arrived.count)")
                expect(app.backgroundOpens.isEmpty, "nothing left reading")
                expect(!app.terminating, "still running after the last other tab closed")
                expect(app.lastCloseMayQuit && app.quitsOnLastClose, "…and a last close may quit again")
                let mine = app.tabs.filter { $0.doc.fileURL?.standardizedFileURL == std }
                expect(mine.count == 1, "one tab for the file", "\(mine.count)")
                tab = mine.first ?? arrived.first
                guard let tab else { return }
                sized(tab)
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.displayIfNeeded()
                expect((tab.text as NSString).length == originalLength && tab.text == original, "the whole file is the text",
                       "\((tab.text as NSString).length) of \(originalLength)")
                expect(tab.lineIndex.length == originalLength && tab.lineIndex.lineCount == LineIndex(original as NSString).lineCount,
                       "the line index (made in the background) is the text's")
                // The same index, not a second scan of the text on the main thread.
                let made = app.lastBackgroundIndexForChecks?.starts.withUnsafeBufferPointer { $0.baseAddress }
                expect(made != nil && tab.lineIndex.starts.withUnsafeBufferPointer { $0.baseAddress } == made,
                       "…the very index made in the background (no second scan)")
                expect(tab.textView.isEditable, "editable once shown")
                expect(!tab.doc.isDirty, "clean once open")
                expect(tab.doc.keepsSavedFingerprint == (originalLength > EditedState.snapshotLimit),
                       "the saved text is chunk hashes past the limit, not a copy")
                tab.window?.makeFirstResponder(tab.textView)
                tab.textView.setSelectedRange(NSRange(location: 10, length: 0))
                tab.textView.insertText("X", replacementRange: tab.textView.selectedRange())
            },
            sync {
                expect(tab.doc.isDirty, "typing makes it unsaved")
                tab.textView.undoManager?.undo()
            },
            sync {
                expect(tab.text == original, "undo puts the text back")
                expect(!tab.doc.isDirty, "…and it is clean again")
                // A change that keeps the length, far down, then its reversal.
                let at = originalLength - 30
                let was = (tab.text as NSString).substring(with: NSRange(location: at, length: 1))
                tab.textView.insertText(was == "Q" ? "R" : "Q", replacementRange: NSRange(location: at, length: 1))
                expect(tab.doc.isDirty, "a same-length change is unsaved")
                tab.textView.insertText(was, replacementRange: NSRange(location: at, length: 1))
                expect(tab.text == original && !tab.doc.isDirty, "…and putting the character back is clean")
                // Save an edit.
                tab.textView.insertText("SAVED ", replacementRange: NSRange(location: 0, length: 0))
                expect(tab.doc.isDirty, "an edit to save")
                expect(tab.save(), "saved")
                expect(!tab.doc.isDirty && tab.doc.keepsSavedFingerprint == (originalLength + 6 > EditedState.snapshotLimit),
                       "clean after saving, the saved text still kept as chunk hashes")
                let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                expect(disk == "SAVED " + original, "the file on disk has the edit", String(disk.prefix(20)))
                // Undo past the save: unsaved (the saved text is now the edited one).
                tab.textView.undoManager?.undo()
            },
            sync {
                expect(tab.text == original && tab.doc.isDirty, "undo past the save is unsaved")
                tab.textView.undoManager?.redo()
            },
            sync {
                expect(tab.text == "SAVED " + original && !tab.doc.isDirty, "redo back to the saved text is clean")
                tab.textView.insertText("more ", replacementRange: NSRange(location: 0, length: 0))
                expect(tab.doc.isDirty, "edited again")
                expect(tab.reloadFromDisk(), "Revert to Saved")
            },
            sync {
                expect(tab.text == "SAVED " + original && !tab.doc.isDirty, "reverted: the saved file, clean")
                tab.doc.markSaved()
                // Two more big files at once (a multi-file open), the second
                // from `cedric -w` and gone before its turn: one read at a
                // time, and the waiting script let go when it can't open.
                try? FileManager.default.removeItem(at: url2)
                try? FileManager.default.copyItem(at: url, to: url2)
                try? FileManager.default.removeItem(at: url3)
                try? FileManager.default.copyItem(at: url, to: url3)
                FileManager.default.createFile(atPath: marker, contents: nil)
                app.open(url2, background: true) { arrived2.append($0) }
                let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
                openURL(app, "cedric://open?path=\(enc(url3.path))&wait=\(enc(marker))")
                expect(app.backgroundOpens.count == 2, "both wait to be read", "\(app.backgroundOpens.count)")
                expect(app.backgroundReading == url2.standardizedFileURL, "…one at a time: the first is read, the second waits")
                expect(FileManager.default.fileExists(atPath: marker), "the script waits")
                try? FileManager.default.removeItem(at: url3)
                // `cedric -w` on it again, now it is gone and still waiting
                // its turn (0.5.4 QA, Codex review): the pending read's, not
                // a new file's empty tab that would save over one put back.
                FileManager.default.createFile(atPath: marker2, contents: nil)
                openURL(app, "cedric://open?path=\(enc(url3.path))&wait=\(enc(marker2))")
                expect(!app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == url3.standardizedFileURL },
                       "a second open of the gone file while it waits makes no new-file tab")
                expect(app.backgroundOpens.count == 2 && app.backgroundOpens[url3.standardizedFileURL] != nil,
                       "…it waits on the read already pending", "\(app.backgroundOpens.count)")
                // Its "couldn't open" alert is answered.
                let dismiss = Timer(timeInterval: 0.2, repeats: true) { _ in
                    MainActor.assumeIsolated { if NSApp.modalWindow != nil { alerts += 1; NSApp.abortModal() } }
                }
                RunLoop.main.add(dismiss, forMode: .modalPanel)
                dismissTimer = dismiss
            },
            { next in waitForAll(next) },
            sync {
                dismissTimer?.invalidate()
                expect(app.backgroundOpens.isEmpty, "both done")
                expect(app.mostBackgroundReadsForChecks == 1, "never more than one big file read (or waiting to be shown) at once",
                       "\(app.mostBackgroundReadsForChecks)")
                expect(arrived2.count == 1 && arrived2.first?.doc.fileURL?.standardizedFileURL == url2.standardizedFileURL,
                       "the first opens", "\(arrived2.count)")
                expect(!app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == url3.standardizedFileURL }, "the gone one has no tab")
                expect(alerts == 1, "…and says so", "\(alerts)")
                expect(!FileManager.default.fileExists(atPath: marker), "cedric -w on it returns (its marker is deleted)")
                expect(!FileManager.default.fileExists(atPath: marker2), "…and so does the second (one alert for both)")
                arrived2.first?.doc.markSaved()
            },
        ])
        return true
    }
}
