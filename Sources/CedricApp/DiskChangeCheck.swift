import AppKit
import CedricCore

/// CEDRIC_CHECK=diskconflict (Scripts/tools-check.sh): another process
/// rewrites an open file, then ⌘S. The save must ask (Keep What’s in
/// This Tab / Reload from Disk / Compare) instead of overwriting, in words
/// that never blame "another app" (DiskConflict); a window becoming key
/// shows the "Changed on disk" bar for a tab with unsaved edits, owl off;
/// a deleted file shows the "deleted" bar and keeps its text unsaved.
@MainActor
extension DevChecks {
    /// Rewrites `url` from another process (as another app would).
    static func rewriteElsewhere(_ url: URL, _ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, url.path]
        try? p.run()
        p.waitUntilExit()
    }

    static func sheetButton(_ tab: EditorWindowController, _ title: String) -> NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.title == title { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return tab.window?.attachedSheet?.contentView.flatMap(find)
    }

    static func diskConflict(_ app: AppDelegate) {
        let url = write("conflict.txt", "mine\n")
        let tab = app.open(url)!
        sized(tab)
        func disk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "-" }
        let compares = app.compareWindows.count
        run([
            sync {
                expect(tab.owl == nil, "the owl is off")
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 4, length: 0))
                type(" one")
                rewriteElsewhere(url, "theirs\n")
                key("s", [.command])
            },
            sync {
                expect(disk() == "theirs\n", "⌘S didn't overwrite the other app's change", disk())
                expect(tab.window?.attachedSheet != nil, "⌘S asks instead")
                expect(sheetButton(tab, "Keep What’s in This Tab") != nil && sheetButton(tab, "Reload from Disk") != nil
                       && sheetButton(tab, "Compare") != nil, "with Keep What’s in This Tab, Reload from Disk and Compare")
                let texts = sheetTexts(tab)
                expect(texts.first == "“conflict.txt” changed on disk.", "the sheet says the file changed on disk", texts.joined(separator: " | "))
                expect(texts.dropFirst().first?.hasPrefix("The file on disk changed since you opened it.") == true,
                       "…since you opened it", texts.joined(separator: " | "))
                expect(!texts.joined().contains("another app") && !texts.joined().contains("Theirs"),
                       "…without “another app” or “Theirs”", texts.joined(separator: " | "))
                expect(sheetButton(tab, "Keep What’s in This Tab")?.hasDestructiveAction == true
                       && sheetButton(tab, "Keep What’s in This Tab")?.keyEquivalent != "\r",
                       "…Keep is destructive and Return doesn't press it", sheetButton(tab, "Keep What’s in This Tab")?.keyEquivalent ?? "-")
                expect(sheetButton(tab, "Cancel")?.keyEquivalent == "\u{1b}", "…Esc cancels")
                sheetButton(tab, "Compare")?.performClick(nil)
            },
            sync {
                expect(app.compareWindows.count == compares + 1, "Compare opens the compare view")
                expect(disk() == "theirs\n" && tab.doc.isDirty, "and saves nothing")
                app.compareWindows.last?.window?.performClose(nil)
                focus(tab)
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet != nil, "⌘S again still asks")
                sheetButton(tab, "Reload from Disk")?.performClick(nil)
            },
            sync {
                expect(tab.text == "theirs\n" && !tab.doc.isDirty, "Reload from Disk takes the file's text", tab.text)
                tab.textView.undoManager?.undo()
                expect(tab.text == "mine one\n", "Undo brings mine back", tab.text)
                rewriteElsewhere(url, "theirs again\n")
                focus(tab)
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet != nil, "a second change asks again")
                sheetButton(tab, "Keep What’s in This Tab")?.performClick(nil)
            },
            sync {
                expect(disk() == "mine one\n" && !tab.doc.isDirty, "Keep What’s in This Tab writes this tab's text", disk())
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 8, length: 0))
                type(" two")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet == nil && disk() == "mine one two\n", "an ordinary ⌘S doesn't ask", disk())
                type(" three")
                rewriteElsewhere(url, "changed while away\n")
                tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: tab.window))
            },
            sync {
                expect(tab.diskBar?.isHidden == false, "becoming key shows the Changed on disk bar (owl off)",
                       tab.diskBar?.label.stringValue ?? "no bar")
                expect(tab.text == "mine one two three\n" && tab.doc.isDirty, "and keeps the unsaved edits", tab.text)
            },
            snapshot("disk-changed-bar.png"),
            sync {
                tab.diskBar?.button("Keep Mine")?.performClick(nil)
                expect(tab.diskBar?.isHidden == true, "Keep Mine hides the bar")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet == nil && disk() == "mine one two three\n", "then ⌘S saves without asking", disk())
                rewriteElsewhere(url, "clean reload\n")
                tab.reloadIfChangedOnDisk()
                expect(tab.text == "clean reload\n" && tab.diskBar?.isHidden != false, "a tab without edits just reloads", tab.text)
                try? FileManager.default.removeItem(at: url)
                tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: tab.window))
            },
            sync {
                expect(tab.diskBar?.isHidden == false && tab.diskBar?.label.stringValue.contains("was deleted or moved") == true,
                       "a deleted file shows the deleted bar", tab.diskBar?.label.stringValue ?? "no bar")
                expect(tab.text == "clean reload\n" && tab.doc.isDirty && tab.doc.missingOnDisk,
                       "and keeps the text, now unsaved", tab.text)
                tab.diskBar?.button("Save")?.performClick(nil)
            },
            sync {
                expect(disk() == "clean reload\n" && !tab.doc.isDirty && !tab.doc.missingOnDisk && tab.diskBar?.isHidden == true,
                       "Save writes it back where it was", disk())
            },
        ] + conflictWordingSteps(app) + linkSteps(app))
    }

    /// The sheet says what Owlink knows: changed since this tab saved it,
    /// or saved from another Owlink tab on the same file (0.5.4 QA #7:
    /// both said "changed by another app").
    static func conflictWordingSteps(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        let url = write("conflict-saved.txt", "one\n")
        var tab: EditorWindowController!
        var other: EditorWindowController!
        func detail() -> String { sheetTexts(tab).dropFirst().joined(separator: " ") }
        func cancel() { sheetButton(tab, "Cancel")?.performClick(nil) }
        return [
            sync {
                guard let t = app.open(url) else { expect(false, "opened conflict-saved.txt"); return }
                tab = t
                sized(t)
                focus(t)
                t.textView.setSelectedRange(NSRange(location: 3, length: 0))
                type(" two")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet == nil && !tab.doc.isDirty, "wording: saved here first")
                type(" three")
                rewriteElsewhere(url, "changed after the save\n")
                key("s", [.command])
            },
            sync {
                expect(detail().hasPrefix("The file on disk changed since Owlink last saved it."), "wording: …since Owlink last saved it", detail())
                cancel()
                // Another tab on the same file saves it (as Save As over it would).
                app.newTab(nil)
                other = app.tabs.last
                focus(other)
                type("from the other tab")
                expect(other.write(to: url), "wording: another tab saves the same file")
                focus(tab)
                key("s", [.command])
            },
            sync {
                expect(detail().hasPrefix("It was saved from another Owlink tab or window"), "wording: …saved from another Owlink tab", detail())
                expect(!detail().contains("another app"), "wording: …not “another app”", detail())
                cancel()
                for t in [tab, other] { t?.doc.markSaved(); t?.window?.performClose(nil) }
            },
        ]
    }

    /// A tab opened through a symbolic link (0.5.4 QA, F2): its stamp is
    /// the target's, with the target's identity. A save through the link
    /// shows no bar; another file with the same date and size, put in
    /// place by an atomic replace or by pointing the link at it, is a
    /// change; a dangling link and a link to a folder keep the text.
    static func linkSteps(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        let fm = FileManager.default
        let target = write("link-target.txt", "linked\n")
        let folder = target.deletingLastPathComponent()
        let link = folder.appendingPathComponent("link.txt")
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "link-target.txt")
        var tab: EditorWindowController!
        func disk() -> String { (try? String(contentsOf: target, encoding: .utf8)) ?? "-" }
        func becomeKey() { tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: tab.window)) }
        /// Another file with `target`'s date and size, `text` the same length.
        func twin(_ name: String, _ text: String) -> URL {
            let u = write(name, text)
            let date = (try? fm.attributesOfItem(atPath: target.path)[.modificationDate]) as? Date
            try? fm.setAttributes([.modificationDate: date as Any], ofItemAtPath: u.path)
            return u
        }
        return [
            sync {
                tab = app.open(link)
                sized(tab)
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 6, length: 0))
                type("!")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet == nil && disk() == "linked!\n", "⌘S through a link saves without asking", disk())
                expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == "link-target.txt", "and keeps the link")
                becomeKey()
            },
            sync {
                expect(tab.diskBar?.isHidden != false && !tab.doc.isDirty, "a save through a link shows no Changed on disk bar")
                // Same date and size, another file renamed over the target.
                let other = twin("link-other.txt", "Linked!\n")
                expect(rename(other.path, target.path) == 0, "replace the target")
                expect(tab.fileChangedOnDisk(link), "an atomic replace with the same date and size is a change")
                tab.reloadIfChangedOnDisk()
                expect(tab.text == "Linked!\n", "and a tab without edits reloads it", tab.text)
                // Same date and size, the link pointed at another file.
                let third = twin("link-third.txt", "LINKED!\n")
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: third.lastPathComponent)
                type(" mine")
                key("s", [.command])
            },
            sync {
                expect(tab.window?.attachedSheet != nil, "⌘S after the link is pointed at a file with the same date and size asks")
                expect((try? String(contentsOfFile: folder.appendingPathComponent("link-third.txt").path, encoding: .utf8)) == "LINKED!\n",
                       "and doesn't write over it")
                sheetButton(tab, "Cancel")?.performClick(nil)
            },
            sync {
                expect(tab.window?.attachedSheet == nil && tab.doc.isDirty, "Cancel leaves the tab unsaved")
                // Dangling: the file the link points at is gone.
                try? fm.removeItem(at: folder.appendingPathComponent("link-third.txt"))
                tab.reloadIfChangedOnDisk()
            },
            sync {
                expect(tab.diskBar?.label.stringValue.contains("was deleted or moved") == true && tab.doc.isDirty
                       && tab.text.contains(" mine"), "a dangling link shows the deleted bar and keeps the text",
                       "\(tab.text) / \(tab.diskBar?.label.stringValue ?? "no bar") / sheet \(tab.window?.attachedSheet != nil)")
                // A link to a folder.
                let sub = folder.appendingPathComponent("link-folder", isDirectory: true)
                try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "link-folder")
                tab.reloadIfChangedOnDisk()
            },
            sync {
                expect(tab.text.contains(" mine") && tab.doc.isDirty, "a link to a folder keeps the text, unsaved", tab.text)
                expect(tab.diskBar?.isHidden == false && tab.diskBar?.label.stringValue.contains("changed on disk") == true,
                       "and shows the Changed on disk bar", tab.diskBar?.label.stringValue ?? "no bar")
            },
        ]
    }
}
