import Foundation
import Testing
@testable import CedricCore

/// Astra batch 9b: the preview's containment decisions compare paths by
/// their UTF-8 bytes, a `/` byte at the boundary, not as Swift text. A
/// slash followed by a combining mark is one Swift character, so a text
/// prefix test missed a first-level folder or file whose name starts with
/// one; and a canonically equivalent but byte-distinct root spelling
/// passed a text prefix test.
@Suite struct PreviewContainmentTests {
    func isText(_ u: URL) -> Bool { ["md", "txt"].contains(u.pathExtension) }
    func page(_ file: URL) throws -> URL { try #require(PreviewFolder.pageURL(forFile: file)) }

    /// Resource reads (`file(for:in:)`): a first-level and a nested
    /// combining-mark name is inside; the folder itself and a sibling
    /// named the folder plus a mark are not.
    @Test func combiningMarkNamesAreInsideTheFolder() throws {
        let t = try makeTree(["doc/\u{301}a.png", "doc/\u{301}d/b.png", "doc/c/\u{301}e/f.png", "doc\u{301}/s.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        for rel in ["\u{301}a.png", "\u{301}d/b.png", "c/\u{301}e/f.png"] {
            let f = doc.appendingPathComponent(rel)
            #expect(PreviewFolder.file(for: try page(f), in: doc) == f.standardizedFileURL, "\(rel) is inside")
        }
        #expect(PreviewFolder.file(for: try page(t.appendingPathComponent("doc\u{301}/s.png")), in: doc) == nil,
                "the folder's name plus a mark is a sibling, outside")
        #expect(PreviewFolder.file(for: try page(doc), in: doc) == nil, "the folder itself is not a file inside it")
    }

    /// A root named with Ω (U+03A9) does not admit the files of one named
    /// with the Ohm sign (U+2126): Swift text calls the two equal, but
    /// their bytes differ, Foundation keeps both spellings (the HFS
    /// decomposition leaves U+2126 alone) and a volume may keep them apart.
    @Test func aCanonicallyEquivalentRootIsNotTheSameRoot() throws {
        let base = "/cedric-no-such-folder-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: base + "/\u{3A9}")
        let sibling = URL(fileURLWithPath: base + "/\u{2126}/x.png")
        #expect(Array(folder.path.utf8) != Array(sibling.deletingLastPathComponent().path.utf8), "two spellings")
        #expect(PreviewFolder.file(for: try page(sibling), in: folder) == nil)
        #expect(PreviewFolder.file(for: try page(URL(fileURLWithPath: base + "/\u{3A9}/x.png")), in: folder) != nil)
    }

    /// Link clicks and `previewDocument`: a Markdown file in a
    /// combining-mark folder, first-level and nested, opens in the
    /// preview; one in the folder-plus-mark sibling is only revealed.
    @Test func linkClicksInCombiningMarkFolders() throws {
        let t = try makeTree(["doc/\u{301}a.md", "doc/\u{301}d/b.md", "doc/c/\u{301}e/f.md", "doc\u{301}/s.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        for rel in ["\u{301}a.md", "\u{301}d/b.md", "c/\u{301}e/f.md"] {
            let f = doc.appendingPathComponent(rel).standardizedFileURL
            #expect(PreviewLinkAction.action(for: try page(f), folder: doc, isText: isText) == .openInCedric(f), "\(rel)")
            #expect(PreviewLinkAction.previewAction(for: try page(f), folder: doc, command: false, isText: isText) == .openInPreview(f))
            #expect(PreviewLinkAction.previewDocument(at: f, root: doc, isText: isText).map { String(decoding: $0.data, as: UTF8.self) }
                    == "doc/" + rel, "\(rel) is read")
        }
        let s = t.appendingPathComponent("doc\u{301}/s.md").standardizedFileURL
        #expect(PreviewLinkAction.action(for: try page(s), folder: doc, isText: isText) == .revealInFinder(s))
        var read = false
        #expect(PreviewLinkAction.previewDocument(at: s, root: doc, isText: isText) { _ in read = true; return nil } == nil)
        #expect(!read, "the sibling's file is not read")
    }

    /// The enclosing-root gate: a document in a combining-mark folder
    /// under the opened folder (or the opened folder itself) gets the
    /// opened folder's files; a document in the opened folder's
    /// name-plus-mark sibling does not.
    @Test func theOpenedFolderEnclosesCombiningMarkFolders() throws {
        let t = try makeTree(["root/img.png", "root/\u{301}d/doc.md", "root/c/\u{301}e/doc.md", "root\u{301}/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("root"), img = root.appendingPathComponent("img.png")
        for rel in ["root/\u{301}d", "root/c/\u{301}e", "root"] {
            let folder = t.appendingPathComponent(rel)
            let hit = PreviewFolder.approved(for: try page(img), in: folder, openedRoot: root, scriptOn: true, siteRoots: false)
            #expect(hit?.root == root, "\(rel)")
            #expect(hit?.file == img.standardizedFileURL, "\(rel)")
        }
        let sibling = t.appendingPathComponent("root\u{301}")
        #expect(PreviewFolder.approved(for: try page(img), in: sibling, openedRoot: root, scriptOn: true, siteRoots: false) == nil,
                "the opened folder's name plus a mark doesn't enclose it")
    }

    /// With JavaScript on, a name starting with a dot byte is hidden even
    /// when a combining mark follows the dot (`hasPrefix(".")` missed it),
    /// on the path asked for and on the path its links lead to; a
    /// combining-mark name that isn't hidden is still served.
    @Test func aDotFollowedByAMarkIsHiddenWithScriptOn() throws {
        let t = try makeTree(["doc/.\u{301}x.png", "doc/.\u{301}d/y.png", "doc/c/.\u{301}e/z.png", "doc/\u{301}ok/w.png", "doc/ok.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let fm = FileManager.default
        let doc = t.appendingPathComponent("doc")
        func served(_ rel: String) throws -> URL? {
            PreviewFolder.file(for: try page(doc.appendingPathComponent(rel)), in: doc, scriptOn: true)
        }
        for rel in [".\u{301}x.png", ".\u{301}d/y.png", "c/.\u{301}e/z.png"] {
            #expect(try served(rel) == nil, "\(rel) is hidden")
            #expect(PreviewFolder.file(for: try page(doc.appendingPathComponent(rel)), in: doc, scriptOn: false) != nil, "\(rel) with script off")
        }
        #expect(try served("\u{301}ok/w.png") != nil, "a mark-leading folder isn't hidden")
        #expect(try served("ok.png") != nil)
        // Asked for by a plain name, leading to a hidden one: refused.
        try fm.createSymbolicLink(at: doc.appendingPathComponent("pics"), withDestinationURL: doc.appendingPathComponent(".\u{301}d"))
        try fm.createSymbolicLink(at: doc.appendingPathComponent("v.png"), withDestinationURL: doc.appendingPathComponent(".\u{301}x.png"))
        #expect(try served("pics/y.png") == nil, "the resolved folder is hidden")
        #expect(try served("v.png") == nil, "the resolved file is hidden")
    }

    /// Validators round 4: the site-root search finds a root above a
    /// document folder whose name starts with a combining mark (the
    /// levels above were counted with a text prefix, which "/" and the
    /// mark missed), and a site-absolute path whose first name starts
    /// with a mark is split at its "/" bytes and served; `//host`, `..`
    /// and the query and fragment keep their rules.
    @Test func siteRootsAboveAndBelowCombiningMarkNames() throws {
        #expect(PreviewRoot.parts(of: "/\u{301}img/b.png") == ["\u{301}img", "b.png"])
        #expect(PreviewRoot.parts(of: "/a/./b.png?x=1#y") == ["a", "b.png"])
        #expect(PreviewRoot.parts(of: "//host/a.png") == nil)
        #expect(PreviewRoot.parts(of: "/a/../b.png") == nil)
        #expect(PreviewRoot.parts(of: "a.png") == nil)
        #expect(PreviewRoot.parts(of: "/") == nil)
        let t = try makeTree(["blog/static/images/a.png", "blog/static/\u{301}img/b.png", "blog/\u{301}posts/doc.md", "blog/posts/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let blog = t.appendingPathComponent("blog").resolvingSymlinksInPath()
        func req(_ p: String) -> URL { URL(string: PreviewFolder.scheme + "://doc/" + p)! }
        let walks = Beneath.kernelEnforced ? [false, true] : [true]
        for docName in ["\u{301}posts", "posts"] {
            let doc = blog.appendingPathComponent(docName)
            for scriptOn in [false, true] {
                for walk in walks {
                    let what = "\(docName) scriptOn \(scriptOn) walk \(walk)"
                    let grants = PreviewGrants()
                    grants.grant([doc])
                    let a = try #require(grants.approve(req("images/a.png"), in: doc, openedRoot: nil, scriptOn: scriptOn, walk: walk), "\(what)")
                    #expect(PreviewRead.data(a.parts, beneath: a.root, scriptOn: scriptOn, walk: walk) == Data("blog/static/images/a.png".utf8), "\(what)")
                    let b = try #require(grants.approve(req("%CC%81img/b.png"), in: doc, openedRoot: nil, scriptOn: scriptOn, walk: walk), "\(what)")
                    #expect(b.parts == ["\u{301}img", "b.png"], "\(what)")
                    #expect(PreviewRead.data(b.parts, beneath: b.root, scriptOn: scriptOn, walk: walk) == Data("blog/static/\u{301}img/b.png".utf8), "\(what)")
                }
            }
        }
    }

    /// Validators round 4: which root holds a document folder or a link
    /// target is decided by the paths' bytes. A first-level combining-mark
    /// folder is inside; the root's name plus a mark is a sibling, and a
    /// canonically equivalent but byte-distinct spelling (Ohm sign for
    /// Omega) is another folder. The opened folder spelled with the Ohm
    /// sign isn't taken for a folder spelled with Omega in the search.
    @Test func theHoldingRootIsDecidedByBytes() throws {
        let base = URL(fileURLWithPath: "/cedric-no-such-folder-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let mark = root.appendingPathComponent("\u{301}d"), sibling = base.appendingPathComponent("root\u{301}")
        #expect(PreviewRoot.openedRoot(root, holding: mark) == root)
        #expect(PreviewRoot.openedRoot(root, holding: root) == root)
        #expect(PreviewRoot.openedRoot(root, holding: sibling) == nil)
        #expect(PreviewRoot.openedRoot(nil, holding: mark) == nil)
        #expect(PreviewRoot.root(holding: mark.appendingPathComponent("a.md"), among: [sibling, root]) == root)
        #expect(PreviewRoot.root(holding: root.appendingPathComponent("\u{301}a.md"), among: [root]) == root)
        #expect(PreviewRoot.root(holding: sibling.appendingPathComponent("a.md"), among: [root]) == nil)
        #expect(PreviewRoot.root(holding: root, among: [root]) == nil, "the root itself isn't a file below it")
        let ohm = base.appendingPathComponent("\u{2126}"), omega = base.appendingPathComponent("\u{3A9}")
        #expect(PreviewRoot.openedRoot(ohm, holding: omega.appendingPathComponent("d")) == nil)
        #expect(PreviewRoot.root(holding: omega.appendingPathComponent("a.md"), among: [ohm]) == nil)
        let dirs = PreviewRoot.searchFolders(from: omega.appendingPathComponent("d"), openedRoot: ohm, home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(dirs.contains { Array($0.path.utf8) == Array(ohm.path.utf8) }, "the opened folder is searched")
        #expect(Array(dirs.last?.path.utf8 ?? "".utf8) == Array(ohm.path.utf8), "added after the walk, not met on it")
    }
}
