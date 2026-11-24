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
/// save (the file on disk has the edit) and Revert to Saved.
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
        let t0 = DevHooks.now()
        let first = app.open(url, background: true) { arrived.append($0) }
        expect(first == nil, "a big file returns no tab at once")
        expect(app.backgroundOpens[std] != nil, "…it is read in the background")
        expect(!app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == std }, "…and has no tab while it reads")
        let second = app.open(url, background: true) { arrived.append($0) }
        expect(second == nil && app.backgroundOpens.count == 1, "opening it again while it reads starts nothing new")
        expect(!app.lastCloseMayQuit, "closing the last other tab while it reads doesn't quit (quit on last close)")
        // Closing another tab while it reads.
        other?.doc.markSaved()
        other?.window?.performClose(nil)
        var tab: EditorWindowController!
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let originalLength = (original as NSString).length

        func waitForTab(_ next: @escaping () -> Void) {
            let deadline = DevHooks.now() + 60
            func poll() {
                if !arrived.isEmpty || DevHooks.now() > deadline { next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
            poll()
        }

        run([
            { next in waitForTab(next) },
            sync {
                print(String(format: "check: note: background open ready in %.0f ms", (DevHooks.now() - t0) * 1000))
                expect(arrived.count == 2 && arrived[0] === arrived[1], "both opens get the one tab", "\(arrived.count)")
                expect(app.backgroundOpens.isEmpty, "nothing left reading")
                expect(app.lastCloseMayQuit, "…and a last close may quit again")
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
            },
        ])
        return true
    }
}
