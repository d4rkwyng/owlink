import XCTest
import UIKit
import CedricCore

@MainActor
final class EditorHighlightTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var oldSetting: Any?

    override func setUp() async throws {
        oldSetting = AppSettings.defaults.object(forKey: AppSettings.Key.highlightOccurrences)
        AppSettings.highlightOccurrences = true
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        if let oldSetting { AppSettings.defaults.set(oldSetting, forKey: AppSettings.Key.highlightOccurrences) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.highlightOccurrences) }
        AppSettings.post()
    }

    private func editor(_ text: String, language: Language = .swift) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = text
        doc.language.choose(language)
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        windows.append(window)
        return editor
    }

    private func background(at offset: Int, in editor: EditorViewController) throws -> UIColor? {
        let layout = try XCTUnwrap(editor.textView.textLayoutManager)
        let manager = try XCTUnwrap(layout.textContentManager)
        var color: UIColor?
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, range in
            let start = manager.offset(from: layout.documentRange.location, to: range.location)
            let end = manager.offset(from: layout.documentRange.location, to: range.endLocation)
            if start <= offset && offset < end { color = attributes[.backgroundColor] as? UIColor }
            return true
        }
        return color
    }

    func testOccurrencesFollowSelectionAndSettingWithoutEditing() throws {
        let text = "alpha beta alpha alphabet alpha"
        let editor = editor(text)
        let couldUndo = editor.textView.undoManager?.canUndo
        editor.textView.selectedRange = NSRange(location: 0, length: 5)
        editor.refreshEditorHighlights()
        XCTAssertNil(try background(at: 1, in: editor))
        XCTAssertNotNil(try background(at: 12, in: editor))
        XCTAssertNil(try background(at: 18, in: editor))
        XCTAssertNotNil(try background(at: 27, in: editor))
        XCTAssertEqual(editor.textView.text, text)
        XCTAssertEqual(editor.textView.undoManager?.canUndo, couldUndo)

        editor.textView.selectedRange = NSRange(location: 1, length: 0)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 1, in: editor))
        XCTAssertNotNil(try background(at: 12, in: editor))
        editor.textView.selectedRange = NSRange(location: 0, length: 3)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 18, in: editor))

        AppSettings.highlightOccurrences = false
        editor.refreshEditorHighlights()
        XCTAssertNil(try background(at: 12, in: editor))
        AppSettings.highlightOccurrences = true
        editor.textView.selectedRange = NSRange(location: 6, length: 4)
        editor.refreshEditorHighlights()
        XCTAssertNil(try background(at: 12, in: editor))
    }

    func testOccurrenceSettingDefaultsOn() {
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.highlightOccurrences)
        XCTAssertTrue(AppSettings.highlightOccurrences)
    }

    func testBracketPairIsCodeOnlyAndCoexistsWithFocus() throws {
        let text = "call(a[b])\n\nOther."
        let editor = editor(text)
        editor.toggleWritingFocus()
        editor.textView.selectedRange = NSRange(location: 5, length: 0)
        editor.updateWriting()
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 4, in: editor))
        XCTAssertNotNil(try background(at: 9, in: editor))
        XCTAssertNil(try background(at: 6, in: editor))
        XCTAssertEqual(editor.textView.text, text)

        editor.setLanguage(.plain)
        editor.refreshEditorHighlights()
        XCTAssertNil(try background(at: 4, in: editor))
        XCTAssertNil(try background(at: 9, in: editor))
    }
}
