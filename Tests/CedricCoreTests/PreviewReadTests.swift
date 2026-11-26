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
