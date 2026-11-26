import Foundation
import Testing
@testable import CedricCore

/// Pasted, dropped and picked images (Astra review findings 1–3): the
/// "images" folder is pinned by descriptor, copies are staged and
/// published without overwriting, and a source symlink's bytes are copied.
@Suite(.serialized) struct ImageStoreTests {
    let fm = FileManager.default

    /// A temp folder with doc/ (the document's folder) and outside/.
    func layout() throws -> (root: URL, doc: URL, outside: URL) {
        let d = tempDir()
        let doc = d.appendingPathComponent("doc"), outside = d.appendingPathComponent("outside")
        try fm.createDirectory(at: doc, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        return (d, doc, outside)
    }

    func listing(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }

    func isSymlink(_ u: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: u.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    @Test func copiesIntoANewImagesFolderWithoutOverwriting() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("one.png")
        try Data("new bytes".utf8).write(to: pic)
        let store = try ImageStore.open(in: doc)
        #expect(try store.copy(from: pic, name: "one.png") == "one.png")
        // Same name again, and a case-only clash on a case-insensitive volume.
        #expect(try store.copy(from: pic, name: "one.png") == "one-2.png")
        let old = Data("older".utf8)
        try old.write(to: doc.appendingPathComponent("images/Two.png"))
        let got = try store.write(Data("png".utf8), name: "two.png")
        let caseSensitive = (try? doc.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        #expect(got == (caseSensitive ? "two.png" : "two-2.png"), "a case-only clash gets a suffix where names ignore case: \(got)")
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/Two.png").path) == old, "the existing file is untouched")
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/one.png").path) == Data("new bytes".utf8))
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/one-2.png").path) == Data("new bytes".utf8))
        #expect(!listing(doc.appendingPathComponent("images")).contains { $0.hasPrefix(".cedric-image-") }, "no staging file is left")
        #expect(MarkdownPaste.imagesPath("my pic.png") == "images/my%20pic.png")
    }

    @Test func anImagesLinkOutIsRefusedAndOneInsideIsTaken() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = d.appendingPathComponent("p.png")
        try Data([1, 2, 3]).write(to: pic)
        try fm.createSymbolicLink(at: doc.appendingPathComponent("images"), withDestinationURL: outside)
        #expect(throws: ImageStore.Failure.outside) { _ = try ImageStore.open(in: doc) }
        #expect(listing(outside).isEmpty, "nothing written outside")
        // A link to a folder inside the document's folder is still fine.
        try fm.removeItem(at: doc.appendingPathComponent("images"))
        try fm.createDirectory(at: doc.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("images").path, withDestinationPath: "assets")
        _ = try ImageStore.open(in: doc).copy(from: pic, name: "p.png")
        #expect(fm.contents(atPath: doc.appendingPathComponent("assets/p.png").path) == Data([1, 2, 3]))
        // A link back to the document's folder itself is refused.
        try fm.removeItem(at: doc.appendingPathComponent("images"))
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("images").path, withDestinationPath: ".")
        #expect(throws: ImageStore.Failure.outside) { _ = try ImageStore.open(in: doc) }
    }

    /// The race the review describes: "images" is swapped for a link out
    /// after it was checked. The copy goes to the folder that was opened.
    @Test func aSwappedImagesFolderDoesNotRedirectTheCopy() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = d.appendingPathComponent("p.png")
        try Data([9]).write(to: pic)
        let images = doc.appendingPathComponent("images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        ImageStore.afterOpen = {
            try? FileManager.default.moveItem(at: images, to: doc.appendingPathComponent("was-images"))
            try? FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
        }
        defer { ImageStore.afterOpen = nil }
        let store = try ImageStore.open(in: doc)
        #expect(isSymlink(images), "the swap happened")
        #expect(try store.copy(from: pic, name: "p.png") == "p.png")
        #expect(listing(outside).isEmpty, "the outside folder is untouched")
        #expect(fm.contents(atPath: doc.appendingPathComponent("was-images/p.png").path) == Data([9]), "the copy is in the folder that was checked")
        // Through insertion: images/p.png no longer leads to that copy, so no link is given.
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: "p.png") }
    }

    /// The link handed to the editor is checked against the published file.
    @Test func aLinkIsGivenOnlyWhileItLeadsToThePublishedFile() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = d.appendingPathComponent("p q.png")
        try Data([4]).write(to: pic)
        let store = try ImageStore.open(in: doc)
        let name = try store.copy(from: pic, name: "p q.png")
        #expect(try store.link(for: name) == "images/p%20q.png", "an unchanged folder gives the link")
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: "never-published.png") }
        // The published file replaced by another of the same name.
        let published = doc.appendingPathComponent("images/p q.png")
        try fm.removeItem(at: published)
        try Data([5]).write(to: published)
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: name) }
        // The pinned "images" moved out of the document's folder (no link left behind).
        let second = try store.write(Data([6]), name: "r.png")
        try fm.moveItem(at: doc.appendingPathComponent("images"), to: outside.appendingPathComponent("moved"))
        #expect(fm.contents(atPath: outside.appendingPathComponent("moved/r.png").path) == Data([6]))
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: second) }
    }

    /// The document's folder replaced at its path after "images" was pinned.
    @Test func aReplacedDocumentFolderGivesNoLink() throws {
        let (d, doc, _) = try layout()
        defer { try? fm.removeItem(at: d) }
        let store = try ImageStore.open(in: doc)
        let name = try store.write(Data([1]), name: "x.png")
        try fm.moveItem(at: doc, to: d.appendingPathComponent("doc-old"))
        try fm.createDirectory(at: doc.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([2]).write(to: doc.appendingPathComponent("images/x.png"))
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: name) }
        #expect(fm.contents(atPath: d.appendingPathComponent("doc-old/images/x.png").path) == Data([1]), "the copy stayed where it was written")
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/x.png").path) == Data([2]), "the new folder's file is untouched")
    }

    /// `name` is one file name, checked before anything is staged.
    @Test func aNameThatIsNotOneFileNameIsRefused() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([3]).write(to: pic)
        let store = try ImageStore.open(in: doc)
        for bad in ["", ".", "..", "../p.png", "a/b.png", "/tmp/p.png", "p\0.png"] {
            #expect(throws: ImageStore.Failure.badName, "\(bad.debugDescription)") { _ = try store.copy(from: pic, name: bad) }
            #expect(throws: ImageStore.Failure.badName, "\(bad.debugDescription)") { _ = try store.write(Data([3]), name: bad) }
        }
        #expect(listing(doc.appendingPathComponent("images")).isEmpty, "nothing staged or published")
        #expect(listing(d) == ["doc", "outside"] && listing(outside) == ["p.png"], "nothing written beside the folders")
    }

    @Test func aSourceSymlinkIsCopiedAsItsBytes() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        try Data("the real picture".utf8).write(to: outside.appendingPathComponent("real.png"))
        let link = outside.appendingPathComponent("link.png")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.png")   // relative, outside
        // A file of the link's target name already in images/: a copied link would point at it.
        try fm.createDirectory(at: doc.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data("decoy".utf8).write(to: doc.appendingPathComponent("images/real.png"))
        let name = try ImageStore.open(in: doc).copy(from: link, name: link.lastPathComponent)
        let copied = doc.appendingPathComponent("images/" + name)
        #expect(name == "link.png")
        #expect(!isSymlink(copied), "a regular file, not a link")
        #expect(fm.contents(atPath: copied.path) == Data("the real picture".utf8), "the target's bytes")
    }

    @Test func foldersAndPipesAreNotCopied() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let folder = outside.appendingPathComponent("x.png")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = outside.appendingPathComponent("pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let store = try ImageStore.open(in: doc)
        #expect(throws: ImageStore.Failure.notRegularFile) { _ = try store.copy(from: folder, name: "x.png") }
        #expect(throws: ImageStore.Failure.notRegularFile) { _ = try store.copy(from: fifo, name: "pipe.png") }
        #expect(listing(doc.appendingPathComponent("images")).isEmpty, "nothing staged or published")
    }

    @Test func aFailedPublishLeavesNoStagingFile() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([7]).write(to: pic)
        let store = try ImageStore.open(in: doc)
        let tooLong = String(repeating: "n", count: 300) + ".png"
        #expect(throws: (any Error).self) { _ = try store.copy(from: pic, name: tooLong) }
        #expect(listing(doc.appendingPathComponent("images")).isEmpty, "the staging file is removed")
    }
}
