import AppKit
import CedricCore

// What a preview link click does (security audit H2): web and mail links
// open after the user confirms the full URL; a text file in the document's
// folder opens in Cedric; any other local file is shown in Finder, never
// opened or launched; every other scheme is ignored with a note.
/// Checks run with the system calls recorded, not made (nothing opens Finder or a browser).
@MainActor
enum PreviewLinkLog {
    static let dryRun = DevEnvironment.values["CEDRIC_CHECK"] != nil
    static var revealed: [URL] = []
    static var opened: [URL] = []
    static func reveal(_ u: URL) { if dryRun { revealed.append(u) } else { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    static func open(_ u: URL) { if dryRun { opened.append(u) } else { NSWorkspace.shared.open(u) } }
}

extension EditorWindowController {
    func previewLink(_ action: PreviewLinkAction) {
        switch action {
        case .openInPreview:
            break // handled by PreviewController
        case .openInCedric(let url):
            (NSApp.delegate as? AppDelegate)?.open(url, background: true)
        case .revealInFinder(let url):
            PreviewLinkLog.reveal(url)
        case .confirmExternal(let url):
            confirmExternalLink(url)
        case .ignore(let why):
            let text = why == "missing"
                ? String(localized: "The preview link points to a file that isn't there.")
                : String(localized: "Owlink doesn't follow “\(why):” links from a preview.")
            showNotice(text, buttons: [])
        }
    }

    private func confirmExternalLink(_ url: URL) {
        // The load and script setting the link was asked from (the page
        // may reload while the prompt is up).
        let load = preview?.pageLoads ?? 0, script = preview?.allowJavaScript ?? false
        LinkPrompt.confirmExternal(url, in: previewPane?.window ?? window) { [weak self] opened in
            self?.preview?.externalLinkAnswered(opened: opened, load: load, scriptCanClick: script)
        }
    }
}

/// The "Open this link?" question, shared by the Markdown preview and PDF tabs.
/// One at a time: a link asked for while a prompt is showing is dropped, so
/// page script clicking a link over and over can't stack prompts.
@MainActor
enum LinkPrompt {
    /// The prompt showing now (weak: gone with its alert, so a prompt
    /// closed without an answer never blocks the next one).
    private static weak var current: NSWindow?
    /// Prompts shown, and dropped because one was showing (for checks).
    private(set) static var shown = 0
    private(set) static var dropped = 0

    static func confirmExternal(_ url: URL, in window: NSWindow?, answered: @escaping @MainActor (Bool) -> Void = { _ in }) {
        if current?.isVisible == true { dropped += 1; return }
        shown += 1
        let a = NSAlert()
        current = a.window
        a.messageText = url.scheme?.lowercased() == "mailto" ? String(localized: "Write an email?") : String(localized: "Open this link?")
        // The site on a line of its own, then the URL (whole, or cut in the
        // middle keeping the host), so a misleading link text or a user name
        // dressed as a site (`https://www.apple.com%2Fsignin@evil.example/`)
        // can't hide where it goes (bidi and control characters shown as
        // escapes: ExternalLinkText).
        let text = ExternalLinkText(url)
        var lines: [String] = []
        if let host = text.host { lines.append(String(localized: "Site: \(host)")) }
        // A host that isn't plain ASCII (`аpple.com`, Cyrillic а) is shown as
        // the punycode the browser opens, then flagged with how it reads.
        if let unicode = text.unicodeHost, let host = text.host {
            lines.append(String(localized: "The site’s name is not plain ASCII: \(host) reads as “\(unicode)”, which can imitate another site."))
        }
        if let user = text.userinfo, let host = text.host {
            lines.append(String(localized: "Before the “@” is a user name (“\(user)”), not the site. This link goes to \(host)."))
        }
        lines.append(text.url)
        a.informativeText = lines.joined(separator: "\n\n")
        // Cancel is the default: Return (a newline typed while page script
        // raised the prompt) and Escape both answer Cancel; Open takes a
        // deliberate click (or Tab and Space).
        let openButton = a.addButton(withTitle: String(localized: "Open"))
        let cancelButton = a.addButton(withTitle: String(localized: "Cancel"))
        openButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"
        let alertWindow = a.window
        // A button has one key equivalent: Escape is caught for the alert's window here.
        var escape: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak cancelButton] e in
            guard e.window === alertWindow, e.keyCode == 53 else { return e }
            cancelButton?.performClick(nil)
            return nil
        }
        let open: (NSApplication.ModalResponse) -> Void = { r in
            if let m = escape { NSEvent.removeMonitor(m); escape = nil }
            let yes = r == .alertFirstButtonReturn
            if yes { PreviewLinkLog.open(url) }
            answered(yes)
        }
        if let w = window, w.isVisible, w.attachedSheet == nil {
            a.beginSheetModal(for: w, completionHandler: open)
        } else {
            open(a.runModal())
        }
    }
}
