import XCTest
import UIKit
import CedricCore

@MainActor
private final class FindTestOptions: UITextSearchOptions {
    var matchCase = false
    var wholeWord = false
    override var stringCompareOptions: NSString.CompareOptions { matchCase ? [] : [.caseInsensitive] }
    override var wordMatchMethod: UITextSearchOptions.WordMatchMethod { wholeWord ? .fullWord : .contains }
}

@MainActor
final class RegexFindTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor(_ text: String) -> EditorViewController {
        let document = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        document.text = text
        let editor = EditorViewController(document: document, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        editor.regexFind.setEnabled(true)
        windows.append(window)
        return editor
    }

    private func wait() async throws { try await Task.sleep(for: .milliseconds(500)) }

    func testSessionFindsRegexAndRespectsCaseAndWholeWords() async throws {
        let editor = editor("cat CAT cats")
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let menu = try XCTUnwrap(interaction.optionsMenuProvider?([]))
        XCTAssertTrue(menu.children.contains { $0.accessibilityIdentifier == "find.regex" })
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        options.wholeWord = true
        session.performSearch(query: "(cat)", options: options)
        try await wait()
        XCTAssertEqual(session.resultCount, 2)
        options.matchCase = true
        session.performSearch(query: "(cat)", options: options)
        try await wait()
        XCTAssertEqual(session.resultCount, 1)
        session.performSearch(query: "(", options: options)
        try await wait()
        XCTAssertEqual(session.resultCount, 0)
    }

    func testReplaceAllCapturesAndUndo() async throws {
        let editor = editor("one 12 two 34")
        editor.textView.becomeFirstResponder()
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        XCTAssertTrue(session.supportsReplacement)
        session.performSearch(query: "([a-z]+) ([0-9]+)", options: options)
        try await wait()
        XCTAssertEqual(session.resultCount, 2)
        session.replaceAll(searchQuery: "([a-z]+) ([0-9]+)", replacementString: "$2:$1", options: options)
        try await wait()
        XCTAssertEqual(editor.textView.text, "12:one 34:two")
        XCTAssertEqual(session.resultCount, 0)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one 12 two 34")
    }

    func testSingleReplacementAndReadOnly() async throws {
        let editor = editor("item 42")
        editor.textView.becomeFirstResponder()
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        session.performSearch(query: "(item) ([0-9]+)", options: options)
        try await wait()
        XCTAssertEqual(session.resultCount, 1)
        session.highlightNextResult(in: .forward)
        session.performSingleReplacement(query: "(item) ([0-9]+)", replacementString: "$2 $1", options: options)
        XCTAssertEqual(editor.textView.text, "42 item")
        editor.setEditLock(.documentLocked, true)
        session.replaceAll(searchQuery: "(.*)", replacementString: "no", options: options)
        try await wait()
        XCTAssertEqual(editor.textView.text, "42 item")
    }

    func testSwitchingBetweenRegexAndSystemSearch() async throws {
        let editor = editor("cat c.t")
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        session.performSearch(query: "c.t", options: options)
        try await wait()
        XCTAssertEqual(session.resultCount, 2)
        editor.regexFind.setEnabled(false)
        try await wait()
        XCTAssertEqual(session.resultCount, 1)
        session.replaceAll(searchQuery: "c.t", replacementString: "$1", options: options)
        try await wait()
        XCTAssertEqual(editor.textView.text, "cat $1")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "cat c.t")
        session.performSearch(query: "c.t", options: options)
        try await wait()
        editor.regexFind.setEnabled(true)
        try await wait()
        XCTAssertEqual(session.resultCount, 2)
    }

    func testFindEditIsSeparateFromOpenTypingUndoGroup() {
        let editor = editor("before")
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        editor.textView.insertText(" typed")
        editor.applyFindReplacement(range: NSRange(location: 0, length: 6), replacement: "after",
                                    name: String(localized: "Replace All"))
        XCTAssertEqual(editor.textView.text, "after typed")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "before typed")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "before")
    }
}
