import XCTest
import UIKit
import CedricCore

@MainActor
final class WritingModeTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var oldUnit: Any?

    override func setUp() async throws {
        oldUnit = AppSettings.defaults.object(forKey: AppSettings.Key.focusUnit)
        AppSettings.focusUnit = .paragraph
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        if let oldUnit { AppSettings.defaults.set(oldUnit, forKey: AppSettings.Key.focusUnit) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.focusUnit) }
    }

    private func editor(_ text: String) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        editor.textView.becomeFirstResponder()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        windows.append(window)
        return editor
    }

    func testFocusIsPerDocumentAndDoesNotEditText() throws {
        let text = "First sentence. Second sentence.\n\nAnother paragraph."
        let first = editor(text)
        let second = editor(text)
        first.textView.selectedRange = NSRange(location: 2, length: 0)
        first.toggleWritingFocus()
        first.updateWriting()
        XCTAssertTrue(first.writing.focus)
        XCTAssertFalse(second.writing.focus)
        XCTAssertEqual(first.textView.text, text)
        let layout = try XCTUnwrap(first.textView.textLayoutManager)
        var colored = false
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, _ in
            if attributes[.foregroundColor] != nil { colored = true }
            return true
        }
        XCTAssertTrue(colored)
        first.toggleWritingFocus()
        colored = false
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, _ in
            if attributes[.foregroundColor] != nil { colored = true }
            return true
        }
        XCTAssertFalse(colored)
    }

    func testTypewriterAddsAndRestoresInset() {
        let editor = editor(String(repeating: "A line of text.\n", count: 100))
        let original = editor.textView.contentInset.bottom
        editor.toggleTypewriter()
        XCTAssertGreaterThan(editor.textView.contentInset.bottom, original)
        editor.textView.selectedRange = NSRange(location: editor.textView.textStorage.length, length: 0)
        editor.updateWriting()
        XCTAssertGreaterThan(editor.textView.contentOffset.y, 0)
        editor.toggleTypewriter()
        XCTAssertEqual(editor.textView.contentInset.bottom, original, accuracy: 0.5)
    }

    func testSentenceFocusChangesRenderingWithoutChangingStorage() throws {
        let editor = editor("First sentence. Second sentence.\n\nLast paragraph.")
        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        editor.toggleWritingFocus()
        AppSettings.focusUnit = .sentence
        XCTAssertEqual(AppSettings.focusUnit, .sentence)
        XCTAssertEqual(editor.textView.selectedRange.location, 2)
        XCTAssertGreaterThan((editor.editorVisibleRange()?.length ?? 0), 20,
                             "bounds \(editor.textView.bounds), content \(editor.textView.contentSize), text \(editor.textView.textStorage.length)")
        editor.updateWriting()
        let layout = try XCTUnwrap(editor.textView.textLayoutManager)
        let manager = try XCTUnwrap(layout.textContentManager)
        var dimmed = false
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, range in
            let start = manager.offset(from: layout.documentRange.location, to: range.location)
            let end = manager.offset(from: layout.documentRange.location, to: range.endLocation)
            if start <= 20 && end > 20 {
                dimmed = attributes[.foregroundColor] != nil
            }
            return true
        }
        XCTAssertTrue(dimmed, "Second sentence should be dimmed")
        XCTAssertEqual(editor.textView.text, "First sentence. Second sentence.\n\nLast paragraph.")
    }
}
