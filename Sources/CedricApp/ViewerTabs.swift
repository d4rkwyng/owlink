import AppKit
import CedricCore

/// A read-only viewer tab (PDF, image, Office / iWork): its own window in
/// the editor's tab group, never written. AppDelegate keeps each kind in
/// its own list (`pdfTabs`, `imageTabs`, `officeTabs`); this is what they
/// share for the session, Reopen Closed Tab, `cedric -w` and "which tab is
/// in front".
@MainActor
protocol ViewerTab: NSWindowController {
    var id: UUID { get }
    var fileURL: URL { get set }
    var sessionTab: SessionTab { get }
    func reloadIfChangedOnDisk()
}

extension PDFTabController: ViewerTab {}

@MainActor
final class ViewerSidebarHost: NSStackView {
    let split = NSSplitView()
    private let missing = NoticeBar(symbol: "exclamationmark.arrow.circlepath")

    init(content: NSView) {
        super.init(frame: content.frame)
        orientation = .vertical
        alignment = .width
        spacing = 0
        detachesHiddenViews = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(content)
        split.setContentHuggingPriority(.init(1), for: .vertical)
        addArrangedSubview(missing)
        addArrangedSubview(split)
        missing.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showMissing(_ url: URL) {
        missing.show(String(localized: "“\(url.lastPathComponent)” was deleted or moved."), buttons: [
            (String(localized: "Keep Open"), { [weak self] in self?.missing.isHidden = true })
        ])
        missing.setAccessibilityLabel(missing.label.stringValue)
    }
}

extension ViewerTab {
    var sidebarHost: ViewerSidebarHost? {
        guard let window, let content = window.contentView else { return nil }
        if let host = content as? ViewerSidebarHost { return host }
        let host = ViewerSidebarHost(content: content)
        window.contentView = host
        return host
    }

    func followRename(_ url: URL) {
        fileURL = url
        window?.title = url.lastPathComponent
        window?.representedURL = url
        window?.tab.toolTip = url.path
    }
}

extension AppDelegate {
    /// Every viewer tab, of every kind.
    var viewerTabs: [any ViewerTab] {
        pdfTabs.map { $0 as any ViewerTab } + imageTabs.map { $0 as any ViewerTab } + officeTabs.map { $0 as any ViewerTab }
            + certificateTabs.map { $0 as any ViewerTab }
    }

    /// The viewer tab showing this file, if one is open.
    func viewerTab(for url: URL) -> (any ViewerTab)? {
        let std = url.standardizedFileURL
        return viewerTabs.first { $0.fileURL.standardizedFileURL == std }
    }

    func viewerTab(for window: NSWindow) -> (any ViewerTab)? {
        viewerTabs.first { $0.window === window }
    }

    /// The viewer tab in front, if the front tab is one (nil when a text tab is).
    var currentViewerTab: (any ViewerTab)? {
        if let pass = validationPass { return pass.viewer }
        let viewers = viewerTabs
        guard !viewers.isEmpty else { return nil }
        if let k = NSApp.keyWindow, tabs.contains(where: { $0.window === k }) { return nil }
        if let v = viewers.first(where: { $0.window === NSApp.keyWindow }) ?? viewers.first(where: { $0.window === NSApp.mainWindow }) {
            return v
        }
        guard NSApp.keyWindow == nil, NSApp.mainWindow == nil else { return nil }
        // Not active: the frontmost of Cedric's tabs.
        for w in NSApp.orderedWindows {
            if let v = viewers.first(where: { $0.window === w }) { return v }
            if tabs.contains(where: { $0.window === w }) { return nil }
        }
        return nil
    }

    /// The one empty, untouched untitled tab, which a newly opened file replaces.
    var replaceableBlankTab: EditorWindowController? {
        tabs.count == 1 && viewerTabs.isEmpty && tabs[0].doc.fileURL == nil && !tabs[0].doc.isDirty && tabs[0].text.isEmpty ? tabs[0] : nil
    }

    /// Puts a viewer tab's window in the tab bar (in `group` at
    /// `tabIndex` when restoring), as makePDFTab does.
    func placeViewerWindow(_ window: NSWindow, in group: NSWindow?, newWindow: Bool, show: Bool, tabIndex: Int?) {
        let host = newWindow ? nil : group ?? AppDelegate.documentKeyWindow ?? (tabs.last?.window ?? viewerTabs.last { $0.window !== window }?.window)
        if let tabIndex, let host = group, host !== window, let tg = host.tabGroup {
            tg.insertWindow(window, at: min(tabIndex, tg.windows.count))
            adoptFloat(of: host, for: window)
        } else if let host, host !== window, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
            adoptFloat(of: host, for: window)
        } else {
            window.center()
        }
        if show { window.makeKeyAndOrderFront(nil) }
        scheduleSessionSave()
    }

    /// A closed viewer tab, for File › Reopen Closed Tab (no text to keep).
    func rememberClosedViewer(_ t: any ViewerTab, persist: Bool = true) {
        finishRestore()
        let r = ClosedTabs.push(t.sessionTab, onto: closedTabs)
        closedTabs = r.list
        for gone in r.dropped {
            closedTexts[gone.id] = nil
            if gone.hasBuffer { store.removeBuffer(gone.id) }
        }
        if persist { saveSession() }
    }

    /// A viewer can't open the file: an alert on the front window.
    func viewerAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .warning
        if let w = currentTab?.window ?? currentViewerTab?.window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// Reopen Closed Tab / restore for an image or Office tab.
    func reopenClosedViewer(_ st: SessionTab) {
        guard let path = st.path else { return }
        let url = URL(fileURLWithPath: path)
        if let open = viewerTab(for: url) {
            open.window?.makeKeyAndOrderFront(nil)
        } else if FileManager.default.fileExists(atPath: path) {
            if st.image != nil {
                makeImageTab(ImageTabController(fileURL: url, id: st.id, state: st.image ?? ImageTabState())).ensureLoaded()
            } else if st.certificate != nil {
                makeCertificateTab(CertificateTabController(fileURL: url, id: st.id)).ensureLoaded()
            } else {
                makeOfficeTab(OfficeTabController(fileURL: url, id: st.id)).ensureLoaded()
            }
        } else {
            NSSound.beep()
        }
        saveSession()
    }

    /// A saved image or Office tab. The selected tab of a window (`place`
    /// nil) loads now; the others when first shown.
    func restoreViewerTab(_ st: SessionTab, into place: (host: NSWindow, index: Int)?) -> NSWindowController? {
        guard let path = st.path, FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if st.image != nil {
            let tab = makeImageTab(ImageTabController(fileURL: url, id: st.id, state: st.image ?? ImageTabState()),
                                   in: place?.host, newWindow: place == nil, show: false, tabIndex: place?.index)
            if place == nil { tab.ensureLoaded() }
            return tab
        }
        if st.certificate != nil {
            let tab = makeCertificateTab(CertificateTabController(fileURL: url, id: st.id), in: place?.host, newWindow: place == nil,
                                         show: false, tabIndex: place?.index)
            if place == nil { tab.ensureLoaded() }
            return tab
        }
        let tab = makeOfficeTab(OfficeTabController(fileURL: url, id: st.id), in: place?.host, newWindow: place == nil, show: false, tabIndex: place?.index)
        if place == nil { tab.ensureLoaded() }
        return tab
    }

    /// The app that opens this file by default, other than Cedric (for
    /// "Open in Default App"): nil if there is none.
    static func defaultApp(for url: URL) -> URL? {
        let me = Bundle.main.bundleURL.standardizedFileURL
        if let d = NSWorkspace.shared.urlForApplication(toOpen: url), d.standardizedFileURL != me { return d }
        return NSWorkspace.shared.urlsForApplications(toOpen: url).first { $0.standardizedFileURL != me }
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The checks set this instead of launching another app.
    nonisolated(unsafe) static var openWithOverride: ((_ file: URL, _ app: URL) -> Void)?

    static func openInDefaultApp(_ url: URL) {
        guard let app = defaultApp(for: url) else { NSSound.beep(); return }
        if let o = openWithOverride { o(url, app); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// File › Open in <App>'s title for this file.
    static func openInTitle(_ url: URL) -> String {
        defaultApp(for: url).map { String(localized: "Open in \(appName($0))") } ?? String(localized: "Open in Default App")
    }
}
