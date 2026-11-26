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
}
