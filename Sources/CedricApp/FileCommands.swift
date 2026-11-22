import AppKit
import CedricCore

// File › Revert to Saved, Save All (⌥⌘S) and Close Window (⇧⌘W).

extension AppDelegate {
    /// Replaces the tab's text with the file on disk, as one edit that ⌘Z
    /// takes back (so it needs no "are you sure?").
    @objc func revertToSaved(_ sender: Any?) {
        guard let t = currentTab, t.doc.fileURL != nil else { NSSound.beep(); return }
        t.reloadFromDisk()
        t.textView.undoManager?.setActionName(String(localized: "Revert to Saved"))
    }

    /// Saves every tab with unsaved changes, in tab order; an untitled tab
    /// with text asks where (cancelling that stops Save All there).
    @objc func saveAll(_ sender: Any?) {
        finishRestore()
        for group in tabGroups() {
            for t in group where t.doc.isDirty {
                if t.doc.fileURL == nil { t.window?.makeKeyAndOrderFront(nil) }
                if !t.save(), t.doc.fileURL == nil { return }
            }
        }
    }

    var hasUnsavedTabs: Bool { tabs.contains { $0.doc.isDirty } }

    /// Closes every tab in the front window. On a quit-causing last window,
    /// the session is saved while those tabs are still open (when reopen is on).
    @objc func closeWindow(_ sender: Any?) {
        guard let w = currentTab?.window else { return }
        closeDocumentWindows(in: w)
    }

    func validateFileItem(_ item: NSMenuItem) -> Bool? {
        let tab = currentTab
        switch item.action {
        case #selector(revertToSaved(_:)):
            guard let tab, tab.doc.fileURL != nil else { return false }
            return tab.doc.isDirty || tab.doc.changedOnDisk
        case #selector(saveAll(_:)): return hasUnsavedTabs
        case #selector(closeWindow(_:)): return tab != nil
        default: return nil
        }
    }
}
