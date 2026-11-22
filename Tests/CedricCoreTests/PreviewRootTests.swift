import Foundation
import Testing
@testable import CedricCore

/// A throwaway folder tree: `files` are paths relative to it.
func makeTree(_ files: [String]) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("cedric-root-\(UUID().uuidString)").resolvingSymlinksInPath()
    for f in files {
        let u = root.appendingPathComponent(f)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(f.utf8).write(to: u)
    }
    if files.isEmpty { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
    return root
}

@Suite struct PreviewRootTests {
    @Test func theDocumentsOwnFolderComesFirst() throws {
        let t = try makeTree(["site/images/x.webp", "site/content/images/x.webp", "site/content/index.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("site/content")
        let hit = try #require(PreviewRoot.resolve("/images/x.webp", from: doc, openedRoot: nil))
        #expect(hit.file.path == doc.appendingPathComponent("images/x.webp").path)
        #expect(hit.root.path == doc.path)
    }

    @Test func walksUpToTheNearestAncestorHoldingThePath() throws {
        let t = try makeTree(["site/images/logo.png", "site/content/blog/2026/post.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("site/content/blog/2026")
        let hit = try #require(PreviewRoot.resolve("/images/logo.png", from: doc, openedRoot: nil))
        #expect(hit.file.path == t.appendingPathComponent("site/images/logo.png").path)
    }

    @Test func siteGeneratorLayouts() throws {
        for sub in ["static", "public", "quartz/static", "content"] {
            let t = try makeTree(["site/\(sub)/images/a b.webp", "site/notes/n.md"])
            defer { try? FileManager.default.removeItem(at: t) }
            let doc = t.appendingPathComponent("site/notes")
            let hit = try #require(PreviewRoot.resolve("/images/a%20b.webp?v=2#x", from: doc, openedRoot: nil), "\(sub)")
            #expect(hit.file.path == t.appendingPathComponent("site/\(sub)/images/a b.webp").path)
            #expect(hit.root.path == t.appendingPathComponent("site/\(sub)").path)
        }
    }

    @Test func theOpenedFolderBoundsTheWalkAndIsTriedLast() throws {
        let t = try makeTree(["images/above.png", "vault/notes/n.md", "vault/assets/images/in.png", "other/images/o.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("vault/notes")
        let vault = t.appendingPathComponent("vault")
        // Above the opened folder: not looked at.
        #expect(PreviewRoot.resolve("/images/above.png", from: doc, openedRoot: vault) == nil)
        #expect(PreviewRoot.resolve("/images/above.png", from: doc, openedRoot: nil) != nil)
        // An opened folder the document isn't in is still tried, last.
        let other = t.appendingPathComponent("other")
        #expect(PreviewRoot.resolve("/images/o.png", from: doc, openedRoot: other)?.file.path == other.appendingPathComponent("images/o.png").path)
        #expect(PreviewRoot.searchFolders(from: doc, openedRoot: vault).map(\.lastPathComponent) == ["notes", "vault"])
    }

    @Test func onlyRootAbsolutePathsAndNoClimbing() throws {
        let t = try makeTree(["site/images/x.png", "secret.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("site")
        #expect(PreviewRoot.resolve("images/x.png", from: doc, openedRoot: nil) == nil)
        #expect(PreviewRoot.resolve("//host/images/x.png", from: doc, openedRoot: nil) == nil)
        #expect(PreviewRoot.resolve("https://host/images/x.png", from: doc, openedRoot: nil) == nil)
        #expect(PreviewRoot.resolve("/images/../../secret.png", from: doc, openedRoot: nil) == nil)
        #expect(PreviewRoot.resolve("/images/%2E%2E/%2E%2E/secret.png", from: doc, openedRoot: nil) == nil)
        #expect(PreviewRoot.resolve("/images", from: doc, openedRoot: nil) == nil, "a folder is not a file")
    }

    @Test func pageLinksFindTheirMarkdown() throws {
        let t = try makeTree(["content/projects/intelbrew.md", "content/blog/index.md", "content/index.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("content")
        #expect(PreviewRoot.resolve("/projects/intelbrew", from: doc, openedRoot: nil, pages: true)?.file.lastPathComponent == "intelbrew.md")
        #expect(PreviewRoot.resolve("/blog", from: doc, openedRoot: nil, pages: true)?.file.path == doc.appendingPathComponent("blog/index.md").path)
        #expect(PreviewRoot.resolve("/projects/intelbrew", from: doc, openedRoot: nil) == nil, "images don't get .md guessed")
    }

    @Test func theFileHandlerServesSiteRootPathsUnderTheSameRules() throws {
        let t = try makeTree(["site/static/images/x.webp", "site/static/.env", "site/static/notes.txt", "site/content/index.md", "site/content/rel.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("site/content")
        let page = try #require(PreviewFolder.pageURL(for: doc))
        func served(_ ref: String, scriptOn: Bool) -> URL? {
            guard let u = URL(string: ref, relativeTo: page)?.absoluteURL else { return nil }
            return PreviewFolder.file(for: u, in: doc, openedRoot: nil, scriptOn: scriptOn)
        }
        #expect(served("/images/x.webp", scriptOn: true)?.path == t.appendingPathComponent("site/static/images/x.webp").path)
        #expect(served("rel.png", scriptOn: true)?.lastPathComponent == "rel.png", "relative paths still work")
        #expect(served("/.env", scriptOn: true) == nil)
        #expect(served("/notes.txt", scriptOn: true) == nil, "with JS on, images, fonts and CSS only")
        #expect(served("/notes.txt", scriptOn: false) != nil)
        #expect(served("/images/missing.webp", scriptOn: false) == nil)
        // A symbolic link out of the root it was found under is refused.
        try FileManager.default.createSymbolicLink(at: t.appendingPathComponent("site/static/out.png"), withDestinationURL: t.appendingPathComponent("site/content/rel.png"))
        #expect(served("/out.png", scriptOn: false) == nil)
    }

    @Test func unreadableImagesBecomeOneHint() throws {
        let t = try makeTree(["site/content/index.md", "site/content/images/ok.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("site/content")
        let html = #"<p><img src="/images/ok.png" alt="a"> <img alt="b" src='/images/gone.webp'> <img src="data:image/png;base64,AA"> <img src="https://x/y.png"></p>"#
        #expect(PreviewImageAccess.localSources(html) == ["/images/ok.png", "/images/gone.webp"])
        // Folder readable: unchanged, a missing image shows its alt text as on the site.
        #expect(PreviewImageAccess.hideUnreadable(html, folder: doc, openedRoot: nil, folderReadable: true, hint: "H").html == html)
        let r = PreviewImageAccess.hideUnreadable(html, folder: doc, openedRoot: nil, folderReadable: false, hint: "H")
        #expect(r.hidden == 1)
        #expect(r.html.hasPrefix("H") && r.html.contains("ok.png") && !r.html.contains("gone.webp") && r.html.contains("data:image"))
        let none = PreviewImageAccess.hideUnreadable(#"<img src="images/ok.png">"#, folder: doc, openedRoot: nil, folderReadable: false, hint: "H")
        #expect(none.hidden == 0 && !none.html.hasPrefix("H"))
        // The owner's tags: src is the first attribute, then alt / size / style.
        let logo = #"<img src="/images/mindtricks_logo.webp" alt="MindTricks.io" width="160" height="160">"#
        let card = #"<img src="/images/intelbrew/intelbrew-card.webp" alt="Intelbrew" style="width:100%;height:150px;object-fit:cover">"#
        #expect(PreviewImageAccess.localSources(logo + card) == ["/images/mindtricks_logo.webp", "/images/intelbrew/intelbrew-card.webp"])
        let gone = PreviewImageAccess.hideUnreadable(logo + card, folder: doc, openedRoot: nil, folderReadable: false, hint: "H")
        #expect(gone.hidden == 2 && gone.html.hasPrefix("H") && !gone.html.contains("<img"))
    }

    @Test func folderAccessNeedsARealOpen() throws {
        let denied = PreviewFolderAccess.Facts(listingFailed: false, siblingCount: 3, anySiblingReadable: false, documentReadableAtPath: true)
        #expect(!PreviewFolderAccess.canRead(denied), "a listing plus the open file is not folder access")
        let granted = PreviewFolderAccess.Facts(listingFailed: false, siblingCount: 3, anySiblingReadable: true, documentReadableAtPath: false)
        #expect(PreviewFolderAccess.canRead(granted))
        #expect(!PreviewFolderAccess.canRead(PreviewFolderAccess.Facts(listingFailed: true, siblingCount: 0, anySiblingReadable: false, documentReadableAtPath: true)))
        let alone = PreviewFolderAccess.Facts(listingFailed: false, siblingCount: 0, anySiblingReadable: false, documentReadableAtPath: true)
        #expect(PreviewFolderAccess.canRead(alone), "a sandbox file with no siblings is readable")
        let filesOnly = PreviewFolderAccess.Facts(listingFailed: false, siblingCount: 0, anySiblingReadable: false, documentReadableAtPath: false)
        #expect(!PreviewFolderAccess.canRead(filesOnly), "a file-only security scope does not open a fresh path")

        let t = try makeTree([
            "notes/index.md", "notes/.secret", "notes/other.md",
            "site/index.md", "site/images/set/card.webp",
            "empty/index.md",
        ])
        defer { try? FileManager.default.removeItem(at: t) }
        try FileManager.default.createDirectory(at: t.appendingPathComponent("empty/images"), withIntermediateDirectories: true)
        let notes = t.appendingPathComponent("notes")
        let withSibling = PreviewFolderAccess.facts(folder: notes, document: notes.appendingPathComponent("index.md"))
        #expect(withSibling.siblingCount == 1 && withSibling.anySiblingReadable && PreviewFolderAccess.canRead(withSibling))
        let dotted = PreviewFolderAccess.facts(folder: notes, document: notes.appendingPathComponent("other.md"))
        #expect(dotted.siblingCount == 1, "the dotfile is not a sibling")
        let site = t.appendingPathComponent("site")
        let nested = PreviewFolderAccess.facts(folder: site, document: site.appendingPathComponent("index.md"))
        #expect(nested.anySiblingReadable && PreviewFolderAccess.canRead(nested), "images/set/card.webp is two levels down")
        let empty = t.appendingPathComponent("empty")
        let bare = PreviewFolderAccess.facts(folder: empty, document: empty.appendingPathComponent("index.md"))
        #expect(bare.siblingCount == 1 && !bare.anySiblingReadable && !PreviewFolderAccess.canRead(bare))
        let missing = PreviewFolderAccess.facts(folder: t.appendingPathComponent("nope"), document: notes.appendingPathComponent("index.md"))
        #expect(missing.listingFailed && !PreviewFolderAccess.canRead(missing))
        let only = try makeTree(["lone/index.md"])
        defer { try? FileManager.default.removeItem(at: only) }
        let lone = PreviewFolderAccess.facts(folder: only.appendingPathComponent("lone"), document: only.appendingPathComponent("lone/index.md"))
        #expect(lone.siblingCount == 0 && lone.documentReadableAtPath && PreviewFolderAccess.canRead(lone))
    }

    @Test func thePageRequestIsTheFolderURL() throws {
        let page = try #require(PreviewFolder.pageURL(for: URL(fileURLWithPath: "/Users/me/My Notes")))
        #expect(PreviewScheme.isPageRequest(page, page: page))
        var bust = URLComponents(url: page, resolvingAgainstBaseURL: false)
        bust?.queryItems = [URLQueryItem(name: "r", value: "4")]
        #expect(PreviewScheme.isPageRequest(try #require(bust?.url), page: page), "a cache-busting query is still the page")
        let noSlash = URL(string: String(page.absoluteString.dropLast()))
        #expect(PreviewScheme.isPageRequest(try #require(noSlash), page: page))
        #expect(!PreviewScheme.isPageRequest(try #require(URL(string: "cedric-doc://doc/images/a.webp")), page: page))
        #expect(!PreviewScheme.isPageRequest(try #require(URL(string: "https://doc" + page.path)), page: page))
        #expect(PreviewScheme.mimeType(forExtension: "WEBP") == "image/webp")
        #expect(PreviewScheme.mimeType(forExtension: "png") == "image/png")
        #expect(PreviewScheme.mimeType(forExtension: "svg") == "image/svg+xml")
        #expect(PreviewScheme.mimeType(forExtension: "txt") == nil)
        let fields = PreviewScheme.responseFields(mimeType: "image/webp", byteCount: 12)
        #expect(fields == PreviewScheme.ResponseFields(status: 200, mimeType: "image/webp", contentLength: 12, cacheControl: "no-store"))
    }

    /// The owner's real case: the mindtricks Quartz site's content/index.md,
    /// read-only, when a checkout is on this machine.
    /// macOS only: `homeDirectoryForCurrentUser` is unavailable on iOS.
    #if os(macOS)
    @Test func mindtricksIndexRendersItsImagesAndWikilinks() throws {
        let content = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("GitHub/mindtricks/content")
        let index = content.appendingPathComponent("index.md")
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return }
        let vault = WikiVault(documentFolder: content)
        let html = Markdown.render(text, options: .preview(vault: vault))
        let page = try #require(PreviewFolder.pageURL(for: content))
        let srcs = PreviewImageAccess.localSources(html)
        #expect(srcs.contains("/images/mindtricks_logo.webp"))
        for src in srcs {
            let u = try #require(URL(string: src, relativeTo: page)?.absoluteURL)
            #expect(PreviewFolder.file(for: u, in: content, openedRoot: nil, scriptOn: false) != nil, "\(src) is served")
        }
        #expect(!html.contains("[["), "no raw wikilinks")
        #expect(html.contains(#">Intelbrew and Tankard: Keeping Homebrew on Intel Macs</a>"#))
        #expect(html.contains("blog/20261117-intelbrew-tankard.md"))
    }
    #endif
}
