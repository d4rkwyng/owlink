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
        PreviewNavigation.decide(url: s.flatMap(URL.init(string:)), linkClick: click, mainFrame: mainFrame,
                                 page: page ?? self.page, expectedPage: expected, loadingShell: loading)
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
        #expect(decide("about:blank#part", click: true, page: URL(string: "about:blank")) == .scrollInPage)
        // A fragment on another page, or on a web page "the same" as an http(s) page, is routed.
        #expect(decide("cedric-doc://doc/tmp/notes/other.md#part", click: true) == .route)
        let web = URL(string: "https://example.com/a")!
        #expect(decide("https://example.com/a#x", click: true, page: web) == .route)
        // Without a page, only about:blank's own fragments.
        #expect(PreviewNavigation.samePage(URL(string: "about:blank#x")!, nil))
        #expect(!PreviewNavigation.samePage(URL(string: "about:srcdoc#x")!, nil))
        #expect(!PreviewNavigation.samePage(URL(string: "https://example.com/#x")!, nil))
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
