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
        let group = try XCTUnwrap(menu.children.first as? UIMenu)
        XCTAssertTrue(group.children.contains { $0.title == "Copy as HTML" })
        XCTAssertTrue(group.children.contains { $0.title == "Copy as Rich Text" })
        await withCheckedContinuation { continuation in
            editor.copyMarkdown(rich: false, selection: range) { continuation.resume() }
        }
        let html = try XCTUnwrap(pasteboard.item[UTType.html.identifier] as? Data)
        let fragment = try XCTUnwrap(String(data: html, encoding: .utf8))
        XCTAssertTrue(fragment.contains("<strong>bold</strong>"))
        XCTAssertFalse(fragment.contains("Before"))
        XCTAssertEqual(pasteboard.item[UTType.utf8PlainText.identifier] as? String, fragment)

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
        XCTAssertTrue(attributed.string.contains("Before bold after"))
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
}
