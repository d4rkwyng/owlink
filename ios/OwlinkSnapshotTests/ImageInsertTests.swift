import XCTest
import UIKit
import CedricCore

/// The Context Bar's Image button (0.6.0): picked images are copied into
/// "images" next to the document (ImageStore) and relative links go in as
/// one undo step.
@MainActor
final class ImageInsertTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var dirs: [URL] = []

    override func tearDown() async throws {
        EditorViewController.imageContainerForTests = nil
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private func editor(_ text: String = "# Notes\n\n") throws -> (EditorViewController, URL) {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("notes.md")
        try Data(text.utf8).write(to: url)
        let doc = TextDocument(fileURL: url)
        doc.text = text
        doc.language = .forFile(named: "notes.md", content: text)
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return (editor, dir)
    }

    private func png(named name: String) throws -> URL {
        let d = try tempDir()
        let url = d.appendingPathComponent(name)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    func testPickedImageIsCopiedAndLinkedAsOneUndo() async throws {
        let (e, dir) = try editor()
        let source = try png(named: "my shot.png")
        e.textView.selectedRange = NSRange(location: (e.textView.text as NSString).length, length: 0)
        let pathsResult = await e.insertImageFiles([source])
        let paths = try XCTUnwrap(pathsResult)
        XCTAssertEqual(paths, ["images/my%20shot.png"])
        XCTAssertTrue(e.textView.text.hasSuffix("![](images/my%20shot.png)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/my shot.png").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("images/my shot.png")), try Data(contentsOf: source))
        // The same name again: never overwritten, the next free name.
        let againResult = await e.insertImageFiles([source])
        let again = try XCTUnwrap(againResult)
        XCTAssertEqual(again, ["images/my%20shot-2.png"])
        e.textView.undoManager?.undo()
        e.textView.undoManager?.undo()
        XCTAssertEqual(e.textView.text, "# Notes\n\n")
    }

    func testOnlyImagesAndOnlyMarkdown() async throws {
        let (e, dir) = try editor()
        let d = try tempDir()
        let text = d.appendingPathComponent("readme.txt")
        try Data("x".utf8).write(to: text)
        let none = await e.insertImageFiles([text])
        XCTAssertNil(none)
        XCTAssertEqual(e.textView.text, "# Notes\n\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images").path))
        e.setLanguage(.plain)
        let plain = await e.insertImageFiles([try png(named: "a.png")])
        XCTAssertNil(plain, "not in plain text")
    }

    func testContextBarImageButtonOffersPhotosFilesAndLink() throws {
        let (e, _) = try editor()
        let old = AppSettings.showContextBar
        defer { AppSettings.showContextBar = old }
        AppSettings.showContextBar = true
        e.updateContextBar()
        let bar = try XCTUnwrap(e.contextBar)
        let button = try XCTUnwrap(bar.buttons["image"])
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        let ids = (button.menu?.children ?? []).flatMap { ($0 as? UIMenu)?.children ?? [$0] }
            .compactMap { ($0 as? UIAction)?.accessibilityIdentifier }
        XCTAssertEqual(ids, ["contextbar.image.photos", "contextbar.image.files", "contextbar.image.link"])
        XCTAssertTrue(e.canPerformAction(#selector(EditorViewController.markdownInsertImageFileMenu(_:)), withSender: nil))
    }

    func testPhotoNames() {
        XCTAssertEqual(EditorViewController.photoName(suggested: "IMG_0001", index: 0), "IMG_0001")
        let fallback = EditorViewController.photoName(suggested: "../x/y", index: 2, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(fallback.hasPrefix("photo-"))
        XCTAssertTrue(fallback.hasSuffix("-3"))
        XCTAssertFalse(fallback.contains("/"))
        XCTAssertTrue(EditorViewController.photoName(suggested: "  ", index: 0).hasPrefix("photo-"))
    }
    /// The document's folder reached through a symbolic link that leads out
    /// of the folder Owlink may write in: refused, nothing written there
    /// (the grant is checked against the resolved path, and the folder
    /// opened beneath it).
    func testDocumentFolderLinkedOutOfTheGrantIsRefused() throws {
        let grant = try tempDir()
        let outside = try tempDir()
        let linked = grant.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertNil(EditorViewController.imageDestination(for: linked, granted: grant, container: try tempDir()),
                     "a folder that resolves outside the grant has no destination")
        let inside = grant.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let dest = try XCTUnwrap(EditorViewController.imageDestination(for: inside, granted: grant, container: try tempDir()))
        XCTAssertEqual(dest.root, grant.resolvingSymlinksInPath().standardizedFileURL)
        // The folder looked up beneath the grant: a link on the way out is refused even when asked directly.
        let copies = EditorViewController.copyImages([try png(named: "a.png")],
                                                     to: (folder: dest.root.appendingPathComponent("linked"), root: dest.root))
        XCTAssertEqual(copies.error, EditorViewController.imageStoreMessage(.outside))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("images").path))
    }

    /// The editor starts closing while the copy runs off the main thread:
    /// no link goes into the closing editor (Sol round 2, should-fix 5).
    func testNoLinkGoesInOnceTheEditorIsClosing() async throws {
        let (e, _) = try editor()
        let source = try png(named: "late.png")
        let opened = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        ImageStore.afterOpen = { opened.signal(); _ = proceed.wait(timeout: .now() + 10) }
        defer { ImageStore.afterOpen = nil }
        let insert = Task { await e.insertImageFiles([source]) }
        // The copy has started (its folder is open) before the close.
        while opened.wait(timeout: .now()) == .timedOut { await Task.yield() }
        e.closeDocument()
        proceed.signal()
        let paths = await insert.value
        XCTAssertNil(paths)
        XCTAssertEqual(e.textView.text, "# Notes\n\n")
    }

    /// The granted folder itself replaced by a symbolic link to another
    /// folder after the destination was worked out: refused, nothing written
    /// in the folder the link leads to (Sol round 2, must-fix 3).
    func testGrantReplacedByALinkIsRefused() throws {
        let grant = try tempDir()
        let other = try tempDir()
        try FileManager.default.createDirectory(at: grant.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let dest = try XCTUnwrap(EditorViewController.imageDestination(for: grant.appendingPathComponent("sub"), granted: grant,
                                                                       container: try tempDir()))
        let moved = grant.deletingLastPathComponent().appendingPathComponent(grant.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: grant, to: moved)
        dirs.append(moved)
        try FileManager.default.createSymbolicLink(at: grant, withDestinationURL: other)
        let copies = EditorViewController.copyImages([try png(named: "a.png")], to: dest)
        XCTAssertEqual(copies.error, EditorViewController.imageStoreMessage(.outside))
        XCTAssertTrue(copies.names.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("sub/images").path))
    }

    /// A picked file that is a symbolic link (to an image or anything else)
    /// is not followed: it isn't copied.
    func testSymlinkedSourceImageIsNotCopied() async throws {
        let (e, dir) = try editor()
        let real = try png(named: "real.png")
        let link = try tempDir().appendingPathComponent("shot.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let paths = await e.insertImageFiles([link])
        XCTAssertNil(paths)
        XCTAssertEqual(e.textView.text, "# Notes\n\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/shot.png").path))
        dismissAlerts(e)
    }

    /// Photos with the same suggested name are staged apart, and both go in.
    func testIdenticalPhotoNamesAreStagedApart() async throws {
        let (e, dir) = try editor()
        let staging = StagedImages(in: try tempDir())
        let source = try png(named: "x.png")
        var staged: [URL] = []
        for i in 0..<2 {
            let url = try XCTUnwrap(EditorViewController.stagedPhotoURL(in: staging.dir, index: i, name: "IMG_0001", ext: "png"))
            try FileManager.default.copyItem(at: source, to: url)
            staged.append(url)
        }
        XCTAssertNotEqual(staged[0], staged[1])
        XCTAssertTrue(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let pathsResult = await e.insertImageFiles(staged, staging: staging)
        let paths = try XCTUnwrap(pathsResult)
        XCTAssertEqual(paths, ["images/IMG_0001.png", "images/IMG_0001-2.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/IMG_0001-2.png").path))
    }

    /// No folder access yet: the insertion waits for the grant and keeps
    /// its staged photos until it goes in; a cancelled grant removes them.
    func testStagedPhotosSurviveTheFolderGrant() async throws {
        let (e, dir) = try editor()
        let parent = try tempDir()
        var staging: StagedImages? = StagedImages(in: parent)
        let stagedDir = try XCTUnwrap(staging?.dir)
        let photo = try XCTUnwrap(EditorViewController.stagedPhotoURL(in: stagedDir, index: 0, name: "IMG_0002", ext: "png"))
        try FileManager.default.copyItem(at: try png(named: "y.png"), to: photo)
        // As if the document's folder weren't writable: the grant is asked for.
        EditorViewController.imageContainerForTests = try tempDir()
        let first = await e.insertImageFiles([photo], staging: staging)
        staging = nil
        XCTAssertNil(first)
        XCTAssertNotNil(e.imagePickerDelegate.pendingInsert)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "still staged while the grant is asked for")
        // Granted (here: the container now holds the folder): it goes in, then the staging goes.
        EditorViewController.imageContainerForTests = nil
        dismissAlerts(e)
        let pathsResult = await e.resumePendingImageInsert()
        let paths = try XCTUnwrap(pathsResult)
        XCTAssertEqual(paths, ["images/IMG_0002.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/IMG_0002.png").path))
        XCTAssertNil(e.imagePickerDelegate.pendingInsert)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDir.path), "removed once inserted")

        // Cancelled: the staging is removed, nothing inserted.
        var other: StagedImages? = StagedImages(in: parent)
        let otherDir = try XCTUnwrap(other?.dir)
        let photo2 = try XCTUnwrap(EditorViewController.stagedPhotoURL(in: otherDir, index: 0, name: "IMG_0003", ext: "png"))
        try FileManager.default.copyItem(at: try png(named: "z.png"), to: photo2)
        EditorViewController.imageContainerForTests = try tempDir()
        _ = await e.insertImageFiles([photo2], staging: other)
        other = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo2.path))
        e.imagePickerDelegate.pendingInsert = nil   // what the alert's Cancel does
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherDir.path), "removed when the grant is cancelled")
        dismissAlerts(e)
    }

    private func dismissAlerts(_ e: EditorViewController) {
        e.presentedViewController?.dismiss(animated: false)
    }
}
