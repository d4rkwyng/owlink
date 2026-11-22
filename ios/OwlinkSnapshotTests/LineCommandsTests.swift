import XCTest
import UIKit
import CedricCore

@MainActor
final class LineCommandsTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor(_ text: String, readOnly: Bool = false) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift"))
        doc.language.choose(.swift)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: readOnly)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    func testDuplicateAndMoveUndo() {
        let editor = editor("one\ntwo\n")
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        editor.duplicateLine(nil)
        XCTAssertEqual(editor.textView.text, "one\ntwo\ntwo\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one\ntwo\n")
        editor.moveLineUp(nil)
        XCTAssertEqual(editor.textView.text, "two\none\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one\ntwo\n")
    }

    func testCommentAndIndentUndo() {
        let editor = editor("let x = 1\n")
        editor.lineIndentation = Indentation(usesTabs: false, width: 4)
        editor.commentSelection(nil)
        XCTAssertEqual(editor.textView.text, "// let x = 1\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "let x = 1\n")
        editor.indentLines(nil)
        XCTAssertEqual(editor.textView.text, "    let x = 1\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "let x = 1\n")
    }

    func testReadOnlyRefusesCommands() {
        let editor = editor("one\n", readOnly: true)
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.duplicateLine(_:)), withSender: nil))
        editor.duplicateLine(nil)
        XCTAssertEqual(editor.textView.text, "one\n")
    }

    func testFilterIsOneUndoStepAndReportsErrors() throws {
        let editor = editor("keep\nDROP\nkeep\ndrop")
        XCTAssertEqual(try editor.filterLines(pattern: "^drop$", regex: true, caseSensitive: false, keep: false), 2)
        XCTAssertEqual(editor.textView.text, "keep\nkeep")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "keep\nDROP\nkeep\ndrop")
        XCTAssertThrowsError(try editor.filterLines(pattern: "(", regex: true, caseSensitive: true, keep: true))
        XCTAssertEqual(editor.textView.text, "keep\nDROP\nkeep\ndrop")
    }

    func testConvertIndentationIsUndoable() {
        let editor = editor("    one\n        two")
        editor.lineIndentation = Indentation(usesTabs: false, width: 4)
        editor.convertIndentationToTabs(nil)
        XCTAssertEqual(editor.textView.text, "\tone\n\t\ttwo")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "    one\n        two")
    }
}
