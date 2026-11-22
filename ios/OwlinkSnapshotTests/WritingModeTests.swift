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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        editor.updateWriting()
        XCTAssertGreaterThan(editor.textView.contentOffset.y, 0)
        if let position = editor.textView.selectedTextRange?.end {
            let caret = editor.textView.caretRect(for: position)
            let top = editor.textView.contentOffset.y + editor.textView.adjustedContentInset.top
            let bottom = editor.textView.contentOffset.y + editor.textView.bounds.height
            XCTAssertEqual(caret.midY, (top + bottom) / 2, accuracy: 30)
        } else {
            XCTFail("Missing caret")
        }
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
        XCTAssertGreaterThan((editor.editorVisibleRange()?.length ?? 0), 20)
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

    func testChangingUnitReappliesFocusThroughSettings() async throws {
        let text = "First sentence. Second sentence.\r\n\r\nLast paragraph."
        let editor = editor(text)
        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        editor.toggleWritingFocus()
        editor.updateWriting()
        AppSettings.focusUnit = .sentence
        try await Task.sleep(for: .milliseconds(150))
        let layout = try XCTUnwrap(editor.textView.textLayoutManager)
        let manager = try XCTUnwrap(layout.textContentManager)
        let visible = try XCTUnwrap(editor.editorVisibleRange())
        let expected = FocusRange.dimmed(visible: visible, focus: FocusRange.range(.sentence, in: text as NSString, caret: 2))
        var actual: [NSRange] = []
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.foregroundColor] != nil {
                let start = manager.offset(from: layout.documentRange.location, to: range.location)
                let end = manager.offset(from: layout.documentRange.location, to: range.endLocation)
                actual.append(NSRange(location: start, length: end - start))
            }
            return true
        }
        XCTAssertEqual(actual, expected)
    }

    func testLargeDocumentPausesWritingAndRestoresInset() {
        let editor = editor(String(repeating: "a", count: LargeDocument.lineThreshold + 1))
        XCTAssertEqual(editor.writingLargeReason, .longLine)
        let base = editor.textView.contentInset
        editor.toggleWritingFocus()
        editor.toggleTypewriter()
        editor.updateWriting()
        XCTAssertEqual(editor.textView.contentInset, base)
        XCTAssertTrue(editor.writing.focus)
        XCTAssertTrue(editor.writing.typewriter)
    }

    func testEmptyDocumentAndEndCaret() {
        let empty = editor("")
        empty.toggleWritingFocus()
        empty.toggleTypewriter()
        empty.updateWriting()
        XCTAssertEqual(empty.textView.text, "")
        let end = editor("One.\r\n\r\nLast.")
        end.textView.selectedRange = NSRange(location: end.textView.textStorage.length, length: 0)
        end.toggleWritingFocus()
        end.updateWriting()
        XCTAssertEqual(end.textView.text, "One.\r\n\r\nLast.")
    }

    // MARK: Follow-up fixes

    /// Polls the run loop until `condition` holds or `timeout` passes.
    private func wait(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func dimmedRanges(_ editor: EditorViewController) throws -> [NSRange] {
        let layout = try XCTUnwrap(editor.textView.textLayoutManager)
        let manager = try XCTUnwrap(layout.textContentManager)
        var actual: [NSRange] = []
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.foregroundColor] != nil {
                let start = manager.offset(from: layout.documentRange.location, to: range.location)
                let end = manager.offset(from: layout.documentRange.location, to: range.endLocation)
                actual.append(NSRange(location: start, length: end - start))
            }
            return true
        }
        return actual
    }

    func testEditBeforeDimmedSpanLeavesExactDimmedSet() throws {
        let editor = editor("First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
        editor.textView.selectedRange = NSRange(location: 20, length: 0)
        editor.toggleWritingFocus()
        editor.updateWriting()
        XCTAssertFalse(try dimmedRanges(editor).isEmpty)
        // Type before the dimmed first paragraph; the caret stays in the second.
        editor.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Inserted words here. ")
        editor.textView.selectedRange = NSRange(location: 41, length: 0)
        editor.textViewDidChange(editor.textView)
        XCTAssertTrue(wait {
            guard let visible = editor.editorVisibleRange() else { return false }
            let text = editor.textView.text as NSString
            let expected = FocusRange.dimmed(visible: visible, focus: FocusRange.range(.paragraph, in: text, caret: 41))
            return (try? self.dimmedRanges(editor)) == expected
        }, "dimmed set follows the edit exactly: \((try? dimmedRanges(editor)) ?? [])")
    }

    func testRecentresAfterReplace() throws {
        let editor = editor(String(repeating: "A line of text.\n", count: 120))
        editor.toggleTypewriter()
        let end = editor.textView.textStorage.length
        editor.textView.selectedRange = NSRange(location: end, length: 0)
        editor.updateWriting()
        let atEnd = editor.textView.contentOffset.y
        // Move the view away, then an edit through replace(_:withText:) pulls it back to the caret.
        editor.textView.setContentOffset(.zero, animated: false)
        let caret = try XCTUnwrap(editor.textView.selectedTextRange)
        editor.textView.replace(caret, withText: "!")
        XCTAssertTrue(wait { editor.textView.contentOffset.y > atEnd / 2 }, "recentred after replace(_:withText:)")
    }

    func testFarCaretDoesNotChangeContentSizeByHand() {
        let editor = editor(String(repeating: "A line of text.\n", count: 400))
        editor.toggleTypewriter()
        editor.textView.selectedRange = NSRange(location: editor.textView.textStorage.length, length: 0)
        editor.updateWriting()
        let size = editor.textView.contentSize
        editor.updateWriting()
        XCTAssertEqual(editor.textView.contentSize, size)
        XCTAssertGreaterThan(editor.textView.contentOffset.y, 0)
    }

    func testWholeTextReplacementLeavesLargeMode() {
        let editor = editor(String(repeating: "a", count: LargeDocument.lineThreshold + 1))
        XCTAssertEqual(editor.writingLargeReason, .longLine)
        editor.replaceAllText(with: "short\ntext")
        XCTAssertNil(editor.writingLargeReason)
    }

    func testDistantFocusRefreshLeavesMiddleRenderingAlone() throws {
        let text = String(repeating: "A line of text.\n", count: 800)
        let editor = editor(text)
        editor.toggleWritingFocus()
        editor.updateWriting()
        let initialVisible = try XCTUnwrap(editor.editorVisibleRange())
        let layout = try XCTUnwrap(editor.textView.textLayoutManager)
        let manager = try XCTUnwrap(layout.textContentManager)
        let middle = (text as NSString).length / 2
        let location = try XCTUnwrap(manager.location(layout.documentRange.location, offsetBy: middle))
        let end = try XCTUnwrap(manager.location(location, offsetBy: 1))
        let marker = try XCTUnwrap(NSTextRange(location: location, end: end))
        let color = UIColor.magenta
        layout.addRenderingAttribute(.foregroundColor, value: color, for: marker)
        editor.textView.selectedRange = NSRange(location: (text as NSString).length - 1, length: 0)
        editor.textView.setContentOffset(CGPoint(x: 0, y: max(0, editor.textView.contentSize.height - editor.textView.bounds.height)), animated: false)
        layout.textViewportLayoutController.layoutViewport()
        editor.updateWriting(center: false)
        let finalVisible = try XCTUnwrap(editor.editorVisibleRange())
        XCTAssertLessThan(NSMaxRange(initialVisible), middle)
        XCTAssertGreaterThan(finalVisible.location, middle)
        var actual: UIColor?
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, range in
            let start = manager.offset(from: layout.documentRange.location, to: range.location)
            let finish = manager.offset(from: layout.documentRange.location, to: range.endLocation)
            if start <= middle && middle < finish { actual = attributes[.foregroundColor] as? UIColor }
            return true
        }
        XCTAssertEqual(actual, color)
    }
}
