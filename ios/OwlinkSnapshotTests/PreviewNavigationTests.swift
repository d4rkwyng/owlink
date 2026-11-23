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
        guard case .local(let file, _, let fragment) = preview.history[preview.historyIndex] else { return XCTFail("a local entry") }
        XCTAssertEqual(file.lastPathComponent, "other.md")
        XCTAssertNil(fragment, "no fragment in the link, none on the entry")

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

    // MARK: Heading fragments

    /// Long pages with headings far down: `## Part` (`id="part"`) and
    /// `## The Part` (`id="the-part"`) in Markdown, `id="sec"` in HTML.
    private func anchorTree() throws -> (root: URL, doc: URL) {
        let (root, doc) = try tree()
        let filler = (1...60).map { "Paragraph \($0) of filler text." }.joined(separator: "\n\n")
        try "# Long\n\n\(filler)\n\n## Part\n\nHere.\n\n\(filler)\n\n## The Part\n\nThere.\n\n\(filler)\n"
            .write(to: root.appendingPathComponent("long.md"), atomically: true, encoding: .utf8)
        let paras = (1...60).map { "<p>Paragraph \($0).</p>" }.joined()
        try "<h1>Page</h1>\(paras)<h2 id=\"sec\">Section</h2><p>Here.</p>\(paras)"
            .write(to: root.appendingPathComponent("long.html"), atomically: true, encoding: .utf8)
        return (root, doc)
    }

    private func fragment(_ preview: PreviewController) -> String?? {
        guard case .local(_, _, let f) = preview.history[preview.historyIndex] else { return nil }
        return .some(f)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(done(), "timed out: \(what)")
    }

    /// A page load with a fragment: its anchor scroll has finished.
    private func waitForAnchor(_ preview: PreviewController, after count: Int) async throws {
        try await waitFor("anchor scroll") { preview.anchorScrolls > count }
        // Nothing (the place's delayed re-apply) moves it afterwards.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    /// The heading's top in the view (CSS px), read in the app's content world.
    private func headingTop(_ preview: PreviewController, id: String) async throws -> Double? {
        let value = try await preview.web.callAsyncJavaScript(
            "const e = document.getElementById(id); return e ? e.getBoundingClientRect().top : null",
            arguments: ["id": id], in: nil, contentWorld: .defaultClient)
        return (value as? NSNumber)?.doubleValue
    }

    func testLinksKeepTheirHeadingFragment() throws {
        let (root, doc) = try anchorTree()
        let preview = PreviewController()
        preview.loadsWeb = false
        preview.documentURL = doc
        preview.show(markdown: "x", palette: EditorPalettes.light)
        preview.handleLink(try link("other.md#part", in: root), command: false)
        XCTAssertEqual(fragment(preview), "part")
        preview.handleLink(try link("long.md#The%20Part", in: root), command: false)
        XCTAssertEqual(fragment(preview), "The Part", "decoded")
        preview.handleLink(try link("page.html#sec", in: root), command: false)
        XCTAssertEqual(fragment(preview), "sec")
        let page = try XCTUnwrap(PreviewFolder.pageURL(forFile: root.appendingPathComponent("other.md").standardizedFileURL))
        let doc2 = try XCTUnwrap(URL(string: page.absoluteString + "#Setup"))
        preview.handleLink(doc2, command: false)
        XCTAssertEqual(fragment(preview), "Setup", "a cedric-doc: link keeps it too")
        guard case .local(let file, _, _) = preview.history[preview.historyIndex] else { return XCTFail("a local entry") }
        XCTAssertEqual(file.lastPathComponent, "other.md", "the file is the path alone")
        preview.handleLink(try link("other.md", in: root), command: false)
        XCTAssertEqual(fragment(preview), .some(nil))
        preview.handleLink(try link("other.md#", in: root), command: false)
        XCTAssertEqual(fragment(preview), .some(nil), "an empty fragment: none")
    }

    func testLinkedPageScrollsToTheHeadingAndBackForwardReturn() async throws {
        let (root, doc) = try anchorTree()
        let preview = PreviewController()
        host(preview)
        preview.loadsWeb = false
        preview.documentURL = doc
        preview.show(markdown: "[l](long.md#the-part)", palette: EditorPalettes.light)

        var n = preview.anchorScrolls
        preview.handleLink(try link("long.md#the-part", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        let anchor = try XCTUnwrap(preview.lastAnchor)
        XCTAssertEqual(anchor.fragment, "the-part")
        XCTAssertTrue(anchor.found)
        let at = preview.web.scrollView.contentOffset.y
        XCTAssertGreaterThan(at, 500, "well down the page, not left at the top")
        XCTAssertEqual(at, anchor.offset, accuracy: 1, "the late top-scroll did not wipe the heading")
        let top = try await headingTop(preview, id: "the-part")
        XCTAssertEqual(try XCTUnwrap(top), 0, accuracy: 4, "the heading is at the top of the view")

        // Back to the document, Forward to the heading again.
        preview.goBack()
        XCTAssertTrue(preview.isHome)
        try await Task.sleep(nanoseconds: 300_000_000)
        n = preview.anchorScrolls
        preview.goForward()
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.found, true)
        XCTAssertEqual(preview.web.scrollView.contentOffset.y, at, accuracy: 2, "Forward: at the heading again")

        // A page further on, then Back: the heading again.
        n = preview.anchorScrolls
        preview.handleLink(try link("long.html#sec", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.fragment, "sec")
        XCTAssertEqual(preview.lastAnchor?.found, true, "page.html#sec: the exact id")
        XCTAssertGreaterThan(preview.web.scrollView.contentOffset.y, 500)
        n = preview.anchorScrolls
        preview.goBack()
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.fragment, "the-part")
        XCTAssertEqual(preview.web.scrollView.contentOffset.y, at, accuracy: 2, "Back: at the heading again")

        // A link without a fragment opens at the top, no anchor scroll.
        n = preview.anchorScrolls
        preview.handleLink(try link("long.md", in: root), command: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(preview.anchorScrolls, n)
        XCTAssertLessThan(preview.web.scrollView.contentOffset.y, 50)
    }

    func testFragmentNamingTheHeadingTextFindsItsSlug() async throws {
        let (root, doc) = try anchorTree()
        let preview = PreviewController()
        host(preview)
        preview.loadsWeb = false
        preview.documentURL = doc
        preview.show(markdown: "x", palette: EditorPalettes.light)

        var n = preview.anchorScrolls
        preview.handleLink(try link("long.md#Part", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.fragment, "Part")
        XCTAssertEqual(preview.lastAnchor?.found, true, "#Part → id=\"part\"")
        let part = preview.web.scrollView.contentOffset.y
        XCTAssertGreaterThan(part, 300)
        let partTop = try await headingTop(preview, id: "part")
        XCTAssertEqual(try XCTUnwrap(partTop), 0, accuracy: 4)

        n = preview.anchorScrolls
        preview.handleLink(try link("long.md#The%20Part", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.found, true, "#The Part → id=\"the-part\"")
        XCTAssertGreaterThan(preview.web.scrollView.contentOffset.y, part + 300)

        // Not a heading: nothing matches, the page stays at the top.
        n = preview.anchorScrolls
        preview.handleLink(try link("long.md#nowhere", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.found, false)
        XCTAssertLessThan(preview.web.scrollView.contentOffset.y, 50)
    }

    func testSamePageLinkStaysAndMatchesTheSlug() async throws {
        let (root, doc) = try anchorTree()
        let preview = PreviewController()
        host(preview)
        preview.loadsWeb = false
        preview.documentURL = doc
        preview.show(markdown: "x", palette: EditorPalettes.light)
        var n = preview.anchorScrolls
        preview.handleLink(try link("long.md#nowhere", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        let count = preview.history.count, index = preview.historyIndex
        let page = try XCTUnwrap(preview.web.url)

        for (href, id) in [("#Part", "part"), ("#the-part", "the-part"), ("#The%20Part", "the-part")] {
            let s = preview.web.scrollView
            s.setContentOffset(CGPoint(x: 0, y: -s.adjustedContentInset.top), animated: false)
            n = preview.anchorScrolls
            preview.handleLink(try XCTUnwrap(URL(string: href, relativeTo: page)?.absoluteURL), command: false)
            try await waitFor("same-page \(href)") { preview.anchorScrolls > n }
            XCTAssertEqual(preview.history.count, count, "\(href): no history step")
            XCTAssertEqual(preview.historyIndex, index)
            XCTAssertEqual(preview.lastAnchor?.found, true, href)
            XCTAssertGreaterThan(s.contentOffset.y, 300, href)
            try await Task.sleep(nanoseconds: 200_000_000)
            let top = try await headingTop(preview, id: id)
            XCTAssertEqual(try XCTUnwrap(top), 0, accuracy: 4, href)
        }
        XCTAssertNil(preview.lastNotice, "nothing refused")
    }

    func testWikilinkToAHeadingCarriesItsSlug() async throws {
        let (root, doc) = try anchorTree()
        let vault = WikiVault(documentFolder: root)
        let html = Markdown.render("[[long#The Part]] [[long#^abc123]]", options: .preview(vault: vault))
        let expected = try XCTUnwrap(WikiVault.href(root.appendingPathComponent("long.md").standardizedFileURL, heading: "The Part"))
        XCTAssertTrue(expected.hasSuffix("long.md#the-part"), expected)
        let hrefs = html.components(separatedBy: "href=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        XCTAssertEqual(hrefs.count, 2, html)
        XCTAssertTrue(hrefs[0].hasSuffix("long.md#the-part"), hrefs[0])
        XCTAssertTrue(hrefs[1].hasSuffix("long.md"), "a block reference: the note, no fragment")

        // Following it in the preview opens the note at the heading.
        let preview = PreviewController()
        host(preview)
        preview.loadsWeb = false
        preview.documentURL = doc
        preview.show(markdown: "[[long#The Part]]", palette: EditorPalettes.light)
        let n = preview.anchorScrolls
        preview.handleLink(try XCTUnwrap(URL(string: hrefs[0])), command: false)
        XCTAssertEqual(fragment(preview), "the-part")
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.found, true)
        XCTAssertGreaterThan(preview.web.scrollView.contentOffset.y, 500)
    }

    /// Scrolling to a heading adds no bridge: page JavaScript off, the
    /// strict CSP, no scripts or handlers in either web view.
    func testHeadingScrollAddsNoBridge() async throws {
        let (root, doc) = try anchorTree()
        let preview = PreviewController()
        host(preview)
        preview.loadsWeb = false
        preview.documentURL = doc
        preview.show(markdown: "x", palette: EditorPalettes.light)
        let n = preview.anchorScrolls
        preview.handleLink(try link("long.md#Part", in: root), command: false)
        try await waitForAnchor(preview, after: n)
        XCTAssertEqual(preview.lastAnchor?.found, true)
        let local = preview.web.configuration
        XCTAssertFalse(local.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(local.userContentController.userScripts.isEmpty)
        XCTAssertTrue(PreviewController.csp.contains("script-src 'none'"))
        XCTAssertFalse(PreviewController.anchorScript.contains("messageHandlers"))
        // The page's own world sees nothing of the app's script. Page
        // JavaScript is off, so the probe may not run at all; that is
        // also the property held. If it runs, the handler is absent.
        do {
            let seen = try await preview.web.callAsyncJavaScript("return typeof window.webkit?.messageHandlers?.cedricScroll",
                                                                 arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(seen as? String, "undefined", "no Cedric bridge in the page world")
        } catch {
            // The page world cannot run script: nothing there to see a bridge.
        }
        let browser = preview.browser.configuration
        XCTAssertTrue(browser.userContentController.userScripts.isEmpty)
        XCTAssertNil(browser.urlSchemeHandler(forURLScheme: PreviewFolder.scheme))
        XCTAssertFalse(browser.websiteDataStore.isPersistent)
        XCTAssertTrue(browser.processPool !== local.processPool)
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
