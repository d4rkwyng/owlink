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

    /// The walk up has the vault walk's bounds (`WikiVault.mayBeVaultRoot`).
    /// Before 0.5.4 it stopped only at the home folder itself and top-level
    /// folders: a document on a disk searched `/Volumes/<disk>` for
    /// `/images/…`, and one beside the home folder searched the folder
    /// holding it.
    @Test func theWalkStopsAtAVolumeAndAtFoldersHoldingHome() throws {
        // A disk: its root is never searched (pure paths; nothing is read there).
        let onDisk = URL(fileURLWithPath: "/Volumes/Backup/site/content")
        #expect(PreviewRoot.searchFolders(from: onDisk, openedRoot: nil).map(\.path) == ["/Volumes/Backup/site/content", "/Volumes/Backup/site"])
        // Opened on purpose, the disk is still tried.
        let disk = URL(fileURLWithPath: "/Volumes/Backup")
        #expect(PreviewRoot.searchFolders(from: onDisk, openedRoot: disk).map(\.path).last == "/Volumes/Backup")

        // A home folder deep in a temp tree: t/home/user.
        let t = try makeTree(["home/images/above.png", "home/user/images/home.png", "home/user/notes/site/n.md",
                              "home/other/site/n.md", "home/user/notes/images/notes.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("home/user")
        // Beside the home folder: the folder holding home (t/home) and above are not searched.
        let beside = t.appendingPathComponent("home/other/site")
        #expect(PreviewRoot.searchFolders(from: beside, openedRoot: nil, home: home).map(\.lastPathComponent) == ["site", "other"])
        #expect(PreviewRoot.resolve("/images/above.png", from: beside, openedRoot: nil, home: home) == nil)
        // Inside it: up to, not including, the home folder.
        let inside = t.appendingPathComponent("home/user/notes/site")
        #expect(PreviewRoot.searchFolders(from: inside, openedRoot: nil, home: home).map(\.lastPathComponent) == ["site", "notes"])
        #expect(PreviewRoot.resolve("/images/notes.png", from: inside, openedRoot: nil, home: home) != nil)
        #expect(PreviewRoot.resolve("/images/home.png", from: inside, openedRoot: nil, home: home) == nil)
        #expect(PreviewRoot.resolve("/images/above.png", from: inside, openedRoot: nil, home: home) == nil)
        // The home folder opened in the sidebar: searched, as before.
        #expect(PreviewRoot.resolve("/images/home.png", from: inside, openedRoot: home, home: home)?.file.lastPathComponent == "home.png")
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

    /// A site-absolute link whose first name starts with a combining mark:
    /// "/" then the mark is one Swift character, so text tests took the
    /// link for relative (resolve refused it; the readability probe looked
    /// beside the document). By the first byte it is site-absolute, split
    /// at the "/" bytes, and still never climbs (Astra batch 17v must 6).
    @Test func aSlashBeforeACombiningMarkStartsASiteAbsoluteLink() throws {
        let t = try makeTree(["site/\u{301}pic.png", "site/sub/doc.md", "secret.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let site = t.appendingPathComponent("site"), doc = site.appendingPathComponent("sub")
        #expect(PreviewRoot.parts(of: "/\u{301}pic.png") == ["\u{301}pic.png"])
        #expect(PreviewRoot.parts(of: "/a/\u{301}b?x#y") == ["a", "\u{301}b"])
        #expect(PreviewRoot.parts(of: "//\u{301}host/x") == nil, "still not a //host link")
        #expect(PreviewRoot.parts(of: "/\u{301}/../../secret.png") == nil, "still never climbs")
        #expect(PreviewRoot.resolve("/\u{301}pic.png", from: doc, openedRoot: site)?.file.lastPathComponent == "\u{301}pic.png")
        #expect(PreviewImageAccess.readable("/\u{301}pic.png", folder: doc, openedRoot: site), "found at the site root, not beside the document")
        #expect(!PreviewImageAccess.readable("/\u{301}/../../secret.png", folder: doc, openedRoot: site))
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
    }

    /// The owner's real case: the mindtricks Quartz site's content/index.md,
    /// read-only, when a checkout is on this machine.
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
}
