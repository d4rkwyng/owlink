import XCTest
import UIKit
import CedricCore

@MainActor
final class BookmarkTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var previousLineNumbers: Any?

    override func setUp() async throws {
        previousLineNumbers = AppSettings.defaults.object(forKey: AppSettings.Key.lineNumbers)
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        if let previousLineNumbers { AppSettings.defaults.set(previousLineNumbers, forKey: AppSettings.Key.lineNumbers) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.lineNumbers) }
        AppSettings.post()
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

    private func caret(_ editor: EditorViewController, line: Int) {
        editor.textView.selectedRange = NSRange(location: editor.lineIndex.starts[line], length: 0)
    }

    private func gutter(in view: UIView) -> LineNumberGutter? {
        if let g = view as? LineNumberGutter { return g }
        return view.subviews.lazy.compactMap { self.gutter(in: $0) }.first
    }

    private func menuItem(_ editor: EditorViewController, _ id: String) throws -> UIAction {
        try XCTUnwrap(editor.bookmarksMenu().children.compactMap { $0 as? UIAction }.first { $0.accessibilityIdentifier == id })
    }

    // MARK: Toggle, Next / Previous, Clear

    func testToggleCaretLineLeavesTextAlone() {
        let editor = editor("a\nb\nc\n")
        caret(editor, line: 1)
        editor.toggleBookmarkMenu(nil)
        XCTAssertEqual(editor.bookmarks.lines, [1])
        XCTAssertEqual(editor.textView.text, "a\nb\nc\n")
        editor.toggleBookmarkMenu(nil)
        XCTAssertTrue(editor.bookmarks.isEmpty)
        XCTAssertEqual(editor.textView.text, "a\nb\nc\n")
    }

    func testToggleWorksReadOnly() {
        let editor = editor("a\nb\n", readOnly: true)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.toggleBookmarkMenu(_:)), withSender: nil))
        caret(editor, line: 1)
        editor.toggleBookmarkMenu(nil)
        XCTAssertEqual(editor.bookmarks.lines, [1])
        XCTAssertEqual(editor.textView.text, "a\nb\n")
        XCTAssertFalse(try menuItem(editor, "editor.bookmarkLine").attributes.contains(.disabled))
    }

    func testNextPreviousWrapAndEmptyIsNoOp() {
        let editor = editor("0\n1\n2\n3\n4\n")
        caret(editor, line: 2)
        editor.nextBookmarkMenu(nil)
        editor.previousBookmarkMenu(nil)
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: editor.lineIndex.starts[2], length: 0))
        editor.bookmarks = Bookmarks([1, 3])
        caret(editor, line: 0)
        editor.nextBookmarkMenu(nil)
        XCTAssertEqual(editor.caretLine, 1)
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: editor.lineIndex.starts[1], length: 0))
        editor.nextBookmarkMenu(nil)
        XCTAssertEqual(editor.caretLine, 3)
        editor.nextBookmarkMenu(nil)
        XCTAssertEqual(editor.caretLine, 1, "Next wraps to the first")
        editor.previousBookmarkMenu(nil)
        XCTAssertEqual(editor.caretLine, 3, "Previous wraps to the last")
        editor.previousBookmarkMenu(nil)
        XCTAssertEqual(editor.caretLine, 1)
    }

    func testClearBookmarks() {
        let editor = editor("a\nb\nc\n")
        editor.bookmarks = Bookmarks([0, 2])
        editor.clearBookmarksMenu(nil)
        XCTAssertTrue(editor.bookmarks.isEmpty)
    }

    // MARK: Following edits

    func testTypedNewlineAboveMovesBookmarks() {
        let editor = editor("a\nb\nc\n")
        editor.bookmarks = Bookmarks([1, 2])
        editor.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
        XCTAssertEqual(editor.bookmarks.lines, [2, 3])
        caret(editor, line: 0)
        editor.textView.insertText("x\n")
        XCTAssertEqual(editor.textView.text, "x\n\na\nb\nc\n")
        XCTAssertEqual(editor.bookmarks.lines, [3, 4])
    }

    func testDeleteLineDropsBookmarkAndUndoRestores() {
        let editor = editor("a\nb\nc\nd\n")
        editor.bookmarks = Bookmarks([1, 2])
        caret(editor, line: 1)
        editor.deleteLine(nil)
        XCTAssertEqual(editor.textView.text, "a\nc\nd\n")
        XCTAssertEqual(editor.bookmarks.lines, [1], "b's bookmark goes, c's moves up with it")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "a\nb\nc\nd\n")
        XCTAssertEqual(editor.bookmarks.lines, [1, 2])
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.textView.text, "a\nc\nd\n")
        XCTAssertEqual(editor.bookmarks.lines, [1])
    }

    func testMoveLineTakesBookmarkAndUndoRestores() {
        let editor = editor("a\nb\nc\n")
        editor.bookmarks = Bookmarks([0])
        caret(editor, line: 0)
        editor.moveLineDown(nil)
        XCTAssertEqual(editor.textView.text, "b\na\nc\n")
        XCTAssertEqual(editor.bookmarks.lines, [1])
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "a\nb\nc\n")
        XCTAssertEqual(editor.bookmarks.lines, [0])
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.textView.text, "b\na\nc\n")
        XCTAssertEqual(editor.bookmarks.lines, [1])
        caret(editor, line: 1)
        editor.moveLineUp(nil)
        XCTAssertEqual(editor.textView.text, "a\nb\nc\n")
        XCTAssertEqual(editor.bookmarks.lines, [0])
    }

    func testMultiLineCommentKeepsBookmarksOnTheirLines() {
        let editor = editor("let a = 1\nlet b = 2\nlet c = 3\n")
        editor.bookmarks = Bookmarks([1, 2])
        editor.textView.selectedRange = NSRange(location: 0, length: (editor.textView.text as NSString).length)
        editor.commentSelection(nil)
        XCTAssertEqual(editor.textView.text, "// let a = 1\n// let b = 2\n// let c = 3\n")
        XCTAssertEqual(editor.bookmarks.lines, [1, 2])
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.bookmarks.lines, [1, 2])
    }

    func testSeveralEditsInOneStepKeepBookmarks() {
        let editor = editor("a\nb\nc\nd\n")
        editor.bookmarks = Bookmarks([1, 3])
        // Insert a line above b and rewrite d, applied as one step.
        editor.applyTextEdits([(NSRange(location: 2, length: 0), "new\n"), (NSRange(location: 6, length: 1), "D")],
                              selection: NSRange(location: 0, length: 0), actionName: "Test")
        XCTAssertEqual(editor.textView.text, "a\nnew\nb\nc\nD\n")
        XCTAssertEqual(editor.bookmarks.lines, [2, 4])
    }

    func testReloadClearsBookmarks() {
        let editor = editor("a\nb\n")
        editor.bookmarks = Bookmarks([1])
        editor.document.onReload?()
        XCTAssertTrue(editor.bookmarks.isEmpty)
    }

    // MARK: Menus

    func testMenuTitlesAndEnablement() throws {
        let editor = editor("a\nb\nc\n")
        caret(editor, line: 1)
        XCTAssertEqual(try menuItem(editor, "editor.bookmarkLine").title, "Bookmark Line")
        for id in ["editor.nextBookmark", "editor.previousBookmark", "editor.clearBookmarks"] {
            XCTAssertTrue(try menuItem(editor, id).attributes.contains(.disabled), id)
        }
        for action in [#selector(EditorViewController.nextBookmarkMenu(_:)), #selector(EditorViewController.previousBookmarkMenu(_:)),
                       #selector(EditorViewController.clearBookmarksMenu(_:))] {
            XCTAssertFalse(editor.canPerformAction(action, withSender: nil))
        }
        let command = UICommand(title: "Bookmark Line", action: #selector(EditorViewController.toggleBookmarkMenu(_:)))
        editor.validate(command)
        XCTAssertEqual(command.title, "Bookmark Line")

        editor.toggleBookmarkMenu(nil)
        XCTAssertEqual(try menuItem(editor, "editor.bookmarkLine").title, "Remove Bookmark")
        editor.validate(command)
        XCTAssertEqual(command.title, "Remove Bookmark")
        for id in ["editor.nextBookmark", "editor.previousBookmark", "editor.clearBookmarks"] {
            XCTAssertFalse(try menuItem(editor, id).attributes.contains(.disabled), id)
        }
        for action in [#selector(EditorViewController.nextBookmarkMenu(_:)), #selector(EditorViewController.previousBookmarkMenu(_:)),
                       #selector(EditorViewController.clearBookmarksMenu(_:))] {
            XCTAssertTrue(editor.canPerformAction(action, withSender: nil))
        }
        caret(editor, line: 0)
        XCTAssertEqual(try menuItem(editor, "editor.bookmarkLine").title, "Bookmark Line")
        // In the ⋯ menu.
        let more = editor.moreMenuItems().compactMap { $0 as? UIMenu }
        XCTAssertTrue(more.contains { $0.title == "Bookmarks" })
    }

    // MARK: Gutter

    func testGutterMarksBookmarkedRowAndTapToggles() throws {
        AppSettings.lineNumbers = true
        let editor = editor("a\nb\nc\nd\n")
        let window = try XCTUnwrap(editor.view.window)
        let numbers = try XCTUnwrap(gutter(in: editor.view))
        caret(editor, line: 1)
        editor.toggleBookmarkMenu(nil)
        window.layoutIfNeeded()
        editor.layoutGutter()
        XCTAssertFalse(numbers.isHidden)
        XCTAssertEqual(numbers.markedRows, [2])
        XCTAssertTrue(numbers.isUserInteractionEnabled)
        let row = try XCTUnwrap(numbers.rows.first { $0.line == 2 })
        let neighbour = try XCTUnwrap(numbers.rows.first { $0.line == 3 })
        XCTAssertEqual(numbers.line(at: CGPoint(x: 4, y: row.midY + 2)), 2)
        XCTAssertEqual(numbers.line(at: CGPoint(x: 4, y: neighbour.midY - 2)), 3)
        // A tap on row 3 bookmarks it; another on row 2 removes that one.
        numbers.onTapLine?(numbers.line(at: CGPoint(x: 4, y: neighbour.midY))!)
        XCTAssertEqual(editor.bookmarks.lines, [1, 2])
        numbers.onTapLine?(numbers.line(at: CGPoint(x: 4, y: row.midY))!)
        XCTAssertEqual(editor.bookmarks.lines, [2])
        XCTAssertEqual(numbers.markedRows, [3])
        XCTAssertEqual(editor.textView.text, "a\nb\nc\nd\n")
    }

    func testGutterFollowsDeleteLineOnNextTurn() throws {
        AppSettings.lineNumbers = true
        let editor = editor("a\nb\nc\nd\n")
        let window = try XCTUnwrap(editor.view.window)
        let numbers = try XCTUnwrap(gutter(in: editor.view))
        editor.bookmarks = Bookmarks([1, 3])
        editor.layoutGutter()
        XCTAssertEqual(numbers.markedRows, [2, 4])
        caret(editor, line: 0)
        editor.deleteLine(nil)
        XCTAssertEqual(editor.bookmarks.lines, [0, 2])
        // The gutter is laid out on the next main-queue turn, not mid-edit.
        let laidOut = expectation(description: "next turn")
        DispatchQueue.main.async { laidOut.fulfill() }
        wait(for: [laidOut], timeout: 2)
        XCTAssertEqual(numbers.bookmarked, [1, 3])
        window.layoutIfNeeded()
        editor.layoutGutter()
        XCTAssertEqual(numbers.markedRows, [1, 3])
    }

    func testBookmarksShowGutterWithNumbersOff() throws {
        AppSettings.lineNumbers = false
        let editor = editor("a\nb\nc\n")
        let window = try XCTUnwrap(editor.view.window)
        let numbers = try XCTUnwrap(gutter(in: editor.view))
        window.layoutIfNeeded()
        XCTAssertTrue(numbers.isHidden)
        caret(editor, line: 0)
        editor.toggleBookmarkMenu(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(numbers.isHidden)
        XCTAssertEqual(numbers.markedRows, [1])
        editor.clearBookmarksMenu(nil)
        window.layoutIfNeeded()
        XCTAssertTrue(numbers.isHidden)
    }
}
