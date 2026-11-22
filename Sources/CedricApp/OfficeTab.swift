import AppKit
import CedricCore

/// Quick Look's preview view (QLPreviewView, in Quartz's QuickLookUI),
/// looked up at run time: linking Quartz would load QuickLookUI and its
/// dependencies on every launch for tabs most sessions never open.
@MainActor
enum QuickLookUI {
    private static var loaded = false

    static var previewViewClass: NSView.Type? {
        if !loaded {
            loaded = true
            for path in ["/System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/QuickLookUI",
                         "/System/Library/Frameworks/QuickLookUI.framework/QuickLookUI",
                         "/System/Library/Frameworks/Quartz.framework/Quartz"] where dlopen(path, RTLD_NOW) != nil { break }
        }
        return NSClassFromString("QLPreviewView") as? NSView.Type
    }

    /// A QLPreviewView showing `url`, or nil if Quick Look isn't there.
    static func makePreview(_ url: URL) -> NSView? {
        guard let cls = previewViewClass else { return nil }
        let v = cls.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.setValue(true, forKey: "shouldCloseWithWindow")
        v.setValue(url as NSURL, forKey: "previewItem")
        return v
    }

    static func refresh(_ v: NSView) {
        let sel = NSSelectorFromString("refreshPreviewItem")
        if v.responds(to: sel) { v.perform(sel) }
    }

    static func close(_ v: NSView) {
        let sel = NSSelectorFromString("close")
        if v.responds(to: sel) { v.perform(sel) }
    }
}

/// One Office / iWork tab (.docx .doc .xlsx .xls .pptx .ppt .pages
/// .numbers .key .rtfd): Quick Look's read-only preview, in a window
/// tabbed with the editor's. File › Open as Text takes a Word document's
/// (or RTFD's) text into a new untitled tab; for a spreadsheet the same
/// item is Open Sheet as CSV. Never writes to the file.
///
/// Launch speed: QuickLookUI is loaded, and the preview made, only when
/// the tab is first shown.
@MainActor
final class OfficeTabController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ViewerTab {
    let id: UUID
    var fileURL: URL
    let format: OfficeFormat?
    private(set) var isLoaded = false
    private(set) var preview: NSView?
    private(set) var message: String?
    private var fileModified: Date?
    private let body = NSView()
    let statusBar = StatusBar()
    private var appearanceObserver: NSObjectProtocol?
    /// Open as Text / Open Sheet as CSV is running (off the main thread).
    private(set) var extracting = false
    private(set) var lastError: String?

    var onChange: ((OfficeTabController) -> Void)?
    var onClose: ((OfficeTabController) -> Void)?

    init(fileURL: URL, id: UUID = UUID()) {
        self.id = id
        self.fileURL = fileURL
        self.format = OfficeFormat.detect(url: fileURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "CedricEditor"
        window.minSize = NSSize(width: 420, height: 240)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        for b in [statusBar.languageButton, statusBar.encodingButton, statusBar.lineEndingButton] { b.isHidden = true }
        let stack = NSStackView(views: [body, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        body.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.tab.toolTip = fileURL.path
        statusBar.position.stringValue = kindName
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(forName: .cedricAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var displayName: String { fileURL.lastPathComponent }

    var kindName: String {
        switch format {
        case .word: String(localized: "Word document")
        case .spreadsheet: String(localized: "Excel spreadsheet")
        case .presentation: String(localized: "PowerPoint presentation")
        case .pages: String(localized: "Pages document")
        case .numbers: String(localized: "Numbers spreadsheet")
        case .keynote: String(localized: "Keynote presentation")
        case .rtfd: String(localized: "RTFD document")
        case nil: String(localized: "Document")
        }
    }

    var palette: EditorPalette { Settings.shared.palette(for: window?.effectiveAppearance) }

    func applyAppearance() {
        window?.appearance = Settings.shared.windowAppearance
        statusBar.background = NSColor(hex: palette.statusBar)
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(hex: palette.gutterBackground).cgColor
    }

    // MARK: Loading

    func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        fileModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            showMessage(String(localized: "“\(displayName)” couldn’t be opened: the file has gone."))
            return
        }
        guard let v = QuickLookUI.makePreview(fileURL) else {
            showMessage(String(localized: "Quick Look isn’t available, so “\(displayName)” can’t be shown. Open as Text may still work."))
            return
        }
        v.frame = body.bounds
        v.autoresizingMask = [.width, .height]
        body.addSubview(v)
        preview = v
        var parts = [kindName]
        if let n = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { parts.append(ImageInfoText.fileSize(Int64(n))) }
        statusBar.position.stringValue = parts.joined(separator: " · ")
    }

    private func showMessage(_ text: String) {
        message = text
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
    }

    func reloadIfChangedOnDisk() {
        guard isLoaded, let known = fileModified, let v = preview,
              let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mod > known else { return }
        fileModified = mod
        QuickLookUI.refresh(v)
    }

    var sessionTab: SessionTab { SessionTab(id: id, path: fileURL.path, untitledName: nil, office: OfficeTabState()) }

    // MARK: Open as Text / Open Sheet as CSV

    /// The document's text as NSAttributedString reads it (.docx with
    /// officeOpenXML, .doc with docFormat, RTFD), or nil.
    nonisolated static func plainText(_ url: URL, format: OfficeFormat?) -> String? {
        var prefix: [UInt8] = []
        if let h = try? FileHandle(forReadingFrom: url) {
            prefix = Array((try? h.read(upToCount: 8)) ?? Data())
            try? h.close()
        }
        let type: NSAttributedString.DocumentType
        switch format {
        case .word: type = prefix == OfficeFormat.oleMagic ? .docFormat : .officeOpenXML
        case .rtfd: type = .rtfd
        default: return nil
        }
        guard let s = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else { return nil }
        // Attachments' placeholder characters out; the editor's line endings.
        return PDFText.normalize(s.string.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n"))
    }

    var canOpenAsText: Bool {
        format?.hasText == true || (format == .spreadsheet && OfficeFormat.isZip(prefix))
    }

    private var prefix: [UInt8] {
        guard let h = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? h.close() }
        return Array((try? h.read(upToCount: 8)) ?? Data())
    }

    /// File › Open as Text (Open Sheet as CSV for .xlsx): a new untitled
    /// tab, read off the main thread. The tab stays.
    @objc func openAsText(_ sender: Any?) {
        guard canOpenAsText, !extracting else { NSSound.beep(); return }
        extracting = true
        lastError = nil
        statusBar.counts.stringValue = format == .spreadsheet ? String(localized: "Reading the sheet…") : String(localized: "Extracting text…")
        let url = fileURL, format = format
        let base = (displayName as NSString).deletingPathExtension
        DispatchQueue.global(qos: .userInitiated).async {
            var text: String?
            var name = String(localized: "\(base) (text)")
            var asFile: String?
            var failure: String?
            if format == .spreadsheet {
                do {
                    let (sheet, csv) = try XLSXSheet.firstSheetCSV(url: url)
                    text = csv
                    name = "\(base) (\(sheet))"
                    asFile = "sheet.csv"
                } catch {
                    failure = String(localized: "“\(url.lastPathComponent)”’s first sheet couldn’t be read (\(String(describing: error))).")
                }
            } else {
                text = Self.plainText(url, format: format)
                if text?.isEmpty != false { failure = String(localized: "“\(url.lastPathComponent)” has no text Owlink can take out.") }
            }
            let result = text, title = name, file = asFile, err = failure
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.extracting = false
                self.statusBar.counts.stringValue = ""
                if let err {
                    self.lastError = err
                    let a = NSAlert()
                    a.messageText = err
                    if let w = self.window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
                    return
                }
                (NSApp.delegate as? AppDelegate)?.openExtractedText(result ?? "", named: title, asFileNamed: file)
            }
        }
    }

    @objc func openInDefaultApp(_ sender: Any?) { AppDelegate.openInDefaultApp(fileURL) }

    @objc func closeWindow(_ sender: Any?) {
        guard let w = window else { return }
        (NSApp.delegate as? AppDelegate)?.closeDocumentWindows(in: w)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        (NSApp.delegate as? AppDelegate)?.shouldCloseDocumentWindow(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        appearanceObserver.map { NotificationCenter.default.removeObserver($0) }
        appearanceObserver = nil
        onClose?(self)
        if let preview { QuickLookUI.close(preview) }
        preview = nil
        window?.delegate = nil
        window?.contentView = NSView()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        loadIfShown()
        (NSApp.delegate as? AppDelegate)?.folderSidebarFollow(self)
    }
    func windowDidBecomeMain(_ notification: Notification) { loadIfShown() }
    func windowDidChangeOcclusionState(_ notification: Notification) { loadIfShown() }

    private func loadIfShown() {
        guard !isLoaded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLoaded, let w = self.window, w.isVisible,
                  w.tabGroup.map({ $0.selectedWindow === w }) ?? true else { return }
            self.ensureLoaded()
        }
    }

    // MARK: Menus

    @objc func pickLanguageMenu(_ sender: Any?) {}
    @objc func pickEncodingMenu(_ sender: Any?) {}
    @objc func pickLineEndingMenu(_ sender: Any?) {}
    @objc func togglePreview(_ sender: Any?) {}
    @objc func showReplace(_ sender: Any?) {}
    @objc func saveDocument(_ sender: Any?) {}
    @objc func saveDocumentAs(_ sender: Any?) {}
    @objc func findInFilesMenu(_ sender: Any?) {}
    /// Zoom is Quick Look's own here (pinch); the editor's font zoom is off.
    @objc func zoomIn(_ sender: Any?) {}
    @objc func zoomOut(_ sender: Any?) {}
    @objc func zoomReset(_ sender: Any?) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if PDFTabController.disabledHere.contains(action) { item.state = .off; return false }
        switch action {
        case #selector(openAsText(_:)):
            item.title = format == .spreadsheet ? String(localized: "Open Sheet as CSV") : String(localized: "Open as Text")
            return canOpenAsText && !extracting
        case #selector(openInDefaultApp(_:)):
            item.title = AppDelegate.openInTitle(fileURL)
            return AppDelegate.defaultApp(for: fileURL) != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomReset(_:)): return false
        case #selector(closeWindow(_:)): return true
        default: return true
        }
    }
}

// MARK: - App: opening Office tabs

extension AppDelegate {
    func officeTab(for url: URL) -> OfficeTabController? {
        let std = url.standardizedFileURL
        return officeTabs.first { $0.fileURL.standardizedFileURL == std }
    }

    /// Opens an Office / iWork document in a Quick Look tab, or focuses
    /// the tab that has it.
    @discardableResult
    func openOffice(_ url: URL) -> OfficeTabController? {
        let std = url.standardizedFileURL
        if let existing = officeTab(for: std) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let blank = replaceableBlankTab
        let tab = makeOfficeTab(OfficeTabController(fileURL: std))
        tab.ensureLoaded()
        blank?.window?.close()
        noteRecent(std)
        return tab
    }

    @discardableResult
    func makeOfficeTab(_ tab: OfficeTabController, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true,
                       tabIndex: Int? = nil) -> OfficeTabController {
        tab.onChange = { [weak self] _ in self?.scheduleSessionSave() }
        tab.onClose = { [weak self] t in
            self?.releaseWaiters(for: t.id)
            guard let self, !self.terminating else { return }
            let last = self.isClosingLastDocument(t.window)
            self.officeTabs.removeAll { $0 === t }
            self.rememberClosedViewer(t)
            if last { self.quitAfterLastClose() }
        }
        officeTabs.append(tab)
        if let window = tab.window { placeViewerWindow(window, in: group, newWindow: newWindow, show: show, tabIndex: tabIndex) }
        return tab
    }
}
