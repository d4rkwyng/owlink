import AppKit
import CedricCore

/// Closing a tab with unsaved edits to a real file keeps the edits for
/// Reopen Closed Tab (ClosedTabs.swift), but the file isn't written. Once
/// per launch, the tab that comes forward says so, with Save Now.
@MainActor
enum CloseNotice {
    static var shown = false
}

extension AppDelegate {
    /// A file tab with unsaved edits was closed: the notice, once per launch.
    func noteClosedUnsaved(id: UUID, name: String) {
        guard !CloseNotice.shown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !CloseNotice.shown, let tab = self.currentTab ?? self.tabs.last else { return }
            CloseNotice.shown = true
            tab.showNotice(String(localized: "Your changes to “\(name)” weren’t saved to the file. Reopen Closed Tab (⇧⌘T) brings them back."),
                           buttons: [(String(localized: "Save Now"), { [weak self, weak tab] in
                               tab?.noticeBar?.isHidden = true
                               self?.saveClosedTab(id)
                           })])
        }
    }

    /// Save Now: reopens the closed tab, saves it (through the ⌘S
    /// conflict check) and, if that wrote the file, closes it again.
    func saveClosedTab(_ id: UUID) {
        // Reopened already (⇧⌘T): save that tab.
        if let open = tabs.first(where: { $0.doc.id == id }) { _ = open.save(); return }
        guard let tab = reopenClosed(id) else { return }
        // Reopened as untitled (the file is open again in another tab): leave it for the user.
        guard tab.doc.fileURL != nil else { return }
        if tab.save() { tab.window?.performClose(nil) }
    }

    /// Quit's Save As when only closed tabs' text is at risk: reopens the
    /// closed tab and runs Save As on it.
    func saveAsClosedTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.doc.id == id }) ?? reopenClosed(id) else { return }
        tab.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { _ = tab.saveAs() }
    }

    /// Reopens closed tab `id` as ⇧⌘T would (moved to the end of the list,
    /// not passed over): the tab, or nil if it didn't reopen.
    private func reopenClosed(_ id: UUID) -> EditorWindowController? {
        guard let i = closedTabs.lastIndex(where: { $0.id == id }) else { NSSound.beep(); return nil }
        let entry = closedTabs.remove(at: i)
        closedTabs.append(entry)
        closedTabsPassedOver.remove(id)
        let before = tabs.count
        reopenClosedTab(nil)
        guard tabs.count > before, let tab = tabs.last, tab.doc.id == id else { return nil }
        return tab
    }
}

