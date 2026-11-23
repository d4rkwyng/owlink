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
///
/// Links browse inside the preview, with app-kept history (Back, Forward,
/// This Document): a Markdown or HTML file the link rules allow
/// (`PreviewLinkAction.previewAction`, `PreviewFiles.linkTarget`) renders
/// here the same way, under the same policy; an http(s) page opens in a
/// separate, isolated web view (`browserConfiguration`: its own process
/// pool, nothing stored, no scripts, handlers or `cedric-doc:`). Nothing a
/// link names is launched; leaving the app (Open in Browser, mailto, a
/// ⌘-click) asks first and shows the whole URL.
final class PreviewController: UIViewController, WKNavigationDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
    private(set) var web: WKWebView!
    /// http(s) pages a link leads to: isolated from `web` (see `browserConfiguration`).
    private(set) var browser: WKWebView!
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
    /// The open document's latest render (This Document), kept while the
    /// reader is on a linked page so edits don't pull them back.
    private var home: (markdown: String, palette: EditorPalette, document: URL?)?
    /// Where This Document was scrolled when the reader left it.
    private var homeFraction: Double?
    /// A scroll share to apply once the page has loaded (and laid out).
    private var pendingFraction: Double?
    private var loaded = false
    private var csvPalette = EditorPalettes.light
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
        // A long-press preview would load the link outside this policy.
        web.allowsLinkPreview = false
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
        browser = WKWebView(frame: .zero, configuration: Self.browserConfiguration())
        browser.navigationDelegate = self
        browser.allowsBackForwardNavigationGestures = false
        browser.allowsLinkPreview = false
        browser.accessibilityIdentifier = "preview.browser"
        browser.frame = container.bounds
        browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        browser.isHidden = true
        container.addSubview(browser)
        setUpHeader(in: container)
        setUpNavBar(in: container)
        setUpNotice(in: container)
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

    /// Renders the open document. Away from it (a linked page), only the
    /// stored copy changes: the reader stays where they are.
    func show(markdown: String, palette: EditorPalette) {
        loadViewIfNeeded()
        home = (markdown, palette, documentURL)
        guard isHome else { return }
        browser.isHidden = true
        render(.markdown(markdown), palette: palette, document: documentURL, rootOverride: nil, keepPlace: true)
    }

    private enum Source {
        case markdown(String)
        case html(String)
    }

    /// Renders `source` for `document` (its folder is the page's base) in
    /// the local preview: scripts stripped, the strict CSP, JavaScript off.
    private func render(_ source: Source, palette: EditorPalette, document: URL?, rootOverride: URL?, keepPlace: Bool) {
        showingCSV = false
        csv?.view.isHidden = true
        web.isHidden = false
        csvPalette = palette
        generation += 1
        let gen = generation
        web.backgroundColor = UIColor(hex: palette.background)
        let folder = document?.deletingLastPathComponent().standardizedFileURL
        let opened = folder.flatMap(PreviewFolderGrants.shared.root(for:)) ?? rootOverride
        let key = "\(folder?.path ?? "-")|\(opened?.path ?? "-")"
        if key != vaultKey {
            vaultKey = key
            vault = folder.map { WikiVault(documentFolder: $0, openedRoot: opened) }
        }

        let vault = self.vault
        files.folder = folder
        files.openedRoot = opened
        files.vaultRoot = vault?.root
        files.vault = vault
        let baseURL = folder.flatMap(PreviewFolder.pageURL(for:))
        let accessKey = "\(folder?.path ?? "-")|\(opened?.path ?? "-")"
        let cachedAccess = folderAccess?.key == accessKey ? folderAccess?.readable : nil
        let hint = "<p class=\"preview-hint\"><a href=\"\(Self.grantURL)\">" + Markdown.escape(String(localized: "Open the folder to see its images")) + "</a></p>\n"
        queue.async { [weak self] in
            // Warm the vault's name index here, off the main thread, so the
            // page's bare-name images don't build it on first request.
            vault?.prepareIndex()
            var body: String
            switch source {
            case .markdown(let markdown): body = HTMLScrub.noScriptNoRemote(Markdown.render(markdown, options: .preview(vault: vault)))
            case .html(let html): body = HTMLScrub.noScriptNoRemote(html)
            }
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
                body = PreviewImageAccess.hideUnreadable(body, folder: folder, openedRoot: opened, folderReadable: readable, hint: hint, vault: vault).html
            }
            let page: String
            switch source {
            case .markdown: page = PreviewHTML.page(body: body, palette: palette, csp: Self.csp, viewport: true)
            case .html: page = Self.htmlPage(body)
            }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.folderAccess = (accessKey, readable)
                self.files.pageHTML = page
                self.files.pageURL = baseURL
                // A reload goes back to the top: keep the reader's place.
                if keepPlace, self.loaded, self.pendingFraction == nil { self.pendingFraction = self.liveFraction }
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

    /// A linked HTML file's page: the same CSP first (before the file's
    /// own markup), after its scripts, frames and remote loads are stripped.
    static func htmlPage(_ scrubbed: String) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\n" + PreviewHTML.viewportMeta + "\n" + scrubbed
    }

    func showCSV(text: NSString, fileName: String, large: Bool, sourceGeneration: Int, palette: EditorPalette,
                 scrollFraction: Double, isSourceCurrent: @escaping () -> Bool,
                 onSelectField: @escaping (Int, Int) -> Void) {
        loadViewIfNeeded()
        generation += 1
        showingCSV = true
        csvPalette = palette
        web.isHidden = true
        // A CSV has no links to browse: back to the document, history cleared.
        browser.stopLoading()
        browser.isHidden = true
        history = [.home]
        historyIndex = 0
        homeFraction = nil
        updateNav()
        let grid: CSVPreviewController
        if let csv {
            grid = csv
        } else {
            grid = CSVPreviewController()
            addChild(grid)
            grid.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(grid.view, belowSubview: header)
            NSLayoutConstraint.activate([
                grid.view.topAnchor.constraint(equalTo: header.bottomAnchor),
                grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                grid.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
            grid.didMove(toParent: self)
            csv = grid
        }
        grid.view.isHidden = false
        grid.onSelectField = onSelectField
        grid.isSourceCurrent = isSourceCurrent
        grid.applyTheme(palette, zoom: userZoom)
        grid.render(text: text, fileName: fileName, large: large, sourceGeneration: sourceGeneration,
                    scrollFraction: scrollFraction)
    }

    var activeScrollView: UIScrollView {
        if showingCSV { return csv?.table ?? web.scrollView }
        return webURL != nil ? browser.scrollView : web.scrollView
    }

    // MARK: Scroll

    /// Where the document's page is scrolled, 0 (top) to 1 (bottom);
    /// setting it before the page has loaded applies it once it has. On a
    /// linked page this is This Document's place, kept for the way back
    /// (text and preview stay in step only on the document).
    var scrollFraction: Double {
        get {
            if showingCSV { return csv?.scrollFraction ?? 0 }
            guard isHome else { return homeFraction ?? 0 }
            return liveFraction
        }
        set {
            if showingCSV {
                csv?.scrollFraction = newValue
                return
            }
            guard isHome else { homeFraction = newValue; return }
            place(newValue)
        }
    }

    /// The local page's place (pending, or as scrolled).
    private var liveFraction: Double {
        if let p = pendingFraction { return p }
        let s = web.scrollView
        return ScrollSync.fraction(offset: s.contentOffset.y, contentHeight: s.contentSize.height, visibleHeight: s.bounds.height,
                                   insetTop: s.adjustedContentInset.top, insetBottom: s.adjustedContentInset.bottom)
    }

    private func place(_ f: Double) {
        pendingFraction = f
        if loaded { applyPendingFraction() }
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
        if webView === browser {
            // Keep the entry at the page actually shown (after redirects).
            if case .web = history[historyIndex], let url = webView.url, Self.isWebURL(url) {
                history[historyIndex] = .web(url)
                updateNav()
            }
            return
        }
        guard webView === web else { return }
        loaded = true
        if let anchor = pendingAnchor, Self.renderGeneration(of: webView.url) == anchor.generation {
            pendingAnchor = nil
            // The heading wins over the place (top, for a new page): that
            // stays only as the fallback when nothing matches, and isn't
            // re-applied later.
            applyPendingFraction()
            scroll(toAnchor: anchor.fragment)
            return
        }
        // The content size settles a moment after the load finishes.
        let f = pendingFraction
        applyPendingFraction()
        guard let f else { return }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.loaded, self.generation == gen, self.pendingFraction == nil else { return }
            self.pendingFraction = f
            self.applyPendingFraction()
        }
    }

    /// The render a local page load belongs to (its `?r=` query).
    static func renderGeneration(of url: URL?) -> Int? {
        guard let url, let r = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "r" })?.value else { return nil }
        return Int(r)
    }

    // MARK: Heading anchors

    /// The heading a local page scrolls to once its render has loaded.
    private var pendingAnchor: (fragment: String, generation: Int)?
    /// The last anchor scroll: the fragment, whether an element matched,
    /// and the scroll view's offset after it (for tests).
    private(set) var lastAnchor: (fragment: String, found: Bool, offset: CGFloat)?
    /// Anchor scrolls finished so far (for tests).
    private(set) var anchorScrolls = 0

    /// Finds the first element whose `id` (or `name`) is one of `ids` and
    /// returns its top and the document's size, in CSS pixels. Run once
    /// per scroll in the app's own content world: the page can't see or
    /// call it, page JavaScript stays off, no handlers, nothing posted back.
    static let anchorScript = """
    let e = null;
    for (const id of ids) { e = document.getElementById(id) || document.getElementsByName(id)[0]; if (e) break; }
    if (!e) return null;
    const doc = document.documentElement;
    return { y: e.getBoundingClientRect().top - doc.getBoundingClientRect().top, h: doc.scrollHeight, w: doc.scrollWidth };
    """

    /// Scrolls the local page so the heading `fragment` names (an exact
    /// `id` or `name`, else the heading slug of that text) is at the top,
    /// through the scroll view as `applyPendingFraction` does. The scroll
    /// view's content size lags the page's layout a little after a load:
    /// until it matches the document's (by the width's scale), and while
    /// a new page's commit moves it back, it tries again shortly (a few
    /// times at most).
    private func scroll(toAnchor fragment: String, attempt: Int = 0) {
        let ids = PreviewAnchor.candidates(for: fragment)
        guard !ids.isEmpty else { return }
        let gen = generation
        web.callAsyncJavaScript(Self.anchorScript, arguments: ["ids": ids], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, gen == self.generation else { return }
            let s = self.web.scrollView
            if case .success(let value) = result, let d = value as? [String: Any],
               let y = (d["y"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue, h > 0 {
                let w = (d["w"] as? NSNumber)?.doubleValue ?? 0
                let expected = w > 0 ? s.contentSize.width / CGFloat(w) * CGFloat(h) : s.contentSize.height
                if attempt < 20, s.contentSize.width == 0 || abs(s.contentSize.height - expected) > max(2, expected * 0.01) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.scroll(toAnchor: fragment, attempt: attempt + 1)
                    }
                    return
                }
                let inset = s.adjustedContentInset
                let scale = s.contentSize.height / CGFloat(h)
                let top = -inset.top
                let bottom = max(top, s.contentSize.height - s.bounds.height + inset.bottom)
                let target = min(max(top, top + CGFloat(y) * scale), bottom)
                s.setContentOffset(CGPoint(x: -inset.left, y: target), animated: false)
                // A new page's first commit can still put it back at the
                // top: check a moment later, and scroll again if so (not
                // when the reader has taken over).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    let held = abs(s.contentOffset.y - target) <= 1 || s.isTracking || s.isDragging || s.isDecelerating
                    if !held, attempt < 20 {
                        self.scroll(toAnchor: fragment, attempt: attempt + 1)
                    } else {
                        self.finishAnchor(fragment, found: true)
                    }
                }
                return
            }
            self.finishAnchor(fragment, found: false) // nothing matched: the place stays
        }
    }

    private func finishAnchor(_ fragment: String, found: Bool) {
        lastAnchor = (fragment, found, web.scrollView.contentOffset.y)
        anchorScrolls += 1
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
        let f = keepingPlace && loaded ? liveFraction : nil
        web.pageZoom = z
        if let f {
            DispatchQueue.main.async { [weak self] in self?.place(f) }
        }
    }

    func setZoom(_ z: Double, save: Bool = true) {
        let c = PreviewZoom.clamped(z)
        guard c != userZoom else { return }
        userZoom = c
        applyZoom(keepingPlace: true)
        if showingCSV { csv?.applyTheme(csvPalette, zoom: userZoom) }
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
        displayEntry(keepPlace: true)
    }

    // MARK: Links

    /// Links in the document's page (security audit H2: nothing a link
    /// names is launched). The grant link asks for the folder; a link
    /// within the page scrolls it; anything else is decided by
    /// `handleLink`. The page's own loads are ours (`cedric-doc:`, or
    /// about:blank for an untitled document); nothing else navigates it.
    /// The isolated browser follows `browserDecision`.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if webView === browser {
            switch Self.browserDecision(url: action.request.url, type: action.navigationType,
                                        mainFrame: action.targetFrame?.isMainFrame, command: Self.command(action),
                                        method: action.request.httpMethod) {
            case .allow: decisionHandler(.allow)
            case .cancel: decisionHandler(.cancel)
            case .push(let url): decisionHandler(.cancel); push(.web(url))
            case .confirm(let url): decisionHandler(.cancel); confirmOpen(url)
            }
            return
        }
        guard webView === web else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.absoluteString == Self.grantURL {
                decisionHandler(.cancel)
                askForFolder()
                return
            }
            // A link within the page (`#part`) is cancelled too: `handleLink`
            // scrolls to it by exact id, else the heading slug.
            decisionHandler(.cancel)
            handleLink(url, command: Self.command(action))
            return
        }
        decisionHandler(Self.localLoadAllowed(action.request.url, type: action.navigationType) ? .allow : .cancel)
    }

    /// The local page's own loads: the first load of a render, nothing a
    /// page could start by itself (a form, a reload of something else).
    static func localLoadAllowed(_ url: URL?, type: WKNavigationType) -> Bool {
        guard type == .other, let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == PreviewFolder.scheme || url?.absoluteString == "about:blank"
    }

    /// ⌘ held (a hardware keyboard): the Mac's ⌘-click, ask to leave the app.
    static func command(_ action: WKNavigationAction) -> Bool {
        if #available(iOS 18.4, *) { return action.modifierFlags.contains(.command) }
        return false
    }

    /// The last link decided (for tests and checks).
    private(set) var lastLinkAction: PreviewLinkAction?

    /// A clicked link in the document's page. A `cedric-doc:` link counts
    /// only as the file `PreviewFiles.linkTarget` confines it to (the
    /// document's folder, a granted folder, the vault or the site root);
    /// a `file:` link is refused; other URLs go by scheme
    /// (`PreviewLinkAction.previewAction`).
    func handleLink(_ url: URL, command: Bool) {
        // A link within the page shown: it stays (no history step).
        if url.fragment != nil, let page = web.url, Self.withoutFragment(url) == Self.withoutFragment(page) {
            if let fragment = PreviewAnchor.fragment(of: url) { scroll(toAnchor: fragment) }
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let routed: URL
        if scheme == PreviewFolder.scheme {
            guard let file = files.linkTarget(url) else {
                lastLinkAction = .ignore("missing")
                notice(String(localized: "The preview link points to a file that isn’t there or that Owlink can’t read."))
                return
            }
            routed = file
        } else if url.isFileURL {
            lastLinkAction = .ignore("file")
            notice(String(localized: "Owlink doesn’t follow “file:” links from a preview."))
            return
        } else {
            routed = url
        }
        let root = routed.isFileURL ? files.linkFolder(routed) : files.folder
        let act = PreviewLinkAction.previewAction(for: routed, folder: root, command: command, isText: Self.opensInOwlink)
        lastLinkAction = act
        switch act {
        case .openInPreview(let file):
            // The file is the path alone (`linkTarget`): carry the clicked link's `#fragment`.
            if let root { push(.local(file, root, PreviewAnchor.fragment(of: url))) }
        case .openWebInPreview(let web):
            push(.web(web))
        case .openInCedric(let file):
            if let onOpenFile {
                onOpenFile(file)
            } else {
                noticeCannotOpen(file)
            }
        case .confirmExternal(let external):
            confirmOpen(external)
        case .revealInFinder(let file):
            notice(String(localized: "Owlink doesn’t open \(file.lastPathComponent) from a preview."))
        case .ignore(let why):
            notice(why == "missing"
                   ? String(localized: "The preview link points to a file that isn’t there or that Owlink can’t read.")
                   : String(localized: "Owlink doesn’t follow “\(why):” links from a preview."))
        }
    }

    /// Files a link may open: notes Owlink edits, and Markdown and HTML
    /// (which `previewAction` shows in the preview unless ⌘ is held).
    static func opensInOwlink(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        if PreviewFiles.notes.contains(url.pathExtension.lowercased()) { return true }
        let language = LanguageDetector.language(forFileName: url.lastPathComponent)
        return language == .markdown || language == .html
    }

    // MARK: Isolated browser

    /// The web view http(s) links open in: a new process pool (not the
    /// local preview's), nothing stored, no user scripts or message
    /// handlers, no `cedric-doc:` handler. Page JavaScript stays at
    /// WebKit's default (real web pages); the app adds nothing to it.
    static func browserConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.processPool = WKProcessPool()
        config.userContentController = WKUserContentController()
        return config
    }

    enum BrowserDecision: Equatable {
        case allow, cancel
        /// A followed link: through the app's history.
        case push(URL)
        /// ⌘-click: ask to open it outside the app.
        case confirm(URL)
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host?.isEmpty ?? true)
    }

    /// The isolated browser's policy: http(s) with a host only (never
    /// `file:`, `cedric-doc:`, `javascript:` or another scheme); no new
    /// windows; a followed link or a GET form in the page goes through the
    /// app's history; the page's own load (and its redirects) and its
    /// sub-frames load; anything else is cancelled.
    static func browserDecision(url: URL?, type: WKNavigationType, mainFrame: Bool?, command: Bool,
                                method: String?) -> BrowserDecision {
        guard let url, isWebURL(url) else { return .cancel }
        guard let mainFrame else { return .cancel }
        if type == .linkActivated {
            if command { return .confirm(url) }
            return mainFrame ? .push(url) : .allow
        }
        if !mainFrame { return .allow }
        switch type {
        case .other, .reload: return .allow
        case .formSubmitted where (method ?? "GET").uppercased() == "GET": return .push(url)
        default: return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === browser else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return } // a load the policy stopped
        notice(String(localized: "The web page could not be loaded."))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    // MARK: History

    /// What the preview shows: the open document, a linked local page
    /// (its file, and the root it may read in), or a web page.
    enum Entry: Equatable {
        case home
        /// A linked document, the root it may read in, and the heading
        /// (`#fragment`) to scroll to once it has loaded.
        case local(URL, URL, String?)
        case web(URL)
    }
    private(set) var history: [Entry] = [.home]
    private(set) var historyIndex = 0
    /// Web pages load (tests turn it off: no network).
    var loadsWeb = true
    var isHome: Bool { history[historyIndex] == .home }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var webURL: URL? { if case .web(let url) = history[historyIndex] { return url }; return nil }
    /// Called when the history or the page shown changes.
    var onNavigationChange: (() -> Void)?

    /// Shows `entry`, dropping anything forward of here.
    func push(_ entry: Entry) {
        loadViewIfNeeded()
        leaving()
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(entry)
        historyIndex += 1
        displayEntry(keepPlace: false)
    }

    func goBack() {
        guard canGoBack else { return }
        leaving()
        historyIndex -= 1
        displayEntry(keepPlace: false)
    }

    func goForward() {
        guard canGoForward else { return }
        leaving()
        historyIndex += 1
        displayEntry(keepPlace: false)
    }

    /// This Document: back to the open document, as a new step (Back
    /// returns to the linked page).
    func goHome() { if !isHome { push(.home) } }

    /// Leaving This Document: keep its place for the way back.
    private func leaving() {
        guard isHome, !showingCSV else { return }
        homeFraction = loaded ? liveFraction : pendingFraction
    }

    private func displayEntry(keepPlace: Bool) {
        loadViewIfNeeded()
        browser.stopLoading()
        pendingAnchor = nil
        switch history[historyIndex] {
        case .home:
            browser.isHidden = true
            web.isHidden = false
            if !keepPlace, let f = homeFraction { pendingFraction = f }
            homeFraction = nil
            if let home {
                render(.markdown(home.markdown), palette: home.palette, document: home.document, rootOverride: nil, keepPlace: keepPlace)
            }
        case .local(let file, let root, let fragment):
            browser.isHidden = true
            web.isHidden = false
            // The same rules again (the file may have changed since the click).
            guard case .openInPreview = PreviewLinkAction.previewAction(for: file, folder: root, command: false, isText: Self.opensInOwlink),
                  let data = try? Data(contentsOf: file), let text = TextCodec.decode(data)?.text else {
                notice(String(localized: "Could not read the preview document."))
                break
            }
            if !keepPlace { pendingFraction = 0 }
            let html = LanguageDetector.language(forFileName: file.lastPathComponent) == .html
            render(html ? .html(text) : .markdown(text), palette: home?.palette ?? csvPalette, document: file,
                   rootOverride: root, keepPlace: keepPlace)
            // Scrolled to once this render's page has loaded (also on Back,
            // Forward and a folder-grant refresh), ahead of the place above.
            pendingAnchor = fragment.map { ($0, generation) }
        case .web(let url):
            generation += 1 // drop a local render still on its way
            web.stopLoading()
            web.isHidden = true
            browser.isHidden = false
            if loadsWeb, Self.isWebURL(url) { browser.load(URLRequest(url: url)) }
        }
        updateNav()
    }

    // MARK: Open in Browser

    /// Opens a URL outside the app (after the person confirms).
    var openExternal: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }
    /// The confirmation on screen (or waiting for a window), and its URL.
    private(set) var linkPrompt: UIAlertController?
    private var promptURL: URL?

    /// Open in Browser: the web page shown, after confirming.
    func openInBrowser() {
        if let url = webURL { confirmOpen(url) }
    }

    /// Asks before anything leaves the app, showing the whole URL (hidden
    /// and direction-changing characters made visible).
    func confirmOpen(_ url: URL) {
        let a = UIAlertController(title: String(localized: "Open this link?"),
                                  message: PromptText.visible(url.absoluteString), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Open"), style: .default) { [weak self] _ in
            self?.finishPrompt(open: true)
        })
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.finishPrompt(open: false)
        })
        a.view.accessibilityIdentifier = "preview.openLinkPrompt"
        linkPrompt = a
        promptURL = url
        if viewIfLoaded?.window != nil, presentedViewController == nil { present(a, animated: true) }
    }

    /// The prompt's answer: Open opens the URL it showed; Cancel nothing.
    func finishPrompt(open: Bool) {
        let url = promptURL
        promptURL = nil
        linkPrompt = nil
        if open, let url { openExternal(url) }
    }

    // MARK: Navigation bar (Back, Forward, This Document, Open in Browser)

    /// Leading top corner, once a link has been followed (also in a
    /// detached preview, where the trailing header is hidden).
    private let navBar = UIStackView()
    private let backButton = UIButton(configuration: .gray())
    private let forwardButton = UIButton(configuration: .gray())
    private let homeButton = UIButton(configuration: .gray())
    private let browserButton = UIButton(configuration: .gray())

    private func setUpNavBar(in container: UIView) {
        navBar.axis = .horizontal
        navBar.spacing = 6
        navBar.translatesAutoresizingMaskIntoConstraints = false
        let buttons: [(UIButton, String, String, String, String?)] = [
            (backButton, "chevron.backward", "preview.nav.back", String(localized: "Back"), nil),
            (forwardButton, "chevron.forward", "preview.nav.forward", String(localized: "Forward"), nil),
            (homeButton, "house", "preview.nav.home", String(localized: "This Document"), String(localized: "Return to this document")),
            (browserButton, "safari", "preview.nav.openInBrowser", String(localized: "Open in Browser"), String(localized: "Asks first, showing the whole address.")),
        ]
        for (b, symbol, id, label, hint) in buttons {
            var c = b.configuration ?? .gray()
            c.cornerStyle = .capsule
            c.image = UIImage(systemName: symbol)
            c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            c.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9)
            b.configuration = c
            b.alpha = 0.85
            b.accessibilityIdentifier = id
            b.accessibilityLabel = label
            b.accessibilityHint = hint
            b.largeContentTitle = label
            b.showsLargeContentViewer = true
            b.pointerStyleProvider = { button, _, _ in UIPointerStyle(effect: .highlight(UITargetedPreview(view: button))) }
            navBar.addArrangedSubview(b)
        }
        backButton.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .primaryActionTriggered)
        forwardButton.addAction(UIAction { [weak self] _ in self?.goForward() }, for: .primaryActionTriggered)
        homeButton.addAction(UIAction { [weak self] _ in self?.goHome() }, for: .primaryActionTriggered)
        browserButton.addAction(UIAction { [weak self] _ in self?.openInBrowser() }, for: .primaryActionTriggered)
        container.addSubview(navBar)
        let g = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            navBar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 10),
            navBar.trailingAnchor.constraint(lessThanOrEqualTo: header.leadingAnchor, constant: -8),
        ])
        updateNav()
    }

    var navBarVisible: Bool { !navBar.isHidden }

    private func updateNav() {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        homeButton.isEnabled = !isHome
        browserButton.isHidden = webURL == nil
        navBar.isHidden = showingCSV || history.count < 2
        onNavigationChange?()
    }

    // MARK: Notice

    /// A short note at the bottom (a link Owlink won't follow), also read
    /// out by VoiceOver.
    private let noticeView = UIButton(configuration: .gray())
    private(set) var lastNotice: String?
    private var noticeGeneration = 0

    private func setUpNotice(in container: UIView) {
        var c = noticeView.configuration ?? .gray()
        c.cornerStyle = .large
        c.titleLineBreakMode = .byWordWrapping
        c.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        noticeView.configuration = c
        noticeView.isUserInteractionEnabled = false
        noticeView.titleLabel?.numberOfLines = 0
        noticeView.accessibilityIdentifier = "preview.notice"
        noticeView.translatesAutoresizingMaskIntoConstraints = false
        noticeView.isHidden = true
        container.addSubview(noticeView)
        let g = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            noticeView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
            noticeView.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            noticeView.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -32),
        ])
    }

    /// A linked note that no editor could open from here.
    func noticeCannotOpen(_ file: URL) {
        notice(String(localized: "Open \(file.lastPathComponent) in Owlink to edit it."))
    }

    private func notice(_ text: String) {
        lastNotice = text
        noticeView.configuration?.title = text
        noticeView.isHidden = false
        noticeView.alpha = 1
        UIAccessibility.post(notification: .announcement, argument: text)
        noticeGeneration += 1
        let gen = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.noticeGeneration else { return }
            UIView.animate(withDuration: 0.25, animations: { self.noticeView.alpha = 0 }) { _ in
                if gen == self.noticeGeneration { self.noticeView.isHidden = true }
            }
        }
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
