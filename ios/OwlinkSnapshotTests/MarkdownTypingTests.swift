import XCTest
import UIKit
import CedricCore

@MainActor
final class MarkdownTypingTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var previousPasteboardItems: [[String: Any]]?

    override func setUp() async throws {
        previousPasteboardItems = UIPasteboard.general.items
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        if let previousPasteboardItems { UIPasteboard.general.items = previousPasteboardItems }
    }

    private func editor(_ language: Language = .markdown, text: String) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(language)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        editor.textView.becomeFirstResponder()
        windows.append(window)
        return editor
    }

    @discardableResult
    private func pressReturn(_ editor: EditorViewController) -> Bool {
        editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\n")
    }

    func testListContinuationAndOneStepUndo() {
        for (original, continued) in [
            ("- item", "- item\n- "),
            ("1. a", "1. a\n2. "),
            ("- [x] done", "- [x] done\n- [ ] "),
        ] {
            let editor = editor(text: original)
            editor.textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
            XCTAssertFalse(pressReturn(editor))
            XCTAssertEqual(editor.textView.text, continued)
            editor.textView.undoManager?.undo()
            XCTAssertEqual(editor.textView.text, original)
        }
    }

    func testEmptyListItemEndsList() {
        let editor = editor(text: "- ")
        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(pressReturn(editor))
        XCTAssertEqual(editor.textView.text, "")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "- ")
    }

    func testReturnInTableAddsRowAsOneUndoStep() {
        let original = "| a | b |\n|---|---|\n| c | d |"
        let editor = editor(text: original)
        editor.textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
        XCTAssertFalse(pressReturn(editor))
        XCTAssertEqual(editor.textView.text, "| a   | b   |\n| --- | --- |\n| c   | d   |\n|     |     |")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, original)
    }

    func testReturnInFenceAndOtherLanguageUsesSystemInsertion() {
        let fenced = editor(text: "```\n- item\n```")
        let position = (fenced.textView.text! as NSString).range(of: "- item").location + 6
        fenced.textView.selectedRange = NSRange(location: position, length: 0)
        XCTAssertTrue(pressReturn(fenced))
        XCTAssertEqual(fenced.textView.text, "```\n- item\n```")

        let swift = editor(.swift, text: "- item")
        swift.textView.selectedRange = NSRange(location: 6, length: 0)
        XCTAssertTrue(pressReturn(swift))
        XCTAssertEqual(swift.textView.text, "- item")
    }

    func testYAMLListContinuation() {
        let yaml = editor(.yaml, text: "- item")
        yaml.textView.selectedRange = NSRange(location: 6, length: 0)
        XCTAssertFalse(pressReturn(yaml))
        XCTAssertEqual(yaml.textView.text, "- item\n- ")
    }

    func testHardwareTabCommandsAndListIndentation() throws {
        let original = "- parent\n- child"
        let editor = editor(text: original)
        let commands = try XCTUnwrap(editor.textView.keyCommands)
        XCTAssertTrue(commands.contains { $0.input == "\t" && $0.modifierFlags.isEmpty && $0.wantsPriorityOverSystemBehavior })
        XCTAssertTrue(commands.contains { $0.input == "\t" && $0.modifierFlags.contains(.shift) && $0.wantsPriorityOverSystemBehavior })

        editor.textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
        editor.handleMarkdownTab(forward: true)
        XCTAssertEqual(editor.textView.text, "- parent\n  - child")
        editor.handleMarkdownTab(forward: false)
        XCTAssertEqual(editor.textView.text, original)
    }

    func testHardwareTabMovesBetweenTableCells() throws {
        let original = "| a | b |\n| --- | --- |\n| c | d |"
        let editor = editor(text: original)
        let a = (original as NSString).range(of: "a")
        editor.textView.selectedRange = NSRange(location: a.location, length: 0)
        editor.handleMarkdownTab(forward: true)
        XCTAssertEqual((editor.textView.text! as NSString).substring(with: editor.textView.selectedRange), "b")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, original)
    }

    func testHardwareTabFallbackInsertsSpacesAndBacktabIsHarmless() {
        let editor = editor(text: "plain")
        editor.textView.selectedRange = NSRange(location: 5, length: 0)
        editor.handleMarkdownTab(forward: true)
        XCTAssertEqual(editor.textView.text, "plain    ")
        editor.handleMarkdownTab(forward: false)
        XCTAssertEqual(editor.textView.text, "plain    ")
    }

    func testSmartPasteURLOverSelectionAndUndo() {
        let original = "read docs now"
        let editor = editor(text: original)
        editor.textView.selectedRange = (original as NSString).range(of: "docs")
        // The pasteboard itself isn't readable from this hostless bundle;
        // the paste override hands its URL to markdownLinkPaste.
        XCTAssertTrue(editor.markdownLinkPaste("https://example.com/docs"))
        XCTAssertEqual(editor.textView.text, "read [docs](https://example.com/docs) now")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, original)
        // Not a URL, or no selection: the normal paste.
        XCTAssertFalse(editor.markdownLinkPaste("just words"))
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(editor.markdownLinkPaste("https://example.com/docs"))
    }
}
