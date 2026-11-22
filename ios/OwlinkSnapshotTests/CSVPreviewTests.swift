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

    private func editor(_ text: String, extension ext: String = "csv", readOnly: Bool = false) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(.csv)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: readOnly)
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
        let header = try XCTUnwrap(grid.headerForTesting.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "preview.csv.header.1" })
        header.sendActions(for: .primaryActionTriggered)
        try await waitForRender(grid, after: 1)
        XCTAssertEqual(grid.order, [2, 1])
        XCTAssertEqual(header.accessibilityValue, "Ascending")
        XCTAssertTrue(header.accessibilityTraits.contains(.selected))
        let row = grid.tableView(grid.table, cellForRowAt: IndexPath(row: 1, section: 0))
        let field = try XCTUnwrap(row.contentView.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "preview.csv.cell.1.0" })
        field.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(editor.textView.selectedRange.location, (text as NSString).range(of: "é").location)
        XCTAssertEqual(editor.textView.text, text)
        grid.sort(column: 1)
        try await waitForRender(grid, after: 2)
        XCTAssertEqual(grid.order, [1, 2])
        grid.sort(column: 1)
        try await waitForRender(grid, after: 3)
        XCTAssertEqual(grid.order, [1, 2])
        XCTAssertNil(grid.sortColumnForTesting)
        let sortedHeader = try XCTUnwrap(grid.headerForTesting.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "preview.csv.header.1" })
        XCTAssertNil(sortedHeader.accessibilityValue)
    }

    func testTSVFocusJumpsToField() async throws {
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
    }

    func testSwitchingBetweenPreviewLanguagesKeepsPreviewOpen() async throws {
        let editor = editor("name,value\nalpha,7\n")
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        XCTAssertFalse(grid.view.isHidden)
        editor.setLanguage(.markdown)
        XCTAssertTrue(editor.previewOn)
        XCTAssertFalse(try XCTUnwrap(editor.preview?.web).isHidden)
        XCTAssertTrue(grid.view.isHidden)
        editor.setLanguage(.csv)
        XCTAssertTrue(editor.previewOn)
        XCTAssertFalse(grid.view.isHidden)
        XCTAssertTrue(try XCTUnwrap(editor.preview?.web).isHidden)
        editor.setLanguage(.swift)
        XCTAssertFalse(editor.previewOn)
    }

    func testMarkdownPreviewStillOpensWebView() async throws {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = (1...200).map { "Line \($0)\n" }.joined(separator: "\n")
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        windows.append(window)
        editor.togglePreview()
        XCTAssertTrue(editor.previewOn)
        XCTAssertFalse(try XCTUnwrap(editor.preview?.web).isHidden)
        XCTAssertNil(editor.preview?.csv?.view.window)
    }

    func testTruncationNoticeAndStaleSelection() async throws {
        let editor = editor("h\n" + String(repeating: "row\n", count: 50_002))
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        XCTAssertEqual(grid.table.numberOfRows(inSection: 0), 50_000)
        XCTAssertFalse(grid.note.isHidden)
        XCTAssertTrue(grid.note.text?.contains("50,000") == true)
        var invoked = false
        grid.isSourceCurrent = { false }
        grid.onSelectField = { _, _ in invoked = true }
        editor.textView.text = "changed"
        editor.textViewDidChange(editor.textView)
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        grid.selectField(row: 1, column: 0)
        XCTAssertEqual(editor.textView.selectedRange.location, 0)
        XCTAssertFalse(invoked)
    }

    func testEmptyAndCRLFEmojiSourceJump() async throws {
        let empty = editor("")
        empty.togglePreview()
        let emptyGrid = try XCTUnwrap(empty.preview?.csv)
        try await waitForRender(emptyGrid)
        XCTAssertEqual(emptyGrid.data.rows, [])
        XCTAssertEqual(emptyGrid.table.numberOfRows(inSection: 0), 0)

        let text = "name,value\r\n😀,ok\r\n"
        let document = editor(text)
        document.togglePreview()
        let grid = try XCTUnwrap(document.preview?.csv)
        try await waitForRender(grid)
        grid.selectField(row: 1, column: 0)
        XCTAssertEqual(document.textView.selectedRange.location, (text as NSString).range(of: "😀").location)
    }

    func testUnclosedQuoteAndLargeModeNotes() async throws {
        let editor = editor("name,value\nok,1\nbroken,\"never closes\n")
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        XCTAssertTrue(grid.note.text?.contains("Unclosed quote on line 3") == true)

        let large = "head\n" + String(repeating: "row\n", count: 600_000)
        grid.render(text: large as NSString, fileName: "large.csv", large: true,
                    sourceGeneration: editor.generation, scrollFraction: 0)
        try await waitForRender(grid, after: 1)
        XCTAssertTrue(grid.note.text?.contains("Showing the first") == true)
        XCTAssertTrue(grid.data.truncated)
    }

    func testReadOnlyCellTapDoesNotOpenKeyboard() async throws {
        let editor = editor("name,value\nalpha,1", readOnly: true)
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        grid.selectField(row: 1, column: 1)
        XCTAssertEqual(editor.textView.selectedRange.location, 17)
        XCTAssertFalse(editor.textView.isFirstResponder)
    }

    func testSortTapWhileNewRenderIsParsingAppliesToNewRows() async throws {
        let editor = editor("name,value\nb,2\na,1")
        editor.togglePreview()
        let grid = try XCTUnwrap(editor.preview?.csv)
        try await waitForRender(grid)
        let snapshot = "name,value\nc,3\na,1\nb,2" as NSString
        grid.render(text: snapshot, fileName: "x.csv", large: false, sourceGeneration: editor.generation,
                    scrollFraction: 0)
        grid.sort(column: 0)
        try await waitForRender(grid, after: 1)
        XCTAssertEqual(grid.data.rows, [["name", "value"], ["c", "3"], ["a", "1"], ["b", "2"]])
        XCTAssertEqual(grid.order, [2, 3, 1])
        XCTAssertEqual(grid.sourceForTesting as String, snapshot as String)
    }
}
