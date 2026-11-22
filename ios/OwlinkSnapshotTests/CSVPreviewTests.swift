import XCTest
import UIKit
import CedricCore

@MainActor
final class CSVPreviewTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor(_ text: String, extension ext: String = "csv") -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(.csv)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = .regular
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private func waitForRender(_ grid: CSVPreviewController, after count: Int = 0) async throws {
        for _ in 0..<100 {
            if grid.renders > count { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("CSV preview did not finish")
    }

    func testSortAndFieldNavigationKeepSourceUnchanged() async throws {
        let text = "Name,Value\n\"é, x\",10\nbeta,2\n"
        let editor = editor(text)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.togglePreview), withSender: nil))
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        XCTAssertEqual(grid.data.rows, [["Name", "Value"], ["é, x", "10"], ["beta", "2"]])
        XCTAssertEqual(grid.order, [1, 2])
        let header = try XCTUnwrap(grid.table.tableHeaderView?.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "preview.csv.header.1" })
        header.sendActions(for: .primaryActionTriggered)
        try await waitForRender(grid, after: 1)
        XCTAssertEqual(grid.order, [2, 1])
        let row = grid.tableView(grid.table, cellForRowAt: IndexPath(row: 1, section: 0))
        let field = try XCTUnwrap(row.contentView.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "preview.csv.cell.1.0" })
        field.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.textView.selectedRange.location, (text as NSString).range(of: "é").location)
        XCTAssertEqual(editor.textView.text, text)
        grid.sort(column: 1)
        try await waitForRender(grid, after: 2)
        XCTAssertEqual(grid.order, [1, 2])
    }

    func testTSVFocusAndLanguageSwitch() async throws {
        let text = "name\tvalue\nalpha\t7\n"
        let editor = editor(text, extension: "tsv")
        editor.toggleFocusPreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        XCTAssertTrue(editor.focusOn)
        XCTAssertEqual(grid.data.rows, [["name", "value"], ["alpha", "7"]])
        grid.selectField(row: 1, column: 1)
        XCTAssertFalse(editor.focusOn)
        XCTAssertEqual(editor.textView.selectedRange.location, (text as NSString).range(of: "7").location)
        editor.setLanguage(.markdown)
        editor.togglePreview()
        XCTAssertFalse(try XCTUnwrap(editor.preview?.web).isHidden)
        XCTAssertTrue(grid.view.isHidden)
    }

    func testTruncationNoticeAndStaleSelection() async throws {
        let editor = editor("h\n" + String(repeating: "row\n", count: 50_002))
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        XCTAssertEqual(grid.table.numberOfRows(inSection: 0), 50_000)
        XCTAssertFalse(grid.note.isHidden)
        XCTAssertTrue(grid.note.text?.contains("50,000") == true)
        editor.textView.text = "changed"
        editor.textViewDidChange(editor.textView)
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        grid.selectField(row: 1, column: 0)
        XCTAssertEqual(editor.textView.selectedRange.location, 0)
    }
}
