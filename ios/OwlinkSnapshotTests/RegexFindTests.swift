import XCTest
import UIKit
import CedricCore

@MainActor
private final class FindTestOptions: UITextSearchOptions {
    var matchCase = false
    var wholeWord = false
    var startsWith = false
    override var stringCompareOptions: NSString.CompareOptions { matchCase ? [] : [.caseInsensitive] }
    override var wordMatchMethod: UITextSearchOptions.WordMatchMethod {
        wholeWord ? .fullWord : startsWith ? .startsWith : .contains
    }
}

@MainActor
final class RegexFindTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func setUp() async throws {
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.findRegex)
    }

    override func tearDown() async throws {
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.findRegex)
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

    /// Polls (up to a deadline) rather than sleeping a fixed time.
    private func until(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func session(_ editor: EditorViewController) throws -> UIFindSession {
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        return try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
    }

    private func search(_ session: UIFindSession, _ query: String, _ options: UITextSearchOptions,
                        expecting count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        session.performSearch(query: query, options: options)
        let reached = try await until { session.resultCount == count }
        XCTAssertTrue(reached, "expected \(count) results, saw \(session.resultCount)", file: file, line: line)
    }

    private func textRange(_ range: NSRange, in view: UITextView) throws -> UITextRange {
        let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: range.location))
        let end = try XCTUnwrap(view.position(from: start, offset: range.length))
        return try XCTUnwrap(view.textRange(from: start, to: end))
    }

    func testSessionFindsRegexAndRespectsCaseAndWholeWords() async throws {
        let editor = editor("cat CAT cats")
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let menu = try XCTUnwrap(interaction.optionsMenuProvider?([]))
        XCTAssertTrue(menu.children.contains { $0.accessibilityIdentifier == "find.regex" })
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        options.wholeWord = true
        try await search(session, "(cat)", options, expecting: 2)
        options.matchCase = true
        try await search(session, "(cat)", options, expecting: 1)
        session.performSearch(query: "(", options: options)
        let invalid = try await until { editor.regexFind.status == .invalidPattern }
        XCTAssertTrue(invalid)
        XCTAssertEqual(session.resultCount, 0)
    }

    func testReplaceAllCapturesAndUndo() async throws {
        let editor = editor("one 12 two 34")
        editor.textView.becomeFirstResponder()
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        XCTAssertTrue(session.supportsReplacement)
        try await search(session, "([a-z]+) ([0-9]+)", options, expecting: 2)
        session.replaceAll(searchQuery: "([a-z]+) ([0-9]+)", replacementString: "$2:$1", options: options)
        let replaced = try await until { editor.textView.text == "12:one 34:two" }
        XCTAssertTrue(replaced)
        let cleared = try await until { session.resultCount == 0 }
        XCTAssertTrue(cleared)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one 12 two 34")
    }

    func testSingleReplacementAndReadOnly() async throws {
        let editor = editor("item 42")
        editor.textView.becomeFirstResponder()
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        try await search(session, "(item) ([0-9]+)", options, expecting: 1)
        session.highlightNextResult(in: .forward)
        session.performSingleReplacement(query: "(item) ([0-9]+)", replacementString: "$2 $1", options: options)
        XCTAssertEqual(editor.textView.text, "42 item")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "item 42", "a single replacement is one undo step")
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.textView.text, "42 item")
        editor.setEditLock(.documentLocked, true)
        session.replaceAll(searchQuery: "(.*)", replacementString: "no", options: options)
        XCTAssertEqual(editor.textView.text, "42 item")
    }

    func testSwitchingBetweenRegexAndSystemSearch() async throws {
        let editor = editor("cat c.t")
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let session = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        let options = FindTestOptions()
        try await search(session, "c.t", options, expecting: 2)
        editor.regexFind.setEnabled(false)
        let literal = try await until { session.resultCount == 1 }
        XCTAssertTrue(literal)
        session.replaceAll(searchQuery: "c.t", replacementString: "$1", options: options)
        let replaced = try await until { editor.textView.text == "cat $1" }
        XCTAssertTrue(replaced)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "cat c.t")
        try await search(session, "c.t", options, expecting: 1)
        editor.regexFind.setEnabled(true)
        let regex = try await until { session.resultCount == 2 }
        XCTAssertTrue(regex)
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

    // MARK: Review fixes

    func testSessionSwitchesBackendAndToggleIsPersisted() throws {
        let editor = editor("text")
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        let ours = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        XCTAssertTrue(editor.regexFind.session === ours, "our session while Regex is on")
        XCTAssertTrue(AppSettings.findRegex)
        editor.regexFind.setEnabled(false)
        XCTAssertFalse(AppSettings.findRegex)
        let system = try XCTUnwrap(editor.textView.findInteraction(interaction, sessionFor: editor.textView))
        XCTAssertNotNil(system)
        XCTAssertTrue(editor.regexFind.session === system, "the wrapper delegates literal search to the text view")
        editor.regexFind.setEnabled(true)
        let next = EditorViewController(document: editor.document, readModeOnOpen: false)
        XCTAssertTrue(next.regexFind.enabled, "the toggle is remembered")
        let menu = try XCTUnwrap(interaction.optionsMenuProvider?([]))
        let toggle = try XCTUnwrap(menu.children.first { $0.accessibilityIdentifier == "find.regex" })
        XCTAssertEqual(toggle.title, "Regex")
    }

    func testStartsWithMapsToWordPrefix() async throws {
        let editor = editor("cat concat cats")
        let session = try session(editor)
        let options = FindTestOptions()
        options.startsWith = true
        try await search(session, "cat", options, expecting: 2)
    }

    func testEmojiAndCRLFUseUTF16AndLineAnchors() async throws {
        let editor = editor("😀 cat\r\ncat 😀\r\n")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        let options = FindTestOptions()
        try await search(session, "cat$", options, expecting: 1)
        try await search(session, "^cat", options, expecting: 1)
        try await search(session, "😀", options, expecting: 2)
        session.replaceAll(searchQuery: "^cat", replacementString: "dog", options: options)
        let replaced = try await until { editor.textView.text == "😀 cat\r\ndog 😀\r\n" }
        XCTAssertTrue(replaced)
        session.replaceAll(searchQuery: "😀", replacementString: "🙂🙂", options: options)
        let both = try await until { editor.textView.text == "🙂🙂 cat\r\ndog 🙂🙂\r\n" }
        XCTAssertTrue(both)
    }

    func testManyMatchesAreDeliveredInChunks() async throws {
        let editor = editor(String(repeating: "ab\n", count: 3000))
        let session = try session(editor)
        try await search(session, "b$", FindTestOptions(), expecting: 3000)
    }

    func testEmptyDocumentAndEmptyQuery() async throws {
        let editor = editor("")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        let options = FindTestOptions()
        session.performSearch(query: "a", options: options)
        let done = try await until { editor.regexFind.status == .idle && session.resultCount == 0 }
        XCTAssertTrue(done)
        session.replaceAll(searchQuery: "a", replacementString: "b", options: options)
        session.replaceAll(searchQuery: "", replacementString: "b", options: options)
        XCTAssertEqual(editor.textView.text, "")
        XCTAssertNil(editor.regexFind.lastMessage)
    }

    func testInvalidPatternWhileTypingIsQuietButReplaceSaysSo() async throws {
        let editor = editor("a (b")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        let options = FindTestOptions()
        session.performSearch(query: "(b", options: options)
        let quiet = try await until { editor.regexFind.status == .invalidPattern }
        XCTAssertTrue(quiet)
        XCTAssertNil(editor.regexFind.lastMessage, "no toast or announcement while typing")
        session.replaceAll(searchQuery: "(b", replacementString: "x", options: options)
        let said = try await until { editor.regexFind.lastMessage == "Invalid pattern" }
        XCTAssertTrue(said)
        XCTAssertEqual(editor.textView.text, "a (b")
    }

    func testTooManyMatchesAndTimeoutHaveTheirOwnMessages() async throws {
        let editor = editor(String(repeating: "a\n", count: RegexFind.maxHighlightedMatches + 1))
        let session = try session(editor)
        let options = FindTestOptions()
        session.performSearch(query: "a", options: options)
        let many = try await until { editor.regexFind.status == .tooManyMatches }
        XCTAssertTrue(many)
        XCTAssertTrue(editor.regexFind.lastMessage?.contains("matches") == true)
        XCTAssertEqual(session.resultCount, 0)
        let slow = self.editor("aaa")
        let slowSession = try self.session(slow)
        slow.regexFind.timeLimitOverride = 0
        slowSession.performSearch(query: "a", options: options)
        let timedOut = try await until { slow.regexFind.status == .timedOut }
        XCTAssertTrue(timedOut)
        XCTAssertTrue(slow.regexFind.lastMessage?.contains("too long") == true)
        XCTAssertNotEqual(slow.regexFind.lastMessage, editor.regexFind.lastMessage)
    }

    func testReplaceAllExceedsHighlightCap() async throws {
        let count = RegexFind.maxHighlightedMatches + 500
        let editor = editor(String(repeating: "a\n", count: count))
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        session.replaceAll(searchQuery: "^a$", replacementString: "bb", options: FindTestOptions())
        let done = try await until(30) { editor.textView.text == String(repeating: "bb\n", count: count) }
        XCTAssertTrue(done)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, String(repeating: "a\n", count: count), "one undo step for all of them")
    }

    func testReplaceAllRefusesOverReplacementLimit() async throws {
        let text = String(repeating: "a\n", count: RegexFind.maxReplacements + 1)
        let editor = editor(text)
        editor.regexFind.timeLimitOverride = 60
        let session = try session(editor)
        session.replaceAll(searchQuery: "a", replacementString: "b", options: FindTestOptions())
        let reported = try await until(60) { editor.regexFind.lastMessage != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(editor.regexFind.lastMessage, String(localized: "Too many replacements (\(RegexFind.maxReplacements)+). Narrow the pattern."))
        XCTAssertEqual(editor.textView.text, text)
    }

    func testToggleKeepsVisibleFindSession() async throws {
        let editor = editor("cat c.t")
        let interaction = try XCTUnwrap(editor.textView.findInteraction)
        interaction.presentFindNavigator(showingReplace: false)
        let visible = try await until { interaction.isFindNavigatorVisible && interaction.activeFindSession != nil }
        XCTAssertTrue(visible)
        let active = try XCTUnwrap(interaction.activeFindSession)
        editor.regexFind.setEnabled(false)
        XCTAssertTrue(interaction.isFindNavigatorVisible)
        XCTAssertTrue(interaction.activeFindSession === active)
        editor.regexFind.setEnabled(true)
        XCTAssertTrue(interaction.isFindNavigatorVisible)
        XCTAssertTrue(interaction.activeFindSession === active)
        interaction.dismissFindNavigator()
        interaction.presentFindNavigator(showingReplace: true)
        let replaceVisible = try await until { interaction.isFindNavigatorVisible && interaction.activeFindSession != nil }
        XCTAssertTrue(replaceVisible)
        let replaceSession = try XCTUnwrap(interaction.activeFindSession)
        editor.regexFind.setEnabled(false)
        XCTAssertTrue(interaction.isFindNavigatorVisible)
        XCTAssertTrue(interaction.activeFindSession === replaceSession)
    }

    func testReplaceAllRerunsWhenTheDocumentChangedMidFlight() async throws {
        let editor = editor("a a")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        session.replaceAll(searchQuery: "a", replacementString: "b", options: FindTestOptions())
        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        editor.textView.insertText(" a")
        let done = try await until { editor.textView.text == "b b b" }
        XCTAssertTrue(done, "saw \(editor.textView.text ?? "")")
    }

    func testEditDuringInFlightSearchGivesResultsForTheNewText() async throws {
        let editor = editor("a a")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        session.performSearch(query: "a", options: FindTestOptions())
        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        editor.textView.insertText(" a a")
        let done = try await until { session.resultCount == 4 }
        XCTAssertTrue(done, "saw \(session.resultCount)")
    }

    func testReplaceRightAfterReplaceIsNotSwallowed() async throws {
        let editor = editor("cat cat cat")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        let options = FindTestOptions()
        try await search(session, "cat", options, expecting: 3)
        let view = editor.textView
        let find = editor.regexFind
        find.replace(foundTextRange: try textRange(NSRange(location: 0, length: 3), in: view), document: nil, withText: "horse")
        XCTAssertEqual(view.text, "horse cat cat")
        // No search has finished since; the next match is where it moved to.
        find.replace(foundTextRange: try textRange(NSRange(location: 6, length: 3), in: view), document: nil, withText: "ox")
        XCTAssertEqual(view.text, "horse ox cat")
        find.replace(foundTextRange: try textRange(NSRange(location: 9, length: 3), in: view), document: nil, withText: "$0!")
        XCTAssertEqual(view.text, "horse ox cat!", "$0 is the whole match")
        view.undoManager?.undo()
        XCTAssertEqual(view.text, "horse ox cat")
    }

    func testReplaceWhileComposingTextReportsInsteadOfDoingNothing() async throws {
        let editor = editor("cat")
        editor.textView.becomeFirstResponder()
        let session = try session(editor)
        let options = FindTestOptions()
        try await search(session, "cat", options, expecting: 1)
        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        editor.textView.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
        guard editor.textView.markedTextRange != nil else { throw XCTSkip("no marked text in this environment") }
        session.replaceAll(searchQuery: "cat", replacementString: "dog", options: options)
        XCTAssertEqual(editor.regexFind.lastMessage, "Finish entering text before replacing.")
        XCTAssertTrue(editor.textView.text.hasPrefix("cat"))
    }
}
