import UIKit
import PDFKit
import QuickLook
import CedricCore

// Read-only viewers for PDF and Office / iWork files, as on the Mac (its
// PDF and Quick Look tabs). `DocumentViewerRoute` decides which file goes
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

/// A PDF, read-only: PDFKit's view, fitted to the width, scrolling
/// continuously down the pages, with the current page shown at the bottom.
final class PDFViewerController: UIViewController, PDFViewDelegate, DocumentViewer {
    let fileURL: URL
    let document: PDFDocument
    private let access: ScopedFileAccess
    let pdfView = PDFView()
    let pageLabel = UILabel()
    private var pageObserver: NSObjectProtocol?

    init(document: PDFDocument, url: URL, access: ScopedFileAccess) {
        self.document = document
        self.fileURL = url
        self.access = access
        super.init(nibName: nil, bundle: nil)
        let pages = document.pageCount
        let kind = pages == 1 ? String(localized: "PDF, 1 page") : String(localized: "PDF, \(pages) pages")
        DocumentViewers.configure(self, url: url, subtitle: DocumentViewers.subtitle(kind: kind, url: url)) { [weak self] in
            self?.close()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.delegate = self
        pdfView.document = document
        pdfView.accessibilityIdentifier = "viewer.pdf"
        view.addSubview(pdfView)

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
        NSLayoutConstraint.activate([
            // Full height: PDFKit's scroll view insets itself for the bar.
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            pageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePageLabel() }
        }
        updatePageLabel()
    }

    private var showedFirstPage = false

    /// Once laid out at its real size, show page 1 from its top: fitting
    /// the width before then left the first page scrolled under the bar.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !showedFirstPage, pdfView.bounds.width > 0, let first = document.page(at: 0) else { return }
        showedFirstPage = true
        pdfView.layoutIfNeeded()
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        pdfView.go(to: PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: pdfView.displayBox).maxY)))
        updatePageLabel()
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

    func updatePageLabel() {
        let count = document.pageCount
        let current = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        pageLabel.text = "  " + String(localized: "\(current) of \(count)") + "  "
        pageLabel.isHidden = count == 0
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
/// its own share and markup buttons don't show: this screen's bar has
/// only the file name and Done.
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = "viewer.quicklook"
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        preview.dataSource = self
        preview.delegate = self
        addChild(preview)
        preview.view.frame = container.bounds
        preview.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(preview.view)
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
