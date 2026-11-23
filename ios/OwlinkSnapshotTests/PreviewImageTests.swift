import XCTest
import CedricCore

@MainActor
final class PreviewImageTests: XCTestCase {
    func testPreviewFilesFindsVaultImageAndRejectsEscapes() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("preview-images-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appendingPathComponent("vault", isDirectory: true)
        let folder = root.appendingPathComponent("notes", isDirectory: true)
        let images = root.appendingPathComponent("Images", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let image = images.appendingPathComponent("logo.webp")
        try Data([1, 2, 3]).write(to: image)
        let outside = temp.appendingPathComponent("outside.webp")
        try Data([4]).write(to: outside)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("escape.webp"), withDestinationURL: outside)

        let vault = WikiVault(documentFolder: folder, openedRoot: root)
        let files = PreviewFiles()
        files.folder = folder
        files.openedRoot = root
        files.vaultRoot = root
        files.vault = vault
        let page = try XCTUnwrap(PreviewFolder.pageURL(for: folder))
        let bare = try XCTUnwrap(URL(string: "logo.webp", relativeTo: page)?.absoluteURL)
        let escape = try XCTUnwrap(URL(string: "escape.webp", relativeTo: page)?.absoluteURL)
        let outsideURL = try XCTUnwrap(PreviewFolder.pageURL(forFile: outside))
        XCTAssertTrue(files.vault === vault)
        XCTAssertFalse(vault.indexIsFresh)
        XCTAssertEqual(files.file(for: bare)?.path, image.path)
        XCTAssertTrue(vault.indexIsFresh)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.file(for: bare))), Data([1, 2, 3]))
        XCTAssertNil(files.file(for: escape))
        XCTAssertNil(files.file(for: outsideURL))
        XCTAssertFalse(PreviewImageAccess.readable("../outside.webp", folder: folder, openedRoot: root, vault: vault))
    }

    /// A folder grant holding several Obsidian vaults (iCloud Drive ›
    /// Obsidian): the preview's vault is the document's own, so its
    /// `.obsidian/app.json` attachment folder is used and the scheme
    /// handler serves that image.
    func testGrantAboveTheVaultUsesTheVaultsAttachmentFolder() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("preview-grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let grant = temp.appendingPathComponent("Obsidian", isDirectory: true)
        let a = grant.appendingPathComponent("A", isDirectory: true)
        let folder = a.appendingPathComponent("notes", isDirectory: true)
        for dir in [folder, a.appendingPathComponent(".obsidian"), a.appendingPathComponent("Attach/deep"),
                    grant.appendingPathComponent("B/.obsidian")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(#"{"attachmentFolderPath":"Attach"}"#.utf8).write(to: a.appendingPathComponent(".obsidian/app.json"))
        let wanted = a.appendingPathComponent("Attach/deep/pic.webp")
        try Data([1]).write(to: wanted)
        try Data([2]).write(to: grant.appendingPathComponent("B/pic.webp"))

        let vault = PreviewController.vault(for: folder, granted: grant)
        XCTAssertEqual(vault.root.standardizedFileURL.path, a.standardizedFileURL.path)
        let files = PreviewFiles()
        files.folder = folder
        files.openedRoot = grant
        files.vaultRoot = vault.root
        files.vault = vault
        let page = try XCTUnwrap(PreviewFolder.pageURL(for: folder))
        let bare = try XCTUnwrap(URL(string: "pic.webp", relativeTo: page)?.absoluteURL)
        XCTAssertEqual(files.file(for: bare)?.path, wanted.path)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.file(for: bare))), Data([1]))
        let html = Markdown.render("![[pic.webp]]", options: .preview(vault: vault))
        XCTAssertTrue(html.contains("Attach/deep/pic.webp"), html)
    }
}
