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

    func testReturnOwnsUndoStepAfterTyping() {
        let editor = editor(text: "- item")
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        editor.textView.insertText("abc")
        XCTAssertEqual(editor.textView.text, "- itemabc")
        editor.textView.selectedRange = NSRange(location: 9, length: 0)
        XCTAssertFalse(pressReturn(editor))
        XCTAssertEqual(editor.textView.text, "- itemabc\n- ")

        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "- itemabc")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "- item")
    }

    /// The system's typing group still open (as during a key event): the
    /// list edit closes it, stays its own step, and groupsByEvent comes back.
    func testReturnClosesAnOpenTypingGroup() throws {
        let editor = editor(text: "- item")
        let undo = try XCTUnwrap(editor.textView.undoManager)
        let wasGrouping = undo.groupsByEvent
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        editor.textView.insertText("abc")
        // The typing went into the run loop's event group, still open.
        XCTAssertTrue(undo.groupsByEvent)
        XCTAssertGreaterThan(undo.groupingLevel, 0)
        XCTAssertFalse(pressReturn(editor))
        XCTAssertEqual(undo.groupingLevel, 0)
        XCTAssertEqual(editor.textView.text, "- itemabc\n- ")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(undo.groupsByEvent, wasGrouping)
        XCTAssertNil(EditorViewController.pendingGroupsByEvent)
        undo.undo()
        XCTAssertEqual(editor.textView.text, "- itemabc")
        undo.undo()
        XCTAssertEqual(editor.textView.text, "- item")
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

        XCTAssertFalse(swift.textView.markdownKeysEnabled?() ?? true)
        XCTAssertFalse((swift.textView.keyCommands ?? []).contains { $0.input == "\t" })
    }

    func testYAMLListContinuation() {
        let yaml = editor(.yaml, text: "- item")
        yaml.textView.selectedRange = NSRange(location: 6, length: 0)
        XCTAssertFalse(pressReturn(yaml))
        XCTAssertEqual(yaml.textView.text, "- item\n- ")

        let plain = editor(.yaml, text: "key: value")
        plain.textView.selectedRange = NSRange(location: 10, length: 0)
        XCTAssertTrue(pressReturn(plain))
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

    func testHardwareTabFallbackReplacesMultilineSelectionWithTab() {
        let tabEditor = editor(text: "plain")
        tabEditor.textView.selectedRange = NSRange(location: 0, length: 5)
        tabEditor.handleMarkdownTab(forward: true)
        XCTAssertEqual(tabEditor.textView.text, "\t")
        tabEditor.handleMarkdownTab(forward: false)
        XCTAssertEqual(tabEditor.textView.text, "\t")

        let multiline = editor(text: "one\ntwo")
        multiline.textView.selectedRange = NSRange(location: 0, length: 7)
        multiline.handleMarkdownTab(forward: true)
        XCTAssertEqual(multiline.textView.text, "\t")
    }

    func testDetectedIndentationControlsMarkdownListTab() {
        let original = "- top\n  - child\n  - sibling\n    - nested"
        let editor = editor(text: original)
        let sibling = (original as NSString).range(of: "- sibling")
        editor.textView.selectedRange = NSRange(location: sibling.location + 3, length: 0)
        editor.handleMarkdownTab(forward: true)
        XCTAssertEqual(editor.textView.text, "- top\n  - child\n    - sibling\n      - nested")
    }

    func testSmartPastePasteboardBranchesAreInjectable() {
        let original = "read docs now"
        let url = URL(string: "https://example.com/docs")!
        let cases: [(urls: [URL], string: String?, pasted: String?)] = [
            ([url], nil, url.absoluteString),
            ([url, url], nil, nil),
            ([], url.absoluteString, url.absoluteString),
            ([], "just words", nil),
            ([], nil, nil),
        ]
        for item in cases {
            let editor = editor(text: original)
            editor.textView.selectedRange = (original as NSString).range(of: "docs")
            editor.markdownPasteboardReader = { (urls: item.urls, string: item.string) }
            if let pasted = item.pasted {
                XCTAssertTrue(editor.handleMarkdownPaste())
                XCTAssertEqual(editor.textView.text, "read [docs](\(pasted)) now")
                editor.textView.undoManager?.undo()
                XCTAssertEqual(editor.textView.text, original)
            } else {
                XCTAssertFalse(editor.handleMarkdownPaste())
                XCTAssertEqual(editor.textView.text, original)
            }
        }
    }
}
