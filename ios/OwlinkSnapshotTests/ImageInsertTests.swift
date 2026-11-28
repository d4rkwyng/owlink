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

    func testPickedImageIsCopiedAndLinkedAsOneUndo() throws {
        let (e, dir) = try editor()
        let source = try png(named: "my shot.png")
        e.textView.selectedRange = NSRange(location: (e.textView.text as NSString).length, length: 0)
        let paths = try XCTUnwrap(e.insertImageFiles([source]))
        XCTAssertEqual(paths, ["images/my%20shot.png"])
        XCTAssertTrue(e.textView.text.hasSuffix("![](images/my%20shot.png)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/my shot.png").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("images/my shot.png")), try Data(contentsOf: source))
        // The same name again: never overwritten, the next free name.
        let again = try XCTUnwrap(e.insertImageFiles([source]))
        XCTAssertEqual(again, ["images/my%20shot-2.png"])
        e.textView.undoManager?.undo()
        e.textView.undoManager?.undo()
        XCTAssertEqual(e.textView.text, "# Notes\n\n")
    }

    func testOnlyImagesAndOnlyMarkdown() throws {
        let (e, dir) = try editor()
        let d = try tempDir()
        let text = d.appendingPathComponent("readme.txt")
        try Data("x".utf8).write(to: text)
        XCTAssertNil(e.insertImageFiles([text]))
        XCTAssertEqual(e.textView.text, "# Notes\n\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images").path))
        e.setLanguage(.plain)
        XCTAssertNil(e.insertImageFiles([try png(named: "a.png")]), "not in plain text")
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
}
