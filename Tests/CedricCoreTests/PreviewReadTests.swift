import Foundation
import Testing
@testable import CedricCore

/// The preview's `cedric-doc:` reads (Astra review, 0.6 batch 4): what was
/// approved by path is read from beneath the approved root's descriptor,
/// so a folder or link swapped between the check and the read can't hand
/// the page another file's bytes.
@Suite(.offPool) struct PreviewReadTests {
    let fm = FileManager.default

    func folder() throws -> URL {
        let d = tempDir()
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.resolvingSymlinksInPath()
    }

    func put(_ root: URL, _ rel: String, _ text: String) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    func page(_ file: URL) -> URL { PreviewFolder.pageURL(forFile: file)! }

    /// Both lookups: the kernel's beneath lookup (where enforced) and the walk.
    var modes: [Bool] { Beneath.kernelEnforced ? [false, true] : [true] }

    @Test func readsTheApprovedFile() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        let img = try put(doc, "img/a.png", "PNG")
        for scriptOn in [false, true] {
            let hit = try #require(PreviewFolder.approved(for: page(img), in: doc, openedRoot: nil, scriptOn: scriptOn))
            #expect(hit.root == doc)
            for walk in modes {
                #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: scriptOn, walk: walk) == Data("PNG".utf8))
            }
        }
    }

    @Test func folderSwappedForALinkOutsideAfterTheCheck() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        let img = try put(doc, "img/a.png", "PNG")
        _ = try put(t, "outside/a.png", "SECRET")
        let hit = try #require(PreviewFolder.approved(for: page(img), in: doc, openedRoot: nil, scriptOn: true))
        // Swap: the checked folder becomes a link to one outside the root.
        try fm.moveItem(at: doc.appendingPathComponent("img"), to: t.appendingPathComponent("img-old"))
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("img").path, withDestinationPath: t.appendingPathComponent("outside").path)
        #expect((try? Data(contentsOf: hit.file)) == Data("SECRET".utf8), "the path now leads outside")
        for scriptOn in [false, true] {
            for walk in modes {
                #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: scriptOn, walk: walk) == nil, "walk \(walk)")
            }
        }
    }

    @Test func fileSwappedForALinkAfterTheCheck() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        let img = try put(doc, "a.png", "PNG")
        let secret = try put(t, "secret.txt", "SECRET")
        _ = try put(doc, ".env", "TOKEN")
        let hit = try #require(PreviewFolder.approved(for: page(img), in: doc, openedRoot: nil, scriptOn: true))
        // Outside the root: refused whatever the script setting.
        try fm.removeItem(at: img)
        try fm.createSymbolicLink(atPath: img.path, withDestinationPath: secret.path)
        for scriptOn in [false, true] {
            for walk in modes { #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: scriptOn, walk: walk) == nil) }
        }
        // Relative, still outside.
        try fm.removeItem(at: img)
        try fm.createSymbolicLink(atPath: img.path, withDestinationPath: "../secret.txt")
        for walk in modes { #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: false, walk: walk) == nil) }
        // Inside, but a dotfile: refused to a page with script on.
        try fm.removeItem(at: img)
        try fm.createSymbolicLink(atPath: img.path, withDestinationPath: ".env")
        for walk in modes { #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: true, walk: walk) == nil) }
    }

    @Test func onlyARegularFileIsRead() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        let img = try put(doc, "a.png", "PNG")
        let hit = try #require(PreviewFolder.approved(for: page(img), in: doc, openedRoot: nil, scriptOn: false))
        // A folder swapped in.
        try fm.removeItem(at: img)
        try fm.createDirectory(at: img, withIntermediateDirectories: false)
        for walk in modes { #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: false, walk: walk) == nil) }
        // A FIFO swapped in: refused, and the open doesn't wait for a writer.
        try fm.removeItem(at: img)
        #expect(mkfifo(img.path, 0o600) == 0)
        for walk in modes { #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: false, walk: walk) == nil) }
        // Gone, or the root gone: fails closed.
        try fm.removeItem(at: img)
        #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: false) == nil)
        #expect(PreviewRead.data(img, beneath: t.appendingPathComponent("nowhere"), scriptOn: false) == nil)
    }

    @Test func aFileOutsideTheRootIsNeverRead() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        _ = try put(doc, "a.png", "PNG")
        let secret = try put(t, "secret.png", "SECRET")
        #expect(PreviewRead.data(secret, beneath: doc, scriptOn: false) == nil)
        #expect(PreviewRead.data(doc.appendingPathComponent("../secret.png"), beneath: doc, scriptOn: false) == nil)
        #expect(PreviewRead.data(doc, beneath: doc, scriptOn: false) == nil)
        // A page with script on: images, fonts and CSS only, no dot folders.
        _ = try put(doc, "notes.txt", "N")
        _ = try put(doc, ".git/x.png", "G")
        #expect(PreviewRead.data(doc.appendingPathComponent("notes.txt"), beneath: doc, scriptOn: true) == nil)
        #expect(PreviewRead.data(doc.appendingPathComponent(".git/x.png"), beneath: doc, scriptOn: true) == nil)
        #expect(PreviewRead.data(doc.appendingPathComponent("notes.txt"), beneath: doc, scriptOn: false) == Data("N".utf8))
    }

    @Test func aLinkStayingInsideIsFollowedWhereTheKernelEnforcesIt() throws {
        guard Beneath.kernelEnforced else { return }
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        _ = try put(doc, "real/a.png", "PNG")
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("alias.png").path, withDestinationPath: "real/a.png")
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("pics").path, withDestinationPath: "real")
        let alias = doc.appendingPathComponent("alias.png"), viaFolder = doc.appendingPathComponent("pics/a.png")
        for f in [alias, viaFolder] {
            let hit = try #require(PreviewFolder.approved(for: page(f), in: doc, openedRoot: nil, scriptOn: true))
            #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: true, walk: false) == Data("PNG".utf8))
            // The component walk follows no link: fails closed.
            #expect(PreviewRead.data(hit.file, beneath: hit.root, scriptOn: true, walk: true) == nil)
        }
    }

    /// One kind of granted root: where the document is, what the preview
    /// grants, the file asked for and the root it must be approved under.
    struct Granted {
        let name: String
        let doc: URL, opened: URL?, root: URL, file: URL, request: URL, vault: Bool
    }

    /// The document's folder, the opened folder, an Obsidian vault and a
    /// site root (`static/`), each holding `a.png` ("ORIG").
    func grantedRoots(_ t: URL) throws -> [Granted] {
        var out: [Granted] = []
        let d = t.appendingPathComponent("d/doc")
        out.append(Granted(name: "document", doc: d, opened: nil, root: d, file: try put(d, "a.png", "ORIG"),
                           request: page(d.appendingPathComponent("a.png")), vault: false))
        let o = t.appendingPathComponent("o/site")
        let od = o.appendingPathComponent("posts")
        try fm.createDirectory(at: od, withIntermediateDirectories: true)
        let of = try put(o, "img/a.png", "ORIG")
        out.append(Granted(name: "opened folder", doc: od, opened: o, root: o, file: of, request: page(of), vault: false))
        let v = t.appendingPathComponent("v/vault")
        try fm.createDirectory(at: v.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let vd = v.appendingPathComponent("notes")
        try fm.createDirectory(at: vd, withIntermediateDirectories: true)
        let vf = try put(v, "att/a.png", "ORIG")
        out.append(Granted(name: "vault", doc: vd, opened: nil, root: v, file: vf,
                           request: page(vd.appendingPathComponent("a.png")), vault: true))
        let s = t.appendingPathComponent("s/blog")
        let sd = s.appendingPathComponent("posts")
        try fm.createDirectory(at: sd, withIntermediateDirectories: true)
        let sf = try put(s, "static/images/a.png", "ORIG")
        out.append(Granted(name: "site root", doc: sd, opened: nil, root: s.appendingPathComponent("static"), file: sf,
                           request: URL(string: PreviewFolder.scheme + "://doc/images/a.png")!, vault: false))
        return out
    }

    /// A granted root renamed away and replaced by another folder holding
    /// a same-named file (Astra review, batch 7c): the reads, of the
    /// earlier approval and of one made after the swap, get the bytes
    /// approved before it or nothing, in both lookups.
    @Test func aRootReplacedAfterItsGrantIsNeverRead() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        for g in try grantedRoots(t) {
            for scriptOn in [false, true] {
                for walk in modes {
                    let grants = PreviewGrants()
                    let vault = WikiVault(documentFolder: g.doc, openedRoot: g.opened)
                    let vaultRoot = g.vault ? vault.root : nil
                    grants.grant([g.doc, g.opened, vaultRoot])
                    let before = try #require(grants.approve(g.request, in: g.doc, openedRoot: g.opened, vaultRoot: vaultRoot,
                                                             scriptOn: scriptOn, vault: vault), "\(g.name)")
                    #expect(before.root.url == g.root.standardizedFileURL, "\(g.name)")
                    #expect(PreviewRead.data(before.parts, beneath: before.root, scriptOn: scriptOn, walk: walk) == Data("ORIG".utf8), "\(g.name)")
                    // The swap: the root's path now names another folder,
                    // with the document's folder and the same file in it.
                    let away = g.root.deletingLastPathComponent().appendingPathComponent(g.root.lastPathComponent + "-away")
                    try fm.moveItem(at: g.root, to: away)
                    try fm.createDirectory(at: g.doc, withIntermediateDirectories: true)
                    if g.vault { try fm.createDirectory(at: g.root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true) }
                    _ = try put(g.file.deletingLastPathComponent(), g.file.lastPathComponent, "EVIL")
                    grants.grant([g.doc, g.opened, vaultRoot])
                    let after = grants.approve(g.request, in: g.doc, openedRoot: g.opened, vaultRoot: vaultRoot, scriptOn: scriptOn, vault: vault)
                    for (which, hit) in [("before", Optional(before)), ("after", after)] {
                        guard let hit else { continue }
                        let got = PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: scriptOn, walk: walk)
                        #expect(got == nil || got == Data("ORIG".utf8), "\(g.name) \(which) scriptOn \(scriptOn) walk \(walk)")
                    }
                    // Back as it was, for the next mode.
                    try fm.removeItem(at: g.root)
                    try fm.moveItem(at: away, to: g.root)
                }
            }
        }
    }

    /// A granted root that couldn't be opened when it was granted is
    /// refused for that grant's lifetime (Astra review, batch 8c): put
    /// back as it was, or replaced by another folder, before the request,
    /// it is never pinned by path then. Only a fresh grant opens it.
    @Test func aRootUnavailableAtItsGrantStaysRefused() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        for g in try grantedRoots(t) {
            // The top folder holding this case's granted roots (t/d, t/o, t/v, t/s).
            let top = t.appendingPathComponent(g.doc.path.dropFirst(t.path.count + 1).split(separator: "/")[0].description)
            let away = t.appendingPathComponent(top.lastPathComponent + "-away")
            for replaced in [false, true] {
                for scriptOn in [false, true] {
                    for walk in modes {
                        let vault = WikiVault(documentFolder: g.doc, openedRoot: g.opened)
                        let vaultRoot = g.vault ? vault.root : nil
                        let grants = PreviewGrants()
                        try fm.moveItem(at: top, to: away)
                        grants.grant([g.doc, g.opened, vaultRoot])
                        if replaced {
                            // Another folder in its place, with the same layout.
                            try fm.copyItem(at: away, to: top)
                            _ = try put(g.file.deletingLastPathComponent(), g.file.lastPathComponent, "EVIL")
                        } else {
                            try fm.moveItem(at: away, to: top)
                        }
                        let what = "\(g.name) replaced \(replaced) scriptOn \(scriptOn) walk \(walk)"
                        let hit = grants.approve(g.request, in: g.doc, openedRoot: g.opened, vaultRoot: vaultRoot, scriptOn: scriptOn, vault: vault)
                        #expect(hit == nil, "\(what)")
                        if let hit { #expect(PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: scriptOn, walk: walk) == nil, "\(what)") }
                        // Granted the same again: still refused.
                        grants.grant([g.doc, g.opened, vaultRoot])
                        #expect(grants.approve(g.request, in: g.doc, openedRoot: g.opened, vaultRoot: vaultRoot, scriptOn: scriptOn, vault: vault) == nil, "\(what)")
                        // A fresh grant opens what is there now.
                        grants.revoke()
                        grants.grant([g.doc, g.opened, vaultRoot])
                        let fresh = try #require(grants.approve(g.request, in: g.doc, openedRoot: g.opened, vaultRoot: vaultRoot,
                                                                scriptOn: scriptOn, vault: vault), "\(what)")
                        #expect(PreviewRead.data(fresh.parts, beneath: fresh.root, scriptOn: scriptOn, walk: walk) == Data((replaced ? "EVIL" : "ORIG").utf8), "\(what)")
                        if replaced {
                            try fm.removeItem(at: top)
                            try fm.moveItem(at: away, to: top)
                        }
                    }
                }
            }
        }
    }

    /// The document's folder pins, but the opened folder granted with it
    /// (by a link not there yet) doesn't: once the link appears, a file
    /// in the opened folder is still refused, not pinned by its path.
    @Test func aDeniedOpenedFolderIsNotPinnedLater() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let real = t.appendingPathComponent("real")
        let doc = real.appendingPathComponent("doc")
        try fm.createDirectory(at: doc, withIntermediateDirectories: true)
        let img = try put(real, "img/a.png", "ORIG")
        let link = t.appendingPathComponent("link")
        let request = page(link.appendingPathComponent("img/a.png"))
        for scriptOn in [false, true] {
            let grants = PreviewGrants()
            grants.grant([doc, link])
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
            #expect(PreviewFolder.approved(for: request, in: doc, openedRoot: link, scriptOn: scriptOn)?.root == link, "approved by path")
            #expect(grants.approve(request, in: doc, openedRoot: link, scriptOn: scriptOn) == nil, "scriptOn \(scriptOn)")
            // A fresh grant: served.
            grants.revoke()
            grants.grant([doc, link])
            let hit = try #require(grants.approve(request, in: doc, openedRoot: link, scriptOn: scriptOn))
            #expect(PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: scriptOn) == Data("ORIG".utf8))
            try fm.removeItem(at: link)
        }
        _ = img
    }

    /// Site roots whose first approval is raced (Astra review, batch 8c):
    /// each found where the search looks for one (`static/` above the
    /// document's folder, that folder above it itself, `static/` in a
    /// folder between the document's and the opened one), with `a.png`
    /// ("ORIG") in it.
    struct Site {
        let name: String
        let doc: URL, opened: URL?, root: URL, request: URL
    }

    func siteRoots(_ t: URL) throws -> [Site] {
        func req(_ p: String) -> URL { URL(string: PreviewFolder.scheme + "://doc/" + p)! }
        let blog = t.appendingPathComponent("s/blog")
        try fm.createDirectory(at: blog.appendingPathComponent("posts"), withIntermediateDirectories: true)
        _ = try put(blog, "static/images/a.png", "ORIG")
        let flat = t.appendingPathComponent("f/blog")
        try fm.createDirectory(at: flat.appendingPathComponent("posts"), withIntermediateDirectories: true)
        _ = try put(flat, "images/a.png", "ORIG")
        let opened = t.appendingPathComponent("o/site")
        try fm.createDirectory(at: opened.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        _ = try put(opened, "a/static/images/a.png", "ORIG")
        return [
            Site(name: "static above", doc: blog.appendingPathComponent("posts"), opened: nil,
                 root: blog.appendingPathComponent("static"), request: req("images/a.png")),
            Site(name: "folder above", doc: flat.appendingPathComponent("posts"), opened: nil, root: flat, request: req("images/a.png")),
            Site(name: "inside the opened folder", doc: opened.appendingPathComponent("a/b"), opened: opened,
                 root: opened.appendingPathComponent("a/static"), request: req("images/a.png")),
        ]
    }

    /// Renames `root` away and puts another folder in its place, with the
    /// same layout below it (the document's folder too, if it was inside)
    /// and `a.png` saying "EVIL"; returns where the original went.
    func replace(_ root: URL, doc: URL) throws -> URL {
        let away = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-away")
        try fm.moveItem(at: root, to: away)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if doc.path.hasPrefix(root.path + "/") { try fm.createDirectory(at: doc, withIntermediateDirectories: true) }
        _ = try put(root, "images/a.png", "EVIL")
        return away
    }

    /// A site root swapped between its discovery and its first approval
    /// and read (the hook runs there): the bytes found before the swap or
    /// nothing, in both lookups. Before 8c the root was pinned by its
    /// path after discovery, so the replacement's bytes were served.
    @Test func aSiteRootReplacedBeforeItsFirstPinIsNeverRead() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        for s in try siteRoots(t) {
            for scriptOn in [false, true] {
                for walk in modes {
                    let what = "\(s.name) scriptOn \(scriptOn) walk \(walk)"
                    let grants = PreviewGrants()
                    grants.grant([s.doc, s.opened])
                    final class Moved { var to: URL? }
                    let away = Moved()
                    grants.siteRootFound = { root in
                        #expect(root.standardizedFileURL == s.root.standardizedFileURL, "\(what)")
                        away.to = try? self.replace(s.root, doc: s.doc)
                    }
                    let hit = grants.approve(s.request, in: s.doc, openedRoot: s.opened, scriptOn: scriptOn, walk: walk)
                    let moved = try #require(away.to, "the hook ran: \(what)")
                    if let hit {
                        let got = PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: scriptOn, walk: walk)
                        #expect(got == nil || got == Data("ORIG".utf8), "\(what)")
                    }
                    try fm.removeItem(at: s.root)
                    try fm.moveItem(at: moved, to: s.root)
                }
            }
        }
    }

    /// A site root found once the folder it is looked for in has been
    /// replaced after the grant: never the replacement's bytes.
    @Test func aSearchFolderReplacedAfterTheGrantIsNeverRead() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        for s in try siteRoots(t) {
            for scriptOn in [false, true] {
                for walk in modes {
                    let what = "\(s.name) scriptOn \(scriptOn) walk \(walk)"
                    let grants = PreviewGrants()
                    grants.grant([s.doc, s.opened])
                    // The folder holding the root (or the root itself, for
                    // a folder serving its own files), swapped.
                    let swapped = s.root.lastPathComponent == "static" ? s.root.deletingLastPathComponent() : s.root
                    let away = try replace(swapped, doc: s.doc)
                    if swapped != s.root { _ = try put(s.root, "images/a.png", "EVIL") }
                    if let hit = grants.approve(s.request, in: s.doc, openedRoot: s.opened, scriptOn: scriptOn, walk: walk) {
                        let got = PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: scriptOn, walk: walk)
                        #expect(got == nil || got == Data("ORIG".utf8), "\(what)")
                    }
                    try fm.removeItem(at: swapped)
                    try fm.moveItem(at: away, to: swapped)
                }
            }
        }
    }

    /// At the cap a new site root is refused, not served from a pin that
    /// isn't kept (the next request would find it again): the roots
    /// already pinned are still served from the same pins (Astra review,
    /// batch 8c, should-fix).
    @Test func aNewRootAtTheCapIsRefused() throws {
        #expect(PreviewGrants.limit == 64)
        #expect(PreviewGrants().capacity == PreviewGrants.limit)
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let blog = t.appendingPathComponent("blog")
        let doc = blog.appendingPathComponent("posts")
        _ = try put(doc, "static/1.png", "ONE")
        _ = try put(blog, "static/2.png", "TWO")
        _ = try put(blog, "public/3.png", "THREE")
        func req(_ n: Int) -> URL { URL(string: PreviewFolder.scheme + "://doc/\(n).png")! }
        for walk in modes {
            let grants = PreviewGrants(capacity: 3)
            grants.grant([doc])
            #expect(grants.count == 1)
            let one = try #require(grants.approve(req(1), in: doc, openedRoot: nil, scriptOn: true, walk: walk))
            #expect(grants.count == 2)
            // The third root: exactly at the cap, kept.
            let two = try #require(grants.approve(req(2), in: doc, openedRoot: nil, scriptOn: true, walk: walk))
            #expect(grants.count == 3)
            #expect(PreviewRead.data(two.parts, beneath: two.root, scriptOn: true, walk: walk) == Data("TWO".utf8))
            // A fourth: refused, and nothing more held open.
            #expect(grants.approve(req(3), in: doc, openedRoot: nil, scriptOn: true, walk: walk) == nil, "walk \(walk)")
            #expect(grants.approve(req(3), in: doc, openedRoot: nil, scriptOn: false, walk: walk) == nil, "walk \(walk)")
            #expect(grants.count == 3)
            #expect(openDescriptors(inside: t) == 3)
            // The pinned ones: the same pins.
            let again = try #require(grants.approve(req(1), in: doc, openedRoot: nil, scriptOn: true, walk: walk))
            #expect(again.root === one.root)
            #expect(PreviewRead.data(again.parts, beneath: again.root, scriptOn: true, walk: walk) == Data("ONE".utf8))
            #expect(grants.approve(req(2), in: doc, openedRoot: nil, scriptOn: true, walk: walk)?.root === two.root)
            // A fresh grant starts over.
            grants.revoke()
            grants.grant([doc])
            let three = try #require(grants.approve(req(3), in: doc, openedRoot: nil, scriptOn: true, walk: walk))
            #expect(PreviewRead.data(three.parts, beneath: three.root, scriptOn: true, walk: walk) == Data("THREE".utf8))
            #expect(grants.count == 2)
        }
    }

    /// The cap holds for the granted roots too (Astra review, batch 10c,
    /// should-fix): with room for one, the document's folder is pinned and
    /// served, and the opened folder past it is denied for that grant,
    /// never opened, and stays refused.
    @Test func aGrantedRootPastTheCapIsRefused() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let opened = t.appendingPathComponent("site")
        let doc = opened.appendingPathComponent("posts")
        let mine = try put(doc, "a.png", "DOC")
        let other = try put(opened, "img/b.png", "OPENED")
        for scriptOn in [false, true] {
            for walk in modes {
                let what = "scriptOn \(scriptOn) walk \(walk)"
                // With room for both, both are served (the requests are good).
                let roomy = PreviewGrants(capacity: 2)
                roomy.grant([doc, opened])
                #expect(roomy.count == 2, "\(what)")
                #expect(roomy.approve(page(other), in: doc, openedRoot: opened, scriptOn: scriptOn, walk: walk) != nil, "\(what)")
                let grants = PreviewGrants(capacity: 1)
                grants.grant([doc, opened])
                #expect(grants.count == 1, "\(what)")
                #expect(grants.pinned(doc) != nil, "\(what)")
                #expect(grants.pinned(opened) == nil, "\(what)")
                let hit = try #require(grants.approve(page(mine), in: doc, openedRoot: opened, scriptOn: scriptOn, walk: walk), "\(what)")
                #expect(PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: scriptOn, walk: walk) == Data("DOC".utf8), "\(what)")
                #expect(grants.approve(page(other), in: doc, openedRoot: opened, scriptOn: scriptOn, walk: walk) == nil, "\(what)")
                // Granted the same again: still one pin, the second still refused.
                grants.grant([doc, opened])
                #expect(grants.approve(page(other), in: doc, openedRoot: opened, scriptOn: scriptOn, walk: walk) == nil, "\(what)")
                #expect(grants.count == 1, "\(what)")
            }
        }
    }

    /// How many descriptors this process has open on something inside
    /// `t` (by the kernel's path for each, against `t`'s real path): other
    /// suites running alongside open files too, but never in this test's
    /// own folder.
    func openDescriptors(inside t: URL) -> Int {
        guard let real = realpath(t.path, nil) else { return -1 }
        let base = String(cString: real) + "/"
        free(real)
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return -1 }
        return fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride).reduce(0) { n, info in
            guard let p = PreviewRead.path(of: info.proc_fd) else { return n }
            return n + ((p + "/").hasPrefix(base) ? 1 : 0)
        }
    }

    /// Pins don't pile up: many requests, under grants that keep changing,
    /// hold at most the granted and site roots open, and a withdrawn
    /// grant closes its pin once no read holds it.
    @Test func pinnedRootsAreBoundedAndClosed() throws {
        let t = try folder()
        defer { try? fm.removeItem(at: t) }
        let roots = try grantedRoots(t)
        #expect(openDescriptors(inside: t) == 0)
        let grants = PreviewGrants()
        weak var firstPin: PinnedRoot?
        for i in 0..<400 {
            let g = roots[i % roots.count]
            let vault = WikiVault(documentFolder: g.doc, openedRoot: g.opened)
            let vaultRoot = g.vault ? vault.root : nil
            grants.grant([g.doc, g.opened, vaultRoot])
            let hit = try #require(grants.approve(g.request, in: g.doc, openedRoot: g.opened, vaultRoot: vaultRoot, scriptOn: true, vault: vault))
            if i == 0 { firstPin = hit.root }
            #expect(PreviewRead.data(hit.parts, beneath: hit.root, scriptOn: true) == Data("ORIG".utf8))
            #expect(grants.count <= 4)
            #expect(openDescriptors(inside: t) <= 4)
        }
        // Also the same grant, asked again and again: one pin per root.
        let g = roots[0]
        grants.grant([g.doc])
        for _ in 0..<200 { _ = grants.approve(g.request, in: g.doc, openedRoot: nil, scriptOn: false) }
        #expect(grants.count == 1)
        #expect(firstPin == nil)
        grants.revoke()
        #expect(grants.count == 0)
        #expect(openDescriptors(inside: t) == 0)
    }
}
