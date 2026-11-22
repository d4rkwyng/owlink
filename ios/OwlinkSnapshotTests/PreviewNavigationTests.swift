import XCTest
import UIKit
import WebKit
import CedricCore

/// In-preview link navigation: the isolated browser's configuration and
/// policy, the local preview's policy, app-kept history, and Open in
/// Browser asking first (security audit H2: nothing is launched).
@MainActor
final class PreviewNavigationTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var temps: [URL] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        for t in temps { try? FileManager.default.removeItem(at: t) }
        temps = []
    }

    private func host(_ vc: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
    }

    /// A folder with the open document, linked pages, a note and a file outside.
    private func tree() throws -> (root: URL, doc: URL) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("preview-nav-\(UUID().uuidString)", isDirectory: true)
        temps.append(temp)
        let root = temp.appendingPathComponent("vault", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in [("doc.md", "# Home"), ("other.md", "# Other"), ("page.html", "<h1>Page</h1><script>x()</script>"),
                             ("notes.txt", "plain"), ("installer.pkg", "x")] {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "# Outside".write(to: temp.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        return (root, root.appendingPathComponent("doc.md"))
    }

    private func link(_ relative: String, in folder: URL) throws -> URL {
        let page = try XCTUnwrap(PreviewFolder.pageURL(for: folder.standardizedFileURL))
        return try XCTUnwrap(URL(string: relative, relativeTo: page)?.absoluteURL)
    }

    // MARK: Isolation

    func testBrowserConfigurationIsIsolated() {
        let config = PreviewController.browserConfiguration()
        XCTAssertFalse(config.websiteDataStore.isPersistent)
        XCTAssertTrue(config.userContentController.userScripts.isEmpty)
        XCTAssertNil(config.urlSchemeHandler(forURLScheme: PreviewFolder.scheme))
        XCTAssertNil(config.urlSchemeHandler(forURLScheme: "cedric-doc"))
        XCTAssertTrue(PreviewController.browserConfiguration().processPool !== config.processPool, "a new pool each time")

        let preview = PreviewController()
        preview.loadViewIfNeeded()
        let browser = preview.browser.configuration, local = preview.web.configuration
        XCTAssertTrue(browser.processPool !== local.processPool, "not the local preview's process pool")
        XCTAssertTrue(browser.userContentController !== local.userContentController)
        XCTAssertFalse(browser.websiteDataStore.isPersistent)
        XCTAssertTrue(browser.userContentController.userScripts.isEmpty)
        XCTAssertNil(browser.urlSchemeHandler(forURLScheme: "cedric-doc"))
        XCTAssertFalse(preview.browser.allowsBackForwardNavigationGestures)
        XCTAssertFalse(preview.browser.allowsLinkPreview)
        // The local preview keeps its own policy.
        XCTAssertFalse(local.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(local.websiteDataStore.isPersistent)
        XCTAssertNotNil(local.urlSchemeHandler(forURLScheme: PreviewFolder.scheme))
        XCTAssertTrue(local.userContentController.userScripts.isEmpty)
        XCTAssertTrue(preview.browser.isHidden)
    }

    func testIsolatedViewHasNoAppBridge() async throws {
        let probe = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: PreviewController.browserConfiguration())
        let waiter = LoadWaiter()
        probe.navigationDelegate = waiter
        probe.loadHTMLString("<html><body>isolated</body></html>", baseURL: nil)
        try await waiter.wait()
        let handler = try await evaluate(probe, "typeof window.webkit?.messageHandlers?.cedricScroll")
        XCTAssertEqual(handler as? String, "undefined", "no Cedric bridge in the isolated web view")
        let body = try await evaluate(probe, "document.body.textContent")
        XCTAssertEqual(body as? String, "isolated")
    }

    private func evaluate(_ web: WKWebView, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(js) { value, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: value) }
            }
        }
    }

    func testLocalPageKeepsStrictCSP() {
        XCTAssertTrue(PreviewController.csp.contains("script-src 'none'"))
        XCTAssertTrue(PreviewController.csp.contains("default-src 'none'"))
        XCTAssertTrue(PreviewController.csp.contains("connect-src 'none'"))
        let page = PreviewController.htmlPage("<p>x</p>")
        XCTAssertTrue(page.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"\(PreviewController.csp)\">"))
    }

    // MARK: Policies

    func testIsolatedPolicyCancelsLocalAndOtherSchemes() throws {
        let types: [WKNavigationType] = [.linkActivated, .other, .formSubmitted, .reload, .backForward]
        for s in ["file:///etc/passwd", "cedric-doc://doc/tmp/a.md", "javascript:alert(1)", "https:///nohost",
                  "ftp://h/x", "smb://h/share", "data:text/html,x", "about:blank", "mailto:a@example.com", "x-owlink://open"] {
            let url = try XCTUnwrap(URL(string: s))
            for type in types {
                for frame in [true, false, nil] as [Bool?] {
                    XCTAssertEqual(PreviewController.browserDecision(url: url, type: type, mainFrame: frame, command: false, method: "GET"),
                                   .cancel, "\(s) \(type.rawValue) \(String(describing: frame))")
                }
            }
        }
        XCTAssertEqual(PreviewController.browserDecision(url: nil, type: .other, mainFrame: true, command: false, method: nil), .cancel)
        let web = try XCTUnwrap(URL(string: "https://example.com/a?b=1"))
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .linkActivated, mainFrame: true, command: false, method: "GET"), .push(web))
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .linkActivated, mainFrame: true, command: true, method: "GET"), .confirm(web))
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .linkActivated, mainFrame: nil, command: false, method: "GET"), .cancel, "no new windows")
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .other, mainFrame: nil, command: false, method: "GET"), .cancel)
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .other, mainFrame: true, command: false, method: "GET"), .allow, "our load")
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .other, mainFrame: false, command: false, method: "GET"), .allow, "a sub-frame")
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .formSubmitted, mainFrame: true, command: false, method: "GET"), .push(web))
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .formSubmitted, mainFrame: true, command: false, method: "POST"), .cancel)
        XCTAssertEqual(PreviewController.browserDecision(url: web, type: .backForward, mainFrame: true, command: false, method: "GET"), .cancel)

        // The local preview loads only its own pages.
        let page = try XCTUnwrap(PreviewFolder.pageURL(for: URL(fileURLWithPath: "/tmp/x")))
        XCTAssertTrue(PreviewController.localLoadAllowed(page, type: .other))
        XCTAssertTrue(PreviewController.localLoadAllowed(URL(string: "about:blank"), type: .other))
        XCTAssertFalse(PreviewController.localLoadAllowed(page, type: .formSubmitted))
        XCTAssertFalse(PreviewController.localLoadAllowed(web, type: .other))
        XCTAssertFalse(PreviewController.localLoadAllowed(URL(fileURLWithPath: "/etc/hosts"), type: .other))
        XCTAssertFalse(PreviewController.localLoadAllowed(URL(string: "javascript:alert(1)"), type: .other))
    }

    // MARK: History

    func testLinksBrowseWithHistory() throws {
        let (root, doc) = try tree()
        let preview = PreviewController()
        preview.loadsWeb = false
        var opened: [URL] = []
        preview.onOpenFile = { opened.append($0) }
        var external: [URL] = []
        preview.openExternal = { external.append($0) }
        preview.documentURL = doc
        preview.show(markdown: "[o](other.md)", palette: EditorPalettes.light)
        XCTAssertTrue(preview.isHome)
        XCTAssertFalse(preview.canGoBack)
        XCTAssertFalse(preview.canGoForward)
        XCTAssertFalse(preview.navBarVisible, "nothing to navigate yet")

        // A sibling Markdown file opens in the preview.
        preview.handleLink(try link("other.md", in: root), command: false)
        guard case .openInPreview(let other) = preview.lastLinkAction else { return XCTFail("\(String(describing: preview.lastLinkAction))") }
        XCTAssertEqual(other.lastPathComponent, "other.md")
        XCTAssertFalse(preview.isHome)
        XCTAssertTrue(preview.canGoBack)
        XCTAssertFalse(preview.canGoForward)
        XCTAssertTrue(preview.navBarVisible)
        XCTAssertFalse(preview.web.isHidden)
        XCTAssertTrue(preview.browser.isHidden)
        guard case .local(let file, _) = preview.history[preview.historyIndex] else { return XCTFail("a local entry") }
        XCTAssertEqual(file.lastPathComponent, "other.md")

        // Editor re-renders while away keep the reader where they are.
        preview.show(markdown: "[o](other.md) edited", palette: EditorPalettes.light)
        preview.show(markdown: "[o](other.md) edited again", palette: EditorPalettes.light)
        XCTAssertFalse(preview.isHome)
        XCTAssertEqual(preview.history.count, 2)
        XCTAssertEqual(preview.historyIndex, 1)

        // Back, Forward, This Document.
        preview.goBack()
        XCTAssertTrue(preview.isHome)
        XCTAssertTrue(preview.canGoForward)
        preview.goForward()
        XCTAssertFalse(preview.isHome)
        XCTAssertFalse(preview.canGoForward)
        preview.goHome()
        XCTAssertTrue(preview.isHome)
        XCTAssertEqual(preview.history.count, 3)
        XCTAssertTrue(preview.canGoBack)
        // At home, a render shows as before.
        preview.show(markdown: "home again", palette: EditorPalettes.light)
        XCTAssertTrue(preview.isHome)

        // A new link drops the forward history.
        preview.goBack()
        XCTAssertTrue(preview.canGoForward)
        preview.handleLink(try link("page.html", in: root), command: false)
        XCTAssertEqual(preview.lastLinkAction.map { if case .openInPreview(let u) = $0 { return u.lastPathComponent } else { return "" } }, "page.html")
        XCTAssertFalse(preview.canGoForward)
        XCTAssertEqual(preview.history.count, 3)

        // Text files open in the editor; ⌘ opens Markdown there too.
        preview.goHome()
        let count = preview.history.count
        preview.handleLink(try link("notes.txt", in: root), command: false)
        preview.handleLink(try link("other.md", in: root), command: true)
        XCTAssertEqual(opened.map(\.lastPathComponent), ["notes.txt", "other.md"])
        // Nothing outside, nothing launched, no other scheme followed.
        preview.handleLink(try link("installer.pkg", in: root), command: false)
        guard case .revealInFinder = preview.lastLinkAction else { return XCTFail("a package is never opened") }
        preview.handleLink(try link("../outside.md", in: root), command: false)
        XCTAssertEqual(preview.lastLinkAction, .ignore("missing"), "outside the roots: refused")
        preview.handleLink(URL(fileURLWithPath: root.appendingPathComponent("other.md").path), command: false)
        XCTAssertEqual(preview.lastLinkAction, .ignore("file"))
        for s in ["smb://attacker/share", "javascript:alert(1)", "ftp://h/x", "x-apple.systempreferences:x"] {
            preview.handleLink(try XCTUnwrap(URL(string: s)), command: false)
            guard case .ignore = preview.lastLinkAction else { return XCTFail("\(s) must be ignored") }
        }
        XCTAssertNotNil(preview.lastNotice)
        XCTAssertEqual(preview.history.count, count, "none of these navigated")
        XCTAssertTrue(external.isEmpty, "nothing left the app")
        XCTAssertNil(preview.linkPrompt)

        // A web link opens in the isolated view, not the system browser.
        let web = try XCTUnwrap(URL(string: "https://example.com/a?b=1"))
        preview.handleLink(web, command: false)
        XCTAssertEqual(preview.lastLinkAction, .openWebInPreview(web))
        XCTAssertEqual(preview.webURL, web)
        XCTAssertFalse(preview.browser.isHidden)
        XCTAssertTrue(preview.web.isHidden)
        XCTAssertTrue(preview.activeScrollView === preview.browser.scrollView)
        XCTAssertTrue(external.isEmpty)
        XCTAssertNil(preview.linkPrompt, "browsing asks nothing and opens nothing")
        preview.goBack()
        XCTAssertNil(preview.webURL)
        XCTAssertTrue(preview.browser.isHidden)
        XCTAssertTrue(preview.isHome)
    }

    // MARK: Open in Browser

    func testOpenInBrowserAsksFirstWithTheWholeURL() throws {
        let preview = PreviewController()
        host(preview)
        preview.loadsWeb = false
        var external: [URL] = []
        preview.openExternal = { external.append($0) }
        let web = try XCTUnwrap(URL(string: "https://example.com/a?b=1"))
        preview.openInBrowser()
        XCTAssertNil(preview.linkPrompt, "nothing to open on the document")

        preview.push(.web(web))
        XCTAssertEqual(preview.webURL, web)
        XCTAssertTrue(external.isEmpty)
        preview.openInBrowser()
        let prompt = try XCTUnwrap(preview.linkPrompt)
        XCTAssertTrue(preview.presentedViewController === prompt)
        XCTAssertEqual(prompt.title, "Open this link?")
        XCTAssertEqual(prompt.message, "https://example.com/a?b=1")
        XCTAssertEqual(prompt.actions.map(\.title), ["Open", "Cancel"])
        preview.finishPrompt(open: false) // what Cancel calls
        prompt.dismiss(animated: false)
        XCTAssertTrue(external.isEmpty, "Cancel opens nothing")
        XCTAssertNil(preview.linkPrompt)

        preview.openInBrowser()
        XCTAssertNotNil(preview.linkPrompt)
        preview.finishPrompt(open: true) // what Open calls
        preview.presentedViewController?.dismiss(animated: false)
        XCTAssertEqual(external, [web])

        // Hidden characters in a URL are shown, not acted on; mailto asks too.
        let mail = try XCTUnwrap(URL(string: "mailto:a@example.com"))
        preview.handleLink(mail, command: false)
        XCTAssertEqual(preview.lastLinkAction, .confirmExternal(mail))
        XCTAssertEqual(preview.linkPrompt?.message, "mailto:a@example.com")
        preview.finishPrompt(open: false)
        preview.presentedViewController?.dismiss(animated: false)
        XCTAssertEqual(external, [web])
    }

    // MARK: Detached

    func testDetachedPreviewHasTheSameNavigation() throws {
        let (root, doc) = try tree()
        let target = PreviewWindows.Target(documentPath: doc.path, editorWindow: "w", title: "doc.md")
        let viewer = DetachedPreviewViewController(target: target)
        let nav = UINavigationController(rootViewController: viewer)
        host(nav)
        viewer.show(DetachedPreviews.Snapshot(url: doc, markdown: "[o](other.md)", palette: EditorPalettes.light))
        let preview = viewer.preview
        preview.loadsWeb = false
        XCTAssertTrue(preview.isHome)
        preview.handleLink(try link("other.md", in: root), command: false)
        XCTAssertFalse(preview.isHome)
        XCTAssertTrue(preview.navBarVisible, "the nav bar shows in a detached preview too")
        // Its next snapshot (the editor typing) leaves the reader there.
        viewer.show(DetachedPreviews.Snapshot(url: doc, markdown: "[o](other.md) typed", palette: EditorPalettes.light))
        XCTAssertFalse(preview.isHome)
        preview.goHome()
        XCTAssertTrue(preview.isHome)
        XCTAssertTrue(preview.canGoBack)
    }

    /// A text note opens in an editor window (not in place, not in the
    /// preview); Markdown and HTML still browse in the preview window.
    func testDetachedPreviewOpensTextLinksInAnEditor() throws {
        let (root, doc) = try tree()
        let target = PreviewWindows.Target(documentPath: doc.path, editorWindow: "w", title: "doc.md")
        let viewer = DetachedPreviewViewController(target: target)
        var opened: [(URL, PreviewWindows.Target)] = []
        var accepts = true
        viewer.openFile = { url, t in opened.append((url, t)); return accepts }
        host(UINavigationController(rootViewController: viewer))
        viewer.show(DetachedPreviews.Snapshot(url: doc, markdown: "[n](notes.txt)", palette: EditorPalettes.light))
        let preview = viewer.preview
        preview.loadsWeb = false
        XCTAssertNotNil(preview.onOpenFile)

        preview.handleLink(try link("notes.txt", in: root), command: false)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0.standardizedFileURL.path, root.appendingPathComponent("notes.txt").standardizedFileURL.path)
        XCTAssertEqual(opened.first?.1, target)
        XCTAssertTrue(preview.isHome, "a text note doesn't browse in the preview")
        XCTAssertFalse(preview.canGoBack)
        XCTAssertNil(preview.lastNotice)

        // No editor could take it: the short note, still no navigation.
        accepts = false
        preview.handleLink(try link("notes.txt", in: root), command: false)
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(preview.isHome)
        XCTAssertEqual(preview.lastNotice, String(localized: "Open notes.txt in Owlink to edit it."))

        for page in ["other.md", "page.html"] {
            preview.goHome()
            preview.handleLink(try link(page, in: root), command: false)
            XCTAssertFalse(preview.isHome, "\(page) browses in the preview")
        }
        XCTAssertEqual(opened.count, 2, "Markdown and HTML don't go to an editor")
    }
}

/// Waits for a web view's load to finish.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var done = false
    private var error: Error?

    func wait(timeout: TimeInterval = 10) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        if let error { throw error }
        if !done { throw URLError(.timedOut) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error; done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error; done = true
    }
}
