import AppKit
import CedricCore

/// Open in Terminal Here (File menu, the folder sidebar's menus): Terminal
/// opens a window at the folder (TerminalHere in CedricCore picks it).
/// NSWorkspace opens the folder's URL with Terminal's app URL: no shell
/// string, no AppleScript, nothing to escape. Checks never launch it:
/// `opener` only records the folder there.
@MainActor
enum TerminalOpener {
    static let dryRun = DevEnvironment.values["CEDRIC_CHECK"] != nil
    /// The folders asked for in a check run.
    static var opened: [URL] = []
    static var opener: @MainActor (URL) -> Void = dryRun ? { @MainActor in opened.append($0) } : { @MainActor in launch($0) }

    static func open(_ folder: URL) { opener(folder) }

    private static func launch(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalHere.terminalBundleID) else {
            NSSound.beep(); return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let text = error.localizedDescription
            Task { @MainActor in
                let a = NSAlert()
                a.messageText = String(localized: "Terminal couldn’t be opened here")
                a.informativeText = text
                a.runModal()
            }
        }
    }
}

extension AppDelegate {
    /// File › Open in Terminal Here: the tab's file's folder (off when untitled).
    @objc func openInTerminalMenu(_ sender: Any?) {
        guard let folder = TerminalHere.folder(forDocument: currentFileURL) else { NSSound.beep(); return }
        TerminalOpener.open(folder)
    }
}
