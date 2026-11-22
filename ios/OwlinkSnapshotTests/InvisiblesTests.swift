import XCTest
import UIKit
import CedricCore

@MainActor
final class InvisiblesTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var oldSetting: Any?
    private var oldWrap: Any?
    private var oldPasteboard: [[String: Any]] = []

    override func setUp() async throws {
        oldSetting = AppSettings.defaults.object(forKey: AppSettings.Key.showInvisibles)
        oldWrap = AppSettings.defaults.object(forKey: AppSettings.Key.wrap)
        oldPasteboard = UIPasteboard.general.items
        AppSettings.showInvisibles = false
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        UIPasteboard.general.items = oldPasteboard
        if let oldSetting { AppSettings.defaults.set(oldSetting, forKey: AppSettings.Key.showInvisibles) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.showInvisibles) }
        if let oldWrap { AppSettings.defaults.set(oldWrap, forKey: AppSettings.Key.wrap) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.wrap) }
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

    private func drainRefresh() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @discardableResult
    private func draw(_ editor: EditorViewController) async -> UIImage {
        editor.textView.layoutIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.invisiblesOverlay.refresh()
        await drainRefresh()
        let overlay = editor.invisiblesOverlay
        return UIGraphicsImageRenderer(size: overlay.bounds.size).image { _ in
            overlay.draw(overlay.bounds)
        }
    }

    func testSettingAndMenuStates() async throws {
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
        XCTAssertEqual(try action().title, "Show Invisibles")
        editor.validate(command)
        XCTAssertEqual(command.state, .off)
        editor.toggleInvisibles()
        XCTAssertTrue(AppSettings.defaults.bool(forKey: "showInvisibles"))
        XCTAssertEqual(try action().state, .on)
        XCTAssertEqual(try action().title, "Hide Invisibles")
        editor.validate(command)
        XCTAssertEqual(command.state, .on)
        XCTAssertFalse(editor.invisiblesOverlay.isHidden)
        await drainRefresh()
        XCTAssertGreaterThan(editor.invisiblesOverlay.displayRequests, 0)
        editor.invisiblesOverlay.layer.displayIfNeeded()
        XCTAssertEqual(editor.invisiblesOverlay.lastGlyphCount, 1)
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
        let storage = NSAttributedString(attributedString: tv.textStorage)
        let image = await draw(editor)
        XCTAssertEqual(editor.invisiblesOverlay.lastGlyphCount, 3)
        XCTAssertEqual(tv.textStorage, storage)
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
        undo.undo()
        XCTAssertEqual(tv.text, original)
    }

    func testOnlyVisibleLinesAreDrawnAsViewportMoves() async throws {
        let text = (0..<500).map { "line \($0)\t value" }.joined(separator: "\n")
        let editor = editor(text)
        AppSettings.showInvisibles = true
        editor.invisiblesOverlay.tracksDrawnRange = true
        await draw(editor)
        let first = try XCTUnwrap(editor.invisiblesOverlay.lastDrawnRange)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        XCTAssertLessThan(NSMaxRange(first), (text as NSString).length)
        editor.textView.setContentOffset(CGPoint(x: 0, y: 3000), animated: false)
        await draw(editor)
        let second = try XCTUnwrap(editor.invisiblesOverlay.lastDrawnRange)
        XCTAssertGreaterThan(second.location, first.location)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        XCTAssertEqual(editor.textView.text, text)
    }

    func testLargeDocumentKeepsInvisiblesOnLikeMac() async throws {
        let text = "a " + String(repeating: "x", count: LargeDocument.lineThreshold + 1)
        let editor = editor(text)
        XCTAssertEqual(editor.writingLargeReason, .longLine)
        AppSettings.showInvisibles = true
        await draw(editor)
        XCTAssertFalse(editor.invisiblesOverlay.isHidden)
        XCTAssertGreaterThan(editor.invisiblesOverlay.lastGlyphCount, 0)
        XCTAssertEqual(editor.textView.text, text)
    }

    func testEmptyAndCRLFCounts() async {
        let empty = editor("")
        AppSettings.showInvisibles = true
        await draw(empty)
        XCTAssertEqual(empty.invisiblesOverlay.lastGlyphCount, 0)
        let lines = editor("a \tb\r\nc d\n")
        await draw(lines)
        XCTAssertEqual(lines.invisiblesOverlay.lastGlyphCount, 5)
    }

    func testSpaceAlignsWithCaretIncludingPadding() async throws {
        let editor = editor("a b")
        editor.textView.textContainer.lineFragmentPadding = 17
        editor.invisiblesOverlay.tracksGlyphPoints = true
        AppSettings.showInvisibles = true
        await draw(editor)
        let position = try XCTUnwrap(editor.textView.position(from: editor.textView.beginningOfDocument, offset: 1))
        let caret = editor.textView.caretRect(for: position)
        let point = try XCTUnwrap(editor.invisiblesOverlay.lastGlyphPoints.first)
        XCTAssertEqual(point.x + editor.textView.bounds.minX, caret.midX, accuracy: 1)
    }

    func testRefreshCoalescesAndCachesGlyphs() async {
        let editor = editor("a b")
        let overlay = editor.invisiblesOverlay
        AppSettings.showInvisibles = true
        await draw(editor)
        let requests = overlay.displayRequests
        let builds = overlay.glyphCacheBuilds
        for _ in 0..<10 { overlay.refresh() }
        await drainRefresh()
        XCTAssertEqual(overlay.displayRequests, requests)
        XCTAssertEqual(overlay.glyphCacheBuilds, builds)
        editor.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
        for _ in 0..<10 { overlay.refresh() }
        await drainRefresh()
        XCTAssertEqual(overlay.displayRequests, requests + 1)
        XCTAssertEqual(overlay.glyphCacheBuilds, builds)
        overlay.color = .red
        overlay.refresh()
        await drainRefresh()
        XCTAssertEqual(overlay.glyphCacheBuilds, builds + 1)
        editor.textView.font = UIFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        overlay.refresh()
        await drainRefresh()
        XCTAssertEqual(overlay.glyphCacheBuilds, builds + 2)
    }

    func testLongUnwrappedLineAtHorizontalOffsetIsBounded() async throws {
        AppSettings.wrap = false
        let text = String(repeating: "x", count: 10_000) + " " + String(repeating: "x", count: 990_000)
        let editor = editor(text)
        let overlay = editor.invisiblesOverlay
        overlay.tracksDrawnRange = true
        AppSettings.showInvisibles = true
        let width = ("x" as NSString).size(withAttributes: [.font: try XCTUnwrap(editor.textView.font)]).width
        editor.textView.setContentOffset(CGPoint(x: width * 9_990, y: 0), animated: false)
        await draw(editor)
        let range = try XCTUnwrap(overlay.lastDrawnRange)
        XCTAssertLessThanOrEqual(overlay.lastProcessedUnitCount, InvisibleWindow.limit)
        XCTAssertGreaterThan(range.location, 0)
        XCTAssertEqual(overlay.lastGlyphCount, 1)
    }
}
