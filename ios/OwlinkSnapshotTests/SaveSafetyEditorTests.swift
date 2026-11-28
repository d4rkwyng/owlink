import XCTest
import UIKit
import CedricCore

/// Save safety in the editor: mixed line endings stay byte-for-byte
/// through Undo, Redo, IME composition and typing, and the recovery
/// writer's first copy is taken at once.
@MainActor
final class SaveSafetyEditorTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var previousAutoCloseBrackets: Any?

    override func setUp() async throws {
        previousAutoCloseBrackets = AppSettings.defaults.object(forKey: AppSettings.Key.autoCloseBrackets)
        AppSettings.autoCloseBrackets = true
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        if let previousAutoCloseBrackets {
            AppSettings.defaults.set(previousAutoCloseBrackets, forKey: AppSettings.Key.autoCloseBrackets)
        } else {
            AppSettings.defaults.removeObject(forKey: AppSettings.Key.autoCloseBrackets)
        }
    }

    /// An editor on `bytes` as read from disk (so the document keeps its mixed endings).
    private func editor(bytes: String, language: Language = .swift) throws -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift"))
        try doc.load(fromContents: Data(bytes.utf8), ofType: nil)
        doc.language.choose(language)
        XCTAssertTrue(doc.mixedLineEndings)
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        editor.textView.becomeFirstResponder()
        windows.append(window)
        return editor
    }

    /// One main run-loop turn, as between two key presses: the deferred
    /// groupsByEvent restore after a command edit runs, so the next system
    /// edit has its undo group.
    private func nextTurn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func saved(_ editor: EditorViewController) throws -> String {
        String(decoding: try editor.document.serialized(editor.textView.textStorage.string), as: UTF8.self)
    }

    /// Types `text` over `range` as the system would: the delegate first,
    /// then (only if it lets the system) the change itself, which doesn't
    /// call the delegate again.
    @discardableResult
    private func type(_ text: String, at range: NSRange, in editor: EditorViewController) -> Bool {
        editor.textView.selectedRange = range
        let systemApplies = editor.textView(editor.textView, shouldChangeTextIn: range, replacementText: text)
        if systemApplies { editor.textView.textStorage.replaceCharacters(in: range, with: text) }
        return systemApplies
    }

    func testUndoAndRedoKeepAMinorityCRLFByteForByte() throws {
        let original = "a\nb\r\nc\nd\ne\n"
        let editor = try editor(bytes: original, language: .plain)
        XCTAssertEqual(editor.textView.text, "a\nb\nc\nd\ne\n")
        // "b\nc" holds the only CRLF.
        XCTAssertTrue(editor.applyTextEdit(TextEdit(range: NSRange(location: 2, length: 3), replacement: "X",
                                                    selection: NSRange(location: 3, length: 0)), actionName: "Test"))
        XCTAssertEqual(try saved(editor), "a\nX\nd\ne\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try saved(editor), original)
        editor.textView.undoManager?.redo()
        XCTAssertEqual(try saved(editor), "a\nX\nd\ne\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try saved(editor), original)
    }

    /// The same through the ordinary path: Backspace over the minority
    /// CRLF (the system's own edit), then the text view's undo and redo.
    func testBackspaceOverAMinorityCRLFThenSystemUndoAndRedoKeepItByteForByte() throws {
        let original = "a\nb\r\nc\nd\ne\n"
        let editor = try editor(bytes: original, language: .plain)
        let undo = try XCTUnwrap(editor.textView.undoManager)
        nextTurn()
        // The caret after "b\n": Backspace deletes the "\n" that is a CRLF on disk.
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        editor.textView.deleteBackward()
        XCTAssertEqual(editor.textView.text, "a\nbc\nd\ne\n")
        XCTAssertEqual(try saved(editor), "a\nbc\nd\ne\n")
        nextTurn()
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.textView.text, "a\nb\nc\nd\ne\n")
        XCTAssertEqual(try saved(editor), original, "system undo puts the CRLF back")
        nextTurn()
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(try saved(editor), "a\nbc\nd\ne\n")
        nextTurn()
        undo.undo()
        XCTAssertEqual(try saved(editor), original)
    }

    /// Each accepted edit is noted once: a system edit (plain typing), one
    /// applied by a command (auto-indent Return, a bracket pair), and an
    /// IME composition before the CRLF (consecutive marked-text updates
    /// that change the UTF-16 length, then committed), which stays the one
    /// after "y".
    func testEveryAcceptedEditBeforeAMinorityBreakIsNotedOnce() throws {
        let editor = try editor(bytes: "  x\ny\r\nz\nw\nv\n")
        func expected() -> String { editor.textView.textStorage.string.replacingOccurrences(of: "y\n", with: "y\r\n") }

        XCTAssertFalse(type("\n", at: NSRange(location: 3, length: 0), in: editor), "auto-indent applies it")
        XCTAssertEqual(try saved(editor), expected())
        nextTurn()

        XCTAssertTrue(type("Q", at: NSRange(location: 0, length: 0), in: editor), "the system types it")
        XCTAssertEqual(try saved(editor), expected())
        nextTurn()

        type("(", at: NSRange(location: 1, length: 0), in: editor)
        XCTAssertEqual(try saved(editor), expected())
        nextTurn()

        // Composition at the start, before the CRLF: each update replaces
        // the marked range with text of another UTF-16 length.
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(editor.textView.markedTextRange)
        XCTAssertEqual(try saved(editor), expected())
        editor.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(try saved(editor), expected())
        editor.textView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(try saved(editor), expected())
        editor.textView.setMarkedText("仮名😀", selectedRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(try saved(editor), expected())
        editor.textView.unmarkText()
        XCTAssertNil(editor.textView.markedTextRange)
        XCTAssertTrue(try saved(editor).hasPrefix("仮名😀Q("))
        XCTAssertEqual(try saved(editor), expected())
        let breaks = try saved(editor).components(separatedBy: "\r\n").count - 1
        XCTAssertEqual(breaks, 1, "still the one CRLF")
    }

    /// A command that declines (returns false) changes neither the text
    /// nor the line-ending entries.
    func testADeclinedCommandLeavesTheBreaksAlone() throws {
        let original = "a\nb\r\nc\nd\ne\n"
        let editor = try editor(bytes: original, language: .plain)
        let length = editor.textView.textStorage.length
        let before = try saved(editor)
        XCTAssertFalse(editor.applyTextEdit(TextEdit(range: NSRange(location: 2, length: length), replacement: "X",
                                                     selection: NSRange(location: 0, length: 0)), actionName: "Test"))
        XCTAssertFalse(editor.applyTextEdits([], selection: NSRange(location: 0, length: 0), actionName: "Test"))
        XCTAssertFalse(editor.applyTextEdits([(NSRange(location: 4, length: 1), "Y"), (NSRange(location: 2, length: 1), "Z")],
                                             selection: NSRange(location: 0, length: 0), actionName: "Test"),
                       "out of order")
        XCTAssertEqual(try saved(editor), before)
        XCTAssertEqual(before, original)
        // The text and its entries still line up: an edit after the CRLF keeps it.
        XCTAssertTrue(editor.applyTextEdit(TextEdit(range: NSRange(location: 6, length: 1), replacement: "DD",
                                                    selection: NSRange(location: 8, length: 0)), actionName: "Test"))
        XCTAssertEqual(try saved(editor), "a\nb\r\nc\nDD\ne\n")
    }

    /// The first unsaved edit is copied before textChanged() returns (no
    /// run-loop turn); the next one waits for the throttle.
    func testRecoveryWriterCopiesTheFirstEditAtOnceAndDefersTheNext() throws {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.updateChangeCount(.done)
        XCTAssertTrue(doc.hasUnsavedChanges)
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        var written: [RecoveryRecord] = []
        var text = "one"
        let writer = RecoveryWriter(document: doc, snapshot: { text }, now: { clock }, write: { written.append($0) })
        defer { writer.stop(keepingCopy: true) }

        writer.textChanged()
        XCTAssertEqual(written.map(\.text), ["one"], "written before textChanged() returned")
        XCTAssertFalse(writer.isWaiting)

        text = "two"
        clock += 1
        writer.textChanged()
        XCTAssertEqual(written.count, 1, "the second edit waits")
        XCTAssertTrue(writer.isWaiting)
        // Its timer fires (going to the background writes the same way).
        writer.writeNow()
        XCTAssertEqual(written.map(\.text), ["one", "two"])
        XCTAssertFalse(writer.isWaiting)
    }
}
