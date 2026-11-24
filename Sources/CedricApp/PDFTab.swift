import AppKit
import CedricCore
import PDFKit

/// The PDF page view: PDFKit's, plus dropping files onto it opens them
/// (as on the editor's text).
final class CedricPDFView: PDFView {
    var onDropFiles: (([URL]) -> Void)?
    /// A link or action leaving the document (a URL, another file), decided
    /// by PreviewLinkAction.pdfAction instead of PDFKit, which would hand
    /// any URL to NSWorkspace in one click.
    var onLink: ((URL) -> Void)?

    /// PDFKit runs a link annotation's action here: links within the
    /// document (GoTo), page navigation (Named) and form resets stay
    /// PDFKit's; a URL or a link to another file goes through the policy;
    /// anything else (Launch and the like) is dropped.
    override func perform(_ action: PDFAction) {
        switch action {
        case let a as PDFActionURL:
            if let url = a.url { onLink?(url) }
        case let a as PDFActionRemoteGoTo:
            onLink?(a.url)
        case is PDFActionGoTo, is PDFActionNamed, is PDFActionResetForm:
            super.perform(action)
        default:
            break
        }
    }
    /// ⌘= / ⌘- reach the view first: Cedric's steps (25%), not PDFKit's.
    var onZoom: ((_ zoomIn: Bool) -> Void)?

    override func zoomIn(_ sender: Any?) { if let onZoom { onZoom(true) } else { super.zoomIn(sender) } }
    override func zoomOut(_ sender: Any?) { if let onZoom { onZoom(false) } else { super.zoomOut(sender) } }

    /// ← / → and Page Up / Page Down: a page back or on (true if handled).
    var onPageKey: ((_ forward: Bool) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
            var forward: Bool?
            switch ch {
            case NSPageDownFunctionKey: forward = true
            case NSPageUpFunctionKey: forward = false
            // ← / →: pages, unless the page is wider than the view (then they scroll it sideways).
            case NSRightArrowFunctionKey where !scrollsSideways: forward = true
            case NSLeftArrowFunctionKey where !scrollsSideways: forward = false
            default: break
            }
            if let forward, onPageKey?(forward) == true { return }
        }
        super.keyDown(with: event)
    }

    private var scrollsSideways: Bool {
        // Fitted to the width: nothing to scroll sideways.
        guard !autoScales, let doc = documentView, let clip = doc.enclosingScrollView?.contentView else { return false }
        return doc.frame.width > clip.bounds.width + 1
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        // Files open in tabs, folders in the folder sidebar.
        FileDrop.urls(info)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }
}

/// PDFKit's link-click hook: its default opens any URL with NSWorkspace.
/// Ours sends it to the tab's policy instead.
final class PDFLinkDelegate: NSObject, PDFViewDelegate, Sendable {
    let follow: @MainActor @Sendable (URL) -> Void
    init(_ follow: @escaping @MainActor @Sendable (URL) -> Void) { self.follow = follow }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        let follow = follow
        MainActor.assumeIsolated { follow(url) }
    }
}

/// The thumbnails sidebar (when shown, a fixed width) beside the pages.
final class PDFPagesView: NSView {
    var thumbnails: NSView? { didSet { oldValue?.removeFromSuperview(); thumbnails.map(addSubview); needsLayout = true } }
    var pages: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let pages { addSubview(pages, positioned: .below, relativeTo: overlay) }
            needsLayout = true
        }
    }
    /// The reader controls, floating over the bottom of the pages.
    var overlay: PDFOverlay? {
        didSet { oldValue?.removeFromSuperview(); overlay.map { addSubview($0, positioned: .above, relativeTo: nil) }; needsLayout = true }
    }
    static let sidebarWidth: CGFloat = 150
    private var tracking: NSTrackingArea?

    override func layout() {
        super.layout()
        let side = thumbnails.map { $0.isHidden ? 0 : Self.sidebarWidth } ?? 0
        thumbnails?.frame = NSRect(x: 0, y: 0, width: side, height: bounds.height)
        let pagesFrame = NSRect(x: side, y: 0, width: max(0, bounds.width - side), height: bounds.height)
        pages?.frame = pagesFrame
        if let o = overlay {
            // Bottom centre of the pages, inside them (clear of the scroller).
            let w = min(o.fit(available: pagesFrame.width - 32), pagesFrame.width - 16)
            let h = PDFOverlay.height
            o.frame = NSRect(x: (pagesFrame.midX - w / 2).rounded(), y: isFlipped ? bounds.height - h - 16 : 16, width: max(0, w), height: h)
            o.needsLayout = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        overlay?.noteActivity()
        super.mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        overlay?.noteActivity()
        super.scrollWheel(with: event)
    }
}

/// One PDF tab: a read-only PDFKit view of a file, in a window tabbed with
/// the editor's. Continuous scroll, zoom, a page-thumbnails sidebar, find
/// (Cedric's find bar, searching with PDFDocument), Go to Page, and Open
/// as Text. Never writes to the file: there is no save path at all.
///
/// Launch speed: the window is cheap; the PDF itself (PDFDocument and the
/// PDFView) is loaded only when the tab is first shown, so a restored PDF
/// tab that isn't selected costs nothing until it is clicked.
@MainActor
final class PDFTabController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let id: UUID
    var fileURL: URL
    private(set) var pdfDocument: PDFDocument?
    private(set) var pdfView: CedricPDFView?
    private(set) var thumbnails: PDFThumbnailView?
    /// The page and zoom to show once loaded (restore), else what was last shown.
    private var state: PDFTabState
    /// The password that unlocked it (Open as Text reopens the file with it).
    private var password: String?
    private(set) var isLoaded = false
    private var fileModified: Date?
    private let body = NSView()
    private let split = PDFPagesView()
    private var stack: NSStackView!
    let statusBar = StatusBar()
    private(set) lazy var findBar: FindBar = makeFindBar()
    private var findBarBuilt = false
    var isFindBarOpen: Bool { findBarBuilt && !findBar.isHidden }
    private var observers: [NSObjectProtocol] = []
    private var appearanceObserver: NSObjectProtocol?
    /// What the find bar found (async, counted as PDFKit reports matches).
    private(set) var matches: [PDFSelection] = []
    private(set) var findInProgress = false
    /// A message instead of the page (damaged, locked); and its button.
    private(set) var message: String?
    /// The password sheet while it is up (the checks fill it in).
    private(set) var passwordAlert: NSAlert?
    /// Open as Text is extracting (off the main thread).
    private(set) var extracting = false

    /// What the last clicked link did (PreviewLinkAction.pdfAction; the check reads it).
    private(set) var lastLinkAction: PreviewLinkAction?
    private lazy var linkDelegate = PDFLinkDelegate { [weak self] url in self?.followLink(url) }

    /// A link out of the PDF: web and mail links ask first with the whole
    /// URL, a file is only shown in Finder, every other scheme is ignored.
    func followLink(_ url: URL) {
        let act = PreviewLinkAction.pdfAction(for: url)
        lastLinkAction = act
        switch act {
        case .confirmExternal(let u): LinkPrompt.confirmExternal(u, in: window)
        case .revealInFinder(let u): PreviewLinkLog.reveal(u)
        case .openInCedric(let u), .openInPreview(let u): PreviewLinkLog.reveal(u) // never for a PDF; reveal at most
        case .ignore: NSSound.beep()
        }
    }

    var onChange: ((PDFTabController) -> Void)?
    var onClose: ((PDFTabController) -> Void)?

    init(fileURL: URL, id: UUID = UUID(), state: PDFTabState = PDFTabState(), pdfDocument: PDFDocument? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.state = state
        self.pdfDocument = pdfDocument
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        // Tabs with the editor's windows.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "CedricEditor"
        window.minSize = NSSize(width: 420, height: 240)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        buildViews()
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.tab.toolTip = fileURL.path
        statusBar.position.stringValue = String(localized: "PDF")
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(forName: .cedricAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var displayName: String { fileURL.lastPathComponent }

    // MARK: Views

    private func buildViews() {
        guard let window else { return }
        body.addSubview(split)
        split.frame = body.bounds
        split.autoresizingMask = [.width, .height]
        // Not a language, encoding or line ending: only the page and zoom.
        for b in [statusBar.languageButton, statusBar.encodingButton, statusBar.lineEndingButton] { b.isHidden = true }
        let stack = NSStackView(views: [body, statusBar])
        self.stack = stack
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.detachesHiddenViews = true
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        body.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar()
        bar.isHidden = true
        // PDFKit searches plain text, with or without case.
        bar.regexBox.isHidden = true
        bar.wordBox.isHidden = true
        bar.onChange = { [weak self] in self?.findChanged() }
        bar.onFind = { [weak self] back in self?.find(backwards: back) }
        bar.onClose = { [weak self] in self?.hideFindBar() }
        stack.insertArrangedSubview(bar, at: 0)
        findBarBuilt = true
        return bar
    }

    var palette: EditorPalette { Settings.shared.palette(for: window?.effectiveAppearance) }

    /// The chrome follows the theme; the pages stay white, as printed.
    func applyAppearance() {
        window?.appearance = Settings.shared.windowAppearance
        let p = palette
        statusBar.background = NSColor(hex: p.statusBar)
        pdfView?.backgroundColor = NSColor(hex: p.gutterBackground)
        thumbnails?.backgroundColor = NSColor(hex: p.gutterBackground)
        overlay?.applyPalette(p)
        messageView?.needsDisplay = true
    }

    // MARK: Loading

    /// Loads the PDF the first time the tab is shown.
    func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        fileModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let doc = pdfDocument ?? PDFDocument(url: fileURL) else {
            pdfDocument = nil
            showMessage(Self.damagedMessage(fileURL), button: nil)
            return
        }
        pdfDocument = doc
        if doc.isLocked {
            showMessage(String(localized: "“\(displayName)” is protected by a password."), button: String(localized: "Enter Password…"))
            askPassword(retry: false)
            return
        }
        attach(doc)
    }

    static func damagedMessage(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path)
            ? String(localized: "“\(url.lastPathComponent)” couldn’t be opened. It isn’t a PDF, or it is damaged.")
            : String(localized: "“\(url.lastPathComponent)” couldn’t be opened: the file has gone.")
    }

    private func attach(_ doc: PDFDocument) {
        clearMessage()
        let v = CedricPDFView()
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.displayDirection = .vertical
        v.minScaleFactor = PDFTabState.minScale
        v.maxScaleFactor = PDFTabState.maxScale
        v.document = doc
        v.onZoom = { [weak self] zoomIn in zoomIn ? self?.zoomIn(nil) : self?.zoomOut(nil) }
        v.onDropFiles = { urls in FileDrop.open(urls) }
        v.onLink = { [weak self] url in self?.followLink(url) }
        v.delegate = linkDelegate
        v.registerForDraggedTypes([.fileURL])
        let thumbs = PDFThumbnailView()
        thumbs.pdfView = v
        thumbs.thumbnailSize = NSSize(width: 96, height: 124)
        thumbs.maximumNumberOfColumns = 1
        thumbs.isHidden = !state.showsThumbnails
        split.thumbnails = thumbs
        split.pages = v
        pdfView = v
        thumbnails = thumbs
        layoutSidebar()
        applyAppearance()
        applyState(state)
        let nc = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observers.append(nc.addObserver(forName: name, object: v, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStatus()
                    self.onChange?(self)
                }
            })
        }
        observers.append(nc.addObserver(forName: .PDFDocumentDidFindMatch, object: doc, queue: .main) { [weak self] n in
            nonisolated(unsafe) let sel = n.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
            MainActor.assumeIsolated { self?.foundMatch(sel) }
        })
        observers.append(nc.addObserver(forName: .PDFDocumentDidEndFind, object: doc, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.findEnded() }
        })
        window?.makeFirstResponder(v)
        v.onPageKey = { [weak self] forward in self?.stepPage(forward) ?? false }
        if let clip = v.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.overlay?.noteActivity() }
            })
        }
        updateStatus()
        // Not before the first frame: the controls aren't needed to draw the page.
        AfterFirstFrame.run { [weak self] in self?.buildOverlay() }
    }

    // MARK: Reader controls (PDFOverlay)

    private(set) var overlay: PDFOverlay?
    /// The view's rotation in degrees (0, 90, 180, 270): the pages are turned
    /// in memory only; nothing is ever written to the file.
    private(set) var viewRotation = 0

    private func buildOverlay() {
        guard overlay == nil, pdfView != nil else { return }
        let o = PDFOverlay()
        o.onControl = { [weak self] c in self?.overlayControl(c) }
        o.onPageEntered = { [weak self] text in self?.overlayPage(text) }
        split.overlay = o
        overlay = o
        o.applyPalette(palette)
        updateStatus()
        o.setThumbnailsOn(thumbnails.map { !$0.isHidden } ?? false)
        o.noteActivity()
    }

    func overlayControl(_ c: PDFOverlay.Control) {
        switch c {
        case .previous: _ = stepPage(false)
        case .next: _ = stepPage(true)
        case .zoomOut: zoomOut(nil)
        case .zoomIn: zoomIn(nil)
        case .actualSize: zoomReset(nil)
        case .fitWidth: zoomToFit(nil)
        case .fitPage: fitPage()
        case .thumbnails: togglePDFThumbnails(nil)
        case .find: showFindBar()
        case .rotateLeft: rotateView(by: -90)
        case .rotateRight: rotateView(by: 90)
        case .openInDefaultApp: openInDefaultApp(nil)
        }
    }

    private func overlayPage(_ text: String) {
        guard let doc = pdfDocument else { return }
        if let i = PageNumberInput.parse(text, pageCount: doc.pageCount) {
            goToPage(i)
            if let v = pdfView { window?.makeFirstResponder(v) }
        } else {
            NSSound.beep()
            updateStatus()
        }
    }

    /// A page on or back; false at either end.
    @discardableResult
    func stepPage(_ forward: Bool) -> Bool {
        guard let doc = pdfDocument, let i = currentPageIndex,
              let n = PDFReader.page(i, moving: forward ? 1 : -1, pageCount: doc.pageCount) else { return false }
        goToPage(n)
        overlay?.noteActivity()
        return true
    }

    /// Fit Page: the whole current page in the view.
    func fitPage() {
        guard let v = pdfView, let page = v.currentPage else { return }
        let b = page.bounds(for: v.displayBox)
        setScale(CGFloat(PDFReader.fitPageScale(pageWidth: Double(b.width), pageHeight: Double(b.height),
                                                viewWidth: Double(v.bounds.width), viewHeight: Double(v.bounds.height),
                                                margin: 8, rotation: page.rotation)))
    }

    /// Rotate Left / Right: every page turned in memory, for viewing. The
    /// tab has no save path, so the file itself never changes.
    func rotateView(by delta: Int) {
        guard let v = pdfView, let doc = pdfDocument else { return }
        let keep = v.currentPage
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i) { p.rotation = PDFReader.rotated(p.rotation, by: delta) }
        }
        viewRotation = PDFReader.rotated(viewRotation, by: delta)
        v.layoutDocumentView()
        if let keep { v.go(to: keep) }
        updateStatus()
    }

    private func layoutSidebar() {
        guard let thumbs = thumbnails else { return }
        _ = thumbs
        split.needsLayout = true
        split.layoutSubtreeIfNeeded()
    }

    /// Page, zoom and sidebar from a saved state (after layout: PDFView
    /// only scrolls to a page once it has a size).
    private func applyState(_ s: PDFTabState) {
        guard let v = pdfView, let doc = pdfDocument else { return }
        if let scale = s.scale {
            v.autoScales = false
            v.scaleFactor = PDFTabState.clampScale(scale)
        } else {
            v.autoScales = true
        }
        let index = s.clampedPage(pageCount: doc.pageCount)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let page = doc.page(at: index) { v.go(to: page) }
        // Once more after the first layout pass, which may reset the scroll.
        DispatchQueue.main.async { [weak self] in
            guard let self, let v = self.pdfView, let page = doc.page(at: index), v.currentPage !== page else { return }
            v.go(to: page)
            self.updateStatus()
        }
    }

    // MARK: Messages (damaged, locked)

    private var messageView: NSView?

    private func showMessage(_ text: String, button: String?) {
        message = text
        messageView?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15)
        var views: [NSView] = [label]
        if let button {
            views.append(NSButton(title: button, target: self, action: #selector(unlockClicked(_:))))
        }
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = 12
        s.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(s)
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            s.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            s.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -40),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        messageView = s
        split.isHidden = true
        statusBar.position.stringValue = String(localized: "PDF")
        statusBar.zoom.stringValue = ""
    }

    private func clearMessage() {
        message = nil
        messageView?.removeFromSuperview()
        messageView = nil
        split.isHidden = false
    }

    @objc private func unlockClicked(_ sender: Any?) { askPassword(retry: false) }

    /// The password sheet (an encrypted PDF). Cancel leaves the tab with
    /// its "protected" message and an Enter Password… button.
    private func askPassword(retry: Bool) {
        guard let doc = pdfDocument, doc.isLocked, passwordAlert == nil else { return }
        guard let window, window.isVisible else {
            // Not on screen yet (just built): ask once it is.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.askPassword(retry: retry)
            }
            return
        }
        let a = NSAlert()
        a.messageText = String(localized: "“\(displayName)” is protected by a password.")
        a.informativeText = retry ? String(localized: "That password didn’t open it. Try again.") : String(localized: "Enter the password to view it.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "Open"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.window.initialFirstResponder = field
        passwordAlert = a
        a.beginSheetModal(for: window) { [weak self] resp in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.passwordAlert = nil
                guard resp == .alertFirstButtonReturn else { return }
                if doc.unlock(withPassword: field.stringValue) {
                    self.password = field.stringValue
                    self.attach(doc)
                    self.onChange?(self)
                } else {
                    self.askPassword(retry: true)
                }
            }
        }
    }

    /// The file changed on disk (applicationDidBecomeActive): reload it,
    /// on the same page.
    func reloadIfChangedOnDisk() {
        guard isLoaded, let known = fileModified,
              let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mod > known else { return }
        let keep = sessionState
        teardownView()
        state = keep
        pdfDocument = nil
        isLoaded = false
        ensureLoaded()
    }

    private func teardownView() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        pdfDocument?.cancelFindString()
        overlay?.stop()
        split.overlay = nil
        overlay = nil
        viewRotation = 0
        split.thumbnails = nil
        split.pages = nil
        pdfView = nil
        thumbnails = nil
        matches = []
    }

    // MARK: Status

    var currentPageIndex: Int? {
        guard let v = pdfView, let doc = pdfDocument, let page = v.currentPage else { return nil }
        return doc.index(for: page)
    }

    func updateStatus() {
        guard let doc = pdfDocument, let v = pdfView else { return }
        let n = doc.pageCount
        let i = (currentPageIndex ?? 0) + 1
        statusBar.position.stringValue = String(localized: "Page \(i) of \(n)")
        statusBar.zoom.stringValue = "\(Int((v.scaleFactor * 100).rounded()))%"
        overlay?.update(page: i - 1, pageCount: n)
    }

    /// What the session keeps: the page and zoom shown (or still to show,
    /// for a tab not loaded yet).
    var sessionState: PDFTabState {
        guard let v = pdfView, isLoaded else { return state }
        return PDFTabState(page: currentPageIndex ?? state.page, scale: v.autoScales ? nil : Double(v.scaleFactor),
                           showsThumbnails: thumbnails.map { !$0.isHidden } ?? state.showsThumbnails)
    }

    var sessionTab: SessionTab { SessionTab(id: id, path: fileURL.path, untitledName: nil, pdf: sessionState) }

    // MARK: Navigation and zoom

    func goToPage(_ index: Int) {
        guard let doc = pdfDocument, let v = pdfView, let page = doc.page(at: max(0, min(index, doc.pageCount - 1))) else { return }
        v.go(to: page)
        updateStatus()
    }

    /// Edit › Go to Line… (⌘L) on a PDF tab: Go to Page.
    @objc func goToLine(_ sender: Any?) {
        guard let doc = pdfDocument, let window else { return }
        let a = NSAlert()
        a.messageText = String(localized: "Go to Page")
        a.informativeText = String(localized: "Page (1–\(doc.pageCount)).")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "\(min(2, doc.pageCount))"
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "Go"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] resp in
            MainActor.assumeIsolated {
                guard let self, resp == .alertFirstButtonReturn else { return }
                guard let i = PageNumberInput.parse(field.stringValue, pageCount: doc.pageCount) else { NSSound.beep(); return }
                self.goToPage(i)
                if let v = self.pdfView { self.window?.makeFirstResponder(v) }
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { setScale((pdfView?.scaleFactor ?? 1) * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setScale((pdfView?.scaleFactor ?? 1) / 1.25) }
    /// ⌘0, Actual Size: 100%.
    @objc func zoomReset(_ sender: Any?) { setScale(1) }
    /// The status bar's 75–200 %.
    @objc func zoomToPercent(_ sender: Any?) {
        guard let p = (sender as? NSMenuItem)?.tag, p > 0 else { return }
        setScale(CGFloat(p) / 100)
    }
    /// ⌘9: fit the page width to the window (how a PDF opens).
    @objc func zoomToFit(_ sender: Any?) {
        pdfView?.autoScales = true
        updateStatus()
        onChange?(self)
    }

    func setScale(_ s: CGFloat) {
        guard let v = pdfView else { return }
        let page = v.currentPage
        v.autoScales = false
        v.scaleFactor = CGFloat(PDFTabState.clampScale(Double(s)))
        if let page { v.go(to: page) }
        updateStatus()
        onChange?(self)
    }

    @objc func togglePDFThumbnails(_ sender: Any?) {
        guard let t = thumbnails else { return }
        t.isHidden.toggle()
        overlay?.setThumbnailsOn(!t.isHidden)
        layoutSidebar()
        onChange?(self)
    }

    // MARK: Find

    func showFindBar() {
        guard pdfDocument != nil, pdfView != nil else { NSSound.beep(); return }
        findBar.isHidden = false
        findBar.showsReplace = false
        if let s = pdfView?.currentSelection?.string, !s.isEmpty, s.count < 200 { findBar.findField.stringValue = s }
        window?.makeFirstResponder(findBar.findField)
        findBar.findField.selectText(nil)
        findChanged()
    }

    func hideFindBar() {
        findBar.isHidden = true
        pdfDocument?.cancelFindString()
        pdfView?.highlightedSelections = nil
        if let v = pdfView { window?.makeFirstResponder(v) }
    }

    private var findOptions: NSString.CompareOptions { findBar.caseBox.state == .on ? [] : [.caseInsensitive] }

    /// The search text changed: count every match (PDFKit searches on its
    /// own thread and reports them) and select the first from here.
    private func findChanged() {
        guard let doc = pdfDocument else { return }
        doc.cancelFindString()
        matches = []
        pdfView?.highlightedSelections = nil
        let s = findBar.findField.stringValue
        guard !s.isEmpty else { findBar.status.stringValue = ""; findInProgress = false; return }
        findInProgress = true
        findBar.status.stringValue = String(localized: "Searching…")
        if let first = doc.findString(s, fromSelection: startSelection(), withOptions: findOptions)
            ?? doc.findString(s, fromSelection: nil, withOptions: findOptions) {
            select(first)
        }
        doc.beginFindString(s, withOptions: findOptions)
    }

    /// From the top of the page shown, so a new search starts where you are.
    private func startSelection() -> PDFSelection? {
        guard let v = pdfView, let page = v.currentPage, let doc = pdfDocument else { return nil }
        if let cur = v.currentSelection, cur.pages.contains(page) { return cur }
        let index = doc.index(for: page)
        guard index > 0, let prev = doc.page(at: index - 1), let text = prev.string, !text.isEmpty else { return nil }
        // The end of the previous page: the search goes on from there.
        return prev.selection(for: NSRange(location: (text as NSString).length - 1, length: 1))
    }

    private func foundMatch(_ sel: PDFSelection?) {
        guard let sel else { return }
        matches.append(sel)
        if matches.count % 50 == 0 { findBar.status.stringValue = String(localized: "\(matches.count) matches…") }
    }

    private func findEnded() {
        findInProgress = false
        let n = matches.count
        findBar.status.stringValue = n == 1 ? String(localized: "1 match") : String(localized: "\(n) matches")
        for m in matches { m.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        pdfView?.highlightedSelections = matches.count <= 5000 ? matches : nil
    }

    func find(backwards: Bool) {
        guard let doc = pdfDocument else { return }
        if !isFindBarOpen || findBar.findField.stringValue.isEmpty { showFindBar(); return }
        let s = findBar.findField.stringValue
        var opts = findOptions
        if backwards { opts.insert(.backwards) }
        // Past the last match: wrap round to the first (or the last).
        if let sel = doc.findString(s, fromSelection: pdfView?.currentSelection, withOptions: opts)
            ?? doc.findString(s, fromSelection: nil, withOptions: opts) {
            select(sel)
        } else {
            NSSound.beep()
        }
    }

    private func select(_ sel: PDFSelection) {
        guard let v = pdfView else { return }
        v.setCurrentSelection(sel, animate: false)
        v.go(to: sel)
        updateStatus()
    }

    @objc func showFind(_ sender: Any?) { showFindBar() }
    @objc func findNextMatch(_ sender: Any?) { find(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { find(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let s = pdfView?.currentSelection?.string, !s.isEmpty else { NSSound.beep(); return }
        findBar.findField.stringValue = s
        if isFindBarOpen { findChanged() }
    }

    // MARK: Open as Text

    /// File › Open as Text: the PDF's text in a new untitled tab, extracted
    /// off the main thread (a long PDF takes a while). The PDF tab stays.
    @objc func openAsText(_ sender: Any?) {
        guard pdfDocument != nil, !extracting else { return }
        extracting = true
        statusBar.counts.stringValue = String(localized: "Extracting text…")
        let url = fileURL, pw = password
        let base = (displayName as NSString).deletingPathExtension
        DispatchQueue.global(qos: .userInitiated).async {
            // Its own PDFDocument: PDFKit objects belong to one thread.
            let d = PDFDocument(url: url)
            if let pw, d?.isLocked == true { _ = d?.unlock(withPassword: pw) }
            let text = PDFText.normalize(d?.string ?? "")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.extracting = false
                self.statusBar.counts.stringValue = ""
                guard !text.isEmpty else {
                    self.showError(String(localized: "“\(self.displayName)” has no text to open (it may be scanned images)."))
                    return
                }
                (NSApp.delegate as? AppDelegate)?.openExtractedText(text, named: String(localized: "\(base) (text)"))
            }
        }
    }

    func showError(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        if let window, window.isVisible { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    // MARK: Printing, closing

    /// File › Open in Default App (the file's default app other than Cedric).
    @objc func openInDefaultApp(_ sender: Any?) { AppDelegate.openInDefaultApp(fileURL) }

    @objc func printDocument(_ sender: Any?) {
        pdfView?.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    /// File › Close Window (⇧⌘W): every tab in this window.
    @objc func closeWindow(_ sender: Any?) {
        guard let w = window else { return }
        (NSApp.delegate as? AppDelegate)?.closeDocumentWindows(in: w)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        (NSApp.delegate as? AppDelegate)?.shouldCloseDocumentWindow(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        pdfDocument?.cancelFindString()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        appearanceObserver.map { NotificationCenter.default.removeObserver($0) }
        appearanceObserver = nil
        // Remembered (Reopen Closed Tab, its page and zoom) before the views go.
        onClose?(self)
        detachViews()
    }

    /// The window is closing: AppKit may keep it (and its views) a while
    /// after this controller is freed, so cut the views' paths back to it
    /// and take them out of the window (as EditorWindowController does).
    private func detachViews() {
        pdfView?.onZoom = nil
        pdfView?.onDropFiles = nil
        pdfView?.onPageKey = nil
        overlay?.stop()
        if findBarBuilt {
            findBar.onChange = nil
            findBar.onFind = nil
            findBar.onClose = nil
        }
        window?.delegate = nil
        window?.contentView = NSView()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        loadIfShown()
        (NSApp.delegate as? AppDelegate)?.folderSidebarFollow(self)
    }
    func windowDidBecomeMain(_ notification: Notification) { loadIfShown() }
    func windowDidChangeOcclusionState(_ notification: Notification) { loadIfShown() }

    /// Loads once the tab is really the one shown. On the next turn: a tab
    /// inserted into a tab group (a restored one, built after launch) is
    /// key for a moment before the selection goes back.
    private func loadIfShown() {
        guard !isLoaded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLoaded, let w = self.window, w.isVisible,
                  w.tabGroup.map({ $0.selectedWindow === w }) ?? true else { return }
            self.ensureLoaded()
        }
    }

    // MARK: Menus

    /// Editor-only commands that AppDelegate would otherwise leave enabled
    /// (they act on "the current text tab"): handled here, as nothing.
    @objc func pickLanguageMenu(_ sender: Any?) {}
    @objc func pickEncodingMenu(_ sender: Any?) {}
    @objc func pickLineEndingMenu(_ sender: Any?) {}
    @objc func togglePreview(_ sender: Any?) {}
    @objc func showReplace(_ sender: Any?) {}
    @objc func saveDocument(_ sender: Any?) {}
    @objc func saveDocumentAs(_ sender: Any?) {}
    @objc func findInFilesMenu(_ sender: Any?) {}

    static let disabledHere: Set<Selector> = [
        #selector(pickLanguageMenu(_:)), #selector(pickEncodingMenu(_:)), #selector(pickLineEndingMenu(_:)),
        #selector(togglePreview(_:)), #selector(showReplace(_:)), #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)),
        #selector(findInFilesMenu(_:)),
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if Self.disabledHere.contains(action) { item.state = .off; return false }
        let ready = pdfView != nil && pdfDocument != nil
        switch action {
        case #selector(goToLine(_:)):
            item.title = String(localized: "Go to Page…")
            return ready
        case #selector(togglePDFThumbnails(_:)):
            setShowHide(item, shown: thumbnails.map { !$0.isHidden } == true,
                        show: String(localized: "Show Page Thumbnails"), hide: String(localized: "Hide Page Thumbnails"))
            return ready
        case #selector(zoomToFit(_:)):
            item.state = pdfView?.autoScales == true ? .on : .off
            return ready
        case #selector(openAsText(_:)): return ready && !extracting
        case #selector(openInDefaultApp(_:)):
            item.title = AppDelegate.openInTitle(fileURL)
            return AppDelegate.defaultApp(for: fileURL) != nil
        case #selector(useSelectionForFind(_:)): return pdfView?.currentSelection?.string?.isEmpty == false
        case #selector(closeWindow(_:)): return true
        default: return ready
        }
    }
}

// MARK: - App: opening, restoring and closing PDF tabs

extension AppDelegate {
    /// The PDF tab for this file, if one is open.
    func pdfTab(for url: URL) -> PDFTabController? {
        let std = url.standardizedFileURL
        return pdfTabs.first { $0.fileURL.standardizedFileURL == std }
    }

    /// The PDF tab in front, if the front tab is one (nil when a text or other viewer tab is).
    var currentPDFTab: PDFTabController? { currentViewerTab as? PDFTabController }

    /// Opens a PDF in a viewer tab (File › Open, drops, the Dock, `cedric`,
    /// Open Recent, Finder): or focuses the tab that has it. A damaged file
    /// is an alert, not a tab.
    @discardableResult
    func openPDF(_ url: URL) -> PDFTabController? {
        let std = url.standardizedFileURL
        if let existing = pdfTab(for: std) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let doc = PDFDocument(url: std) else {
            let a = NSAlert()
            a.messageText = PDFTabController.damagedMessage(std)
            a.alertStyle = .warning
            if let w = currentTab?.window ?? currentPDFTab?.window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
            return nil
        }
        // An empty, untouched untitled tab is replaced, as for text files.
        let blank = replaceableBlankTab
        let tab = makePDFTab(PDFTabController(fileURL: std, pdfDocument: doc))
        tab.ensureLoaded()
        blank?.window?.close()
        noteRecent(std)
        return tab
    }

    /// Adds a PDF tab beside the others (in `group` at `tabIndex` when restoring).
    @discardableResult
    func makePDFTab(_ tab: PDFTabController, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true,
                    tabIndex: Int? = nil) -> PDFTabController {
        tab.onChange = { [weak self] _ in self?.scheduleSessionSave() }
        tab.onClose = { [weak self] t in
            self?.releaseWaiters(for: t.id)
            guard let self, !self.terminating else { return }
            let last = self.isClosingLastDocument(t.window)
            self.pdfTabs.removeAll { $0 === t }
            self.rememberClosedViewer(t)
            if last { self.quitAfterLastClose() }
        }
        pdfTabs.append(tab)
        guard let window = tab.window else { return tab }
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
        return tab
    }

    /// A saved PDF tab. The selected tab of a window (`place` nil) loads
    /// now; the others when first shown.
    func restorePDFTab(_ st: SessionTab, into place: (host: NSWindow, index: Int)?) -> PDFTabController? {
        guard let path = st.path, FileManager.default.fileExists(atPath: path) else { return nil }
        let tab = PDFTabController(fileURL: URL(fileURLWithPath: path), id: st.id, state: st.pdf ?? PDFTabState())
        makePDFTab(tab, in: place?.host, newWindow: place == nil, show: false, tabIndex: place?.index)
        if place == nil { tab.ensureLoaded() }
        return tab
    }

    /// Open as Text's result: a new untitled tab, unsaved (kept with the session).
    /// `asFileNamed`: detect the language as for a file of that name
    /// (an Excel sheet's CSV: "sheet.csv").
    func openExtractedText(_ text: String, named base: String, asFileNamed: String? = nil) {
        let open = tabs.filter { $0.doc.fileURL == nil }.map(\.doc.untitledName)
        let doc = EditorDocument(untitledName: UntitledNames.next(open: open, base: base))
        doc.languageChoice = asFileNamed.map { .forFile(named: $0, content: text) } ?? .untitled(content: text)
        let tab = makeTab(doc, text: text)
        doc.markDirtyFromSession()
        tab.updateTitle()
    }

    /// Reopen Closed Tab for a PDF: on the page it was closed at.
    func reopenClosedPDF(_ st: SessionTab) {
        guard let path = st.path else { return }
        let url = URL(fileURLWithPath: path)
        if let open = pdfTab(for: url) {
            open.window?.makeKeyAndOrderFront(nil)
        } else if FileManager.default.fileExists(atPath: path) {
            let tab = makePDFTab(PDFTabController(fileURL: url, id: st.id, state: st.pdf ?? PDFTabState()))
            tab.ensureLoaded()
        } else {
            NSSound.beep()
        }
        saveSession()
    }
}
