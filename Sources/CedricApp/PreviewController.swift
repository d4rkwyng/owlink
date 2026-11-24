import AppKit
import CedricCore
import UniformTypeIdentifiers
import WebKit

/// The side-by-side preview for Markdown and HTML. JavaScript and network
/// access are off unless the user turns them on (View menu), per tab:
/// scripts are disabled with WKWebpagePreferences, and remote loads are
/// blocked twice, by a WebKit content rule list and by a
/// Content-Security-Policy in the page. Local Markdown and HTML documents
/// browse here; a web page never loads in the preview (web links ask, then
/// open in the browser: PreviewNavigation, PreviewLinkAction).
///
/// Markdown is rendered on a background queue from a copy of the text; a
/// newer render drops an older result. The page is loaded once; after
/// that only the blocks that changed are swapped in, by Cedric's own
/// script in the app's content world (`.defaultClient`), which runs with
/// page JavaScript off. So the preview doesn't flash, keeps its scroll
/// position and its decoded images. The same script reports the preview's
/// scrolling (as a source line, from the blocks' `data-line`) so the
/// editor can follow it. With page JavaScript on, the page is reloaded
/// whole each time instead, so the page's own scripts run.
@MainActor
final class PreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let container = NSView()
    private enum Entry {
        case home
        /// A linked document, the folder it may read, and the heading
        /// (`#fragment`) to scroll to once it has loaded.
        case local(URL, URL, String?)
    }
    private var history: [Entry] = [.home]
    private var historyIndex = 0
    private var home: (String, Language, EditorPalette, URL?)?
    private var keyMonitor: KeyMonitor?
    var onNavigationChange: (() -> Void)?
    var onNavigationError: ((String) -> Void)?
    var isHome: Bool { if case .home = history[historyIndex] { return true }; return false }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var navigationTitle: String {
        switch history[historyIndex] {
        case .home: return String(localized: "Preview")
        case .local(let url, _, _): return url.lastPathComponent
        }
    }
    var allowJavaScript = false { didSet { if isHome { homeJavaScript = allowJavaScript } } }
    var allowNetwork = false { didSet { if isHome { homeNetwork = allowNetwork } } }
    /// The live document's JavaScript / Network setting, restored when
    /// returning Home. A navigated-to local page starts with both off.
    private var homeJavaScript = false
    private var homeNetwork = false
    private static var blockRules: WKContentRuleList?
    private static var compiling = false
    private static var waiting: [() -> Void] = []
    private static let queue = DispatchQueue(label: "cedric.md-preview", qos: .userInitiated)

    /// What the loaded page was built for (theme, policy, folder): while
    /// it matches, a render only swaps the body.
    private var shellKey: String?
    /// The page is loading: a newer body waits for it.
    private var loadingShell = false
    private var pendingBody: String?
    private var expectedPageURL: URL?
    private var shellNavigation: WKNavigation?
    /// The heading the page being loaded scrolls to when it has finished
    /// (a local entry's fragment; set by displayEntry, used once).
    private var pendingAnchor: String?
    /// The anchor scrolled to last and whether it was found (for checks).
    private(set) var lastAnchor: (fragment: String, found: Bool)?
    /// Bumped by each render; a result for an older one is dropped.
    private var generation = 0
    private let latest = RenderTicket()
    /// Called after a whole page load (the tab scrolls it in step).
    var onLoaded: (() -> Void)?
    /// The user scrolled the preview: the source line now at its top.
    var onScrolledToLine: ((Double) -> Void)?
    /// A link to a text file was clicked (open it in Cedric).
    /// A clicked link, decided (see PreviewLinkAction).
    var onLink: ((PreviewLinkAction) -> Void)?
    /// Where wikilinks resolve (kept while the document's folder is the same:
    /// its name index is rebuilt at most every few seconds).
    private var vault: WikiVault?
    private var vaultOpenedRoot: URL?
    /// Rendering for a PDF export: wikilinks and embeds by relative path
    /// (Markdown.Options.exportLinks), not `cedric-doc:` links.
    var exportLinks = false

    /// The folder open in the sidebar, when it holds `folder`.
    static func openedRoot(for folder: URL?) -> URL? {
        let opened = FolderSidebar.shared?.rootURL.standardizedFileURL
        return folder.flatMap { f in
            opened.flatMap { (f.standardizedFileURL.path + "/").hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") ? $0 : nil }
        }
    }

    /// The vault an exported copy of a document in `folder` resolves wikilinks in.
    static func exportVault(for folder: URL?) -> WikiVault? {
        folder.map { WikiVault(documentFolder: $0, openedRoot: openedRoot(for: $0)) }
    }

    /// The preview's own vault when it is that export vault and its note-name
    /// index is already built. Copy as Rich Text reuses it instead of walking
    /// the folder again.
    func vaultReadyForExport(of folder: URL?) -> WikiVault? {
        guard let folder, let vault, vault.indexIsFresh else { return nil }
        let export = WikiVault(documentFolder: folder, openedRoot: Self.openedRoot(for: folder))
        guard vault.documentFolder == export.documentFolder, vault.root == export.root else { return nil }
        return vault
    }
    /// The last link clicked (for checks).
    private(set) var lastLinkAction: PreviewLinkAction?
    /// After a Cancel while page JavaScript was on, that page load asks
    /// nothing more (ExternalLinkGate): script `click()`s can't loop the
    /// prompt, whatever URL they use. A new load asks again.
    private var externalGate = ExternalLinkGate()
    /// Web links dropped by that rule (for checks).
    private(set) var droppedExternal = 0

    /// The user answered the prompt for a link asked from page load `load`.
    func externalLinkAnswered(opened: Bool, load: Int, scriptCanClick: Bool) {
        externalGate.answered(opened: opened, load: load, scriptCanClick: scriptCanClick)
    }

    /// Serves the document's folder (and nothing else) to the page.
    private let folderFiles = DocumentFolderFiles()

    /// For the checks: renders applied, whole loads, and main-thread time.
    private(set) var bodySwaps = 0
    private(set) var pageLoads = 0
    private(set) var mainThreadTimes: [Double] = []
    private(set) var lastRenderMs: Double = 0

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(folderFiles, forURLScheme: DocumentFolderFiles.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: Self.appScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        ucc.add(ScrollMessages(self), contentWorld: .defaultClient, name: "cedricScroll")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        webView.setValue(false, forKey: "drawsBackground")
        keyMonitor = KeyMonitor(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      let window = self.container.window, window.isKeyWindow,
                      let focused = window.firstResponder as? NSView, focused.isDescendant(of: self.container) else { return false }
                switch event.charactersIgnoringModifiers {
                case "[": if self.canGoBack { self.goBack() }; return true
                case "]": if self.canGoForward { self.goForward() }; return true
                default: return false
                }
            }
            return handled ? nil : event
        })
    }

    // Swift 6.1 has no `isolated deinit` without an experimental flag, so
    // the deinit is nonisolated: it removes the key monitor right away on
    // the main thread, or hops there when the last release is elsewhere.
    deinit {
        guard let keyMonitor else { return }
        if Thread.isMainThread { MainActor.assumeIsolated { keyMonitor.remove() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { keyMonitor.remove() } } }
    }

    func renderHome(text: String, language: Language, palette: EditorPalette, folder: URL?) {
        home = (text, language, palette, folder)
        if isHome { show(text: text, language: language, palette: palette, baseURL: folder) }
    }

    private func push(_ entry: Entry) {
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(entry)
        historyIndex += 1
        applyTrust(for: entry)
        displayEntry()
    }

    func goBack() { if canGoBack { historyIndex -= 1; applyTrust(for: history[historyIndex]); displayEntry() } }
    func goForward() { if canGoForward { historyIndex += 1; applyTrust(for: history[historyIndex]); displayEntry() } }
    func goHome() { if !isHome { push(.home) } }
    func trustChanged() { if case .local = history[historyIndex] { displayEntry() } }

    /// The live document changed on disk: JavaScript and Network go off now
    /// and stay off when Back/Home returns to it, whatever entry is showing.
    func resetTrust() {
        homeJavaScript = false
        homeNetwork = false
        allowJavaScript = false
        allowNetwork = false
    }

    /// A linked local document does not inherit JavaScript/Network trust
    /// granted for the live document. Home restores the user's setting.
    private func applyTrust(for entry: Entry) {
        switch entry {
        case .home:
            allowJavaScript = homeJavaScript
            allowNetwork = homeNetwork
        case .local:
            allowJavaScript = false
            allowNetwork = false
        }
    }

    private func displayEntry() {
        generation += 1
        latest.set(generation)
        shellKey = nil
        pendingBody = nil
        loadingShell = false
        pendingAnchor = nil
        switch history[historyIndex] {
        case .home:
            if let home { show(text: home.0, language: home.1, palette: home.2, baseURL: home.3) }
        case .local(let url, let root, let fragment):
            // Checked and read by the same symlink-free path, so a link
            // swapped in between can't point the read outside `root`.
            guard let (target, data) = PreviewLinkAction.previewDocument(at: url, root: root, isText: Self.opensInCedric),
                  let text = TextCodec.decode(data)?.text, let home else {
                onNavigationError?(String(localized: "Could not read the preview document."))
                onNavigationChange?()
                return
            }
            // Kind and folder from the same path (the root resolved like it,
            // so the folder's prefix checks against the root still hold):
            // the page's relative loads come from where the file really is.
            let language = LanguageDetector.language(forFileName: target.lastPathComponent) ?? .markdown
            // Scrolled to after the page has loaded (didFinish), also on Back/Forward.
            pendingAnchor = fragment
            show(text: text, language: language, palette: home.2, baseURL: target.deletingLastPathComponent(),
                 rootOverride: PreviewFolder.resolved(root.standardizedFileURL))
        }
        onNavigationChange?()
    }

    /// Compiles the "block all remote loads" rule list once per app run.
    private static func withRules(_ then: @escaping () -> Void) {
        if blockRules != nil { then(); return }
        waiting.append(then)
        guard !compiling else { return }
        compiling = true
        // WebKit's rule regexes have no alternation: one rule per scheme.
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "cedric-block-network-v2", encodedContentRuleList: json) { list, error in
            if let error { FileHandle.standardError.write(Data("preview: rule list: \(error)\n".utf8)) }
            MainActor.assumeIsolated {
                blockRules = list
                compiling = false
                let w = waiting
                waiting = []
                w.forEach { $0() }
            }
        }
    }

    /// Renders the document. `baseURL` is the file's folder, for relative
    /// images (the page may read files in that folder only).
    func show(text: String, language: Language, palette: EditorPalette, baseURL folder: URL?, rootOverride: URL? = nil) {
        folderFiles.folder = folder
        // The folder open in the sidebar, when the document is inside it:
        // the last place a site-root path (`/images/x.webp`) is looked for.
        folderFiles.openedRoot = rootOverride ?? Self.openedRoot(for: folder)
        if let folder {
            if vault?.documentFolder != folder.standardizedFileURL || vaultOpenedRoot != folderFiles.openedRoot {
                vault = WikiVault(documentFolder: folder, openedRoot: folderFiles.openedRoot)
                vaultOpenedRoot = folderFiles.openedRoot
            }
        } else {
            vault = nil
        }
        folderFiles.vaultRoot = vault?.root
        folderFiles.vault = vault
        let vault = self.vault
        let exportLinks = self.exportLinks
        let baseURL = folder.flatMap(DocumentFolderFiles.pageURL(for:))
        generation += 1
        let gen = generation
        latest.set(gen)
        let csp = self.csp
        let key = "\(language.rawValue)|\(palette.name)|\(palette.isDark)|\(csp)|\(baseURL?.absoluteString ?? "-")|\(allowJavaScript)|\(allowNetwork)"
        guard language == .markdown else {
            shellKey = nil
            load(Self.injectCSP(csp, into: text), key: nil, baseURL: baseURL)
            return
        }
        let ticket = latest
        // An immutable copy, whatever `text` is backed by (the storage keeps changing).
        let text = (text as NSString).copy() as! NSString as String
        Self.queue.async {
            // Skip a render a newer one has already replaced.
            guard ticket.value == gen else { return }
            let t0 = DispatchTime.now()
            let body = Markdown.render(text, options: exportLinks ? .export(vault: vault) : .preview(vault: vault))
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation else { return }
                    let applyStart = DispatchTime.now()
                    self.lastRenderMs = ms
                    self.apply(body: body, key: key, palette: palette, csp: csp, baseURL: baseURL)
                    self.noteMainThread(applyStart)
                }
            }
        }
    }

    /// Main-thread time spent on the preview since `start` (the tab notes
    /// its part too: taking the copy of the text).
    func noteMainThread(_ start: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        mainThreadTimes.append(ms)
        if mainThreadTimes.count > 400 { mainThreadTimes.removeFirst(200) }
    }

    func resetMainThreadTimes() { mainThreadTimes = [] }

    /// The preview bar's Refresh: the next render loads the whole page
    /// again (images and linked files re-read), not just a body swap.
    func forceReload() {
        shellKey = nil
        if !isHome { displayEntry() }
    }

    /// Swaps the body into the loaded page, or loads the page.
    private func apply(body: String, key: String, palette: EditorPalette, csp: String, baseURL: URL?) {
        if key == shellKey, !allowJavaScript {
            if loadingShell { pendingBody = body; return }
            bodySwaps += 1
            webView.callAsyncJavaScript("return window.__cedricPatch ? window.__cedricPatch(html) : (document.body.innerHTML = html, -1)",
                                        arguments: ["html": body], in: nil, in: .defaultClient) { _ in }
            return
        }
        load(Self.page(body: body, palette: palette, csp: csp), key: key, baseURL: baseURL)
    }

    private func load(_ html: String, key: String?, baseURL: URL?) {
        pendingBody = nil
        let gen = generation
        let go = { [weak self] in
            guard let self, self.generation == gen else { return }
            let ucc = self.webView.configuration.userContentController
            ucc.removeAllContentRuleLists()
            if !self.allowNetwork, let rules = Self.blockRules { ucc.add(rules) }
            self.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = self.allowJavaScript
            self.folderFiles.scriptOn = self.allowJavaScript
            self.shellKey = key
            self.loadingShell = true
            self.expectedPageURL = baseURL ?? URL(string: "about:blank")
            self.pageLoads += 1
            self.shellNavigation = self.webView.loadHTMLString(html, baseURL: baseURL)
        }
        if allowNetwork { go() } else { Self.withRules(go) }
    }

    var csp: String {
        let net = allowNetwork ? " https: http:" : ""
        let doc = " \(DocumentFolderFiles.scheme): file:"
        let script = allowJavaScript ? "'unsafe-inline'\(doc)\(net)" : "'none'"
        return "default-src 'none'; img-src\(doc) data:\(net); media-src\(doc) data:\(net); style-src 'unsafe-inline'\(doc)\(net); font-src\(doc) data:\(net); script-src \(script); connect-src \(allowNetwork ? "*" : "'none'")"
    }

    nonisolated static func injectCSP(_ csp: String, into html: String) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\n" + html
    }

    nonisolated static func hex(_ c: UInt32) -> String { PreviewHTML.hex(c) }

    /// The whole page (built in CedricCore, shared with the iOS app). `csp` nil: none (an exported file).
    nonisolated static func page(body: String, palette p: EditorPalette, csp: String?, title: String? = nil) -> String {
        PreviewHTML.page(body: body, palette: p, csp: csp, title: title)
    }

    nonisolated static func styles(_ p: EditorPalette) -> String { PreviewHTML.styles(p) }

    /// Cedric's own script, in the app's content world (it runs with page
    /// JavaScript off; the page can't see or call it). `__cedricPatch`
    /// swaps in only the top-level blocks that changed (comparing them
    /// without their data-line numbers), keeps the scroll position, and
    /// returns [kept, removed, inserted]. A scroll by the user posts the
    /// source line at the top (interpolated between blocks); scrolls Cedric
    /// makes itself are quiet for a moment, so the two sides don't chase
    /// each other.
    static let appScript = """
    (function(){
      if (window.__cedricPatch) return;
      const strip = s => s.replace(/ data-line="\\d+"/g, '');
      const key = e => (e.__ck !== undefined ? e.__ck : (e.__ck = strip(e.outerHTML)));
      const lines = (from, to) => {
        if (from.getAttribute('data-line') === to.getAttribute('data-line')) return;
        const a = [from, ...from.querySelectorAll('[data-line]')], b = [to, ...to.querySelectorAll('[data-line]')];
        for (let i = 0; i < a.length && i < b.length; i++) a[i].setAttribute('data-line', b[i].getAttribute('data-line'));
      };
      const quiet = () => { window.__cedricQuietUntil = Date.now() + 250; };
      const pin = () => { window.__cedricSetY = window.scrollY; };
      window.__cedricPatch = function(html) {
        const b = document.body; if (!b) return -1;
        quiet();
        const y = window.scrollY;
        // The block at the top of the view stays where it is (if it is kept).
        const kids = b.children;
        let lo = 0, hi = kids.length - 1, at = -1;
        while (lo <= hi) { const m = (lo + hi) >> 1; if (kids[m].getBoundingClientRect().top <= 0) { at = m; lo = m + 1; } else hi = m - 1; }
        const anchor0 = at >= 0 ? kids[at] : null, offset0 = anchor0 ? anchor0.getBoundingClientRect().top : 0;
        const keep = () => {
          if (anchor0 && anchor0.isConnected) { const d = anchor0.getBoundingClientRect().top - offset0; if (Math.abs(d) >= 1) window.scrollBy(0, d); }
          else if (window.scrollY !== y) window.scrollTo(0, y);
          pin();
        };
        const t = document.createElement('template'); t.innerHTML = html;
        const loose = n => n.nodeType === 3 && n.textContent.trim() !== '';
        window.__cedricEls = null;
        if ([...t.content.childNodes].some(loose) || [...b.childNodes].some(loose)) {
          b.innerHTML = html; keep(); return [0, -1, -1];
        }
        const old = [...b.children], nw = [...t.content.children];
        const ol = old.length, nl = nw.length;
        let p = 0;
        while (p < ol && p < nl && key(old[p]) === key(nw[p])) { lines(old[p], nw[p]); p++; }
        let s = 0;
        while (s < ol - p && s < nl - p && key(old[ol - 1 - s]) === key(nw[nl - 1 - s])) { lines(old[ol - 1 - s], nw[nl - 1 - s]); s++; }
        const anchor = s > 0 ? old[ol - s] : null;
        for (let i = p; i < ol - s; i++) old[i].remove();
        for (let i = p; i < nl - s; i++) b.insertBefore(nw[i], anchor);
        keep();
        return [p, ol - s - p, nl - s - p];
      };
      const els = () => window.__cedricEls || (window.__cedricEls = [...document.querySelectorAll('[data-line]')]);
      const top = e => e.getBoundingClientRect().top + window.scrollY;
      // The source line at page offset y, from the blocks around it.
      window.__cedricLineAt = function(y) {
        const a = els(); if (!a.length) return 0;
        let lo = 0, hi = a.length - 1, best = -1;
        while (lo <= hi) { const m = (lo + hi) >> 1; if (top(a[m]) <= y + 1) { best = m; lo = m + 1; } else hi = m - 1; }
        if (best < 0) return 0;
        const l0 = +a[best].dataset.line, t0 = top(a[best]);
        let k = best + 1; while (k < a.length && +a[k].dataset.line === l0) k++;
        if (k >= a.length) return l0;
        const t1 = top(a[k]), l1 = +a[k].dataset.line;
        return t1 > t0 ? l0 + (l1 - l0) * Math.min(1, Math.max(0, (y - t0) / (t1 - t0))) : l0;
      };
      // Scrolls so source line `line` is at the top.
      window.__cedricScrollTo = function(line) {
        const a = els();
        quiet();
        if (!a.length) { window.scrollTo(0, 0); return; }
        let lo = 0, hi = a.length - 1, best = -1;
        while (lo <= hi) { const m = (lo + hi) >> 1; if (+a[m].dataset.line <= line) { best = m; lo = m + 1; } else hi = m - 1; }
        if (best < 0) { window.scrollTo(0, 0); return; }
        while (best > 0 && +a[best - 1].dataset.line === +a[best].dataset.line) best--;
        const l0 = +a[best].dataset.line, t0 = top(a[best]);
        let k = best + 1; while (k < a.length && +a[k].dataset.line === l0) k++;
        let y = t0;
        if (k < a.length) { const l1 = +a[k].dataset.line; y = t0 + (top(a[k]) - t0) * Math.min(1, (line - l0) / Math.max(1, l1 - l0)); }
        window.__cedricSetY = Math.max(0, Math.min(y - 8, document.documentElement.scrollHeight - window.innerHeight));
        window.scrollTo(0, Math.max(0, y - 8));
      };
      // Scrolls to the first of `ids` that is an element's id (or an
      // anchor's name), its top at the top of the view (as WebKit's own
      // fragment scroll), and pins that place. `follow`: the editor is told
      // now, rather than by a scroll event an occluded page may deliver late.
      window.__cedricScrollToAnchor = function(ids, follow) {
        let e = null;
        for (const id of ids) { e = document.getElementById(id) || document.getElementsByName(id)[0]; if (e) break; }
        if (!e) return false;
        const max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        const y = Math.max(0, Math.min(Math.round(e.getBoundingClientRect().top + window.scrollY), max));
        quiet();
        window.__cedricSetY = y;
        window.scrollTo(0, y);
        if (follow) window.webkit.messageHandlers.cedricScroll.postMessage(window.__cedricLineAt(y + 8));
        return true;
      };
      window.addEventListener('scroll', function() {
        // Not the scrolls Cedric makes (sync, or keeping the place after an edit).
        if (Date.now() < (window.__cedricQuietUntil || 0) || Math.abs(window.scrollY - (window.__cedricSetY ?? -1e9)) < 2) return;
        window.__cedricSetY = undefined;
        window.webkit.messageHandlers.cedricScroll.postMessage(window.__cedricLineAt(window.scrollY + 8));
      }, { passive: true });
    })();
    """

    /// Scrolls so the block nearest source line `line` is at the top
    /// (Markdown, by its data-line attributes, between two blocks in
    /// proportion), or to `fraction` of the page (HTML). Works with page
    /// JavaScript off: this runs in the app's own content world.
    func sync(line: Int, fraction: Double, markdown: Bool) {
        guard isHome else { return }
        let js: String
        if markdown {
            js = "window.__cedricScrollTo && window.__cedricScrollTo(\(line))"
        } else {
            js = "window.__cedricQuietUntil = Date.now() + 250; window.scrollTo(0,(document.documentElement.scrollHeight-window.innerHeight)*\(fraction))"
        }
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === shellNavigation else { return }
        shellNavigation = nil
        loadingShell = false
        expectedPageURL = nil
        let anchor = pendingAnchor
        pendingAnchor = nil
        if let body = pendingBody {
            pendingBody = nil
            bodySwaps += 1
            webView.callAsyncJavaScript("return window.__cedricPatch ? window.__cedricPatch(html) : (document.body.innerHTML = html, -1)",
                                        arguments: ["html": body], in: nil, in: .defaultClient) { _ in }
        }
        // (Evaluated after the patch above: one content world, in order.)
        if let anchor { scroll(toAnchor: anchor, follow: false) }
        if isHome { onLoaded?() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, navigation === shellNavigation {
            shellNavigation = nil
            loadingShell = false
            expectedPageURL = nil
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    fileprivate func scrolledByUser(_ line: Double) { if isHome { onScrolledToLine?(line) } }

    // The first load is ours; a link within the page scrolls it; any other
    // click goes to `onLink` as a PreviewLinkAction (nothing is ever
    // launched: audit H2; a web page never loads here: S1); everything
    // else is cancelled (PreviewNavigation).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        switch PreviewNavigation.decide(url: url, linkClick: action.navigationType == .linkActivated,
                                        mainFrame: action.targetFrame?.isMainFrame, page: webView.url,
                                        expectedPage: expectedPageURL, loadingShell: loadingShell) {
        case .allowPage:
            decisionHandler(.allow)
        case .scrollInPage:
            // In-page anchors stay in the page, including ⌘-click (which would
            // otherwise treat the preview's folder URL as a file to reveal).
            // WebKit's navigation is cancelled, so no spelling of the URL
            // (`about:blank%23x` on macOS 15) can load another document;
            // Cedric's own scroll finds the exact id or a heading by its text
            // (`#Part` → `id="part"`), and pins the place so the editor
            // follows once instead of bouncing it back.
            decisionHandler(.cancel)
            if let url, let fragment = PreviewAnchor.fragment(of: url) { scroll(toAnchor: fragment, follow: isHome) }
        case .route:
            decisionHandler(.cancel)
            guard let url else { return }
            let root = folderFiles.linkFolder(url)
            let act = PreviewLinkAction.previewAction(for: folderFiles.linkTarget(url), folder: root, command: action.modifierFlags.contains(.command), isText: Self.opensInCedric)
            lastLinkAction = act
            switch act {
            // The file's path came through without its `#fragment`: carry it along.
            case .openInPreview(let file): if let root { push(.local(file, root, PreviewAnchor.fragment(of: url))) }
            case .confirmExternal where !externalGate.asks(load: pageLoads, scriptCanClick: allowJavaScript):
                droppedExternal += 1
            default: onLink?(act)
            }
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    /// A navigation response the policy above let through must still be
    /// the preview's own page: never a web page (a redirect is a new
    /// navigation action, so this is a second line, failing closed).
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(PreviewNavigation.allowsResponse(url: response.response.url, mainFrame: response.isForMainFrame) ? .allow : .cancel)
    }

    /// No new windows: `target=_blank` and `window.open` clicks come through
    /// the policy above as clicks with no target frame.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    /// Scrolls the local page to the heading `fragment` names (an exact
    /// `id` or `name`, else the heading slug of that text), in Cedric's own
    /// content world: no page script runs. `follow`: the editor follows (the
    /// live document), as for a scroll by the user.
    private func scroll(toAnchor fragment: String, follow: Bool) {
        let candidates = PreviewAnchor.candidates(for: fragment)
        guard !candidates.isEmpty else { return }
        let gen = generation
        webView.callAsyncJavaScript("return window.__cedricScrollToAnchor ? window.__cedricScrollToAnchor(ids, follow) : false",
                                    arguments: ["ids": candidates, "follow": follow], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                let found = (try? result.get()).flatMap { ($0 as? NSNumber)?.boolValue } ?? false
                self.lastAnchor = (fragment, found)
            }
        }
    }

    /// Text files Cedric edits: Markdown and anything it colours, plain text.
    static func opensInCedric(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        let ext = url.pathExtension.lowercased()
        if ["txt", "text", "log"].contains(ext) { return true }
        return LanguageDetector.language(forFileName: url.lastPathComponent) != nil
    }
}

/// The newest render's number, readable from the render queue.
final class RenderTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ v: Int) { lock.lock(); current = v; lock.unlock() }
}

/// The preview's scroll messages, without the user content controller
/// keeping the preview alive.
private final class ScrollMessages: NSObject, WKScriptMessageHandler {
    weak var owner: PreviewController?
    init(_ owner: PreviewController) { self.owner = owner }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let line = (message.body as? NSNumber)?.doubleValue else { return }
        MainActor.assumeIsolated { owner?.scrolledByUser(line) }
    }
}

/// The page's view of the document's folder: `cedric-doc://doc/<folder>/…`
/// is the page's base URL, so relative images, styles and links resolve
/// into it, and this handler serves files from that folder (and its
/// subfolders) only. A plain `file:` base gives the page no access at all
/// (WebKit's sandbox), and loadFileURL would need the page itself on disk.
@MainActor
final class DocumentFolderFiles: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = PreviewFolder.scheme
    var folder: URL?
    /// The sidebar's folder, when it holds the document.
    var openedRoot: URL?
    /// The Obsidian vault wikilinks resolve in.
    var vaultRoot: URL?
    var vault: WikiVault?
    /// The page may run JavaScript: serve only images, fonts and CSS.
    var scriptOn = false
    private var stopped: Set<ObjectIdentifier> = []

    nonisolated static func pageURL(for folder: URL) -> URL? { PreviewFolder.pageURL(for: folder) }
    nonisolated static func fileURL(for url: URL) -> URL? { PreviewFolder.fileURL(for: url) }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        // With JavaScript on, only images, fonts and CSS (no dotfiles):
        // page script must not be able to read the folder's other files.
        guard let url = task.request.url, let folder,
              let file = PreviewFolder.file(for: url, in: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, scriptOn: scriptOn, vault: vault) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let box = TaskBox(task)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let task = box.task
                    guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
                    guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
                    let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                    task.didReceive(data)
                    task.didFinish()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    /// A clicked link's file: as given, or a site-root path's page
    /// (`/projects/intelbrew` → `content/projects/intelbrew.md`).
    func linkTarget(_ url: URL) -> URL {
        guard url.scheme == Self.scheme, let file = PreviewFolder.fileURL(for: url), !FileManager.default.fileExists(atPath: file.path),
              let folder, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let hit = PreviewRoot.resolve(path, from: folder, openedRoot: openedRoot, pages: true),
              let page = PreviewFolder.pageURL(forFile: hit.file) else { return url }
        return page
    }

    /// The folder a clicked link may open text files in: the document's,
    /// or the sidebar's or the vault's when the file is inside that.
    func linkFolder(_ url: URL) -> URL? {
        guard let file = PreviewFolder.fileURL(for: linkTarget(url)) else { return folder }
        for root in [vaultRoot, openedRoot, folder].compactMap({ $0 }) {
            let r = root.standardizedFileURL.path
            if file.path.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return root }
        }
        return folder
    }
}

/// A scheme task handed across the file read (WebKit calls back on the main thread).
private final class TaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    init(_ task: any WKURLSchemeTask) { self.task = task }
}

/// The preview's ⌘[ / ⌘] key monitor, handed from the nonisolated deinit
/// to the main thread to be removed.
private final class KeyMonitor: @unchecked Sendable {
    private let token: Any?
    init(_ token: Any?) { self.token = token }
    @MainActor func remove() { if let token { NSEvent.removeMonitor(token) } }
}
