import UIKit
import PDFKit
import QuickLook
import CedricCore

// Read-only viewers for PDF and Office / iWork files, as on the Mac (its
// PDF and Quick Look tabs); spreadsheets have their own grid
// (SpreadsheetViewer.swift). `DocumentViewerRoute` decides which file goes
// where; `DocumentBrowserViewController.presentDocument` presents them.
//
// Nothing here writes to, moves or deletes the file: there is no save path,
// no UIDocument, no file coordinator writing, Quick Look's editing (markup)
// is disabled, and links inside a document don't open on their own.

/// A file's security scope (a file picked in Files, or opened in place
/// from another app), held while a viewer shows it. Stopped exactly once:
/// by `stop()` (Done, a failure, its window going away) or when the
/// viewer is released.
final class ScopedFileAccess {
    let url: URL
    private(set) var isActive: Bool
    private let stopAccess: (URL) -> Void

    init(_ url: URL,
         startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stopAccess = stopAccess
        // False for a file in the app's own container: nothing to stop.
        isActive = startAccess(url)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        stopAccess(url)
    }

    deinit { stop() }
}

/// A read-only viewer: `tearDown()` ends its file access (idempotent),
/// for a window that goes away without Done.
@MainActor protocol DocumentViewer: UIViewController {
    func tearDown()
}

enum DocumentViewers {
    /// The viewers among `controllers` (each one, or the root of a
    /// navigation controller showing one).
    @MainActor static func viewers(in controllers: [UIViewController]) -> [DocumentViewer] {
        controllers.flatMap { c -> [DocumentViewer] in
            if let nav = c as? UINavigationController { return nav.viewControllers.compactMap { $0 as? DocumentViewer } }
            return (c as? DocumentViewer).map { [$0] } ?? []
        }
    }

    /// Ends each viewer's file access (a second call does nothing).
    @MainActor static func tearDown(_ viewers: [DocumentViewer]) {
        for v in viewers { v.tearDown() }
    }

    /// The window `root` belongs to is going away (`sceneDidDisconnect`):
    /// every viewer it presents stops its file access now, rather than
    /// whenever the retained controllers are released, and is dismissed.
    @MainActor static func tearDown(presentedBy root: UIViewController?) {
        var chain: [UIViewController] = []
        var next = root?.presentedViewController
        while let c = next {
            chain.append(c)
            next = c.presentedViewController
        }
        let viewers = viewers(in: chain)
        tearDown(viewers)
        if !viewers.isEmpty { root?.dismiss(animated: false) }
    }

    /// The navigation controller a viewer is shown in: full screen like the
    /// editor, following the theme's light or dark.
    @MainActor static func navigationController(for viewer: UIViewController, traits: UITraitCollection) -> UINavigationController {
        let nav = UINavigationController(rootViewController: viewer)
        nav.modalPresentationStyle = .fullScreen
        nav.navigationBar.prefersLargeTitles = false
        let palette = AppSettings.theme.palette(systemIsDark: traits.userInterfaceStyle == .dark)
        nav.overrideUserInterfaceStyle = EditorBarStyle.interfaceStyle(theme: AppSettings.theme, isDark: palette.isDark)
        return nav
    }

    /// "Excel spreadsheet · 12 KB": what the file is, under its name.
    static func subtitle(kind: String, url: URL) -> String {
        var parts = [kind]
        if let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { parts.append(ImageInfoText.fileSize(Int64(n))) }
        return parts.joined(separator: " · ")
    }

    /// Share: the system share sheet with the file's URL (also Open In).
    /// Nothing is written; the viewer keeps its file access while it is up.
    @MainActor static func shareItem(for vc: UIViewController, url: URL) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: nil, action: nil)
        item.primaryAction = UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak vc, weak item] _ in
            guard let vc, vc.presentedViewController == nil else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = item
            vc.present(sheet, animated: true)
        }
        item.accessibilityIdentifier = "viewer.share"
        item.accessibilityLabel = String(localized: "Share")
        return item
    }

    /// Title (the file name), subtitle, and Done, which closes the viewer
    /// and ends its file access.
    @MainActor static func configure(_ vc: UIViewController, url: URL, subtitle: String, done: @escaping () -> Void) {
        vc.title = url.lastPathComponent
        vc.navigationItem.largeTitleDisplayMode = .never
        if #available(iOS 26.0, *) { vc.navigationItem.subtitle = subtitle }
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in done() })
        item.accessibilityIdentifier = "viewer.done"
        vc.navigationItem.leftBarButtonItem = item
    }
}

// MARK: PDF

/// A PDF, read-only: PDFKit's view, fitted to the width on open and on
/// rotation, scrolling continuously down the pages, with "n of m" at the
/// bottom, a thumbnail strip, find (PDFKit's find navigator), and Share.
/// A password-protected PDF asks for its password (unlocked in memory
/// only); a damaged or empty one shows why, with Share still there.
final class PDFViewerController: UIViewController, PDFViewDelegate, DocumentViewer {
    let fileURL: URL
    let document: PDFDocument?
    private let access: ScopedFileAccess
    let pdfView = PDFView()
    let pageLabel = UILabel()
    let thumbnailView = PDFThumbnailView()
    let messageView = UIView()
    private let messageContent = UIContentUnavailableView(configuration: .empty())
    private var pageObserver: NSObjectProtocol?
    private var shareItem: UIBarButtonItem!
    private lazy var searchItem: UIBarButtonItem = {
        let i = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.find() })
        i.accessibilityIdentifier = "viewer.pdf.search"
        i.accessibilityLabel = String(localized: "Find in PDF")
        return i
    }()
    private lazy var thumbnailsItem: UIBarButtonItem = {
        let i = UIBarButtonItem(image: UIImage(systemName: "rectangle.grid.1x2"), primaryAction: UIAction { [weak self] _ in self?.toggleThumbnails() })
        i.accessibilityIdentifier = "viewer.pdf.thumbnails"
        i.accessibilityLabel = String(localized: "Page Thumbnails")
        return i
    }()
    private var thumbnailHeight: NSLayoutConstraint!
    private var pageLabelBottom: NSLayoutConstraint!

    init(document: PDFDocument?, url: URL, access: ScopedFileAccess) {
        self.document = document
        self.fileURL = url
        self.access = access
        super.init(nibName: nil, bundle: nil)
        let kind: String
        if let document, !document.isLocked {
            let pages = document.pageCount
            kind = pages == 1 ? String(localized: "PDF, 1 page") : String(localized: "PDF, \(pages) pages")
        } else {
            kind = String(localized: "PDF")
        }
        DocumentViewers.configure(self, url: url, subtitle: DocumentViewers.subtitle(kind: kind, url: url)) { [weak self] in
            self?.close()
        }
        shareItem = DocumentViewers.shareItem(for: self, url: url)
        updateBarItems()
    }

    required init?(coder: NSCoder) { fatalError() }

    var isLocked: Bool { document?.isLocked ?? false }
    private var hasPages: Bool { (document?.pageCount ?? 0) > 0 }

    private func updateBarItems() {
        let usable = document != nil && !isLocked && hasPages
        navigationItem.rightBarButtonItems = usable ? [shareItem, searchItem, thumbnailsItem] : [shareItem]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.delegate = self
        pdfView.accessibilityIdentifier = "viewer.pdf"
        pdfView.isFindInteractionEnabled = true
        view.addSubview(pdfView)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.layoutMode = .horizontal
        thumbnailView.thumbnailSize = CGSize(width: 44, height: 58)
        thumbnailView.backgroundColor = .systemBackground.withAlphaComponent(0.92)
        thumbnailView.pdfView = pdfView
        thumbnailView.isHidden = true
        thumbnailView.accessibilityIdentifier = "viewer.pdf.thumbnails"
        thumbnailView.accessibilityLabel = String(localized: "Page Thumbnails")
        view.addSubview(thumbnailView)

        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textColor = .secondaryLabel
        pageLabel.backgroundColor = .systemBackground.withAlphaComponent(0.85)
        pageLabel.textAlignment = .center
        pageLabel.layer.cornerRadius = 8
        pageLabel.layer.masksToBounds = true
        pageLabel.accessibilityIdentifier = "viewer.pdf.page"
        view.addSubview(pageLabel)

        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageContent.translatesAutoresizingMaskIntoConstraints = false
        messageView.addSubview(messageContent)
        messageView.backgroundColor = .systemBackground
        messageView.isHidden = true
        messageView.accessibilityIdentifier = "viewer.message"
        view.addSubview(messageView)

        thumbnailHeight = thumbnailView.heightAnchor.constraint(equalToConstant: 0)
        pageLabelBottom = pageLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            // Full height: PDFKit's scroll view insets itself for the bar.
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            thumbnailHeight,
            pageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageLabelBottom,
            pageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            messageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageContent.topAnchor.constraint(equalTo: messageView.safeAreaLayoutGuide.topAnchor),
            messageContent.bottomAnchor.constraint(equalTo: messageView.safeAreaLayoutGuide.bottomAnchor),
            messageContent.leadingAnchor.constraint(equalTo: messageView.safeAreaLayoutGuide.leadingAnchor),
            messageContent.trailingAnchor.constraint(equalTo: messageView.safeAreaLayoutGuide.trailingAnchor),
        ])
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePageLabel() }
        }
        showDocumentOrState()
    }

    /// The pages, or why there are none: damaged, locked, empty.
    private func showDocumentOrState() {
        var c = UIContentUnavailableConfiguration.empty()
        if document == nil {
            c.image = UIImage(systemName: "exclamationmark.triangle")
            c.text = String(localized: "Can’t Open This PDF")
            c.secondaryText = String(localized: "The file is damaged or isn’t a PDF. Use Share to open it in another app.")
        } else if isLocked {
            c.image = UIImage(systemName: "lock.fill")
            c.text = String(localized: "Password Protected")
            c.secondaryText = String(localized: "Enter the password to view this PDF.")
            var b = UIButton.Configuration.filled()
            b.title = String(localized: "Enter Password")
            c.button = b
            c.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.askForPassword() }
        } else if !hasPages {
            c.image = UIImage(systemName: "doc")
            c.text = String(localized: "No Pages")
            c.secondaryText = String(localized: "This PDF has no pages.")
        } else {
            messageView.isHidden = true
            pdfView.isHidden = false
            if pdfView.document !== document { pdfView.document = document }
            showedFirstPage = false
            view.setNeedsLayout()
            updatePageLabel()
            updateBarItems()
            return
        }
        messageContent.configuration = c
        messageView.accessibilityLabel = [c.text, c.secondaryText].compactMap { $0 }.joined(separator: ". ")
        messageView.isHidden = false
        pdfView.isHidden = true
        pageLabel.isHidden = true
        updateBarItems()
    }

    private var showedFirstPage = false
    private var fittedSize: CGSize = .zero

    /// Once laid out at its real size, show page 1 from its top, fitted to
    /// the width; after a rotation (or a new window size), fit again.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard pdfView.document != nil, pdfView.bounds.width > 0 else { return }
        if !showedFirstPage, pdfView.document?.page(at: 0) != nil {
            showedFirstPage = true
            fittedSize = pdfView.bounds.size
            pdfView.layoutIfNeeded()
            fitToWidth()
            showFirstPageTop()
            updatePageLabel()
        } else if pdfView.bounds.size != fittedSize {
            // Rotated (or resized): fit again, at the same place; on the
            // first page, at its top (under the bar, not behind it).
            fittedSize = pdfView.bounds.size
            let dest = pdfView.currentDestination
            pdfView.layoutIfNeeded()
            fitToWidth()
            if let first = pdfView.document?.page(at: 0), dest == nil || dest?.page == first {
                showFirstPageTop()
            } else if let dest {
                pdfView.go(to: dest)
            }
        }
    }

    /// The page's width fills the view. (Setting autoScales again here
    /// would let PDFKit scroll on its own later.)
    private func fitToWidth() {
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
    }

    /// Page 1 from its top, just below the bar. PDFKit puts the
    /// destination at the top of its view, under the bar (whose height it
    /// doesn't always allow for), so where the page landed is measured and
    /// put right.
    private func showFirstPageTop() {
        guard let first = pdfView.document?.page(at: 0) else { return }
        let top = first.bounds(for: pdfView.displayBox).maxY
        pdfView.go(to: PDFDestination(page: first, at: CGPoint(x: 0, y: top)))
        pdfView.layoutIfNeeded()
        let landed = pdfView.convert(first.bounds(for: pdfView.displayBox), from: first).minY
        let want = pdfView.safeAreaInsets.top
        let scale = max(pdfView.scaleFactor, 0.01)
        if abs(landed - want) > 0.5 {
            pdfView.go(to: PDFDestination(page: first, at: CGPoint(x: 0, y: top + (want - landed) / scale)))
        }
    }

    /// The bar's height can settle after the first layout: page 1, if the
    /// reader is still there, goes back below it.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard showedFirstPage, let first = pdfView.document?.page(at: 0), pdfView.currentPage == first else { return }
        showFirstPageTop()
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

    func updatePageLabel() {
        let count = document?.pageCount ?? 0
        let current = pdfView.currentPage.flatMap { p in document.map { $0.index(for: p) + 1 } } ?? 1
        pageLabel.text = "  " + String(localized: "\(current) of \(count)") + "  "
        pageLabel.accessibilityLabel = String(localized: "Page \(current) of \(count)")
        pageLabel.isHidden = count == 0 || isLocked || document == nil
    }

    // MARK: Thumbnails and find

    func toggleThumbnails() {
        // Showing the strip makes PDFKit scroll to the current page's top
        // under the bar: page 1 is put back below it.
        defer {
            if let first = pdfView.document?.page(at: 0), pdfView.currentPage == first { showFirstPageTop() }
        }
        let show = thumbnailView.isHidden
        thumbnailView.isHidden = !show
        thumbnailHeight.constant = show ? 76 : 0
        pageLabelBottom.constant = show ? -84 : -8
        thumbnailsItem.isSelected = show
        view.layoutIfNeeded()
    }

    private func find() {
        pdfView.findInteraction.presentFindNavigator(showingReplace: false)
    }

    // MARK: Password

    /// Unlocks the document in memory (nothing is written).
    @discardableResult
    func unlock(password: String) -> Bool {
        guard let document, document.isLocked, document.unlock(withPassword: password) else { return false }
        let pages = document.pageCount
        let kind = pages == 1 ? String(localized: "PDF, 1 page") : String(localized: "PDF, \(pages) pages")
        if #available(iOS 26.0, *) { navigationItem.subtitle = DocumentViewers.subtitle(kind: kind, url: fileURL) }
        showDocumentOrState()
        return true
    }

    private func askForPassword(wrong: Bool = false) {
        guard presentedViewController == nil else { return }
        let a = UIAlertController(title: String(localized: "Password Protected"),
                                  message: wrong ? String(localized: "That password is incorrect. Try again.")
                                                 : String(localized: "Enter the password for “\(fileURL.lastPathComponent)”."),
                                  preferredStyle: .alert)
        a.addTextField { f in
            f.isSecureTextEntry = true
            f.placeholder = String(localized: "Password")
            f.accessibilityIdentifier = "viewer.pdf.password"
        }
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let ok = UIAlertAction(title: String(localized: "Unlock"), style: .default) { [weak self, weak a] _ in
            guard let self else { return }
            if !self.unlock(password: a?.textFields?.first?.text ?? "") {
                DispatchQueue.main.async { self.askForPassword(wrong: true) }
            }
        }
        a.addAction(ok)
        a.preferredAction = ok
        present(a, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isLocked { askForPassword(); return }
        // Insets are final once on screen: page 1 sits right below the bar
        // (measured, so a top already right stays where it is).
        if let first = pdfView.document?.page(at: 0), pdfView.currentPage == first { showFirstPageTop() }
    }

    private func close() {
        dismiss(animated: true) { [access] in access.stop() }
    }

    func tearDown() { access.stop() }

    /// A web or mail link in the PDF asks first (as the preview does);
    /// any other link (a file, an app's scheme) is dropped. Links within
    /// the document are PDFKit's own and still go to their page.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""), presentedViewController == nil else { return }
        let a = UIAlertController(title: ExternalLinkText.promptTitle(for: url),
                                  message: ExternalLinkText(url).promptMessage, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Open"), style: .default) { _ in UIApplication.shared.open(url) })
        let cancel = UIAlertAction(title: String(localized: "Cancel"), style: .cancel)
        a.addAction(cancel)
        a.preferredAction = cancel
        present(a, animated: true)
    }
}

// MARK: Office / iWork (Quick Look)

/// An Office or iWork document (or an RTFD package), read-only, in Quick
/// Look. QLPreviewController is a child here, not the presented screen, so
/// its own share and markup buttons don't show: this screen's bar has the
/// file name, Done and Share.
final class QuickLookViewerController: UIViewController, QLPreviewControllerDataSource, QLPreviewControllerDelegate, DocumentViewer {
    let fileURL: URL
    let format: OfficeFormat
    private let access: ScopedFileAccess
    let preview = QLPreviewController()

    private final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(_ url: URL) {
            previewItemURL = url
            previewItemTitle = url.lastPathComponent
        }
    }

    init(url: URL, format: OfficeFormat, access: ScopedFileAccess) {
        self.fileURL = url
        self.format = format
        self.access = access
        super.init(nibName: nil, bundle: nil)
        DocumentViewers.configure(self, url: url, subtitle: DocumentViewers.subtitle(kind: format.kindName, url: url)) { [weak self] in
            self?.close()
        }
        navigationItem.rightBarButtonItems = [DocumentViewers.shareItem(for: self, url: url)]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Quick Look fills the space under the bar, edge to edge (its content
    /// keeps clear of the home indicator itself); how it scales what it
    /// draws inside is its own.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = "viewer.quicklook"
        view.addSubview(container)
        preview.dataSource = self
        preview.delegate = self
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview.view)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: container.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            preview.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        preview.didMove(toParent: self)
    }

    private func close() {
        dismiss(animated: true) { [access] in access.stop() }
    }

    func tearDown() { access.stop() }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { Item(fileURL) }

    /// Read-only: no markup, no edits saved back to the file.
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        .disabled
    }

    /// Links in the document don't leave the app on their own.
    func previewController(_ controller: QLPreviewController, shouldOpen url: URL, for item: QLPreviewItem) -> Bool { false }
}
