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

    /// iOS opens a preview link only when the resolved path sits under the
    /// document's folder, a granted folder, the vault or the site root.
    @Test func linkTargetsStayInsideTheirRoots() throws {
        let t = try makeTree([
            "notes/a.md", "notes/sibling.md", "notes-evil/x.md",
            "outside/secret.md",
            "site/content/blog/post.md", "site/content/projects/intelbrew.md",
            "vault/other.md",
        ])
        defer { try? FileManager.default.removeItem(at: t) }
        let notes = t.appendingPathComponent("notes")
        let outside = t.appendingPathComponent("outside/secret.md")
        let sibling = notes.appendingPathComponent("sibling.md")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: notes.appendingPathComponent("escape.md"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: t.appendingPathComponent("site/content/out.md"), withDestinationURL: outside)
        func open(_ path: String, folder: URL, granted: URL? = nil, vault: URL? = nil) -> URL? {
            PreviewFolder.linkTarget(URL(string: "cedric-doc://doc" + path)!, folder: folder, openedRoot: granted, vaultRoot: vault)
        }
        #expect(open(sibling.path, folder: notes)?.path == sibling.path, "a sibling in the folder opens")
        #expect(open(notes.path + "/../outside/secret.md", folder: notes) == nil, "`..` is refused")
        #expect(open(notes.path + "/%2E%2E/outside/secret.md", folder: notes) == nil, "encoded `..` is refused")
        #expect(open(outside.path, folder: notes) == nil, "an absolute path outside the folder is refused")
        #expect(open("/etc/passwd", folder: notes) == nil, "a cedric-doc URL of an absolute path is refused")
        #expect(open(notes.appendingPathComponent("escape.md").path, folder: notes) == nil, "a symlink out of the folder is refused")
        #expect(open(t.appendingPathComponent("notes-evil/x.md").path, folder: notes) == nil, "a look-alike prefix is refused")
        #expect(open(outside.path, folder: notes, granted: t)?.path == outside.path, "a granted folder covers the file")
        #expect(open(t.appendingPathComponent("vault/other.md").path, folder: notes, vault: t.appendingPathComponent("vault"))?.path == t.appendingPathComponent("vault/other.md").path)
        let blog = t.appendingPathComponent("site/content/blog")
        let page = t.appendingPathComponent("site/content/projects/intelbrew.md")
        #expect(open("/projects/intelbrew", folder: blog)?.path == page.path, "a site-root page opens under the root it resolved in")
        #expect(open("/out.md", folder: t.appendingPathComponent("site/content")) == nil, "a site-root symlink out of that root is refused")
    }

    /// One start and one stored bookmark per resolved path, including a
    /// symlink to a folder already granted and a second pass over the same
    /// bookmarks (the next time they are loaded).
    @Test func folderGrantsStartAndStoreOnce() throws {
        let t = try makeTree(["vault/a.md", "other/b.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = t.appendingPathComponent("vault")
        let via = t.appendingPathComponent("via")
        try FileManager.default.createSymbolicLink(at: via, withDestinationURL: vault)
        #expect(PreviewGrantSet.resolvedPath(via) == PreviewGrantSet.resolvedPath(vault))

        var grants = PreviewGrantSet()
        var starts = 0
        var stores = 0
        func add(_ url: URL, storeSucceeds: Bool = true) {
            grants.apply(url, start: { _ in starts += 1 }, store: { _ in
                guard storeSucceeds else { return false }
                stores += 1
                return true
            })
        }
        add(vault, storeSucceeds: false)
        #expect(starts == 1 && stores == 0 && grants.stored.isEmpty, "a failed bookmark is not remembered")
        add(vault)
        add(vault)
        add(via)
        #expect(starts == 1 && stores == 1, "the same folder, and a symlink to it, start and store once")
        #expect(grants.stored == [PreviewGrantSet.resolvedPath(vault)])
        let again = grants.decide(vault)
        #expect(!again.start && !again.store)
        let other = t.appendingPathComponent("other")
        #expect(grants.decide(other) == PreviewGrantSet.Decision(start: true, store: true))
        add(other)
        #expect(starts == 2 && stores == 2 && grants.stored.count == 2)

        var loaded = PreviewGrantSet()
        var loadedStarts = 0
        for url in [vault, vault, via, other] {
            loaded.apply(url, start: { _ in loadedStarts += 1 }, store: { _ in true })
        }
        #expect(loadedStarts == 2, "loading duplicate bookmarks starts each resolved path once")
        #expect(loaded.stored.count == 2)
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
        #expect(route(web) == .openWebInPreview(web))
        #expect(route(web, command: true) == .confirmExternal(web))
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
