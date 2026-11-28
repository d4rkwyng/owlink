import XCTest
import UIKit
import CedricCore

/// Not valid UTF-8: the guessed 8-bit encoding is said in a notice with
/// Reopen with Encoding… and Keep, as the Mac's encoding bar (0.5.4).
@MainActor
final class EncodingNoticeTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
    }

    private func editor(bytes: Data, name: String = "old.txt") throws -> EditorViewController {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let doc = TextDocument(fileURL: url)
        try doc.load(fromContents: bytes, ofType: nil)
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    /// "café “quoted”" in Windows-1252: not UTF-8.
    private let eightBit = Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x71, 0x94, 0x0A])

    func testUTF8FileShowsNoNotice() throws {
        let e = try editor(bytes: Data("café\n".utf8))
        XCTAssertFalse(e.document.encodingGuessed)
        XCTAssertTrue(e.encodingNotice?.isHidden ?? true)
    }

    func testGuessShowsNoticeAndKeepHidesIt() throws {
        let e = try editor(bytes: eightBit)
        XCTAssertTrue(e.document.encodingGuessed)
        let bar = try XCTUnwrap(e.encodingNotice)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.label.text, e.encodingNoticeText)
        XCTAssertTrue(e.encodingNoticeText.contains(e.document.encoding.shortName))
        XCTAssertEqual(bar.reopenButton.menu?.children.count, TextEncoding.allCases.count)
        XCTAssertFalse(e.document.hasUnsavedChanges)
        e.keepGuessedEncoding()
        XCTAssertTrue(bar.isHidden)
        XCTAssertFalse(e.document.encodingGuessed)
        XCTAssertFalse(e.document.hasUnsavedChanges, "Keep changes nothing to save")
        // Not back after a later refresh (a reload of the same file).
        e.document.encodingGuessed = true
        e.refreshEncodingNotice()
        XCTAssertTrue(bar.isHidden)
    }

    func testReopenReadsTheBytesAgainAsOneUndo() throws {
        let e = try editor(bytes: eightBit)
        let guessed = e.document.encoding
        let other: TextEncoding = guessed == .latin1 ? .windows1252 : .latin1
        let before = e.textView.text ?? ""
        XCTAssertTrue(e.reopen(with: other))
        XCTAssertEqual(e.document.encoding, other)
        XCTAssertFalse(e.document.encodingGuessed)
        XCTAssertTrue(e.encodingNotice?.isHidden ?? true)
        let expected = TextCodec.decode(eightBit, as: other)?.text
        XCTAssertEqual(e.textView.text, expected)
        XCTAssertNotEqual(e.textView.text, before)
        e.textView.undoManager?.undo()
        XCTAssertEqual(e.textView.text, before)
        XCTAssertEqual(e.document.encoding, guessed)
    }

    /// Reopen reads the file as it is on disk now (not the bytes read at
    /// open), and one Undo brings back the text, the encoding and the guess.
    func testReopenReadsTheFileChangedOnDiskAndUndoRestoresTheGuess() throws {
        let e = try editor(bytes: eightBit)
        let guessed = e.document.encoding
        let before = e.textView.text ?? ""
        XCTAssertTrue(e.document.encodingGuessed)
        // Changed on disk after it was opened: "naïve" in Latin-1.
        let changed = Data([0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A])
        try changed.write(to: e.document.fileURL)
        XCTAssertTrue(e.reopen(with: .latin1))
        XCTAssertEqual(e.textView.text, TextCodec.decode(changed, as: .latin1)?.text)
        XCTAssertEqual(e.document.encoding, .latin1)
        XCTAssertFalse(e.document.encodingGuessed)
        XCTAssertTrue(e.encodingNotice?.isHidden ?? true)
        e.textView.undoManager?.undo()
        XCTAssertEqual(e.textView.text, before)
        XCTAssertEqual(e.document.encoding, guessed)
        XCTAssertTrue(e.document.encodingGuessed, "the guess is back")
        XCTAssertFalse(e.encodingNotice?.isHidden ?? true, "and its notice")
        XCTAssertFalse(e.textView.undoManager?.canUndo ?? true, "one step")
    }

    func testReopenAsUTF8RefusesInvalidBytes() throws {
        let e = try editor(bytes: eightBit)
        let before = e.textView.text
        XCTAssertFalse(e.reopen(with: .utf8))
        XCTAssertEqual(e.textView.text, before)
        XCTAssertTrue(e.document.encodingGuessed, "still a guess")
    }

    func testMenuOffersReopenWithEncoding() throws {
        let e = try editor(bytes: eightBit)
        let menu = e.reopenWithEncodingMenu()
        XCTAssertEqual(menu.title, EditorViewController.reopenWithEncodingTitle)
        let on = menu.children.compactMap { $0 as? UIAction }.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(on, [e.document.encoding.displayName])
        // The ••• menu has one item for it (no repeated encoding titles there).
        XCTAssertEqual(e.reopenWithEncodingAction().title, EditorViewController.reopenWithEncodingTitle)
    }
}
