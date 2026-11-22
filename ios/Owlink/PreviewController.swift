import UIKit
import WebKit
import UniformTypeIdentifiers
import CedricCore

/// The Markdown preview: the core's renderer and page (`Markdown.render`,
/// `PreviewHTML`, the same as the Mac's) in a WKWebView with JavaScript off,
/// scripts stripped and nothing loaded from the network.
///
/// The text size is the person's zoom (pinch, or ⌘+ and ⌘− in Focus
/// Preview), kept for the app, times the Dynamic Type scale, as the web
/// view's page zoom so the text reflows. The scroll position survives the
/// reloads that follow typing, and can be set as a share of the page
/// (Focus Preview keeps text and preview at the same place).
///
/// Images and wikilinks resolve on disk only. The page is loaded from
/// `cedric-doc://doc/<folder>/` (not `loadHTMLString`, which on iOS does
/// not adopt a custom-scheme base URL, so `/images/…` never reaches the
/// handler). `PreviewFiles` serves that page and the files: the document's
/// folder, the site root `PreviewRoot` finds, and the Obsidian vault, read
/// in this process (which holds the security-scoped access).
/// A file opened on its own from Files grants only itself. A folder listing
/// can still succeed, so access is a real open of a sibling file
/// (`PreviewFolderAccess`); without it, images become one "Open the folder"
/// hint, which asks for the folder. Split preview, full-screen read-only,
/// Focus Preview and the detached preview all come through `show`.
final class PreviewController: UIViewController, WKNavigationDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
    private(set) var web: WKWebView!
    private(set) var csv: CSVPreviewController?
    private var showingCSV = false
    private let queue = DispatchQueue(label: "owlink.preview", qos: .userInitiated)
    private var generation = 0
    static let csp = "default-src 'none'; img-src data: \(PreviewFolder.scheme):; media-src data: \(PreviewFolder.scheme):; style-src 'unsafe-inline'; font-src data:; script-src 'none'; connect-src 'none'"
    /// The hint's link: asks for the document's folder.
    static let grantURL = "owlink-preview:open-folder"
    /// The open document (its folder is the page's base).
    var documentURL: URL?
    /// A text file a preview link names, to open in Owlink.
    var onOpenFile: ((URL) -> Void)?
    private let files = PreviewFiles()
    private var vault: WikiVault?
    private var vaultKey: String?
    /// Folder-access probe for this document and grant. Preview refreshes
    /// on each edit; the probe (real file opens) runs once per folder.
    private var folderAccess: (key: String, readable: Bool)?
    private var last: (markdown: String, palette: EditorPalette)?
    /// A scroll share to apply once the page has loaded (and laid out).
    private var pendingFraction: Double?
    private var loaded = false
    private(set) var userZoom = PreviewZoom.load(AppSettings.defaults)
    private var pinchStart = 1.0
    /// Called with the new zoom (for a short "Text 120%" note).
    var onZoom: ((Double) -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(files, forURLScheme: PreviewFolder.scheme)
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.accessibilityIdentifier = "editor.previewWeb"
        // Our pinch sets the text size (it reflows); WebKit's own would
        // magnify the page sideways.
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        web.addGestureRecognizer(pinch)
        let container = UIView()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
        setUpHeader(in: container)
        view = container
    }

    // MARK: Header (Focus Preview, Open in New Window)

    /// Small controls in the preview's own top corner: Focus Preview (or
    /// back out of it) and, where there can be more windows (iPad), Open
    /// Preview in New Window, which can also be dragged out to make one.
    private let header = UIStackView()
    private let focusButton = UIButton(configuration: .gray())
    private let detachButton = UIButton(configuration: .gray())
    private var onFocus: (() -> Void)?
    private var onDetach: (() -> Void)?
    private var detachActivity: (() -> NSUserActivity?)?

    private func setUpHeader(in container: UIView) {
        header.axis = .horizontal
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        for (b, id) in [(focusButton, "preview.header.focus"), (detachButton, "preview.header.detach")] {
            var c = b.configuration ?? .gray()
            c.cornerStyle = .capsule
            c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            c.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9)
            b.configuration = c
            b.alpha = 0.85
            b.accessibilityIdentifier = id
            b.pointerStyleProvider = { button, _, _ in UIPointerStyle(effect: .highlight(UITargetedPreview(view: button))) }
            header.addArrangedSubview(b)
        }
        focusButton.addAction(UIAction { [weak self] _ in self?.onFocus?() }, for: .primaryActionTriggered)
        detachButton.addAction(UIAction { [weak self] _ in self?.onDetach?() }, for: .primaryActionTriggered)
        detachButton.configuration?.image = UIImage(systemName: "macwindow.badge.plus")
        detachButton.accessibilityLabel = String(localized: "Open Preview in New Window")
        detachButton.accessibilityHint = String(localized: "Or drag it out to make a window.")
        detachButton.addInteraction(UIDragInteraction(delegate: self))
        container.addSubview(header)
        let g = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
        ])
        header.isHidden = true
    }

    /// Shows the header with what it can do here (nothing: hidden, as in a
    /// detached preview window). `focusOn`: the button leaves Focus Preview.
    func configureHeader(focusOn: Bool, onFocus: (() -> Void)?, onDetach: (() -> Void)?,
                         detachActivity: (() -> NSUserActivity?)?) {
        loadViewIfNeeded()
        self.onFocus = onFocus
        self.onDetach = onDetach
        self.detachActivity = detachActivity
        focusButton.isHidden = onFocus == nil
        detachButton.isHidden = onDetach == nil
        focusButton.configuration?.image = UIImage(systemName: focusOn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        focusButton.accessibilityLabel = focusOn ? String(localized: "Exit Focus Preview") : String(localized: "Focus Preview")
        header.isHidden = onFocus == nil && onDetach == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyZoom(keepingPlace: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.applyZoom(keepingPlace: true)
        }
    }

    func show(markdown: String, palette: EditorPalette) {
        loadViewIfNeeded()
        showingCSV = false
        csv?.view.isHidden = true
        web.isHidden = false
        generation += 1
        let gen = generation
        web.backgroundColor = UIColor(hex: palette.background)
        last = (markdown, palette)
        let folder = documentURL?.deletingLastPathComponent().standardizedFileURL
        let opened = folder.flatMap(PreviewFolderGrants.shared.root(for:))
        let key = "\(folder?.path ?? "-")|\(opened?.path ?? "-")"
        if key != vaultKey {
            vaultKey = key
            vault = folder.map { WikiVault(documentFolder: $0, openedRoot: opened) }
        }

        let vault = self.vault
        files.folder = folder
        files.openedRoot = opened
        files.vaultRoot = vault?.root
        let baseURL = folder.flatMap(PreviewFolder.pageURL(for:))
        let document = documentURL
        let accessKey = "\(folder?.path ?? "-")|\(opened?.path ?? "-")"
        let cachedAccess = folderAccess?.key == accessKey ? folderAccess?.readable : nil
        let hint = "<p class=\"preview-hint\"><a href=\"\(Self.grantURL)\">" + Markdown.escape(String(localized: "Open the folder to see its images")) + "</a></p>\n"
        queue.async { [weak self] in
            var body = HTMLScrub.noScriptNoRemote(Markdown.render(markdown, options: .preview(vault: vault)))
            let readable: Bool
            if let cachedAccess {
                readable = cachedAccess
            } else if let folder, let document {
                readable = PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: document))
            } else {
                readable = false
            }
            if let folder {
                // No access to the folder (a file opened on its own, even
                // when its parent happens to list): images can't load, so
                // a hint instead of empty boxes.
                body = PreviewImageAccess.hideUnreadable(body, folder: folder, openedRoot: opened, folderReadable: readable, hint: hint).html
            }
            let page = PreviewHTML.page(body: body, palette: palette, csp: Self.csp, viewport: true)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.folderAccess = (accessKey, readable)
                self.files.pageHTML = page
                self.files.pageURL = baseURL
                // A reload goes back to the top: keep the reader's place.
                if self.loaded, self.pendingFraction == nil { self.pendingFraction = self.scrollFraction }
                self.loaded = false
                guard let baseURL else {
                    self.web.loadHTMLString(page, baseURL: nil)
                    return
                }
                // A distinct URL per render, so a repeat load isn't served
                // from WebKit's cache. The query is not part of the page match.
                var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                parts?.queryItems = [URLQueryItem(name: "r", value: String(gen))]
                var request = URLRequest(url: parts?.url ?? baseURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                self.web.load(request)
            }
        }
    }

    func showCSV(text: String, fileName: String, large: Bool, sourceGeneration: Int,
                 onSelectField: @escaping (Int, Int) -> Void) {
        loadViewIfNeeded()
        generation += 1
        showingCSV = true
        web.isHidden = true
        let grid: CSVPreviewController
        if let csv {
            grid = csv
        } else {
            grid = CSVPreviewController()
            addChild(grid)
            grid.view.frame = view.bounds
            grid.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(grid.view, belowSubview: header)
            grid.didMove(toParent: self)
            csv = grid
        }
        grid.view.isHidden = false
        grid.onSelectField = onSelectField
        grid.render(text: text, fileName: fileName, large: large, sourceGeneration: sourceGeneration)
    }

    var activeScrollView: UIScrollView { showingCSV ? (csv?.table ?? web.scrollView) : web.scrollView }

    // MARK: Scroll

    /// Where the page is scrolled, 0 (top) to 1 (bottom); setting it before
    /// the page has loaded applies it once it has.
    var scrollFraction: Double {
        get {
            if showingCSV {
                let s = activeScrollView
                return ScrollSync.fraction(offset: s.contentOffset.y, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                           insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
            }
            if let p = pendingFraction { return p }
            let s = web.scrollView
            return ScrollSync.fraction(offset: s.contentOffset.y, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                       insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
        }
        set {
            if showingCSV {
                let s = activeScrollView
                let y = ScrollSync.offset(fraction: newValue, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                          insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
                s.setContentOffset(CGPoint(x: s.contentOffset.x, y: y), animated: false)
                return
            }
            pendingFraction = newValue
            if loaded { applyPendingFraction() }
        }
    }

    private func applyPendingFraction() {
        guard let f = pendingFraction else { return }
        let s = web.scrollView
        let y = ScrollSync.offset(fraction: f, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                  insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
        s.setContentOffset(CGPoint(x: -s.adjustedContentInset.left, y: y), animated: false)
        pendingFraction = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        // The content size settles a moment after the load finishes.
        let f = pendingFraction
        applyPendingFraction()
        guard let f else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.loaded, self.pendingFraction == nil else { return }
            self.pendingFraction = f
            self.applyPendingFraction()
        }
    }

    // MARK: Text size

    /// Dynamic Type's scale for body text (1 at the default size).
    private var dynamicTypeScale: Double {
        Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traitCollection) / 17)
    }

    var pageZoom: Double { PreviewZoom.pageZoom(user: userZoom, dynamicTypeScale: dynamicTypeScale) }

    private func applyZoom(keepingPlace: Bool) {
        let z = CGFloat(pageZoom)
        guard web.pageZoom != z else { return }
        let f = keepingPlace && loaded ? scrollFraction : nil
        web.pageZoom = z
        if let f {
            DispatchQueue.main.async { [weak self] in self?.scrollFraction = f }
        }
    }

    func setZoom(_ z: Double, save: Bool = true) {
        let c = PreviewZoom.clamped(z)
        guard c != userZoom else { return }
        userZoom = c
        applyZoom(keepingPlace: true)
        if save { PreviewZoom.save(c, AppSettings.defaults) }
        onZoom?(c)
    }

    func bigger() { setZoom(PreviewZoom.step(userZoom, in: true)) }
    func smaller() { setZoom(PreviewZoom.step(userZoom, in: false)) }
    func actualSize() { setZoom(1) }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = userZoom
        case .changed: setZoom(PreviewZoom.pinched(pinchStart, scale: Double(g.scale)), save: false)
        case .ended, .cancelled: PreviewZoom.save(userZoom, AppSettings.defaults)
        default: break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    static func withoutFragment(_ u: URL) -> String {
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? u.absoluteString
    }

    // MARK: Folder access

    /// http and https leave the app only after the person confirms the host.
    private func confirmSafari(_ url: URL, host: String) {
        let shown = PromptText.visible(host)
        let a = UIAlertController(title: String(localized: "Open \(shown) in Safari?"), message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Open"), style: .default) { _ in
            UIApplication.shared.open(url)
        })
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.preferredAction = a.actions.first
        present(a, animated: true)
    }

    /// Asks for the document's folder (or one above it, a site's root).
    private func askForFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = documentURL?.deletingLastPathComponent()
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        PreviewFolderGrants.shared.add(url)
        if let last { show(markdown: last.markdown, palette: last.palette) }
    }

    /// Web links ask, then open in Safari, never inside the preview. A
    /// wikilink or a link to a text file under the document's folder, a
    /// granted folder or the site root opens it in Owlink; anything else
    /// is refused.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            decisionHandler(.cancel)
            if let host = url.host, !host.isEmpty { confirmSafari(url, host: host) }
            return
        }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.absoluteString == Self.grantURL {
                decisionHandler(.cancel)
                askForFolder()
                return
            }
            if url.fragment != nil, let page = webView.url, Self.withoutFragment(url) == Self.withoutFragment(page) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if let file = files.linkTarget(url), PreviewFiles.notes.contains(file.pathExtension.lowercased()) { onOpenFile?(file) }
            return
        }
        decisionHandler(action.navigationType == .other ? .allow : .cancel)
    }
}

/// Dragging Open Preview in New Window out of the preview makes the window
/// where it is dropped (iPad, Stage Manager, an external display).
extension PreviewController: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let activity = detachActivity?() else { return [] }
        let provider = NSItemProvider()
        provider.registerObject(activity, visibility: .all)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = activity
        return [item]
    }
}
