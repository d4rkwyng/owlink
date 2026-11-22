import XCTest
import UIKit
import CedricCore
import UniformTypeIdentifiers

@MainActor
private final class InvisiblesPasteboard: CopyPasteboard {
    var changeCount = 0
    var item: [String: Any] = [:]
    func write(_ item: [String: Any]) {
        self.item = item
        changeCount += 1
    }
}

@MainActor
final class InvisiblesTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var oldSetting: Any?
    private var oldPasteboard: [[String: Any]] = []

    override func setUp() async throws {
        oldSetting = AppSettings.defaults.object(forKey: AppSettings.Key.showInvisibles)
        oldPasteboard = UIPasteboard.general.items
        AppSettings.showInvisibles = false
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        UIPasteboard.general.items = oldPasteboard
        if let oldSetting { AppSettings.defaults.set(oldSetting, forKey: AppSettings.Key.showInvisibles) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.showInvisibles) }
        AppSettings.post()
    }

    private func editor(_ text: String) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        windows.append(window)
        return editor
    }

    @discardableResult
    private func draw(_ editor: EditorViewController) -> UIImage {
        editor.textView.layoutIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.invisiblesOverlay.refresh()
        let overlay = editor.invisiblesOverlay
        return UIGraphicsImageRenderer(size: overlay.bounds.size).image { _ in
            overlay.draw(overlay.bounds)
        }
    }

    func testSettingAndMenuStates() throws {
        XCTAssertEqual(AppSettings.Key.showInvisibles, "showInvisibles")
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.showInvisibles)
        XCTAssertFalse(AppSettings.showInvisibles)
        let editor = editor("a b")
        func action() throws -> UIAction {
            let group = try XCTUnwrap(editor.moreMenuItems().first as? UIMenu)
            return try XCTUnwrap(group.children.compactMap { $0 as? UIAction }.first { $0.accessibilityIdentifier == "editor.menu.showInvisibles" })
        }
        let command = UICommand(title: "Show Invisibles", action: #selector(EditorViewController.toggleInvisibles))
        XCTAssertEqual(try action().state, .off)
        editor.validate(command)
        XCTAssertEqual(command.state, .off)
        editor.toggleInvisibles()
        XCTAssertTrue(AppSettings.defaults.bool(forKey: "showInvisibles"))
        XCTAssertEqual(try action().state, .on)
        editor.validate(command)
        XCTAssertEqual(command.state, .on)
        XCTAssertFalse(editor.invisiblesOverlay.isHidden)
        editor.toggleInvisibles()
        XCTAssertTrue(editor.invisiblesOverlay.isHidden)
    }

    func testDrawingPreservesTextSelectionUndoAndCopy() async throws {
        let original = "one \ttwo\nthree"
        let editor = editor(original)
        let tv = editor.textView
        tv.becomeFirstResponder()
        tv.selectedRange = NSRange(location: (original as NSString).length, length: 0)
        tv.insertText("!")
        let selection = tv.selectedRange
        let undo = try XCTUnwrap(tv.undoManager)
        XCTAssertTrue(undo.canUndo)
        AppSettings.showInvisibles = true
        let image = draw(editor)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        let blank = UIGraphicsImageRenderer(size: image.size).image { _ in }
        XCTAssertNotEqual(image.pngData(), blank.pngData())
        XCTAssertEqual(tv.text, original + "!")
        XCTAssertEqual(tv.selectedRange, selection)
        XCTAssertTrue(undo.canUndo)
        tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length)
        let count = UIPasteboard.general.changeCount
        tv.copy(nil)
        XCTAssertGreaterThan(UIPasteboard.general.changeCount, count)
        XCTAssertEqual(tv.text(in: try XCTUnwrap(tv.selectedTextRange)), original + "!")
        let pasteboard = InvisiblesPasteboard()
        editor.copyPasteboard = pasteboard
        editor.setLanguage(.markdown)
        await withCheckedContinuation { continuation in
            editor.copyMarkdown(rich: false, selection: tv.selectedRange) { continuation.resume() }
        }
        let html = try XCTUnwrap(pasteboard.item[UTType.utf8PlainText.identifier] as? String)
        XCTAssertTrue(html.contains("one"))
        XCTAssertFalse(html.contains("·"))
        XCTAssertFalse(html.contains("→"))
        XCTAssertFalse(html.contains("¬"))
        undo.undo()
        XCTAssertEqual(tv.text, original)
    }

    func testOnlyVisibleLinesAreDrawnAsViewportMoves() throws {
        let text = (0..<500).map { "line \($0)\t value" }.joined(separator: "\n")
        let editor = editor(text)
        AppSettings.showInvisibles = true
        draw(editor)
        let first = try XCTUnwrap(editor.invisiblesOverlay.lastDrawnRange)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        XCTAssertLessThan(NSMaxRange(first), (text as NSString).length)
        editor.textView.setContentOffset(CGPoint(x: 0, y: 3000), animated: false)
        draw(editor)
        let second = try XCTUnwrap(editor.invisiblesOverlay.lastDrawnRange)
        XCTAssertGreaterThan(second.location, first.location)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        XCTAssertEqual(editor.textView.text, text)
    }

    func testLargeDocumentKeepsInvisiblesOnLikeMac() throws {
        let text = "a " + String(repeating: "x", count: LargeDocument.lineThreshold + 1)
        let editor = editor(text)
        XCTAssertEqual(editor.writingLargeReason, .longLine)
        AppSettings.showInvisibles = true
        draw(editor)
        XCTAssertFalse(editor.invisiblesOverlay.isHidden)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        XCTAssertEqual(editor.textView.text, text)
    }
}
