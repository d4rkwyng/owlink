import Foundation
import Testing
@testable import CedricCore

/// Security audit H2: preview links never launch anything.
@Suite struct PreviewLinkTests {
    func isText(_ u: URL) -> Bool { ["md", "txt", "command", "sh"].contains(u.pathExtension) }

    @Test func linksAreConfined() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("doc"), out = root.appendingPathComponent("out")
        let fm = FileManager.default
        try fm.createDirectory(at: doc.appendingPathComponent("Setup.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        for f in ["doc/a.md", "doc/build.command", "doc/x.pkg", "out/secret.md", "out/run.command"] {
            try "x".write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(at: doc.appendingPathComponent("link.md"), withDestinationURL: out.appendingPathComponent("secret.md"))
        func act(_ s: String) -> PreviewLinkAction { PreviewLinkAction.action(for: URL(string: s)!, folder: doc, isText: isText) }
        let page = PreviewFolder.pageURL(for: doc)!.absoluteString
        #expect(act("https://example.com/x?y=1") == .confirmExternal(URL(string: "https://example.com/x?y=1")!))
        #expect(act("mailto:a@example.com") == .confirmExternal(URL(string: "mailto:a@example.com")!))
        #expect(act(page + "a.md") == .openInCedric(doc.appendingPathComponent("a.md").standardizedFileURL))
        // A script opens as text in Cedric (never runs); an app, a package: shown only.
        #expect(act(page + "build.command") == .openInCedric(doc.appendingPathComponent("build.command").standardizedFileURL))
        #expect(act(page + "Setup.app") == .revealInFinder(doc.appendingPathComponent("Setup.app").standardizedFileURL))
        #expect(act(page + "x.pkg") == .revealInFinder(doc.appendingPathComponent("x.pkg").standardizedFileURL))
        // Outside the folder (.., an absolute path, a symlink, file:): shown, never read.
        #expect(act(page + "../out/secret.md") == .revealInFinder(out.appendingPathComponent("secret.md").standardizedFileURL))
        #expect(act("cedric-doc://doc" + out.path + "/run.command") == .revealInFinder(out.appendingPathComponent("run.command").standardizedFileURL))
        if case .revealInFinder = act(page + "link.md") {} else { Issue.record("a symlink out of the folder is only revealed") }
        #expect(act(URL(fileURLWithPath: out.path + "/secret.md").absoluteString) == .revealInFinder(out.appendingPathComponent("secret.md").standardizedFileURL))
        if case .openInCedric = act(URL(fileURLWithPath: doc.path + "/a.md").absoluteString) {} else { Issue.record("file: inside opens") }
        // Everything else: ignored.
        for s in ["smb://attacker/share", "x-apple.systempreferences:com.apple.Security", "ftp://h/x", "javascript:alert(1)", "vnc://h", "https:///nohost"] {
            if case .ignore = act(s) {} else { Issue.record("\(s) must be ignored") }
        }
        if case .ignore = act(page + "nothere.md") {} else { Issue.record("a missing file is ignored") }
        // Untitled (no folder): a local file is only revealed.
        #expect(PreviewLinkAction.action(for: URL(fileURLWithPath: doc.path + "/a.md"), folder: nil, isText: isText) == .revealInFinder(doc.appendingPathComponent("a.md").standardizedFileURL))
    }

    @Test func previewRoutingKeepsSecurityRules() throws {
        let t = try makeTree(["vault/doc.md", "vault/page.html", "vault/page.xhtml", "vault/note.mdown", "vault/run.sh", "vault/installer.pkg", "outside.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("vault")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: t.appendingPathComponent("outside.md"))
        func route(_ url: URL, command: Bool = false) -> PreviewLinkAction {
            PreviewLinkAction.previewAction(for: url, folder: root, command: command, isText: { isText($0) || LanguageDetector.language(forFileName: $0.lastPathComponent) != nil })
        }
        let web = try #require(URL(string: "https://example.com/a?b=1"))
        // S1: a plain click on a web link asks too; it never opens in the preview.
        #expect(route(web) == .confirmExternal(web))
        #expect(route(web, command: true) == .confirmExternal(web))
        let plain = try #require(URL(string: "http://example.com/"))
        #expect(route(plain) == .confirmExternal(plain))
        let mail = try #require(URL(string: "mailto:a@example.com"))
        #expect(route(mail) == .confirmExternal(mail))
        let md = root.appendingPathComponent("doc.md"), html = root.appendingPathComponent("page.html")
        #expect(route(md) == .openInPreview(md))
        #expect(route(html) == .openInPreview(html))
        #expect(route(root.appendingPathComponent("page.xhtml")) == .openInPreview(root.appendingPathComponent("page.xhtml")))
        #expect(route(root.appendingPathComponent("note.mdown")) == .openInPreview(root.appendingPathComponent("note.mdown")))
        #expect(route(md, command: true) == .openInCedric(md))
        #expect(route(root.appendingPathComponent("run.sh")) == .openInCedric(root.appendingPathComponent("run.sh")))
        #expect(route(root.appendingPathComponent("installer.pkg")) == .revealInFinder(root.appendingPathComponent("installer.pkg")))
        #expect(route(root.appendingPathComponent("escape.md")) == .revealInFinder(root.appendingPathComponent("escape.md")))
        #expect(route(t.appendingPathComponent("outside.md")) == .revealInFinder(t.appendingPathComponent("outside.md")))
        #expect(route(try #require(URL(string: "smb://host/share"))) == .ignore("smb"))
    }
}

/// 0.5.1 S3: a linked preview document is read from the very path that
/// was checked, so a symbolic link swapped after the check can't make the
/// preview read a file outside the folder.
@Suite struct PreviewDocumentReadTests {
    func isText(_ u: URL) -> Bool { LanguageDetector.language(forFileName: u.lastPathComponent) != nil }

    @Test func theCheckedPathIsThePathRead() throws {
        let t = try makeTree(["doc/real.md", "outside/secret.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let fm = FileManager.default
        let doc = t.appendingPathComponent("doc")
        let real = doc.appendingPathComponent("real.md"), secret = t.appendingPathComponent("outside/secret.md")
        try "inside".write(to: real, atomically: true, encoding: .utf8)
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let link = doc.appendingPathComponent("link.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // The race: right after the check, before the read, the link is
        // swapped to point outside the folder.
        var read: [URL] = []
        let got = PreviewLinkAction.previewDocument(at: link, root: doc, isText: isText) { path in
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(at: link, withDestinationURL: secret)
            read.append(path)
            return try? Data(contentsOf: path)
        }
        #expect(got.map { String(decoding: $0.data, as: UTF8.self) } == "inside", "the swapped link's target is never read")
        #expect(got?.file == PreviewFolder.resolved(real), "the page's file is the checked, resolved path")
        #expect(read == [PreviewFolder.resolved(real)], "exactly the checked path is read")

        // The link now points outside the folder: refused, and nothing is read.
        var readOutside = false
        #expect(PreviewLinkAction.previewDocument(at: link, root: doc, isText: isText) { _ in readOutside = true; return nil } == nil)
        #expect(!readOutside, "a link out of the folder is not read")
        // The real file, and its default read.
        #expect(PreviewLinkAction.previewDocument(at: real, root: doc, isText: isText).map { String(decoding: $0.data, as: UTF8.self) } == "inside")
    }
}

/// 0.5.2 S1: the preview's web view only ever shows Cedric's own page.
/// No web page (or any other scheme) loads in it, whatever starts the
/// navigation; a click is routed (web links ask, then open in the browser).
@Suite struct PreviewNavigationTests {
    let page = URL(string: "cedric-doc://doc/tmp/notes/")!

    func decide(_ s: String?, click: Bool = false, mainFrame: Bool? = true, page: URL? = nil,
                expected: URL? = nil, loading: Bool = false) -> PreviewNavigation {
        decide(url: s.flatMap(URL.init(string:)), click: click, mainFrame: mainFrame, page: page, expected: expected, loading: loading)
    }

    func decide(url: URL?, click: Bool = false, mainFrame: Bool? = true, page: URL? = nil,
                expected: URL? = nil, loading: Bool = false) -> PreviewNavigation {
        PreviewNavigation.decide(url: url, linkClick: click, mainFrame: mainFrame,
                                 page: page ?? self.page, expectedPage: expected, loadingShell: loading)
    }

    /// `s` the way WebKit hands a navigation's URL to the policy delegate:
    /// an NSURL made from the bytes of the URL string WebKit built
    /// (CFURLCreateAbsoluteURLWithBytes), never re-parsed by `URL(string:)`.
    /// So a click on `#x` in an about:blank page is `about:blank#x` on every
    /// macOS (seen on macOS 27: absoluteString `about:blank#x`), and an href
    /// written `about:blank%23x` stays `about:blank%23x`.
    static func webKitURL(_ s: String) -> URL {
        let bytes = Array(s.utf8)
        return CFURLCreateAbsoluteURLWithBytes(nil, bytes, bytes.count, CFStringBuiltInEncodings.UTF8.rawValue, nil, true)! as URL
    }

    @Test func onlyCedricsOwnPageLoads() {
        #expect(decide(page.absoluteString, expected: page, loading: true) == .allowPage)
        #expect(decide("about:blank", page: URL(string: "about:blank"), expected: URL(string: "about:blank"), loading: true) == .allowPage)
        // Not while Cedric isn't loading, not another URL, not in a frame or a new window.
        #expect(decide(page.absoluteString, expected: page, loading: false) == .cancel)
        #expect(decide("cedric-doc://doc/tmp/other/", expected: page, loading: true) == .cancel)
        #expect(decide(page.absoluteString, mainFrame: false, expected: page, loading: true) == .cancel)
        #expect(decide(page.absoluteString, mainFrame: nil, expected: page, loading: true) == .cancel)
        #expect(decide(nil, expected: page, loading: true) == .cancel)
        // Script moving the page to a #place of itself (not a click): cancelled.
        #expect(decide(page.absoluteString + "#x", expected: page, loading: true) == .cancel)
    }

    // Grok 4.7 NIT: `about:` is a page scheme only as exactly the blank
    // page (plus a fragment), never another name that starts with it.
    @Test func aboutIsAPageSchemeOnlyAsExactlyBlank() {
        for s in ["about:blank", "ABOUT:BLANK", "about:blank#x", "about:blank%23x"] {
            #expect(PreviewNavigation.isPageScheme(URL(string: s)!), "\(s)")
        }
        for s in ["about:blankevil", "about:blank-x", "about:blanks#x", "about:blankevil%23x", "about:blank?x", "about:blank/x", "about:srcdoc", "about:"] {
            guard let u = URL(string: s) else { continue }
            #expect(!PreviewNavigation.isPageScheme(u), "\(s)")
            #expect(!PreviewNavigation.allowsResponse(url: u, mainFrame: true), "\(s)")
            #expect(decide(url: u, page: u, expected: u, loading: true) == .cancel, "\(s)")
            #expect(decide(url: u, click: true, page: URL(string: "about:blank")) == .route, "\(s)")
        }
    }

    @Test func onlyThePagesOwnResponseIsShown() {
        #expect(PreviewNavigation.allowsResponse(url: page, mainFrame: true))
        #expect(PreviewNavigation.allowsResponse(url: URL(string: "about:blank"), mainFrame: true))
        for s in ["https://example.com/", "http://example.com/", "about:srcdoc", "about:foo", "file:///etc/hosts", "data:text/html,x", "x-unknown:y"] {
            #expect(!PreviewNavigation.allowsResponse(url: URL(string: s), mainFrame: true), "\(s)")
        }
        #expect(!PreviewNavigation.allowsResponse(url: page, mainFrame: false), "no frame")
        #expect(!PreviewNavigation.allowsResponse(url: nil, mainFrame: true))
    }

    @Test func noWebPageLoadsWithoutAClick() {
        // Redirects, meta refresh, `location =`, form submits, frames, new windows:
        // whatever the scheme, in any frame, loading or not, even if expected.
        let remote = ["https://example.com/", "http://example.com/x", "HTTPS://EXAMPLE.COM/", "ws://example.com/",
                      "ftp://example.com/", "file:///etc/hosts", "data:text/html,hi", "blob:https://example.com/1",
                      "javascript:alert(1)", "about:srcdoc", "x-unknown:thing", "smb://h/s"]
        for s in remote {
            for frame in [true, false, nil] as [Bool?] {
                for loading in [true, false] {
                    #expect(decide(s, mainFrame: frame, expected: URL(string: s), loading: loading) == .cancel,
                            "\(s) frame \(String(describing: frame)) loading \(loading)")
                }
            }
        }
    }

    @Test func clicksAreRoutedNeverLoaded() {
        // A click on a web link, in the page or a new window (target=_blank),
        // is routed: PreviewLinkAction asks before the browser opens it.
        for s in ["https://example.com/a?b=1", "http://example.com/", "https://example.com/#x", "mailto:a@example.com",
                  "x-unknown:thing", "file:///etc/hosts", "cedric-doc://doc/tmp/notes/other.md"] {
            for frame in [true, false, nil] as [Bool?] {
                #expect(decide(s, click: true, mainFrame: frame) == .route, "\(s)")
            }
        }
        #expect(PreviewLinkAction.previewAction(for: URL(string: "https://example.com/a")!, folder: nil, command: false, isText: { _ in false })
                == .confirmExternal(URL(string: "https://example.com/a")!))
    }

    @Test func inPageAnchorsStayInThePage() {
        #expect(decide(page.absoluteString + "#part", click: true) == .scrollInPage)
        #expect(decide(url: Self.webKitURL(page.absoluteString + "#part"), click: true) == .scrollInPage)
        #expect(decide(url: Self.webKitURL("about:blank#part"), click: true, page: URL(string: "about:blank")) == .scrollInPage)
        // The main frame only: a #place in a frame or a new window (nil) is routed.
        for frame in [false, nil] as [Bool?] {
            #expect(decide(page.absoluteString + "#part", click: true, mainFrame: frame) == .route, "\(String(describing: frame))")
            #expect(decide(url: Self.webKitURL("about:blank#part"), click: true, mainFrame: frame, page: URL(string: "about:blank")) == .route)
        }
        // A fragment on another page, or on a web page "the same" as an http(s) page, is routed.
        #expect(decide("cedric-doc://doc/tmp/notes/other.md#part", click: true) == .route)
        let web = URL(string: "https://example.com/a")!
        #expect(decide("https://example.com/a#x", click: true, page: web) == .route)
        // Without a page, only about:blank's own fragments.
        #expect(PreviewNavigation.samePage(Self.webKitURL("about:blank#x"), nil))
        #expect(!PreviewNavigation.samePage(URL(string: "about:srcdoc#x")!, nil))
        #expect(!PreviewNavigation.samePage(URL(string: "https://example.com/#x")!, nil))
    }

    // macOS 15 Foundation reads `URL(string: "about:blank#x")` as
    // `about:blank%23x` (no fragment); macOS 26 as `about:blank` + `#x`; and
    // what WebKit hands `decide` (webKitURL) follows the same Foundation.
    // So on the blank page a main-frame click reads the same in either
    // spelling, and the preview cancels WebKit's navigation and scrolls
    // itself: no spelling loads another document (security read NIT 1).
    @Test func aboutBlankAnchorsAreTheSameOnEveryFoundation() {
        let blank = URL(string: "about:blank")!
        for s in ["about:blank#part", "about:blank%23part", "ABOUT:BLANK%23part"] {
            for u in [URL(string: s)!, Self.webKitURL(s)] {
                #expect(PreviewNavigation.split(u).page.lowercased() == "about:blank" && PreviewNavigation.split(u).fragment == "part", "\(s) → \(u.absoluteString)")
                #expect(decide(url: u, click: true) == .route, "\(s) on a cedric-doc page is another page")
                #expect(PreviewNavigation.samePage(u, nil) && PreviewNavigation.samePage(u, blank), "\(s)")
                #expect(PreviewAnchor.fragment(of: u) == "part", "\(s)")
            }
        }
        // A click on #part in the blank page: stays in the page, whichever
        // spelling this macOS's Foundation gives it.
        for s in ["about:blank#part", "ABOUT:BLANK#part", "about:blank%23part", "ABOUT:BLANK%23part", "about:blank%23"] {
            for u in [URL(string: s)!, Self.webKitURL(s)] {
                #expect(decide(url: u, click: true, page: blank) == .scrollInPage, "\(s) → \(u.absoluteString)")
                #expect(decide(url: u, click: true, page: URL(string: "about:blank%23a")) == .scrollInPage, "\(s)")
                // The main frame only, and only on the blank page.
                for frame in [false, nil] as [Bool?] {
                    #expect(decide(url: u, click: true, mainFrame: frame, page: blank) == .route, "\(s) frame \(String(describing: frame))")
                }
                #expect(decide(url: u, click: true, page: page) == .route, "\(s) on a cedric-doc page")
                #expect(decide(url: u, click: false, page: blank, expected: blank, loading: true) == .cancel, "\(s) not a click")
            }
        }
        // The %23 spelling with no page shown yet: routed (the %23 is read
        // as the # only with the blank page on screen).
        #expect(PreviewNavigation.decide(url: Self.webKitURL("about:blank%23part"), linkClick: true, mainFrame: true, page: nil,
                                         expectedPage: nil, loadingShell: false) == .route)
        // `%2523` is a literal `%23`, not a `#`.
        #expect(Self.webKitURL("about:blank%2523part").absoluteString == "about:blank%2523part")
        #expect(decide(url: Self.webKitURL("about:blank%2523part"), click: true, page: blank) == .route)
        // Already on an anchor of the blank page (webView.url), either spelling.
        for page in ["about:blank#a", "about:blank%23a"] {
            for p in [URL(string: page), Self.webKitURL(page)] {
                for b in ["about:blank#b", "about:blank%23b"] {
                    #expect(decide(url: Self.webKitURL(b), click: true, page: p) == .scrollInPage, "\(b) on \(page)")
                }
            }
        }
        #expect(PreviewAnchor.fragment(of: URL(string: "about:blank%23The%20Part")!) == "The Part")
        #expect(PreviewAnchor.fragment(of: URL(string: "about:blank%23")!) == nil)
        #expect(PreviewNavigation.split(blank).fragment == nil)
        // Still closed: no fragment, another about: page, or a %23 outside about:.
        #expect(decide("about:blank", click: true, page: blank) == .route)
        #expect(decide("about:srcdoc%23x", click: true, page: blank) == .route)
        #expect(decide("about:blankx%23y", click: true, page: blank) == .route)
        #expect(!PreviewNavigation.samePage(URL(string: "about:srcdoc%23x")!, nil))
        #expect(!PreviewNavigation.samePage(URL(string: "about:blank%23x")!, URL(string: "cedric-doc://doc/tmp/notes/")))
        #expect(decide("https://example.com/a%23x", click: true, page: URL(string: "https://example.com/a")) == .route)
        #expect(decide(page.absoluteString + "%23part", click: true) == .route, "a cedric-doc %23 is a path, not an anchor")
        #expect(PreviewNavigation.split(URL(string: "cedric-doc://doc/tmp/a%23b.md")!).fragment == nil)
        #expect(PreviewAnchor.fragment(of: URL(string: "cedric-doc://doc/tmp/a%23b.md")!) == nil)
    }
}

/// Links to a heading (`other.md#part`): the fragment the preview carries
/// with a local document, and the ids it looks for.
@Suite struct PreviewAnchorTests {
    @Test func fragmentIsKeptAndDecoded() {
        let u = URL(string: "cedric-doc://doc/tmp/notes/other.md#part")!
        #expect(PreviewAnchor.fragment(of: u) == "part")
        #expect(PreviewFolder.fileURL(for: u)?.path == "/tmp/notes/other.md", "the file is the path alone")
        #expect(PreviewAnchor.fragment(of: URL(string: "cedric-doc://doc/tmp/notes/other.md#The%20Part")!) == "The Part")
        #expect(PreviewAnchor.fragment(of: URL(string: "cedric-doc://doc/tmp/notes/other.md")!) == nil)
        #expect(PreviewAnchor.fragment(of: URL(string: "cedric-doc://doc/tmp/notes/other.md#")!) == nil)
    }

    @Test func candidatesPreferTheExactIdThenTheSlug() {
        #expect(PreviewAnchor.candidates(for: "part") == ["part"])
        #expect(PreviewAnchor.candidates(for: "Part") == ["Part", "part"])
        #expect(PreviewAnchor.candidates(for: "The Part") == ["The Part", "the-part"])
        #expect(PreviewAnchor.candidates(for: "sec") == ["sec"])
        #expect(PreviewAnchor.candidates(for: "") == [])
        #expect(PreviewAnchor.candidates(for: "?!") == ["?!"], "no empty slug")
    }

    @Test func headingIdsMatchTheRenderedHeadings() {
        for (heading, fragment) in [("Part", "part"), ("The *Big* Part", "The Big Part"), ("Setup & Run", "Setup & Run")] {
            let html = Markdown.render("## \(heading)\n")
            let id = PreviewAnchor.headingID(fragment)
            #expect(html.contains("id=\"\(id)\""), "\(heading) → #\(id) in \(html)")
            #expect(PreviewAnchor.candidates(for: fragment).contains(id))
        }
    }

    @Test func wikilinkHeadingHref() {
        let file = URL(fileURLWithPath: "/tmp/v/Other Note.md")
        #expect(WikiVault.href(file) == "cedric-doc://doc/tmp/v/Other%20Note.md")
        #expect(WikiVault.href(file, heading: "The Part") == "cedric-doc://doc/tmp/v/Other%20Note.md#the-part")
        #expect(WikiVault.href(file, heading: "^abc123") == "cedric-doc://doc/tmp/v/Other%20Note.md", "a block reference: the note")
        let link = URL(string: WikiVault.href(file, heading: "The Part")!)!
        #expect(PreviewAnchor.fragment(of: link) == "the-part" && PreviewFolder.fileURL(for: link)?.path == file.path)
    }
}

/// 0.5.2 S1 security read: after a Cancel with page JavaScript on, that
/// page load asks nothing more, whatever URL its script "clicks".
@Suite struct ExternalLinkGateTests {
    @Test func aCancelWithScriptOnSilencesThatLoad() {
        var g = ExternalLinkGate()
        #expect(g.asks(load: 3, scriptCanClick: true))
        g.answered(opened: false, load: 3, scriptCanClick: true)
        // Any link from the same load (a new URL each time) is dropped.
        #expect(!g.asks(load: 3, scriptCanClick: true))
        // A new load (an edit, Refresh, navigating) asks again.
        #expect(g.asks(load: 4, scriptCanClick: true))
        #expect(g.asks(load: 2, scriptCanClick: true))
    }

    @Test func withoutScriptEveryClickAsks() {
        var g = ExternalLinkGate()
        g.answered(opened: false, load: 1, scriptCanClick: false)
        #expect(g.declinedLoad == nil && g.asks(load: 1, scriptCanClick: false))
        // Declined with script on, then the same load number with script off
        // (only the user can click then): asks.
        g.answered(opened: false, load: 1, scriptCanClick: true)
        #expect(g.asks(load: 1, scriptCanClick: false))
    }

    @Test func openingDoesNotSilence() {
        var g = ExternalLinkGate()
        g.answered(opened: true, load: 5, scriptCanClick: true)
        #expect(g.asks(load: 5, scriptCanClick: true))
        // A later Cancel on a new load silences only that load.
        g.answered(opened: false, load: 6, scriptCanClick: true)
        #expect(g.asks(load: 5, scriptCanClick: true) && !g.asks(load: 6, scriptCanClick: true) && g.asks(load: 7, scriptCanClick: true))
    }
}

/// 0.5.2 S1 security read: the link prompt makes the real site obvious.
@Suite struct ExternalLinkTextTests {
    func text(_ s: String) -> ExternalLinkText { ExternalLinkText(URL(string: s)!) }

    @Test func aUserNameDressedAsASiteIsCalledOut() {
        let t = text("https://www.apple.com%2Fsignin@evil.example/")
        #expect(t.host == "evil.example")
        #expect(t.userinfo == "www.apple.com/signin")
        #expect(t.url == "https://www.apple.com%2Fsignin@evil.example/", "short: shown whole")
        let p = text("ftp://user:secret@files.example:2121/a")
        #expect(p.host == "files.example" && p.userinfo == "user:secret")
    }

    @Test func plainLinksHaveNoUserName() {
        let t = text("https://example.com/a?b=1#c")
        #expect(t.host == "example.com" && t.userinfo == nil && t.url == "https://example.com/a?b=1#c")
        let m = text("mailto:someone@example.com")
        #expect(m.host == nil && m.userinfo == nil && m.url == "mailto:someone@example.com")
    }

    @Test func aLongUserNameCantPushTheHostOutOfSight() {
        let long = "https://www.apple.com%2Fsignin%2F" + String(repeating: "a", count: 400) + "@evil.example/next"
        let t = text(long)
        #expect(t.host == "evil.example")
        #expect(t.url.count <= ExternalLinkText.maxURL, "\(t.url.count)")
        #expect(t.url.hasPrefix("https://www.apple.com") && t.url.contains("…") && t.url.contains("@evil.example/next"), "\(t.url)")
        #expect((t.userinfo?.count ?? 0) <= ExternalLinkText.maxUserinfo && t.userinfo?.contains("…") == true, "\(t.userinfo ?? "nil")")
    }

    @Test func aLongURLIsCutInTheMiddleKeepingTheHost() {
        let long = "https://example.com:8443/" + String(repeating: "x", count: 500) + "?q=end"
        let t = text(long)
        #expect(t.url.count == ExternalLinkText.maxURL, "\(t.url.count)")
        #expect(t.url.hasPrefix("https://example.com:8443/") && t.url.hasSuffix("?q=end") && t.url.contains("…"), "\(t.url)")
        // A host longer than the limit is still kept whole.
        let host = (1...4).map { String(repeating: "h\($0)", count: 30) }.joined(separator: ".") + ".example"
        let h = text("https://\(host)/" + String(repeating: "p", count: 300))
        #expect(h.host == host && h.url.hasPrefix("https://\(host)/") && h.url.contains("…"))
        // A long mailto (no host) is cut in the middle too.
        let m = text("mailto:a@example.com?body=" + String(repeating: "b", count: 400))
        #expect(m.url.count == ExternalLinkText.maxURL && m.url.hasPrefix("mailto:a@example.com") && m.url.contains("…"))
    }

    // Grok 4.7 review: a homograph host (Cyrillic а in `аpple.com`) is
    // shown as the punycode the opened URL has, and flagged with its
    // Unicode reading; the user-name warning names the punycode too.
    @Test func aNonASCIIHostShowsItsPunycode() {
        let u = URL(string: "https://аpple.com/signin")!
        let t = ExternalLinkText(u)
        let opened = URLComponents(string: u.absoluteString)?.rangeOfHost.map { String(u.absoluteString[$0]) }
        #expect(t.host == opened && t.host?.unicodeScalars.allSatisfy(\.isASCII) == true, "\(t.host ?? "nil") vs \(opened ?? "nil")")
        #expect(t.host?.lowercased().hasPrefix("xn--") == true, "\(t.host ?? "nil")")
        #expect(t.host != "apple.com" && t.host != "аpple.com")
        #expect(t.unicodeHost == "аpple.com", "\(t.unicodeHost ?? "nil")")
        #expect(t.url.contains(t.host ?? "?"), "the Site line names the host the URL shows")
        // Written as punycode already: still flagged with how it reads.
        let p = text("https://xn--pple-43d.com/")
        #expect(p.host == "xn--pple-43d.com" && p.unicodeHost == "аpple.com", "\(p.unicodeHost ?? "nil")")
        // With a user name dressed as a site: the warning's host is the punycode.
        let w = ExternalLinkText(URL(string: "https://www.apple.com%2Fsignin@аpple.com/")!)
        #expect(w.host?.unicodeScalars.allSatisfy(\.isASCII) == true && w.host?.hasPrefix("xn--") == true && w.unicodeHost == "аpple.com",
                "\(w.host ?? "nil")")
        // A percent-escaped host is flagged with its decoded name.
        let e = text("https://%D0%B0pple.com/")
        #expect(e.host == "%D0%B0pple.com" && e.unicodeHost == "аpple.com", "\(e.host ?? "nil") \(e.unicodeHost ?? "nil")")
        // Plain ASCII hosts: no flag.
        for s in ["https://example.com/", "https://EXAMPLE.com:8443/a", "https://a-b.example.co.uk/", "http://[::1]:8080/", "https://127.0.0.1/"] {
            #expect(text(s).unicodeHost == nil, "\(s)")
        }
        #expect(text("mailto:someone@example.com").unicodeHost == nil)
    }

    @Test func hiddenCharactersStayVisible() {
        #expect(ExternalLinkText.middle("abcdefghij", 5) == "ab…ij")
        #expect(ExternalLinkText.middle("abc", 5) == "abc")
        // A user name with a right-to-left override, once decoded, is escaped.
        let t = text("https://a%E2%80%AEb@evil.example/")
        #expect(t.userinfo == "a<U+202E>b" && t.host == "evil.example", "\(t.userinfo ?? "nil")")
    }
}
