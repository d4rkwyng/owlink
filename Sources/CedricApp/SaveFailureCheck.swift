import AppKit
import CedricCore

/// Part of CEDRIC_CHECK=readonly: a save that fails says why (0.5.4 QA
/// #6). A pipe put in a file's place in a 0555 folder, then ⌘S and Keep
/// (QA A1f): the alert names the reason, says the text is still in the
/// tab and offers Save As… and Cancel, not a lone OK with an empty body;
/// Save As… saves the tab's text to the place chosen.
@MainActor
extension DevChecks {
    /// The sheet's labels (message and informative text), in view order.
    static func sheetTexts(_ tab: EditorWindowController) -> [String] {
        func find(_ v: NSView) -> [String] {
            var out: [String] = []
            if let f = v as? NSTextField, !f.isEditable, !f.stringValue.isEmpty { out.append(f.stringValue) }
            for s in v.subviews { out += find(s) }
            return out
        }
        return tab.window?.attachedSheet?.contentView.map(find) ?? []
    }

    static func saveFailureSteps(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        let url = write("sf/fifo.md", "mine\n")
        let folder = url.deletingLastPathComponent()
        var tab: EditorWindowController!
        func restore() { chmod(folder.path, 0o755) }
        let elsewhere = write("sf-elsewhere/saved-elsewhere.md", "old\n")
        return [
            sync {
                guard let t = app.open(url) else { expect(false, "save failure: opened fifo.md"); return }
                tab = t
                sized(t)
                focus(t)
                t.textView.setSelectedRange(NSRange(location: 4, length: 0))
                type(" one")
                unlink(url.path)
                expect(mkfifo(url.path, 0o644) == 0 && chmod(folder.path, 0o555) == 0, "save failure: a pipe in its place, folder 0555")
                key("s", [.command])
            },
            sync {
                guard let tab else { return }
                expect(sheetButton(tab, EditorWindowController.conflictKeep) != nil, "save failure: ⌘S asks first (the file changed)")
                sheetButton(tab, EditorWindowController.conflictKeep)?.performClick(nil)
            },
            sync {
                guard let tab else { return }
                let texts = sheetTexts(tab)
                expect(tab.window?.attachedSheet != nil, "save failure: Keep can't save, and an alert says so")
                expect(texts.first == "Couldn’t save “fifo.md”.", "save failure: the headline names the file", texts.joined(separator: " | "))
                let detail = texts.dropFirst().joined(separator: " ")
                expect(detail.contains("not a regular file") && detail.contains("pipe"), "save failure: …says why (a pipe)", detail)
                expect(detail.contains("Your text is still in this tab"), "save failure: …says the text is still in the tab", detail)
                expect(!texts.joined().contains("couldn’t be saved in the folder"), "save failure: …not Foundation's bare headline",
                       texts.joined(separator: " | "))
                expect(sheetButton(tab, "Save As…") != nil && sheetButton(tab, "Cancel") != nil && sheetButton(tab, "OK") == nil,
                       "save failure: …offers Save As… and Cancel, not a lone OK")
                expect(sheetButton(tab, "Cancel")?.keyEquivalent == "\u{1b}", "save failure: …Esc cancels")
            },
            sync {
                guard let tab else { return }
                sheetButton(tab, "Cancel")?.performClick(nil)
                expect(tab.text == "mine one\n" && tab.doc.isDirty, "save failure: Cancel keeps the text, unsaved", tab.text)
            },
            // ⌘S only once the alert has gone: with a sheet still attached
            // AppKit may not send it to the tab.
            waitFor("save failure: the alert is dismissed") { tab?.window?.attachedSheet == nil },
            sync {
                // Codex round 2: and Save As… from the same alert saves it elsewhere.
                key("s", [.command])
            },
            sync {
                guard let tab else { return }
                sheetButton(tab, EditorWindowController.conflictKeep)?.performClick(nil)
            },
            sync {
                guard let tab else { return }
                expect(sheetButton(tab, "Save As…") != nil, "save failure: the alert again, with Save As…")
                EditorWindowController.checkSaveAsURL = elsewhere
                sheetButton(tab, "Save As…")?.performClick(nil)
            },
            waitFor("save failure: Save As… saves it elsewhere") { tab?.doc.fileURL == elsewhere },
            sync {
                guard let tab else { return }
                expect(EditorWindowController.checkSaveAsURL == nil, "save failure: Save As… opened the panel (the check's choice used)")
                expect((try? Data(contentsOf: elsewhere)) == Data("mine one\n".utf8), "save failure: …the tab's text, in the new file",
                       (try? String(contentsOf: elsewhere, encoding: .utf8)) ?? "-")
                expect(tab.doc.fileURL == elsewhere, "save failure: …the tab is that file now", tab.doc.fileURL?.path ?? "-")
                expect(!tab.doc.isDirty && tab.window?.attachedSheet == nil, "save failure: …saved, clean, no sheet left")
                expect(tab.window?.title.hasPrefix("saved-elsewhere.md") == true, "save failure: …and titled so", tab.window?.title ?? "-")
                restore()
                unlink(url.path)
                tab.window?.performClose(nil)
            },
        ]
    }
}
