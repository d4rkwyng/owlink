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
