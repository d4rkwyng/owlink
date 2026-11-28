import Foundation
import Testing
@testable import CedricCore

/// Pasted, dropped and picked images (Astra review findings 1–3): the
/// "images" folder is pinned by descriptor, copies are staged and
/// published without overwriting, and a source symlink's bytes are copied.
/// Most tests run once per path the store can take: the kernel-enforced
/// one (where `containmentEnforced`: macOS 26) and the folder-by-folder
/// fallback (the macOS 15-era kernel of the Swift 6.1 CI job has no
/// `RENAME_RESOLVE_BENEATH`; forced with `forceFallback` elsewhere, so the
/// macOS 26 job covers it too). The few that pin kernel-only behavior
/// don't run on macOS 15.
let needsContainment: Comment = "needs a kernel that keeps open and rename beneath a folder (O_RESOLVE_BENEATH and RENAME_RESOLVE_BENEATH; not macOS 15)"

enum StoreMode: String, CustomTestStringConvertible, Sendable {
    case kernel, fallback
    var testDescription: String { rawValue }
}

/// The paths this kernel can run: both where it enforces beneath lookups,
/// the fallback alone where it doesn't.
let storeModes: [StoreMode] = ImageStore.containmentEnforced ? [.kernel, .fallback] : [.fallback]

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

    /// Stores opened from now on take `mode`'s path (reset with `forceFallback = false`).
    func use(_ mode: StoreMode) { ImageStore.forceFallback = mode == .fallback }

    @Test(arguments: storeModes) func copiesIntoANewImagesFolderWithoutOverwriting(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
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
        #if targetEnvironment(simulator)
        // The simulator's folders answer a stat case-sensitively and a rename case-insensitively, so a
        // case-only clash can't be told apart from a changed folder there; a device and a Mac agree.
        #else
        let got = try store.write(Data("png".utf8), name: "two.png")
        let caseSensitive = (try? doc.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        #expect(got == (caseSensitive ? "two.png" : "two-2.png"), "a case-only clash gets a suffix where names ignore case: \(got)")
        #endif
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/Two.png").path) == old, "the existing file is untouched")
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/one.png").path) == Data("new bytes".utf8))
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/one-2.png").path) == Data("new bytes".utf8))
        #expect(!listing(doc.appendingPathComponent("images")).contains { $0.hasPrefix(".cedric-image-") }, "no staging file is left")
        #expect(MarkdownPaste.imagesPath("my pic.png") == "images/my%20pic.png")
    }

    @Test(.enabled(if: ImageStore.containmentEnforced, needsContainment)) func anImagesLinkOutIsRefusedAndOneInsideIsTaken() throws {
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
    /// after it was checked. Nothing is written: not through the link, not
    /// in the folder that was checked (images/<name> no longer leads there).
    @Test(arguments: storeModes) func aSwappedImagesFolderDoesNotRedirectTheCopy(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
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
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "p.png") }
        #expect(listing(outside).isEmpty, "the outside folder is untouched")
        #expect(listing(doc.appendingPathComponent("was-images")).isEmpty, "the folder that was checked gets neither staged bytes nor a file")
        #expect(listing(doc) == ["images", "was-images"], "no staging file is left in the document's folder")
        // Through insertion: images/p.png no longer leads to that copy, so no link is given.
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: "p.png") }
    }

    /// Must-fix 1 (Astra, batch 3): the pinned "images" moved outside the
    /// document's folder after it was opened. The moved-out folder gets
    /// neither staged bytes nor a published file.
    @Test(arguments: storeModes) func anImagesFolderMovedOutAfterOpenReceivesNothing(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = d.appendingPathComponent("p.png")
        try Data([9]).write(to: pic)
        let images = doc.appendingPathComponent("images"), moved = outside.appendingPathComponent("moved")
        ImageStore.afterOpen = { try? FileManager.default.moveItem(at: images, to: moved) }
        defer { ImageStore.afterOpen = nil }
        let store = try ImageStore.open(in: doc)
        #expect(fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: images.path), "the move happened")
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "p.png") }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.write(Data([8]), name: "w.png") }
        #expect(listing(moved).isEmpty, "the moved-out folder gets neither staged bytes nor a published file")
        #expect(listing(doc).isEmpty, "nothing staged or made in the document's folder")
        #expect(listing(outside) == ["moved"], "nothing else written outside")
    }

    /// The same, after the bytes are staged and before they are published:
    /// the rename is resolved beneath the document's folder, so a moved-out
    /// "images" (gone, or swapped for a link out) gets nothing, and the
    /// staging file is removed.
    @Test(.enabled(if: ImageStore.containmentEnforced, needsContainment)) func anImagesFolderMovedOutBeforePublishReceivesNothing() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = d.appendingPathComponent("p.png")
        try Data([9]).write(to: pic)
        let images = doc.appendingPathComponent("images"), moved = outside.appendingPathComponent("moved")
        defer { ImageStore.beforePublish = nil }
        // Moved out, nothing in its place.
        var store = try ImageStore.open(in: doc)
        ImageStore.beforePublish = { try? FileManager.default.moveItem(at: images, to: moved) }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "p.png") }
        #expect(fm.fileExists(atPath: moved.path), "the move happened")
        #expect(listing(moved).isEmpty, "the moved-out folder gets neither staged bytes nor a published file")
        #expect(listing(doc).isEmpty, "the staging file is removed")
        // Moved out and swapped for a link to it.
        try fm.removeItem(at: moved)
        ImageStore.beforePublish = nil
        store = try ImageStore.open(in: doc)
        ImageStore.beforePublish = {
            try? FileManager.default.moveItem(at: images, to: moved)
            try? FileManager.default.createSymbolicLink(at: images, withDestinationURL: moved)
        }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.write(Data([8]), name: "w.png") }
        #expect(isSymlink(images), "the swap happened")
        #expect(listing(moved).isEmpty, "the folder behind the link out gets nothing")
        #expect(listing(doc) == ["images"], "the staging file is removed")
        // Moved out and a new "images" made in its place: refused, and neither folder gets
        // anything (r6: this was published in the new folder, with no link given).
        try fm.removeItem(at: images)
        try fm.removeItem(at: moved)
        ImageStore.beforePublish = nil
        store = try ImageStore.open(in: doc)
        ImageStore.beforePublish = {
            try? FileManager.default.moveItem(at: images, to: moved)
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.write(Data([7]), name: "n.png") }
        #expect(listing(moved).isEmpty, "the moved-out folder gets nothing")
        #expect(listing(images).isEmpty, "the new folder gets nothing")
        #expect(listing(doc) == ["images"], "no staging file is left")
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: "n.png") }
    }

    /// Where the kernel can't keep the open and the rename beneath the
    /// document's folder (macOS 15), the folder-by-folder fallback copies
    /// into a plain "images", missing (made) or already there, with the
    /// exact bytes and name. Runs on every kernel: one without containment
    /// takes the fallback for real, one with it is told to (Derek, 0.6:
    /// this was the refusal test, `noContainment`, before the fallback).
    @Test func withoutKernelContainmentTheFallbackCopiesIntoAPlainImagesFolder() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        try Data([3]).write(to: outside.appendingPathComponent("p.png"))
        if #available(macOS 26, *) {
            #expect(ImageStore.containmentEnforced, "this macOS enforces O_RESOLVE_BENEATH and RENAME_RESOLVE_BENEATH")
        }
        defer { ImageStore.forceFallback = false }
        ImageStore.forceFallback = ImageStore.containmentEnforced
        // "images" missing: made, and the copy lands in it.
        let store = try ImageStore.open(in: doc)
        #expect(!store.kernel, "the fallback path")
        #expect(try store.copy(from: outside.appendingPathComponent("p.png"), name: "p.png") == "p.png")
        #expect(listing(doc) == ["images"], "the images folder is made, nothing is staged beside it")
        #expect(listing(doc.appendingPathComponent("images")) == ["p.png"], "the exact name, no staging file left")
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/p.png").path) == Data([3]), "the exact bytes")
        #expect(try store.link(for: "p.png") == "images/p.png")
        #expect(listing(outside) == ["p.png"], "nothing written outside")
        // "images" already there, with a file in it.
        let again = try ImageStore.open(in: doc)
        let bytes = Data("second picture".utf8)
        #expect(try again.write(bytes, name: "q r.png") == "q r.png")
        #expect(listing(doc.appendingPathComponent("images")) == ["p.png", "q r.png"])
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/q r.png").path) == bytes, "the exact bytes")
        #expect(fm.contents(atPath: doc.appendingPathComponent("images/p.png").path) == Data([3]), "the file already there is untouched")
        #expect(try again.link(for: "q r.png") == "images/q%20r.png")
        #expect(listing(d) == ["doc", "outside"] && listing(outside) == ["p.png"], "nothing written outside")
    }

    /// A store keeps the path it was opened with: one opened on the kernel
    /// path stays on it after the fallback is forced. Both stage in the
    /// held "images" (r6: the kernel path staged in the document's folder
    /// before the handle-based publish; Derek, 0.6: this was the forced
    /// post-open refusal test before the fallback).
    @Test(.enabled(if: ImageStore.containmentEnforced, needsContainment)) func aStoreKeepsThePathItWasOpenedWith() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([3]).write(to: pic)
        defer { ImageStore.forceFallback = false; ImageStore.beforePublish = nil }
        let images = doc.appendingPathComponent("images")
        var stagedIn: [String] = []
        ImageStore.beforePublish = {
            if self.listing(doc).contains(where: { $0.hasPrefix(".cedric-image-") }) { stagedIn.append("doc") }
            if self.listing(images).contains(where: { $0.hasPrefix(".cedric-image-") }) { stagedIn.append("images") }
        }
        let store = try ImageStore.open(in: doc)
        ImageStore.forceFallback = true
        #expect(store.kernel)
        #expect(try store.copy(from: pic, name: "p.png") == "p.png")
        #expect(try store.write(Data([3]), name: "w.png") == "w.png")
        #expect(stagedIn == ["images", "images"], "the kernel path stages in the held images folder: \(stagedIn)")
        let fallback = try ImageStore.open(in: doc)
        #expect(!fallback.kernel)
        #expect(try fallback.write(Data([4]), name: "x.png") == "x.png")
        #expect(stagedIn == ["images", "images", "images"], "the fallback stages in the held images folder: \(stagedIn)")
        #expect(listing(doc) == ["images"] && listing(images) == ["p.png", "w.png", "x.png"], "published, no staging file left")
        #expect(listing(outside) == ["p.png"], "nothing written outside")
    }

    /// The fallback uses only a real "images" folder: a symbolic link, to a
    /// folder outside or inside the document's folder, back to it, or to
    /// nothing, is refused before anything is made or written.
    @Test func theFallbackRefusesASymlinkedImagesFolder() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        defer { ImageStore.forceFallback = false }
        ImageStore.forceFallback = true
        let pic = d.appendingPathComponent("p.png")
        try Data([1, 2, 3]).write(to: pic)
        let images = doc.appendingPathComponent("images")
        // To a folder outside.
        try fm.createSymbolicLink(at: images, withDestinationURL: outside)
        #expect(throws: ImageStore.Failure.imagesIsLink) { _ = try ImageStore.open(in: doc) }
        #expect(listing(outside).isEmpty, "nothing written outside")
        #expect(listing(doc) == ["images"] && isSymlink(images), "the link is left as it was")
        // To a folder inside.
        try fm.removeItem(at: images)
        try fm.createDirectory(at: doc.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: images.path, withDestinationPath: "assets")
        #expect(throws: ImageStore.Failure.imagesIsLink) { _ = try ImageStore.open(in: doc) }
        #expect(listing(doc.appendingPathComponent("assets")).isEmpty, "nothing written in the folder it leads to")
        #expect(listing(doc) == ["assets", "images"])
        // Back to the document's folder itself.
        try fm.removeItem(at: images)
        try fm.createSymbolicLink(atPath: images.path, withDestinationPath: ".")
        #expect(throws: ImageStore.Failure.imagesIsLink) { _ = try ImageStore.open(in: doc) }
        // To nothing: not made through.
        try fm.removeItem(at: images)
        try fm.createSymbolicLink(atPath: images.path, withDestinationPath: "made-through")
        #expect(throws: ImageStore.Failure.imagesIsLink) { _ = try ImageStore.open(in: doc) }
        #expect(listing(doc) == ["assets", "images"], "no folder made through the dangling link")
        // A file named "images" isn't a folder.
        try fm.removeItem(at: images)
        try Data([9]).write(to: images)
        #expect(throws: (any Error).self) { _ = try ImageStore.open(in: doc) }
        #expect(fm.contents(atPath: images.path) == Data([9]), "the file is untouched")
        #expect(listing(d) == ["doc", "outside", "p.png"] && listing(outside).isEmpty, "nothing written anywhere else")
    }

    /// The fallback's race: "images" is swapped after the bytes are staged
    /// in it and before they are published. Swapped for another folder or
    /// for a link out, nothing is published anywhere and the staging file is
    /// removed (r6: it was published in the folder that was opened, now
    /// under another name, with no link given).
    /// Moved out of the document's folder, nothing is published and the
    /// staging file is removed. Swapped right after open, nothing is
    /// staged.
    @Test func theFallbackPublishesOnlyIntoTheOpenedFolderWhenImagesIsSwapped() throws {
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        defer { ImageStore.forceFallback = false; ImageStore.beforePublish = nil; ImageStore.afterOpen = nil }
        ImageStore.forceFallback = true
        let pic = d.appendingPathComponent("p.png")
        try Data([9]).write(to: pic)
        let images = doc.appendingPathComponent("images")
        let was1 = doc.appendingPathComponent("was-images-1"), was2 = doc.appendingPathComponent("was-images-2")
        // Swapped for another folder.
        var store = try ImageStore.open(in: doc)
        ImageStore.beforePublish = {
            try? FileManager.default.moveItem(at: images, to: was1)
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.write(Data([7]), name: "n.png") }
        #expect(listing(was1).isEmpty, "the folder that was opened keeps neither staged bytes nor a file")
        #expect(listing(images).isEmpty, "the new folder gets nothing")
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: "n.png") }
        // Swapped for a link out.
        try fm.removeItem(at: images)
        ImageStore.beforePublish = nil
        try fm.createDirectory(at: images, withIntermediateDirectories: false)
        store = try ImageStore.open(in: doc)
        ImageStore.beforePublish = {
            try? FileManager.default.moveItem(at: images, to: was2)
            try? FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
        }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "p.png") }
        #expect(isSymlink(images), "the swap happened")
        #expect(listing(was2).isEmpty, "the folder that was opened keeps neither staged bytes nor a file")
        #expect(listing(outside).isEmpty, "the folder behind the link out gets nothing")
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: "p.png") }
        // Moved out of the document's folder.
        try fm.removeItem(at: images)
        ImageStore.beforePublish = nil
        try fm.createDirectory(at: images, withIntermediateDirectories: false)
        store = try ImageStore.open(in: doc)
        let moved = outside.appendingPathComponent("moved")
        ImageStore.beforePublish = { try? FileManager.default.moveItem(at: images, to: moved) }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.write(Data([8]), name: "w.png") }
        #expect(fm.fileExists(atPath: moved.path), "the move happened")
        #expect(listing(moved).isEmpty, "the moved-out folder keeps neither staged bytes nor a published file")
        #expect(listing(outside) == ["moved"])
        // Swapped for another folder right after open: nothing is staged.
        try fm.removeItem(at: moved)
        ImageStore.beforePublish = nil
        try fm.createDirectory(at: images, withIntermediateDirectories: false)
        let was3 = doc.appendingPathComponent("was-images-3")
        ImageStore.afterOpen = {
            try? FileManager.default.moveItem(at: images, to: was3)
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        }
        store = try ImageStore.open(in: doc)
        ImageStore.afterOpen = nil
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.write(Data([6]), name: "z.png") }
        #expect(listing(was3).isEmpty && listing(images).isEmpty, "neither folder gets staged bytes or a file")
        #expect(listing(doc) == ["images", "was-images-1", "was-images-2", "was-images-3"], "nothing staged beside them")
        #expect(listing(d) == ["doc", "outside", "p.png"] && listing(outside).isEmpty, "nothing written outside")
    }

    /// A name taken between the free-name check and the rename is never
    /// overwritten (`RENAME_EXCL`): the next free name is used.
    @Test(arguments: storeModes) func aNameTakenJustBeforeTheRenameIsNotOverwritten(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false; ImageStore.beforeRename = nil }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let images = doc.appendingPathComponent("images")
        let store = try ImageStore.open(in: doc)
        var tried: [String] = []
        ImageStore.beforeRename = { name in
            tried.append(name)
            if tried.count == 1 { try? Data("decoy".utf8).write(to: images.appendingPathComponent(name)) }
        }
        #expect(try store.write(Data("mine".utf8), name: "c.png") == "c-2.png")
        #expect(tried == ["c.png", "c-2.png"], "\(tried)")
        #expect(fm.contents(atPath: images.appendingPathComponent("c.png").path) == Data("decoy".utf8), "the file that took the name is untouched")
        #expect(fm.contents(atPath: images.appendingPathComponent("c-2.png").path) == Data("mine".utf8))
        #expect(listing(images) == ["c-2.png", "c.png"] && listing(doc) == ["images"], "no staging file left")
        #expect(listing(outside).isEmpty)
    }

    /// The link handed to the editor is checked against the published file.
    @Test(arguments: storeModes) func aLinkIsGivenOnlyWhileItLeadsToThePublishedFile(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
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

    /// A published name looked up in another spelling of the same name
    /// (case, normalization) is the same file on APFS: the link is given
    /// (identity), where a `String`-keyed record missed it and refused. A
    /// file that isn't the one published under any spelling still gets no
    /// link (Astra batch 17v).
    @Test(arguments: storeModes) func aPublishedNameInAnotherSpellingOfItIsTheSameFile(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
        let (d, doc, _) = try layout()
        defer { try? fm.removeItem(at: d) }
        let store = try ImageStore.open(in: doc)
        let name = try store.write(Data([7]), name: "Caf\u{E9}.png")
        let images = doc.appendingPathComponent("images")
        let other = "CAFE\u{301}.PNG"
        guard Beneath.FileID(path: images.appendingPathComponent(other).path, followLast: false)
                == Beneath.FileID(path: images.appendingPathComponent(name).path, followLast: false) else { return }  // a sensitive volume
        #expect(try store.link(for: name) == MarkdownPaste.imagesPath(name))
        #expect(try store.link(for: other) == MarkdownPaste.imagesPath(other))
        // Replaced by another file: no spelling of it gives a link.
        try fm.removeItem(at: images.appendingPathComponent(name))
        try Data([8]).write(to: images.appendingPathComponent(name))
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: name) }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.link(for: other) }
    }

    /// The publication record keeps two canonically equivalent names (two
    /// files on a volume that keeps names as bytes) as two records: the
    /// second never replaces the first's file, so the first, unchanged, is
    /// still linked, and the second's file under the first's name is not
    /// (Astra batch 17v must 3; APFS can't hold the pair, so the record is
    /// tested on its own).
    @Test func twinNamesKeepTheirOwnPublishedFiles() {
        let nfc = "caf\u{E9}.png", nfd = "cafe\u{301}.png"
        let first = Beneath.FileID(dev: 1, ino: 10), second = Beneath.FileID(dev: 1, ino: 20)
        var p = ImageStore.Publications()
        p.record(nfc, first)
        p.record(nfd, second)
        // Two separate files: each name leads to its own.
        let disk: [FolderTree.PathKey: Beneath.FileID] = [FolderTree.PathKey(nfc): first, FolderTree.PathKey(nfd): second]
        let lookup = { (n: String) in disk[FolderTree.PathKey(n)] }
        #expect(p.isPublished(nfc, here: first, lookup: lookup), "the first, unchanged, under its own name")
        #expect(p.isPublished(nfd, here: second, lookup: lookup))
        #expect(!p.isPublished(nfc, here: second, lookup: lookup), "the second's file moved onto the first's name")
        #expect(!p.isPublished(nfd, here: first, lookup: lookup))
        #expect(!p.isPublished("other.png", here: Beneath.FileID(dev: 1, ino: 30), lookup: lookup))
    }

    /// The document's folder replaced at its path after "images" was pinned.
    @Test(arguments: storeModes) func aReplacedDocumentFolderGivesNoLink(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
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

    /// `name` is one file name, checked before anything is staged. A slash
    /// followed by a combining mark is one Swift character (a text search
    /// for "/" misses it) but Darwin still splits the name at that byte
    /// (Astra batch 5, must-fix 1).
    @Test(arguments: storeModes) func aNameThatIsNotOneFileNameIsRefused(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([3]).write(to: pic)
        let store = try ImageStore.open(in: doc)
        let slashMark = "a/\u{301}b.png", upMark = "../\u{301}p.png"
        #expect(!slashMark.contains(Character("/")) && !upMark.contains(Character("/")), "a Character search misses these slashes")
        for bad in ["", ".", "..", "../p.png", "a/b.png", "/tmp/p.png", "p\0.png", "\0", slashMark, upMark, "/\u{301}"] {
            #expect(throws: ImageStore.Failure.badName, "\(bad.debugDescription)") { _ = try store.copy(from: pic, name: bad) }
            #expect(throws: ImageStore.Failure.badName, "\(bad.debugDescription)") { _ = try store.write(Data([3]), name: bad) }
        }
        #expect(listing(doc.appendingPathComponent("images")).isEmpty, "nothing staged or published")
        #expect(listing(doc) == ["images"], "nothing staged in the document's folder")
        #expect(listing(d) == ["doc", "outside"] && listing(outside) == ["p.png"], "nothing written beside the folders")
    }

    @Test(arguments: storeModes) func aSourceSymlinkIsCopiedAsItsBytes(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
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

    @Test(arguments: storeModes) func foldersAndPipesAreNotCopied(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
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

    /// An "images" on another volume than the document's folder (forced
    /// here; a separate mount in use) is reported before anything is
    /// staged: no staging file is made or filled.
    @Test(arguments: storeModes) func anImagesFolderOnAnotherVolumeIsReportedBeforeStaging(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([3]).write(to: pic)
        let store = try ImageStore.open(in: doc)
        defer { ImageStore.forceOtherVolume = false }
        ImageStore.forceOtherVolume = true
        #expect(throws: ImageStore.Failure.otherVolume) { _ = try store.copy(from: pic, name: "p.png") }
        #expect(throws: ImageStore.Failure.otherVolume) { _ = try store.write(Data([3]), name: "w.png") }
        #expect(listing(doc) == ["images"] && listing(doc.appendingPathComponent("images")).isEmpty, "nothing staged or published")
        // The same store works once they are on one volume.
        ImageStore.forceOtherVolume = false
        #expect(try store.write(Data([3]), name: "w.png") == "w.png")
    }

    @Test(arguments: storeModes) func aFailedPublishLeavesNoStagingFile(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([7]).write(to: pic)
        let store = try ImageStore.open(in: doc)
        let tooLong = String(repeating: "n", count: 300) + ".png"
        #expect(throws: (any Error).self) { _ = try store.copy(from: pic, name: tooLong) }
        #expect(listing(doc.appendingPathComponent("images")).isEmpty, "the staging file is removed")
        #expect(listing(doc) == ["images"], "and none is left in the document's folder")
    }
    /// iOS: the document's folder is looked up beneath the grant, so a
    /// document folder that is a link out of the grant is refused, and a
    /// picked source that is a symbolic link is refused when links aren't
    /// followed (Sol review, 0.6.0).
    @Test func openBeneathRefusesAFolderLinkOutAndNoFollowRefusesALinkedSource() throws {
        let (root, doc, outside) = try layout()
        defer { try? fm.removeItem(at: root) }
        let grant = root.resolvingSymlinksInPath()
        // doc/ is in the grant: opened, and a copy lands there.
        let pic = outside.appendingPathComponent("p.png")
        try Data([1, 2, 3]).write(to: pic)
        let store = try ImageStore.open(in: doc.resolvingSymlinksInPath(), beneath: grant)
        #expect(try store.copy(from: pic, name: "p.png", followLink: false) == "p.png")
        // A linked document folder that leads out of the grant.
        let linked = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        #expect(throws: ImageStore.Failure.outside) { _ = try ImageStore.open(in: grant.appendingPathComponent("linked"), beneath: grant) }
        #expect(throws: ImageStore.Failure.outside) { _ = try ImageStore.open(in: outside.resolvingSymlinksInPath(), beneath: doc.resolvingSymlinksInPath()) }
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("images").path), "nothing made outside the grant")
        // A picked source that is a link: refused without following, copied with.
        let link = root.appendingPathComponent("link.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: pic)
        #expect(throws: ImageStore.Failure.notRegularFile) { _ = try store.copy(from: link, name: "l.png", followLink: false) }
        #expect(try store.copy(from: link, name: "l.png") == "l.png")
    }

    /// iOS: the grant itself replaced, by a symbolic link to another folder
    /// or by another folder renamed into its place, is refused: the root is
    /// opened without following a final link and checked against the
    /// folder as it was granted (Sol round 2, must-fix 3).
    @Test func openBeneathRefusesAReplacedRoot() throws {
        let (top, _, outside) = try layout()
        defer { try? fm.removeItem(at: top) }
        let grant = top.resolvingSymlinksInPath().appendingPathComponent("grant")
        try fm.createDirectory(at: grant.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let id = try #require(Beneath.FileID(path: grant.path, followLast: false))
        _ = try ImageStore.open(in: grant.appendingPathComponent("sub"), beneath: grant, rootID: id)
        // Renamed away, and another folder in its place.
        try fm.moveItem(at: grant, to: top.appendingPathComponent("was-grant"))
        try fm.createDirectory(at: grant.appendingPathComponent("sub"), withIntermediateDirectories: true)
        #expect(throws: ImageStore.Failure.outside) { _ = try ImageStore.open(in: grant.appendingPathComponent("sub"), beneath: grant, rootID: id) }
        #expect(!fm.fileExists(atPath: grant.appendingPathComponent("sub/images").path))
        // A symbolic link in its place: refused even with no identity to check.
        try fm.removeItem(at: grant)
        try fm.createSymbolicLink(at: grant, withDestinationURL: outside)
        #expect(throws: ImageStore.Failure.outside) { _ = try ImageStore.open(in: grant.appendingPathComponent("sub"), beneath: grant) }
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("sub/images").path))
    }

    /// iOS (Astra round 4, must-fix 2): the document's folder, opened
    /// beneath the grant, moved out of the grant (to a sibling on the same
    /// volume) while a copy is going on: nothing is published there, the
    /// staged file is removed, and the copy throws. The grant stays held
    /// and the folder is looked up beneath it again before publishing.
    @Test(arguments: storeModes) func aDocumentFolderMovedOutOfTheGrantBeforePublishReceivesNothing(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false; ImageStore.beforePublish = nil }
        let (top, _, outside) = try layout()
        defer { try? fm.removeItem(at: top) }
        let grant = top.resolvingSymlinksInPath().appendingPathComponent("grant")
        let sub = grant.appendingPathComponent("sub"), moved = top.resolvingSymlinksInPath().appendingPathComponent("moved")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let pic = outside.appendingPathComponent("p.png")
        try Data([4, 5, 6]).write(to: pic)
        let id = try #require(Beneath.FileID(path: grant.path, followLast: false))
        // The control: left alone, it publishes.
        let kept = try ImageStore.open(in: sub, beneath: grant, rootID: id)
        #expect(try kept.copy(from: pic, name: "p.png", followLink: false) == "p.png")
        #expect(try kept.link(for: "p.png") == "images/p.png")
        // Moved out of the grant between the open and the publish.
        let store = try ImageStore.open(in: sub, beneath: grant, rootID: id)
        ImageStore.beforePublish = { try? FileManager.default.moveItem(at: sub, to: moved) }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "q.png", followLink: false) }
        ImageStore.beforePublish = nil
        #expect(fm.fileExists(atPath: moved.path), "the move happened")
        #expect(listing(moved.appendingPathComponent("images")) == ["p.png"], "\(mode): nothing published in the moved folder")
        #expect(listing(moved) == ["images"], "\(mode): no staging file left in the moved folder")
        #expect(listing(grant).isEmpty, "nothing made in the grant in its place")
    }

    // MARK: r6 fault injection (handle-based publishing)

    /// The staging names in `u`.
    func staged(_ u: URL) -> [String] { listing(u).filter { $0.hasPrefix(".cedric-image-") } }

    /// The POSIX code `body` throws (nil: none thrown; -1: another error).
    func posixCode(_ body: () throws -> Any) -> Int? {
        do { _ = try body(); return nil } catch {
            let e = error as NSError
            return e.domain == NSPOSIXErrorDomain ? e.code : -1
        }
    }

    /// A staging file found in `dirs` replaced (renamed over) by another
    /// writer's file holding `bytes`: a new file, not ours. Returns its URL.
    func replaceStaged(in dirs: [URL], with bytes: Data) -> URL? {
        for dir in dirs {
            guard let name = staged(dir).first else { continue }
            let theirs = dir.appendingPathComponent("theirs.part"), at = dir.appendingPathComponent(name)
            guard (try? bytes.write(to: theirs)) != nil, rename(theirs.path, at.path) == 0 else { return nil }
            return at
        }
        return nil
    }

    /// A grant with sub/ in it (both resolved), and where sub/ is moved out to.
    func grantLayout() throws -> (top: URL, grant: URL, sub: URL, moved: URL, outside: URL, id: Beneath.FileID) {
        let (top, _, outside) = try layout()
        let base = top.resolvingSymlinksInPath()
        let grant = base.appendingPathComponent("grant")
        let sub = grant.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let id = try #require(Beneath.FileID(path: grant.path, followLast: false))
        return (top, grant, sub, base.appendingPathComponent("moved"), outside, id)
    }

    /// r6 a (Astra/Sol r5 must-fix 1): the first candidate is taken
    /// (EEXIST) and the document's folder moves out of the grant before the
    /// retry: the retry publishes nothing in the moved folder, and the copy
    /// throws.
    @Test(arguments: storeModes) func aDocumentFolderMovedOutOfTheGrantDuringANameRetryReceivesNothing(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false; ImageStore.beforeRename = nil }
        let (top, grant, sub, moved, outside, id) = try grantLayout()
        defer { try? fm.removeItem(at: top) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([4, 5, 6]).write(to: pic)
        let store = try ImageStore.open(in: sub, beneath: grant, rootID: id)
        let decoy = Data("decoy".utf8)
        var tried: [String] = []
        ImageStore.beforeRename = { name in
            tried.append(name)
            if tried.count == 1 { try? decoy.write(to: sub.appendingPathComponent("images").appendingPathComponent(name)) }
            if tried.count == 2 { try? FileManager.default.moveItem(at: sub, to: moved) }
        }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "c.png", followLink: false) }
        ImageStore.beforeRename = nil
        #expect(tried == ["c.png", "c-2.png"], "\(mode): a retry after EEXIST: \(tried)")
        #expect(fm.fileExists(atPath: moved.path), "the move happened")
        #expect(listing(moved.appendingPathComponent("images")) == ["c.png"], "\(mode): nothing published in the moved folder")
        #expect(fm.contents(atPath: moved.appendingPathComponent("images/c.png").path) == decoy, "the file that took the name is untouched")
        #expect(listing(moved) == ["images"], "\(mode): no staging file left in the moved folder")
        #expect(listing(grant).isEmpty, "nothing made in the grant in its place")
    }

    /// r6 b: "images" renamed away after the check and replaced, by another
    /// folder or by a link out: nothing lands in the replacement or behind
    /// the link, the renamed original keeps nothing, and the copy throws.
    @Test(arguments: storeModes) func anImagesFolderSwappedAfterTheCheckReceivesNothing(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false; ImageStore.beforePublish = nil }
        for byLink in [false, true] {
            let (d, doc, outside) = try layout()
            defer { try? fm.removeItem(at: d) }
            let pic = d.appendingPathComponent("p.png")
            try Data([9]).write(to: pic)
            let images = doc.appendingPathComponent("images"), was = doc.appendingPathComponent("was-images")
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            let store = try ImageStore.open(in: doc)
            ImageStore.beforePublish = {
                try? FileManager.default.moveItem(at: images, to: was)
                if byLink { try? FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside) }
                else { try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: false) }
            }
            let what = "\(mode), \(byLink ? "a link out" : "another folder")"
            #expect(throws: ImageStore.Failure.destinationChanged, "\(what)") { _ = try store.copy(from: pic, name: "p.png") }
            ImageStore.beforePublish = nil
            #expect(byLink ? isSymlink(images) : !isSymlink(images) && fm.fileExists(atPath: images.path), "\(what): the swap happened")
            if !byLink { #expect(listing(images).isEmpty, "\(what): nothing lands in the replacement") }
            #expect(listing(outside).isEmpty, "\(what): nothing behind the link")
            #expect(listing(was).isEmpty, "\(what): the renamed original keeps neither staged bytes nor a file")
            #expect(listing(doc) == ["images", "was-images"], "\(what): no staging file beside them")
        }
    }

    /// r6 c (Astra r5 must-fix 2): the staging entry replaced by another
    /// writer, then the copy refused (the document's folder moved out of
    /// the grant): the other writer's file survives byte for byte, the copy
    /// throws, and the entry is left and reported, not removed.
    @Test(arguments: storeModes) func aStagingEntryReplacedByAnotherWriterSurvivesARefusal(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false; ImageStore.beforePublish = nil; ImageStore.leftBehind = nil }
        let (top, grant, sub, moved, outside, id) = try grantLayout()
        defer { try? fm.removeItem(at: top) }
        let pic = outside.appendingPathComponent("p.png")
        try Data([4, 5, 6]).write(to: pic)
        let store = try ImageStore.open(in: sub, beneath: grant, rootID: id)
        let theirs = Data("another writer's file".utf8)
        var replaced: URL?
        var left: [String] = []
        ImageStore.leftBehind = { left.append($0) }
        ImageStore.beforePublish = {
            replaced = self.replaceStaged(in: [sub, sub.appendingPathComponent("images")], with: theirs)
            try? FileManager.default.moveItem(at: sub, to: moved)
        }
        #expect(throws: ImageStore.Failure.destinationChanged) { _ = try store.copy(from: pic, name: "q.png", followLink: false) }
        ImageStore.beforePublish = nil
        let at = try #require(replaced, "the staging entry was found and replaced")
        let rel = Array(at.pathComponents.dropFirst(sub.pathComponents.count))
        let now = rel.reduce(moved) { $0.appendingPathComponent($1) }
        #expect(fm.contents(atPath: now.path) == theirs, "\(mode): the other writer's file survives byte for byte")
        #expect(left == [at.lastPathComponent], "\(mode): the entry is left and reported: \(left)")
        #expect(!listing(moved.appendingPathComponent("images")).contains("q.png"), "\(mode): nothing published")
        #expect(listing(grant).isEmpty)
    }

    /// r6 d: the write fails partway (ENOSPC, EIO): the copy throws that
    /// error, nothing is published under any name, and the staging file is
    /// removed only while it is still the file made (replaced, it is left
    /// and reported).
    @Test(arguments: storeModes) func aFailedWriteMidCopyPublishesNothing(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false; ImageStore.writeFault = nil; ImageStore.leftBehind = nil }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let pic = outside.appendingPathComponent("p.png")
        try Data(repeating: 3, count: 64 * 1024).write(to: pic)
        let images = doc.appendingPathComponent("images")
        let store = try ImageStore.open(in: doc)
        var left: [String] = []
        ImageStore.leftBehind = { left.append($0) }
        // Out of space partway: a partial staging file, ours.
        ImageStore.writeFault = { fd in _ = ftruncate(fd, 100); return ENOSPC }
        #expect(posixCode { try store.copy(from: pic, name: "p.png") } == Int(ENOSPC), "\(mode): the write's error")
        #expect(listing(images).isEmpty && listing(doc) == ["images"], "\(mode): nothing published, the staging file removed")
        #expect(left.isEmpty)
        // An I/O error, with the staging entry replaced by another writer meanwhile.
        let theirs = Data("another writer's file".utf8)
        var replaced: URL?
        ImageStore.writeFault = { _ in
            replaced = self.replaceStaged(in: [doc, images], with: theirs)
            return EIO
        }
        #expect(posixCode { try store.copy(from: pic, name: "p.png") } == Int(EIO), "\(mode): the write's error")
        let at = try #require(replaced, "the staging entry was found and replaced")
        #expect(fm.contents(atPath: at.path) == theirs, "\(mode): the other writer's file survives byte for byte")
        #expect(left == [at.lastPathComponent], "\(mode): the entry is left and reported: \(left)")
        #expect(listing(images).allSatisfy { $0.hasPrefix(".cedric-image-") }, "\(mode): nothing published under any name: \(listing(images))")
        // The same store still works afterwards.
        ImageStore.writeFault = nil
        #expect(try store.copy(from: pic, name: "p.png") == "p.png")
        #expect(fm.contents(atPath: images.appendingPathComponent("p.png").path) == fm.contents(atPath: pic.path))
    }

    /// r6: the staging file is made 0600, but a published image has the
    /// mode any new file gets here (as a plain write gives), as before.
    @Test(arguments: storeModes) func aPublishedImageHasTheUsualFileMode(mode: StoreMode) throws {
        use(mode)
        defer { ImageStore.forceFallback = false }
        let (d, doc, outside) = try layout()
        defer { try? fm.removeItem(at: d) }
        let plain = outside.appendingPathComponent("plain.png")
        try Data([1]).write(to: plain)
        let name = try ImageStore.open(in: doc).copy(from: plain, name: "p.png")
        func perms(_ u: URL) -> Int? { (try? fm.attributesOfItem(atPath: u.path)[.posixPermissions]) as? Int }
        let want = try #require(perms(plain))
        #expect(perms(doc.appendingPathComponent("images").appendingPathComponent(name)) == want, "\(mode): \(String(want, radix: 8))")
    }

    // MARK: r7 (Astra r6): the mode

    #if os(macOS)
    /// r7 c (Astra r6 must-fix 3): a published image has the mode a new
    /// file made 0666 gets under the umask at the time, never wider: 0600
    /// under 077, 0644 under 022, under 077 still with no file descriptor to
    /// spare (a probe file couldn't be made), and 0600 after the umask is
    /// narrowed between two copies.
    /// Each runs in its own process (an exit test), so no other test sees
    /// the umask.
    @Test func aPublishedImageIsNeverWiderThanTheUmaskGives() async throws {
        let runs: [(String, ExitTest.Result?)] = [
            ("077", await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
                publishedModeExit(umask: 0o077, starved: false, thenUmask: 0)
            }),
            ("022", await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
                publishedModeExit(umask: 0o022, starved: false, thenUmask: 0)
            }),
            ("077, no descriptor to spare", await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
                publishedModeExit(umask: 0o077, starved: true, thenUmask: 0)
            }),
            ("022 then 077", await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
                publishedModeExit(umask: 0o022, starved: false, thenUmask: 0o077)
            }),
        ]
        for (label, result) in runs {
            let r = try #require(result, "umask \(label): the process didn't exit 0")
            let said = String(decoding: r.standardErrorContent, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("r7 mode: ") && $0 != "r7 mode: done" }
            #expect(said.isEmpty, "umask \(label): \(said.joined(separator: "; "))")
            if said.isEmpty { #expect(String(decoding: r.standardErrorContent, as: UTF8.self).contains("r7 mode: done"), "umask \(label): the check ran") }
        }
    }
    #endif
}

#if os(macOS)
/// r7 c, in an exit test's own process: under `umask`, a copy is published
/// with the mode a new 0666 file gets. `starved`: the copy runs with no file
/// descriptor to spare beyond the ones it needs itself (the fewest that let
/// it succeed), so nothing else, like a probe file in a temporary folder,
/// can be made meanwhile (TMPDIR can't stand in a missing temporary folder:
/// NSTemporaryDirectory doesn't read it here). `thenUmask` non-zero: a
/// second copy under that umask. Exits 0 either way (a failed exit test
/// returns no output); what was wrong goes to stderr as an "r7 mode: "
/// line, and "r7 mode: done" when all held.
func publishedModeExit(umask mask: mode_t, starved: Bool, thenUmask later: mode_t) -> Never {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data(("r7 mode: " + s + "\n").utf8)); exit(0) }
    let base = FileManager.default.temporaryDirectory.path
    umask(mask)
    var template = Array((base + "/cedric-r7-mode.XXXXXX").utf8CString)
    guard let made = mkdtemp(&template) else { fail("mkdtemp \(errno)") }
    let doc = URL(fileURLWithPath: String(cString: made))
    func check(_ m: mode_t, _ got: String) {
        var st = stat()
        guard lstat(doc.appendingPathComponent("images").appendingPathComponent(got).path, &st) == 0 else { fail("no \(got)") }
        let want = 0o666 & ~m
        if st.st_mode & 0o777 != want {
            fail("umask \(String(m, radix: 8)): \(got) is \(String(st.st_mode & 0o777, radix: 8)), want \(String(want, radix: 8))")
        }
    }
    do {
        let store = try ImageStore.open(in: doc)
        if starved {
            var lim = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { fail("getrlimit") }
            lim.rlim_cur = 256
            guard setrlimit(RLIMIT_NOFILE, &lim) == 0 else { fail("setrlimit \(errno)") }
            var spare: [Int32] = []
            while true { let f = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC); if f < 0 { break }; spare.append(f) }
            guard errno == EMFILE, !spare.isEmpty else { fail("descriptors not exhausted: \(errno)") }
            var got: String?
            var freed = 0
            while got == nil, freed < 8, let f = spare.popLast() {
                close(f); freed += 1
                got = try? store.write(Data([1, 2, 3]), name: "a.png")
            }
            spare.forEach { close($0) }
            guard let got else { fail("no copy with \(freed) descriptors free") }
            FileHandle.standardError.write(Data("r7 info: published with \(freed) descriptor(s) free\n".utf8))
            check(mask, got)
        } else {
            check(mask, try store.write(Data([1, 2, 3]), name: "a.png"))
        }
        if later != 0 { umask(later); check(later, try store.write(Data([4]), name: "b.png")) }
    } catch { fail("umask \(String(mask, radix: 8)): \(error)") }
    try? FileManager.default.removeItem(at: doc)
    FileHandle.standardError.write(Data("r7 mode: done\n".utf8))
    exit(0)
}
#endif
