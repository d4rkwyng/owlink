import AppKit
import CedricCore

/// The details of the certificates (and keys, requests) in a file, as
/// selectable text: a heading per item with an "Expired" / "Expires in N
/// days" badge, then its fields in plain words. Shared by the Certificate
/// panel beside a PEM text and the certificate tab for a DER file.
@MainActor
final class CertificateDetailsView: NSView, NSTextViewDelegate {
    let scroll = NSScrollView()
    let textView = NSTextView()
    private(set) var items: [CertificateItem] = []
    /// What each "Copy" link copies: (what, the exact text), in link order.
    private(set) var copyTargets: [(label: String, value: String)] = []
    static let copyScheme = "cedric-copy"
    /// What is shown, for the checks.
    var renderedText: String { textView.string }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Copies `copyTargets[index].value` to the general pasteboard, as is.
    func performCopy(_ index: Int) {
        guard copyTargets.indices.contains(index) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(copyTargets[index].value, forType: .string)
    }

    /// The index of the Copy link for `label` (the nth one with that label).
    func copyIndex(_ label: String, _ nth: Int = 0) -> Int? {
        copyTargets.indices.filter { copyTargets[$0].label == label }.dropFirst(nth).first
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.scheme == Self.copyScheme,
              let i = Int(url.host ?? "") else { return false }
        performCopy(i)
        return true
    }

    /// `pems`: each item's own PEM block, exactly (from the text, or
    /// encoded from DER), for its "Copy Certificate (PEM)".
    func show(_ items: [CertificateItem], pems: [String?] = [], palette: EditorPalette, now: Date = Date(), emptyText: String? = nil) {
        self.items = items
        copyTargets = []
        textView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        func copyLink(_ label: String, _ value: String, title: String = String(localized: "Copy")) -> NSAttributedString {
            copyTargets.append((label, value))
            return NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                   .link: URL(string: "\(Self.copyScheme)://\(copyTargets.count - 1)")!])
        }
        let bg = NSColor(hex: palette.background), fg = NSColor(hex: palette.foreground)
        scroll.backgroundColor = bg
        textView.backgroundColor = bg
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12), mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let dim = fg.withAlphaComponent(0.62)
        let table = NSMutableParagraphStyle()
        table.tabStops = [NSTextTab(textAlignment: .left, location: 132)]
        table.headIndent = 132
        table.paragraphSpacing = 3
        // Fingerprints have no spaces: wrap them by character, under their column.
        let hashes = table.mutableCopy() as! NSMutableParagraphStyle
        hashes.lineBreakMode = .byCharWrapping
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = 10
        heading.paragraphSpacing = 6
        if items.isEmpty {
            out.append(NSAttributedString(string: emptyText ?? String(localized: "No certificates in this file."),
                                          attributes: [.font: body, .foregroundColor: dim]))
        }
        let certCount = items.filter { $0.certificate != nil }.count
        var certIndex = 0
        for (k, item) in items.enumerated() {
            if k > 0 { out.append(NSAttributedString(string: "\n")) }
            var title = item.title
            if item.certificate != nil {
                certIndex += 1
                if certCount > 1 { title = String(localized: "\(certIndex) of \(certCount): \(title)") }
            }
            out.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                                       .foregroundColor: fg, .paragraphStyle: heading]))
            guard let c = item.certificate else {
                if item == .privateKey {
                    out.append(NSAttributedString(string: "\n" + String(localized: "Keep this file private. Owlink doesn’t read or show keys."),
                                                  attributes: [.font: body, .foregroundColor: dim, .paragraphStyle: table]))
                }
                if case .request(let subject?) = item, !subject.isEmpty {
                    out.append(NSAttributedString(string: "\n" + String(localized: "Subject") + "\t" + CertificateInfo.distinguishedName(subject),
                                                  attributes: [.font: body, .foregroundColor: fg, .paragraphStyle: table]))
                }
                continue
            }
            let badge = c.badge(at: now)
            if !badge.isEmpty {
                let color: NSColor
                switch c.validity(at: now) {
                case .expired?, .notYetValid?: color = .systemRed
                case .valid(let d)? where d <= 30: color = .systemOrange
                default: color = .systemGreen
                }
                out.append(NSAttributedString(string: "  "))
                out.append(NSAttributedString(string: " \(badge) ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
                    .backgroundColor: color.blended(withFraction: palette.isDark ? 0.15 : 0.0, of: .black) ?? color,
                    .paragraphStyle: heading,
                ]))
            }
            if let pem = pems.indices.contains(k) ? pems[k] : nil {
                out.append(NSAttributedString(string: "   "))
                out.append(copyLink("pem", pem, title: String(localized: "Copy Certificate (PEM)")))
            }
            for row in c.rows() {
                let isHash = row.name.hasPrefix("SHA") || row.name == String(localized: "Serial number")
                out.append(NSAttributedString(string: "\n" + row.name + "\t", attributes: [.font: body, .foregroundColor: dim,
                                                                                         .paragraphStyle: isHash ? hashes : table]))
                out.append(NSAttributedString(string: row.value, attributes: [.font: isHash ? mono : body, .foregroundColor: fg,
                                                                               .paragraphStyle: isHash ? hashes : table]))
                // Fingerprints wrap by character: their Copy goes on a line of its own, under them.
                out.append(NSAttributedString(string: isHash && row.value.count > 40 ? "\u{2028}" : "  ",
                                              attributes: [.paragraphStyle: isHash ? hashes : table]))
                out.append(copyLink(row.name, row.value))
            }
        }
        textView.textStorage?.setAttributedString(out)
    }
}

/// The Certificate panel beside a PEM text (a `PreviewRenderer` in the
/// preview's pane): the text is parsed off the main thread on each
/// (debounced) render; a newer render drops an older result.
@MainActor
final class CertificatePanel: PreviewRenderer {
    let details = CertificateDetailsView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var view: NSView { details }
    private var generation = 0
    /// Rendered at least once (for the checks).
    private(set) var renders = 0
    private static let queue = DispatchQueue(label: "cedric.certificates", qos: .userInitiated)
    /// The user closed the panel (⌥⌘P): certificate files open without it
    /// until it is shown again. Kept in UserDefaults.
    static var closedByUser: Bool {
        get { UserDefaults.standard.bool(forKey: "certificatePanelClosed") }
        set { UserDefaults.standard.set(newValue, forKey: "certificatePanelClosed") }
    }

    /// In large mode only the first megabyte is read.
    var isLarge: () -> Bool = { false }

    func render(text: String, language: Language, palette: EditorPalette, baseURL: URL?, fileName: String?) {
        generation += 1
        let gen = generation
        let source = isLarge() ? String((text as NSString).substring(to: min((text as NSString).length, 1 << 20))) : text
        Self.queue.async {
            let found = Certificates.items(inText: source)
            let ns = source as NSString
            let items = found.map(\.item)
            // Each certificate's own block, exactly as it is in the text.
            let pems: [String?] = found.map { $0.item.certificate != nil ? ns.substring(with: $0.range) : nil }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.details.show(items, pems: pems, palette: palette, emptyText: String(localized: "No certificate here yet. Paste one (-----BEGIN CERTIFICATE-----)."))
                    self.renders += 1
                }
            }
        }
    }

    func sync(line: Int, fraction: Double, language: Language) {}
    func handles(_ language: Language) -> Bool { !language.hasPreview }
}

/// A binary (DER) certificate or PKCS#7 bundle (.cer .crt .der .p7b
/// .p7c): read-only details in a window tabbed with the editor's, **Copy
/// as PEM** (the main action) and **Open as PEM Text**, which opens the
/// certificates as PEM in a new untitled tab. Never writes to the file.
@MainActor
final class CertificateTabController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ViewerTab {
    let id: UUID
    var fileURL: URL
    private(set) var isLoaded = false
    let details = CertificateDetailsView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    /// The main action: the certificates as PEM on the clipboard.
    let copyPEMButton = NSButton(title: String(localized: "Copy as PEM"), target: nil, action: nil)
    let pemButton = NSButton(title: String(localized: "Open as PEM Text"), target: nil, action: nil)
    let statusBar = StatusBar()
    private var fileModified: Date?
    private var appearanceObserver: NSObjectProtocol?
    private(set) var items: [CertificateItem] = []

    var onClose: ((CertificateTabController) -> Void)?

    init(fileURL: URL, id: UUID = UUID()) {
        self.id = id
        self.fileURL = fileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "CedricEditor"
        window.minSize = NSSize(width: 420, height: 240)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        for b in [statusBar.languageButton, statusBar.encodingButton, statusBar.lineEndingButton] { b.isHidden = true }
        for b in [copyPEMButton, pemButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        copyPEMButton.action = #selector(copyAsPEM(_:))
        copyPEMButton.keyEquivalent = "\r"
        pemButton.action = #selector(viewAsPEM(_:))
        let bar = NSStackView(views: [copyPEMButton, pemButton])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.alignment = .centerY
        let stack = NSStackView(views: [bar, details, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        details.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.tab.toolTip = fileURL.path
        statusBar.position.stringValue = String(localized: "Certificate")
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(forName: .cedricAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyAppearance()
                if self.isLoaded { self.details.show(self.items, pems: self.itemPEMs, palette: self.palette) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var palette: EditorPalette { Settings.shared.palette(for: window?.effectiveAppearance) }

    func applyAppearance() {
        window?.appearance = Settings.shared.windowAppearance
        statusBar.background = NSColor(hex: palette.statusBar)
    }

    /// Reads and shows the file (small: certificates are a few KB; read on
    /// the main thread, files over 4 MB refused).
    func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        load()
    }

    private func load() {
        fileModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 4 << 20, let data = try? Data(contentsOf: fileURL) else {
            items = []
            details.show([], palette: palette, emptyText: String(localized: "“\(fileURL.lastPathComponent)” couldn’t be read."))
            return
        }
        items = Certificates.items(inDER: data)
        details.show(items, pems: itemPEMs, palette: palette, emptyText: String(localized: "“\(fileURL.lastPathComponent)” isn’t a certificate Owlink can read."))
        let n = items.filter { $0.certificate != nil }.count
        statusBar.position.stringValue = n == 1 ? String(localized: "Certificate (DER)") : String(localized: "\(n) certificates (PKCS#7)")
        pemButton.isEnabled = n > 0
        copyPEMButton.isEnabled = n > 0
    }

    func reloadIfChangedOnDisk() {
        guard isLoaded, let known = fileModified,
              let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mod > known else { return }
        load()
    }

    var sessionTab: SessionTab { SessionTab(id: id, path: fileURL.path, untitledName: nil, certificate: OfficeTabState()) }

    /// The certificates as PEM, one block each.
    var pemText: String { items.compactMap { $0.certificate.map { PEM.encode($0.der) } }.joined() }

    /// Each item's PEM (certificates only), for its Copy Certificate (PEM).
    var itemPEMs: [String?] { items.map { $0.certificate.map { PEM.encode($0.der) } } }

    /// Copy as PEM: every certificate, BEGIN/END lines, 64 columns.
    @objc func copyAsPEM(_ sender: Any?) {
        let text = pemText
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusBar.counts.stringValue = String(localized: "Copied as PEM")
    }

    @objc func viewAsPEM(_ sender: Any?) {
        let text = pemText
        guard !text.isEmpty else { NSSound.beep(); return }
        let base = (fileURL.lastPathComponent as NSString).deletingPathExtension
        (NSApp.delegate as? AppDelegate)?.openExtractedText(text, named: String(localized: "\(base) (PEM)"), asFileNamed: "certificate.pem")
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
    @objc func zoomIn(_ sender: Any?) {}
    @objc func zoomOut(_ sender: Any?) {}
    @objc func zoomReset(_ sender: Any?) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if PDFTabController.disabledHere.contains(action) { item.state = .off; return false }
        switch action {
        case #selector(openInDefaultApp(_:)):
            item.title = AppDelegate.openInTitle(fileURL)
            return AppDelegate.defaultApp(for: fileURL) != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomReset(_:)): return false
        default: return true
        }
    }
}

// MARK: - App: opening certificate tabs

extension AppDelegate {
    /// Opens a DER certificate or PKCS#7 bundle in a certificate tab, or
    /// focuses the tab that has it.
    @discardableResult
    func openCertificate(_ url: URL) -> CertificateTabController? {
        let std = url.standardizedFileURL
        if let existing = certificateTabs.first(where: { $0.fileURL.standardizedFileURL == std }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let blank = replaceableBlankTab
        let tab = makeCertificateTab(CertificateTabController(fileURL: std))
        tab.ensureLoaded()
        blank?.window?.close()
        noteRecent(std)
        return tab
    }

    @discardableResult
    func makeCertificateTab(_ tab: CertificateTabController, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true,
                            tabIndex: Int? = nil) -> CertificateTabController {
        tab.onClose = { [weak self] t in
            self?.releaseWaiters(for: t.id)
            guard let self, !self.terminating else { return }
            let last = self.isClosingLastDocument(t.window)
            self.certificateTabs.removeAll { $0 === t }
            self.rememberClosedViewer(t)
            if last { self.quitAfterLastClose() }
        }
        certificateTabs.append(tab)
        if let window = tab.window { placeViewerWindow(window, in: group, newWindow: newWindow, show: show, tabIndex: tabIndex) }
        return tab
    }
}
