import UIKit
import CedricCore

/// The detached preview windows (iPad: "Open Preview in New Window"): which
/// are open, the latest text of each followed document, and the editor's
/// side of the conversation. Read-only by construction: a preview window
/// only ever receives the editor's text; it never opens the document, so
/// it can't save it, and never registers with `OpenDocuments`.
@MainActor enum DetachedPreviews {
    struct Snapshot {
        var url: URL
        var markdown: String
        var palette: EditorPalette
    }

    static var registry = PreviewWindowRegistry()
    private static var latest: [String: Snapshot] = [:]
    private static var viewers: [String: Weak] = [:]

    private final class Weak {
        weak var value: DetachedPreviewViewController?
        init(_ v: DetachedPreviewViewController) { value = v }
    }

    /// An editor of this document should ask: send it its text (a preview
    /// window came back after a relaunch, or opened before any text came).
    static let needsText = Notification.Name("OwlinkDetachedPreviewNeedsText")

    /// Offered here (iPad), hidden on an iPhone.
    static var available: Bool {
        PreviewWindows.detachAvailable(supportsMultipleScenes: UIApplication.shared.supportsMultipleScenes,
                                       isPhone: UIDevice.current.userInterfaceIdiom == .phone)
    }

    static func hasPreviews(forPath path: String) -> Bool { registry.hasPreviews(forPath: path) }

    // MARK: Editor side

    /// The activity that asks for a preview window of `target` (a menu
    /// item, or dragged out of the preview).
    static func activity(for target: PreviewWindows.Target, snapshot: Snapshot) -> NSUserActivity {
        latest[target.documentKey] = snapshot
        let a = NSUserActivity(activityType: PreviewWindows.activityType)
        a.userInfo = PreviewWindows.userInfo(for: target)
        a.title = String(localized: "\(target.title) Preview")
        a.targetContentIdentifier = target.documentKey
        return a
    }

    /// Opens a preview window for `target`, or brings its existing one forward.
    static func open(_ target: PreviewWindows.Target, snapshot: Snapshot, from scene: UIScene?, onError: @escaping (Error) -> Void) {
        let activity = activity(for: target, snapshot: snapshot)
        if let id = registry.existing(forPath: target.documentPath), let s = session(id) {
            UIApplication.shared.requestSceneSessionActivation(s, userActivity: nil, options: nil, errorHandler: onError)
            return
        }
        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = scene
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: options, errorHandler: onError)
    }

    /// The editor's text changed (debounced as its own preview) or was loaded.
    static func publish(path: String, snapshot: Snapshot) {
        let ids = registry.previewWindows(forPath: path)
        guard !ids.isEmpty else { return }
        latest[OpenDocumentRegistry.key(forPath: path)] = snapshot
        for id in ids { viewers[id]?.value?.show(snapshot) }
    }

    /// The editor scrolled: its previews follow, roughly.
    static func scroll(path: String, fraction: Double) {
        for id in registry.previewWindows(forPath: path) { viewers[id]?.value?.follow(scroll: fraction) }
    }

    /// The editor closed the document: its preview windows close too.
    static func documentClosed(path: String) {
        apply(registry.actions(for: .documentClosed(path: path), documents: OpenDocuments.registry))
        if !registry.hasPreviews(forPath: path) { latest[OpenDocumentRegistry.key(forPath: path)] = nil }
    }

    /// An editor window went away: previews of what it had open go blank.
    static func editorWindowGone(_ window: String) {
        apply(registry.actions(for: .editorWindowGone(window: window), documents: OpenDocuments.registry))
    }

    private static func apply(_ actions: [String: PreviewWindowRegistry.Action]) {
        for (id, action) in actions {
            viewers[id]?.value?.blank()
            if action == .close, let s = session(id) {
                UIApplication.shared.requestSceneSessionDestruction(s, options: nil, errorHandler: nil)
            }
        }
    }

    private static func session(_ id: String) -> UISceneSession? {
        UIApplication.shared.openSessions.first { $0.persistentIdentifier == id }
    }

    /// A note a preview window's link names (a `.txt`, say) opens in an
    /// editor window, never in place of the followed document (closing it
    /// would close this preview too). Already open somewhere: that window
    /// comes forward. Else an idle browser opens it, the followed
    /// document's window first. False when every window has an editor up.
    static func openInEditor(_ url: URL, for target: PreviewWindows.Target) -> Bool {
        if let s = OpenDocuments.otherWindow(having: url, than: "") {
            UIApplication.shared.requestSceneSessionActivation(s, userActivity: nil, options: nil, errorHandler: nil)
            return true
        }
        let browsers = UIApplication.shared.connectedScenes.compactMap { scene -> (String, DocumentBrowserViewController)? in
            guard let ws = scene as? UIWindowScene,
                  let b = ws.windows.lazy.compactMap({ $0.rootViewController as? DocumentBrowserViewController }).first
            else { return nil }
            return (ws.session.persistentIdentifier, b)
        }
        let idle = browsers.filter { $0.1.presentedViewController == nil }
        guard let (id, browser) = idle.first(where: { $0.0 == target.editorWindow }) ?? idle.first else { return false }
        browser.presentDocument(at: url)
        if let s = session(id) {
            UIApplication.shared.requestSceneSessionActivation(s, userActivity: nil, options: nil, errorHandler: nil)
        }
        return true
    }

    // MARK: Preview window side

    static func attach(_ viewer: DetachedPreviewViewController, window id: String, target: PreviewWindows.Target) {
        registry.register(previewWindow: id, target: target)
        viewers[id] = Weak(viewer)
        if PreviewWindows.state(for: target, documents: OpenDocuments.registry) == .blank {
            viewer.blank()
            return
        }
        if let s = latest[target.documentKey] { viewer.show(s) }
        NotificationCenter.default.post(name: needsText, object: nil, userInfo: ["path": target.documentPath])
    }

    static func detach(window id: String) {
        registry.unregister(previewWindow: id)
        viewers[id] = nil
    }
}

/// A preview window's scene.
final class PreviewSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let route = PreviewWindows.route(activities: options.userActivities.map { ($0.activityType, $0.userInfo) },
                                         sessionUserInfo: session.userInfo)
        guard case .preview(let target) = route else { return }
        // Kept with the session, so the window comes back after a relaunch.
        session.userInfo = PreviewWindows.userInfo(for: target)
        ws.title = String(localized: "\(target.title) Preview")
        ws.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 400)
        let viewer = DetachedPreviewViewController(target: target)
        let nav = UINavigationController(rootViewController: viewer)
        let w = UIWindow(windowScene: ws)
        w.rootViewController = nav
        w.makeKeyAndVisible()
        window = w
        DetachedPreviews.attach(viewer, window: session.persistentIdentifier, target: target)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        DetachedPreviews.detach(window: scene.session.persistentIdentifier)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let t = PreviewWindows.target(userInfo: scene.session.userInfo) else { return nil }
        let a = NSUserActivity(activityType: PreviewWindows.activityType)
        a.userInfo = PreviewWindows.userInfo(for: t)
        return a
    }
}

/// The preview alone in its own window, following the editor's text:
/// no document of its own, nothing to save.
final class DetachedPreviewViewController: UIViewController {
    let target: PreviewWindows.Target
    /// The same preview as the editor's (links browse here too, with
    /// Back, Forward and This Document).
    let preview = PreviewController()
    /// Opens a linked note in an editor window; false when none can take
    /// it. Replaceable for tests.
    var openFile: @MainActor (URL, PreviewWindows.Target) -> Bool = { DetachedPreviews.openInEditor($0, for: $1) }
    private let blankLabel = UILabel()
    private var scrollFollow = PreviewScrollFollow()
    /// The editor's palette for this document, once a snapshot has arrived.
    private var palette: EditorPalette?

    init(target: PreviewWindows.Target) {
        self.target = target
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = target.title
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.closeWindow() })
        close.accessibilityIdentifier = "detachedPreview.close"
        navigationItem.rightBarButtonItem = close
        addChild(preview)
        preview.view.frame = view.bounds
        preview.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(preview.view)
        preview.didMove(toParent: self)
        preview.web.accessibilityIdentifier = "detachedPreview.web"
        // A linked note opens in an editor window (this one stays open);
        // Markdown and HTML links still browse in this preview.
        preview.onOpenFile = { [weak self] url in
            guard let self else { return }
            if !self.openFile(url, self.target) { self.preview.noticeCannotOpen(url) }
        }
        blankLabel.text = String(localized: "\(target.title) isn’t open in Owlink. Open it to see its preview here.")
        blankLabel.numberOfLines = 0
        blankLabel.textAlignment = .center
        blankLabel.textColor = .secondaryLabel
        blankLabel.font = .preferredFont(forTextStyle: .body)
        blankLabel.adjustsFontForContentSizeCategory = true
        blankLabel.translatesAutoresizingMaskIntoConstraints = false
        blankLabel.isHidden = true
        blankLabel.accessibilityIdentifier = "detachedPreview.blank"
        view.addSubview(blankLabel)
        let g = view.readableContentGuide
        NSLayoutConstraint.activate([
            blankLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            blankLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            blankLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.changed, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.applyBarStyle()
        }
        applyBarStyle()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyBarStyle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyBarStyle()
    }

    /// The same title treatment as the editor: every theme, System follows
    /// this window's phone appearance.
    private func applyBarStyle() {
        let p = palette ?? AppSettings.theme.palette(systemIsDark: traitCollection.userInterfaceStyle == .dark)
        EditorBarStyle.apply(navigationController: navigationController,
                             item: navigationItem,
                             window: view.window,
                             foreground: UIColor(hex: p.foreground),
                             interfaceStyle: EditorBarStyle.interfaceStyle(theme: AppSettings.theme, isDark: p.isDark))
    }

    @objc private func settingsChanged() { applyBarStyle() }

    func show(_ s: DetachedPreviews.Snapshot) {
        loadViewIfNeeded()
        palette = s.palette
        applyBarStyle()
        blankLabel.isHidden = true
        preview.view.isHidden = false
        preview.documentURL = s.url
        preview.show(markdown: s.markdown, palette: s.palette)
    }

    /// The editor has let the document go: no text, nothing stale.
    func blank() {
        loadViewIfNeeded()
        preview.view.isHidden = true
        blankLabel.isHidden = false
        scrollFollow = PreviewScrollFollow()
    }

    func follow(scroll fraction: Double) {
        guard !preview.view.isHidden, let f = scrollFollow.next(fraction) else { return }
        preview.scrollFraction = f
    }

    private func closeWindow() {
        guard let s = view.window?.windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(s, options: nil, errorHandler: nil)
    }

    // ⌘+, ⌘− and ⌘0 (the View menu's) size the preview's text here.
    @objc func biggerFont() { preview.bigger() }
    @objc func smallerFont() { preview.smaller() }
    @objc func actualSizeFont() { preview.actualSize() }
    @objc func closeDocument() { closeWindow() }
}
