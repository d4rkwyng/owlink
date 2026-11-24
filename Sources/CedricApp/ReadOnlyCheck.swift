import AppKit
import CedricCore

/// CEDRIC_CHECK=readonly: a file the user can't write (ReadOnlyFile.swift).
/// A 0444 file opens read-only with the bar and a title mark; typing
/// changes nothing; ⌘S asks (Save As / Cancel) and leaves the bytes and
/// the mode alone; Cedric's Apply says read-only. chmod 644 while open
/// (seen when the window becomes key): a normal tab that saves. chmod
/// 444 again: read-only again; Allow Editing takes typing, but ⌘S still
/// won't write over it and Apply stays off. Reload (the Changed on disk
/// bar) and Revert to Saved on a dirty tab whose file went 0444 take the
/// file's text, stay read-only and undo back to the unsaved edits. A
/// Finder-locked file is read-only too.
extension DevChecks {
    static func readOnlyCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "readonly" else { return false }
        let original = "# Read me\n\nTry editing it.\n"
        let file = write("ro/readonly.md", original)
        let locked = write("ro/locked.md", original)
        chmod(file.path, 0o444)
        func bytes(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<unreadable>" }
        func mode(_ u: URL) -> mode_t { var st = stat(); _ = stat(u.path, &st); return st.st_mode & 0o777 }
        guard let tab = app.open(file) else { expect(false, "opened readonly.md"); finish(); return true }
        sized(tab)
        let snap = OwlDocumentSnapshot(text: original, generation: tab.doc.changeCount, fileName: "readonly.md", language: "markdown")
        let proposal = try? OwlEditProposal.anchored(find: "Try editing it.", replace: "Editing this file is not permitted.", in: snap).get()
        func applyState() -> OwlEditProposal.ApplyState? { proposal.map { tab.chatPanel().state(of: $0) } }
        func dismissSheet() { if let w = tab.window, let s = w.attachedSheet { w.endSheet(s, returnCode: .alertSecondButtonReturn) } }
        let reload = write("ro/reload.md", "disk one\n")
        let mine = "disk one mine\n", theirs = "disk two, longer\n"
        var reloadTab: EditorWindowController?
        func becomeKey() { tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: tab.window)) }
        run([
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.makeFirstResponder(tab.textView)
                expect(tab.fileReadOnly == .permissions, "a 0444 file opens read-only", String(describing: tab.fileReadOnly))
                expect(!tab.textView.isEditable, "the text view is read-only")
                expect(tab.readOnlyBar?.isHidden == false && tab.readOnlyBar?.label.stringValue.contains("read-only") == true,
                       "the bar says so", tab.readOnlyBar?.label.stringValue ?? "no bar")
                expect(tab.readOnlyBar?.button("Allow Editing") != nil && tab.readOnlyBar?.button("Save As…") != nil,
                       "…with Allow Editing and Save As")
                expect(tab.window?.title.contains("— Read-Only") == true, "the title says Read-Only", tab.window?.title ?? "-")
                expect(applyState() == .readOnly, "Cedric's Apply is read-only", String(describing: applyState()))
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                key("x")
                expect(tab.text == original && !tab.doc.isDirty, "typing changes nothing", tab.text)
            },
            sync {
                key("s", [.command])
                expect(tab.window?.attachedSheet != nil, "⌘S asks instead of saving")
                dismissSheet()
                expect(bytes(file) == original && mode(file) == 0o444, "the file is untouched (bytes and mode 0444)",
                       String(format: "%o", mode(file)))
            },
            sync {
                // chmod 644 while open: seen when the window becomes key.
                chmod(file.path, 0o644)
                becomeKey()
                expect(tab.fileReadOnly == nil && tab.textView.isEditable, "chmod 644: editable again")
                expect(tab.readOnlyBar?.isHidden == true, "…the bar goes")
                expect(tab.window?.title.contains("Read-Only") == false, "…and the title mark", tab.window?.title ?? "-")
                if case .ready = applyState() {} else { expect(false, "…and Apply is back", String(describing: applyState())) }
                tab.window?.makeFirstResponder(tab.textView)
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                key("x")
                key("s", [.command])
                expect(tab.window?.attachedSheet == nil && bytes(file) == original + "x", "…and ⌘S saves", bytes(file))
            },
            sync {
                // chmod 444 again: read-only again (on save too, before the window is key).
                chmod(file.path, 0o444)
                tab.textView.insertText("y", replacementRange: tab.textView.selectedRange())
                key("s", [.command])
                expect(tab.fileReadOnly == .permissions && !tab.textView.isEditable, "chmod 444: ⌘S sees it read-only")
                dismissSheet()
                expect(bytes(file) == original + "x" && mode(file) == 0o444, "…and doesn't write (the last save's bytes)", bytes(file))
            },
            sync {
                // Allow Editing: typing works; Save still asks, Apply stays off.
                if let b = tab.readOnlyBar?.button("Allow Editing") { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(tab.textView.isEditable, "Allow Editing: the buffer takes typing")
                expect(tab.readOnlyBar?.button("Allow Editing") == nil && tab.readOnlyBar?.isHidden == false, "…the bar stays, without the button")
                tab.window?.makeFirstResponder(tab.textView)
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                key("z")
                expect(tab.text.hasSuffix("z"), "…typed text lands", String(tab.text.suffix(4)))
                expect(applyState() == .readOnly, "…Apply stays read-only", String(describing: applyState()))
                key("s", [.command])
                expect(tab.window?.attachedSheet != nil, "…⌘S still asks")
                dismissSheet()
                expect(bytes(file) == original + "x" && mode(file) == 0o444, "…and never writes over it", bytes(file))
            },
            snapshot("readonly.png"),
            sync {
                // Reload / Revert on a tab whose file turned read-only (0444)
                // and changed on disk while it had unsaved edits: the buffer
                // takes the file's text (Undo brings the edits back), the
                // tab stays read-only, and nothing unsaved is marked saved.
                // Before the fix the read-only view refused the replacement
                // but the tab was still marked saved with the old text.
                reloadTab = app.open(reload)
                guard let r = reloadTab else { expect(false, "opened reload.md"); return }
                sized(r)
                focus(r)
                r.textView.setSelectedRange(NSRange(location: 8, length: 0))
                type(" mine")
                expect(r.text == mine && r.doc.isDirty, "reload: unsaved edits typed", r.text)
            },
            sync {
                // Its own run-loop turn: Undo groups by event.
                guard let r = reloadTab else { return }
                rewriteElsewhere(reload, theirs)
                chmod(reload.path, 0o444)
                r.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: r.window))
                expect(r.fileReadOnly == .permissions && !r.textView.isEditable, "…chmod 444 while dirty: read-only")
                expect(r.diskBar?.isHidden == false && r.text == mine && r.doc.isDirty, "…the Changed on disk bar, edits kept",
                       r.diskBar?.label.stringValue ?? "no bar")
            },
            sync {
                guard let r = reloadTab else { return }
                // The bar's Reload.
                r.diskBar?.button("Reload")?.performClick(nil)
                expect(r.text == theirs, "Reload on a read-only tab takes the file's text", r.text)
                expect(!(r.text == mine && !r.doc.isDirty), "…never the unsaved text marked saved", r.text)
                expect(!r.doc.isDirty && r.diskBar?.isHidden == true, "…saved, and the bar goes",
                       "dirty \(r.doc.isDirty) bar \(String(describing: r.diskBar?.isHidden))")
                expect(r.fileReadOnly == .permissions && !r.textView.isEditable, "…and the tab stays read-only")
            },
            sync {
                guard let r = reloadTab else { return }
                r.textView.undoManager?.undo()
            },
            sync {
                // Undo's dirty state catches up on the next turn (storageEdited).
                guard let r = reloadTab else { return }
                expect(r.text == mine && r.doc.isDirty, "…Undo brings the unsaved edits back, unsaved", r.text)
                expect(!r.textView.isEditable, "…still read-only after Undo")
                key("x")
                expect(r.text == mine, "…typing is still refused", r.text)
            },
            sync {
                guard let r = reloadTab else { return }
                // File › Revert to Saved, the same way.
                app.revertToSaved(nil)
                expect(r.text == theirs && !r.doc.isDirty, "Revert to Saved on a read-only tab takes the file's text", r.text)
                expect(!r.textView.isEditable && r.fileReadOnly == .permissions, "…and stays read-only")
            },
            sync {
                guard let r = reloadTab else { return }
                r.textView.undoManager?.undo()
            },
            sync {
                guard let r = reloadTab else { return }
                expect(r.text == mine && r.doc.isDirty, "…Undo brings the edits back, unsaved", r.text)
                app.revertToSaved(nil)
                expect(bytes(reload) == theirs && mode(reload) == 0o444, "…the file is untouched", bytes(reload))
                chmod(reload.path, 0o644)
            },
            sync {
                // Locked in the Finder (uchg), mode 0644.
                guard chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0 else { expect(false, "chflags uchg"); return }
                guard let t = app.open(locked) else { expect(false, "opened locked.md"); return }
                expect(t.fileReadOnly == .locked && !t.textView.isEditable, "a locked file opens read-only")
                expect(t.readOnlyBar?.label.stringValue.contains("locked") == true, "…and the bar says locked",
                       t.readOnlyBar?.label.stringValue ?? "no bar")
                chflags(locked.path, 0)
                t.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: t.window))
                expect(t.fileReadOnly == nil && t.textView.isEditable, "unlocked: editable")
                // Leave nothing unsaved or read-only behind.
                chmod(file.path, 0o644)
            },
        ])
        return true
    }
}
