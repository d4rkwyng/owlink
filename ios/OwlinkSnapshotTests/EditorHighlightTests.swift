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

    func testBracketPairInAllLanguagesCoexistsWithFocus() throws {
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
        XCTAssertNotNil(try background(at: 4, in: editor))
        XCTAssertNotNil(try background(at: 9, in: editor))
        // Bracket matching does not depend on "Highlight occurrences" (the Mac ignores it too).
        AppSettings.highlightOccurrences = false
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 4, in: editor))
        XCTAssertNotNil(try background(at: 9, in: editor))
    }

    func testOccurrencesOffKeepsBracketsOnly() throws {
        AppSettings.highlightOccurrences = false
        let editor = editor("(alpha) alpha")
        editor.textView.selectedRange = NSRange(location: 1, length: 0)
        editor.refreshEditorHighlights()
        XCTAssertNil(try background(at: 8, in: editor))
        editor.textView.selectedRange = NSRange(location: 7, length: 0)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 0, in: editor))
        XCTAssertNotNil(try background(at: 6, in: editor))
        XCTAssertNil(try background(at: 9, in: editor))
    }

    func testEmojiBeforeMatchUsesUTF16Offsets() throws {
        let text = "😀😀 alpha alpha"
        let editor = editor(text)
        let ns = text as NSString
        let second = ns.range(of: "alpha", options: .backwards).location
        editor.textView.selectedRange = NSRange(location: ns.range(of: "alpha").location, length: 5)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: second, in: editor))
        XCTAssertNotNil(try background(at: second + 4, in: editor))
        XCTAssertNil(try background(at: second - 1, in: editor))
        XCTAssertNil(try background(at: ns.range(of: "alpha").location, in: editor))
    }

    func testDisappearingClearsHighlights() throws {
        let editor = editor("alpha alpha")
        editor.textView.selectedRange = NSRange(location: 1, length: 0)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 7, in: editor))
        editor.viewDidDisappear(false)
        XCTAssertNil(try background(at: 7, in: editor))
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 7, in: editor))
    }

    func testScrollPathDoesNotRefreshSynchronously() throws {
        let editor = editor("alpha alpha")
        editor.textView.selectedRange = NSRange(location: 1, length: 0)
        editor.scrollViewDidScroll(editor.textView)
        // Only the debounced pass paints on scroll; nothing is drawn yet.
        XCTAssertNil(try background(at: 7, in: editor))
    }

    func testDebouncedSelectionAndCRLF() async throws {
        let editor = editor("alpha\r\nalpha\r\nlast")
        editor.textView.selectedRange = NSRange(location: 1, length: 0)
        editor.textViewDidChangeSelection(editor.textView)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(try background(at: 8, in: editor))
        editor.textView.selectedRange = NSRange(location: editor.textView.textStorage.length, length: 0)
        editor.textViewDidChangeSelection(editor.textView)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(try background(at: 8, in: editor))
    }

    func testMarkedTextAndEmptyDocument() throws {
        let editor = editor("xx alpha alpha")
        editor.textView.selectedRange = NSRange(location: 3, length: 5)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 9, in: editor))
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.setMarkedText("y", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(editor.textView.markedTextRange)
        editor.refreshEditorHighlights()
        XCTAssertNil(try background(at: 10, in: editor))
        editor.textView.unmarkText()
        editor.textView.selectedRange = NSRange(location: 4, length: 5)
        editor.refreshEditorHighlights()
        XCTAssertNotNil(try background(at: 10, in: editor), "highlights come back once the composition is committed")
        let empty = self.editor("")
        empty.refreshEditorHighlights()
        XCTAssertEqual(empty.textView.text, "")
        XCTAssertNil(try background(at: 0, in: empty))
    }

    func testScrollingRefreshesVisibleOccurrences() async throws {
        let text = (["alpha"] + Array(repeating: "filler", count: 100) + ["alpha", "alpha"]).joined(separator: "\n")
        let editor = editor(text)
        editor.textView.selectedRange = NSRange(location: 0, length: 5)
        editor.textViewDidChangeSelection(editor.textView)
        let last = (text as NSString).range(of: "alpha", options: .backwards).location
        editor.textView.setContentOffset(CGPoint(x: 0, y: 1_000), animated: false)
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.scrollViewDidScroll(editor.textView)
        try await Task.sleep(for: .milliseconds(200))
        let visible = try XCTUnwrap(editor.editorVisibleRange())
        XCTAssertTrue(NSLocationInRange(last, visible))
        XCTAssertNotNil(try background(at: last, in: editor))
    }
}
