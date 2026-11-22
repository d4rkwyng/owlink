import XCTest
import UIKit
import UniformTypeIdentifiers
import CedricCore

@MainActor
private final class TestCopyPasteboard: CopyPasteboard {
    private(set) var changeCount = 0
    private(set) var item: [String: Any] = [:]
    func write(_ item: [String: Any]) {
        self.item = item
        changeCount += 1
    }
}

@MainActor
final class CopyMarkdownTests: XCTestCase {
    func testCopySelectionAndWholeDocumentAsHTMLAndRichText() async throws {
        let pasteboard = TestCopyPasteboard()
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = #"Before **bold** after <script>alert(1)</script><img src="https://evil.example/x" onerror="bad()">"#
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        editor.copyPasteboard = pasteboard
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        XCTAssertNotNil(editor.view.window)

        let range = (doc.text as NSString).range(of: "**bold**")
        let menu = try XCTUnwrap(editor.textView(editor.textView, editMenuForTextIn: range, suggestedActions: []))
        // The Line submenu comes first; the copy items are in the trailing group.
        let group = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first { $0.title == "Cedric" })
        XCTAssertTrue(group.children.contains { $0.title == "Copy as HTML" })
        XCTAssertTrue(group.children.contains { $0.title == "Copy as Rich Text" })
        await withCheckedContinuation { continuation in
            editor.copyMarkdown(rich: false, selection: range) { continuation.resume() }
        }
        let fragment = try XCTUnwrap(pasteboard.item[UTType.utf8PlainText.identifier] as? String)
        XCTAssertTrue(fragment.contains("<strong>bold</strong>"))
        XCTAssertFalse(fragment.contains("Before"))
        XCTAssertNil(pasteboard.item[UTType.html.identifier], "Copy as HTML puts the source as text only, as on the Mac")
        XCTAssertEqual(pasteboard.item.count, 1)

        await withCheckedContinuation { continuation in
            editor.copyMarkdown(rich: true, selection: NSRange(location: 0, length: 0)) { continuation.resume() }
        }
        let page = try XCTUnwrap(pasteboard.item[UTType.html.identifier] as? Data)
        let rendered = try XCTUnwrap(String(data: page, encoding: .utf8))
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("onerror"))
        XCTAssertFalse(rendered.contains("https://evil.example/x"))
        let rtf = try XCTUnwrap(pasteboard.item[UTType.rtf.identifier] as? Data)
        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(attributed.string.hasPrefix("Before bold after") || attributed.string.contains("\nBefore bold after"))
        XCTAssertTrue(rendered.contains("<strong>bold</strong>"))
        XCTAssertEqual(pasteboard.item[UTType.utf8PlainText.identifier] as? String, attributed.string)
    }

    func testStaleCopyDoesNotOverwriteNewPasteboardContents() async {
        let pasteboard = TestCopyPasteboard()
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "**first**"
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        editor.copyPasteboard = pasteboard
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        await withCheckedContinuation { continuation in
            editor.copyMarkdown(rich: false, selection: NSRange(location: 0, length: 0)) { continuation.resume() }
            pasteboard.write([UTType.utf8PlainText.identifier: "newer copy"])
        }
        XCTAssertEqual(pasteboard.item[UTType.utf8PlainText.identifier] as? String, "newer copy")
    }

    private func makeEditor(_ text: String, ext: String = "md", pasteboard: TestCopyPasteboard) -> (EditorViewController, UIWindow) {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        if ext == "md" { doc.language.choose(.markdown) }
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        editor.copyPasteboard = pasteboard
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (editor, window)
    }

    private func copy(_ editor: EditorViewController, rich: Bool, _ range: NSRange = NSRange(location: 0, length: 0)) async {
        await withCheckedContinuation { continuation in
            editor.copyMarkdown(rich: rich, selection: range) { continuation.resume() }
        }
    }

    func testNonMarkdownAndEmptyDocumentsWriteNothing() async {
        let pasteboard = TestCopyPasteboard()
        let (plain, w1) = makeEditor("**not markdown**", ext: "txt", pasteboard: pasteboard)
        defer { w1.isHidden = true; w1.rootViewController = nil }
        await copy(plain, rich: false)
        await copy(plain, rich: true)
        XCTAssertEqual(pasteboard.changeCount, 0)
        XCTAssertFalse(plain.canPerformAction(#selector(EditorViewController.copyAsHTML), withSender: nil))

        let (empty, w2) = makeEditor("  \n", pasteboard: pasteboard)
        defer { w2.isHidden = true; w2.rootViewController = nil }
        var announcements: [String] = []
        empty.announceAccessibility = { announcements.append($0) }
        await copy(empty, rich: false)
        await copy(empty, rich: true)
        XCTAssertEqual(announcements, ["Nothing to copy.", "Nothing to copy."])
        XCTAssertEqual(pasteboard.changeCount, 0)
        XCTAssertTrue(empty.canPerformAction(#selector(EditorViewController.copyAsHTML), withSender: nil))
    }

    func testCRLFAndEmojiSelectionsAndEscaping() async throws {
        let pasteboard = TestCopyPasteboard()
        let text = "Intro\r\n\r\n😀 **bold** 👩‍👩‍👧 and a < b & c\r\n"
        let (editor, window) = makeEditor(text, pasteboard: pasteboard)
        defer { window.isHidden = true; window.rootViewController = nil }
        let ns = text as NSString
        await copy(editor, rich: false, ns.range(of: "😀 **bold** 👩‍👩‍👧"))
        var html = try XCTUnwrap(pasteboard.item[UTType.utf8PlainText.identifier] as? String)
        XCTAssertTrue(html.contains("😀 <strong>bold</strong> 👩‍👩‍👧"))
        XCTAssertFalse(html.contains("Intro"))

        await copy(editor, rich: false, ns.range(of: "a < b & c"))
        html = try XCTUnwrap(pasteboard.item[UTType.utf8PlainText.identifier] as? String)
        XCTAssertTrue(html.contains("a &lt; b &amp; c"), html)
        XCTAssertFalse(html.contains("a < b"))
        XCTAssertFalse(html.contains("\r"))
    }

    func testRichTextCopyIsRefusedWhenHugeAndOutOfRangeSelectionIsIgnored() async {
        let pasteboard = TestCopyPasteboard()
        let (editor, window) = makeEditor("**x**", pasteboard: pasteboard)
        defer { window.isHidden = true; window.rootViewController = nil }
        await copy(editor, rich: false, NSRange(location: 40, length: 2))
        XCTAssertEqual(pasteboard.changeCount, 0)
        let big = String(repeating: "word ", count: EditorViewController.richTextCopyLimit / 5 + 10)
        editor.textView.text = big
        var announcements: [String] = []
        editor.announceAccessibility = { announcements.append($0) }
        await copy(editor, rich: true)
        XCTAssertEqual(announcements, ["That’s too much to copy as rich text. Select less."])
        XCTAssertEqual(pasteboard.changeCount, 0)
        await copy(editor, rich: false)
        XCTAssertEqual(pasteboard.changeCount, 1, "the HTML copy has no such limit")
    }
}
