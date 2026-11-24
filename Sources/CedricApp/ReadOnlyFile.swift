import AppKit
import CedricCore

/// A tab on a file the user can't write (FileWriteAccess in CedricCore:
/// chmod 444, locked in the Finder, a read-only volume). Like a binary
/// file's Open Anyway: the text shows read-only under a bar that says
/// why, with Allow Editing. Allow Editing lets the buffer take typing, but
/// the file stays read-only: Save offers Save As and never writes over
/// it, and Cedric's Apply stays off ("A read-only document never
/// applies"). Checked at open, when the window becomes key, on save and
/// before Apply, so a chmod while the file is open takes effect: a file
/// that becomes writable is a normal tab again.
extension EditorWindowController {
    /// Typing is off: the file is read-only and Allow Editing wasn't chosen.
    var fileBlocksTyping: Bool { fileReadOnly != nil && !readOnlyEditingAllowed }

    /// Editable as far as the binary state and Follow File go.
    private var editableApartFromFile: Bool {
        tail == nil && (binary == nil || binary == .editable)
    }

    /// Reads the file's write access again and updates the tab if it changed.
    func recheckWriteAccess() {
        let now = doc.fileURL.flatMap { FileWriteAccess.blocked(at: $0) }
        guard now != fileReadOnly else { return }
        fileReadOnly = now
        if now == nil { readOnlyEditingAllowed = false }
        setEditable(editableApartFromFile)
        showReadOnlyBar()
        updateTitle()
        owlChat?.refreshCards()
    }

    /// Runs `replace` with the panes editable for a read-only file, so a
    /// replacement the user asked for from disk (Reload, Revert to Saved,
    /// Reload Theirs) gets past `shouldChangeText` and registers for Undo;
    /// typing, Find/Replace and Apply stay refused. Read-only again after.
    /// Only the file's read-only state is lifted: binary text and Follow
    /// File stay as they are.
    func replacingFromDisk<T>(_ replace: () -> T) -> T {
        guard fileBlocksTyping, editableApartFromFile else { return replace() }
        panes.forEach { $0.textView.isEditable = true }
        defer { setEditable(editableApartFromFile) }
        return replace()
    }

    /// Allow Editing: the buffer takes typing; the file stays read-only.
    func allowReadOnlyEditing() {
        guard fileReadOnly != nil else { return }
        readOnlyEditingAllowed = true
        setEditable(editableApartFromFile)
        showReadOnlyBar()
        window?.makeFirstResponder(textView)
    }

    private func showReadOnlyBar() {
        guard let reason = fileReadOnly else { readOnlyBar?.isHidden = true; return }
        let bar: NoticeBar
        if let b = readOnlyBar {
            bar = b
        } else {
            bar = NoticeBar(symbol: "lock")
            stack.insertArrangedSubview(bar, at: 0)
            readOnlyBar = bar
        }
        var buttons: [(String, () -> Void)] = [(String(localized: "Save As…"), { [weak self] in _ = self?.saveAs() })]
        if !readOnlyEditingAllowed {
            buttons.insert((String(localized: "Allow Editing"), { [weak self] in self?.allowReadOnlyEditing() }), at: 0)
        }
        bar.show(FileWriteAccess.notice(reason, name: doc.displayName), buttons: buttons)
        bar.setAccessibilityLabel(bar.label.stringValue)
        bar.isHidden = false
    }

    /// ⌘S on a read-only file: say so and offer Save As; never write over it.
    func askSaveReadOnly(_ url: URL, _ reason: FileWriteAccess.Blocked) {
        let a = NSAlert()
        a.messageText = String(localized: "“\(url.lastPathComponent)” is read-only.")
        a.informativeText = FileWriteAccess.notice(reason, name: url.lastPathComponent)
        a.addButton(withTitle: String(localized: "Save As…"))
        a.addButton(withTitle: String(localized: "Cancel"))
        if let window, window.isVisible {
            a.beginSheetModal(for: window) { [weak self] r in
                if r == .alertFirstButtonReturn { _ = self?.saveAs() }
            }
        } else if a.runModal() == .alertFirstButtonReturn {
            _ = saveAs()
        }
    }
}
