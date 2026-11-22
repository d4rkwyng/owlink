import XCTest
import UIKit
import CedricCore

@MainActor
final class MarkdownTypingTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var previousPasteboardItems: [[String: Any]]?
    private var previousAutoCloseBrackets: Any?

    override func setUp() async throws {
        previousPasteboardItems = UIPasteboard.general.items
        previousAutoCloseBrackets = AppSettings.defaults.object(forKey: AppSettings.Key.autoCloseBrackets)
        AppSettings.autoCloseBrackets = true
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        if let previousPasteboardItems { UIPasteboard.general.items = previousPasteboardItems }
        if let previousAutoCloseBrackets {
            AppSettings.defaults.set(previousAutoCloseBrackets, forKey: AppSettings.Key.autoCloseBrackets)
        } else {
            AppSettings.defaults.removeObject(forKey: AppSettings.Key.autoCloseBrackets)
        }
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
        type("\n", in: editor)
    }

    @discardableResult
    private func type(_ text: String, in editor: EditorViewController) -> Bool {
        let range = editor.textView.selectedRange
        let shouldChange = editor.textView(editor.textView, shouldChangeTextIn: range, replacementText: text)
        if shouldChange,
           let start = editor.textView.position(from: editor.textView.beginningOfDocument, offset: range.location),
           let end = editor.textView.position(from: start, offset: range.length),
           let textRange = editor.textView.textRange(from: start, to: end) {
            editor.textView.replace(textRange, withText: text)
        }
        return shouldChange
    }

    @discardableResult
    private func backspace(_ editor: EditorViewController) -> Bool {
        let caret = editor.textView.selectedRange.location
        precondition(caret > 0)
        return delete(in: editor, range: NSRange(location: caret - 1, length: 1))
    }

    /// Forward delete at the caret (hardware Forward Delete): range is (caret, 1).
    @discardableResult
    private func forwardDelete(_ editor: EditorViewController) -> Bool {
        let caret = editor.textView.selectedRange.location
        let length = (editor.textView.text! as NSString).length
        precondition(caret < length)
        return delete(in: editor, range: NSRange(location: caret, length: 1))
    }

    @discardableResult
    private func delete(in editor: EditorViewController, range: NSRange) -> Bool {
        let shouldChange = editor.textView(editor.textView, shouldChangeTextIn: range, replacementText: "")
        if shouldChange,
           let start = editor.textView.position(from: editor.textView.beginningOfDocument, offset: range.location),
           let end = editor.textView.position(from: start, offset: range.length),
           let textRange = editor.textView.textRange(from: start, to: end) {
            editor.textView.replace(textRange, withText: "")
        }
        return shouldChange
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
        XCTAssertNil(editor.pendingGroupsByEvent)
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

    func testReturnInFenceAndOtherLanguageUsesAutoIndent() {
        let fenced = editor(text: "```\n- item\n```")
        let position = (fenced.textView.text! as NSString).range(of: "- item").location + 6
        fenced.textView.selectedRange = NSRange(location: position, length: 0)
        // No indent to keep: the system inserts the newline (same as the Mac).
        XCTAssertTrue(pressReturn(fenced))
        XCTAssertEqual(fenced.textView.text, "```\n- item\n\n```")

        let swift = editor(.swift, text: "- item")
        swift.textView.selectedRange = NSRange(location: 6, length: 0)
        XCTAssertTrue(pressReturn(swift))
        XCTAssertEqual(swift.textView.text, "- item\n")

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
        XCTAssertEqual(plain.textView.text, "key: value\n")
    }

    func testAutoIndentAndPairEdits() {
        let code = editor(.swift, text: "    if ready {")
        code.textView.selectedRange = NSRange(location: (code.textView.text! as NSString).length, length: 0)
        XCTAssertFalse(pressReturn(code))
        XCTAssertEqual(code.textView.text, "    if ready {\n        ")

        let pair = editor(.swift, text: "    call()")
        pair.textView.selectedRange = NSRange(location: 9, length: 0)
        XCTAssertFalse(pressReturn(pair))
        XCTAssertEqual(pair.textView.text, "    call(\n        \n    )")
        XCTAssertEqual(pair.textView.selectedRange.location, 18)

        let prose = editor(text: "  paragraph")
        prose.textView.selectedRange = NSRange(location: 11, length: 0)
        XCTAssertFalse(pressReturn(prose))
        XCTAssertEqual(prose.textView.text, "  paragraph\n  ")
    }

    func testPairSkipWrapAndBackspace() {
        let pair = editor(.swift, text: " ")
        pair.textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(type("(", in: pair))
        XCTAssertEqual(pair.textView.text, "() ")
        XCTAssertEqual(pair.textView.selectedRange.location, 1)
        XCTAssertEqual(pair.autoClosers, [1])
        XCTAssertFalse(type(")", in: pair))
        XCTAssertEqual(pair.textView.text, "() ")
        XCTAssertEqual(pair.textView.selectedRange.location, 2)

        let shifted = editor(.swift, text: "")
        XCTAssertFalse(type("\"", in: shifted))
        XCTAssertEqual(shifted.autoClosers, [1])
        XCTAssertTrue(type("x", in: shifted))
        XCTAssertEqual(shifted.autoClosers, [2])
        XCTAssertFalse(type("\"", in: shifted))
        XCTAssertEqual(shifted.textView.text, "\"x\"")

        let existingQuote = editor(.swift, text: "\"")
        existingQuote.textView.selectedRange = NSRange(location: 0, length: 0)
        // Not a pairing skip (the closer was already in the file). The quote
        // is still inserted exactly, so typographic substitution cannot rewrite it.
        XCTAssertFalse(type("\"", in: existingQuote))
        XCTAssertEqual(existingQuote.textView.text, "\"\"")
        XCTAssertEqual(existingQuote.textView.selectedRange.location, 1)

        let wrapped = editor(.swift, text: "word")
        wrapped.textView.selectedRange = NSRange(location: 0, length: 4)
        XCTAssertFalse(type("[", in: wrapped))
        XCTAssertEqual(wrapped.textView.text, "[word]")
        XCTAssertEqual(wrapped.textView.selectedRange, NSRange(location: 1, length: 4))

        let deleted = editor(.swift, text: "")
        XCTAssertFalse(type("(", in: deleted))
        XCTAssertFalse(backspace(deleted))
        XCTAssertEqual(deleted.textView.text, "")
        XCTAssertEqual(deleted.textView.selectedRange.location, 0)

        let ordinary = editor(.swift, text: "(x)")
        ordinary.textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertTrue(backspace(ordinary))
        XCTAssertEqual(ordinary.textView.text, "()")

        // Pair-delete at a non-zero offset, and a quote pair.
        let offset = editor(.swift, text: "a()")
        offset.textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(backspace(offset))
        XCTAssertEqual(offset.textView.text, "a")
        XCTAssertEqual(offset.textView.selectedRange.location, 1)

        let quotes = editor(.swift, text: "")
        XCTAssertFalse(type("\"", in: quotes))
        XCTAssertFalse(backspace(quotes))
        XCTAssertEqual(quotes.textView.text, "")
        XCTAssertEqual(quotes.textView.selectedRange.location, 0)

        // Forward delete must not pair-delete: |() becomes ).
        let forward = editor(.swift, text: "()")
        forward.textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(forwardDelete(forward))
        XCTAssertEqual(forward.textView.text, ")")
        XCTAssertEqual(forward.textView.selectedRange.location, 0)
    }

    func testPairingLanguageAndSettingGatesDoNotDisableAutoIndent() {
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.autoCloseBrackets)
        XCTAssertTrue(AppSettings.autoCloseBrackets)
        AppSettings.autoCloseBrackets = true
        for language in [Language.markdown, .plain, .diff] {
            let value = editor(language, text: "")
            XCTAssertTrue(type("(", in: value), "\(language)")
            XCTAssertEqual(value.textView.text, "(")
        }

        let swift = editor(.swift, text: "if ready {")
        swift.textView.selectedRange = NSRange(location: (swift.textView.text! as NSString).length, length: 0)
        AppSettings.autoCloseBrackets = false
        XCTAssertTrue(type("(", in: swift))
        XCTAssertEqual(swift.textView.text, "if ready {(")
        swift.textView.selectedRange = NSRange(location: (swift.textView.text! as NSString).length, length: 0)
        XCTAssertFalse(pressReturn(swift))
        XCTAssertEqual(swift.textView.text, "if ready {(\n    ")
    }

    func testPythonClauseRealignment() {
        let python = editor(.python, text: "if ready:\n    pass\n        else")
        python.textView.selectedRange = NSRange(location: (python.textView.text! as NSString).length, length: 0)
        XCTAssertFalse(type(":", in: python))
        XCTAssertEqual(python.textView.text, "if ready:\n    pass\nelse:")
    }

    func testYAMLColonAndPythonPassDedentOnReturn() {
        let yaml = editor(.yaml, text: "key:")
        yaml.textView.selectedRange = NSRange(location: 4, length: 0)
        XCTAssertFalse(pressReturn(yaml))
        XCTAssertEqual(yaml.textView.text, "key:\n  ")

        let python = editor(.python, text: "    pass")
        python.textView.selectedRange = NSRange(location: 8, length: 0)
        // Dedent to column 0 is a plain newline; the system inserts it.
        XCTAssertTrue(pressReturn(python))
        XCTAssertEqual(python.textView.text, "    pass\n")
        python.textView.undoManager?.undo()
        XCTAssertEqual(python.textView.text, "    pass")
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
