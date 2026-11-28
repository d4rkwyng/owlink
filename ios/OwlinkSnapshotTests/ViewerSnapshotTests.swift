import XCTest
import UIKit
import PDFKit
import CedricCore

/// The read-only viewers, drawn: the PDF viewer, the spreadsheet grid
/// (.xlsx with one sheet and with several, CSV), and their error,
/// password and truncation states, in light and dark at iPhone and iPad
/// sizes (PNGs in EditorSnapshotTests.outDir named
/// `viewer-<case>-<iphone|ipad>-<light|dark>.png`). Each also checks that
/// real content shows at a readable size: the sheet fills the width on
/// open, its first cell isn't a sliver, the PDF fits the width.
@MainActor
final class ViewerSnapshotTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    struct Config {
        let pad: Bool
        let dark: Bool
        var size: CGSize { pad ? CGSize(width: 1032, height: 1376) : CGSize(width: 402, height: 874) }
        var name: String { (pad ? "ipad" : "iphone") + "-" + (dark ? "dark" : "light") }
    }

    static let configs = [false, true].flatMap { pad in [false, true].map { Config(pad: pad, dark: $0) } }

    // MARK: Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private func sample(_ name: String) throws -> URL {
        let b = Bundle(for: Self.self)
        let src = try XCTUnwrap(b.url(forResource: (name as NSString).deletingPathExtension,
                                      withExtension: (name as NSString).pathExtension, subdirectory: "Samples"), name)
        let url = try tempDir().appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = try tempDir().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func host(_ viewer: UIViewController, _ c: Config) -> UIWindow {
        let traits = UITraitCollection(userInterfaceStyle: c.dark ? .dark : .light)
        let nav = DocumentViewers.navigationController(for: viewer, traits: traits)
        nav.overrideUserInterfaceStyle = c.dark ? .dark : .light
        if c.pad {
            nav.traitOverrides.horizontalSizeClass = .regular
            nav.traitOverrides.verticalSizeClass = .regular
            nav.traitOverrides.userInterfaceIdiom = .pad
        }
        // One window on screen at a time: a covered window draws blank.
        for old in windows { old.isHidden = true }
        let w = UIWindow(frame: CGRect(origin: .zero, size: c.size))
        w.overrideUserInterfaceStyle = c.dark ? .dark : .light
        w.rootViewController = nav
        w.makeKeyAndVisible()
        w.layoutIfNeeded()
        windows.append(w)
        return w
    }

    private func spreadsheet(_ url: URL, _ format: SpreadsheetFormat, _ c: Config,
                             limits: SpreadsheetLimits = .standard) async throws -> (UIWindow, SpreadsheetViewerController) {
        let v = SpreadsheetViewerController(url: url, format: format, access: ScopedFileAccess(url), limits: limits)
        let w = host(v, c)
        await v.loaded()
        w.layoutIfNeeded()
        v.grid.collectionView.layoutIfNeeded()
        return (w, v)
    }

    /// The window as a PNG. In this hostless bundle drawHierarchy fails
    /// and layer.render draws a window holding a prominent (tinted glass)
    /// bar button as blank white, so Done is drawn plain for the picture
    /// (and put back after).
    private func snapshot(_ w: UIWindow, _ name: String) async throws {
        let items = ((w.rootViewController as? UINavigationController)?.viewControllers ?? [])
            .compactMap { $0.navigationItem.leftBarButtonItem }
        let styles = items.map(\.style)
        for i in items { i.style = .plain }
        defer { for (i, s) in zip(items, styles) { i.style = s } }
        w.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        w.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { ctx in
            if !w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) { w.layer.render(in: ctx.cgContext) }
        }
        try XCTUnwrap(img.pngData()).write(to: EditorSnapshotTests.outDir.appendingPathComponent("viewer-" + name + ".png"))
        let a = XCTAttachment(image: img)
        a.name = name
        add(a)
    }

    /// Real content at a readable size: the grid fills (at least 90% of)
    /// the width it has, and the first data cell is wider than 40 pt.
    private func assertFills(_ v: SpreadsheetViewerController, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let cv = v.grid.collectionView
        XCTAssertGreaterThan(cv.bounds.width, v.view.bounds.width * 0.9, "\(what): the grid isn't full width", file: file, line: line)
        let used = min(cv.contentSize.width, cv.bounds.width)
        XCTAssertGreaterThanOrEqual(used, cv.bounds.width * 0.9, "\(what): the sheet uses \(used) of \(cv.bounds.width) pt", file: file, line: line)
        let first = cv.cellForItem(at: SpreadsheetGridView.indexPath(row: 0, column: 0))
        XCTAssertNotNil(first, "\(what): A1 isn't on screen", file: file, line: line)
        if let first {
            let f = first.convert(first.bounds, to: v.view)
            XCTAssertGreaterThan(f.width, 40, "\(what): A1 is \(f.width) pt wide", file: file, line: line)
            XCTAssertGreaterThan(f.height, 16, "\(what): A1 is \(f.height) pt tall", file: file, line: line)
            XCTAssertTrue(v.view.bounds.intersects(f), file: file, line: line)
        }
    }

    private func barItem(_ v: UIViewController, _ id: String) -> UIBarButtonItem? {
        ((v.navigationItem.rightBarButtonItems ?? []) + (v.navigationItem.leftBarButtonItems ?? []))
            .first { $0.accessibilityIdentifier == id }
    }

    // MARK: Spreadsheets

    func testXLSXSingleSheet() async throws {
        for c in Self.configs {
            let (w, v) = try await spreadsheet(try sample("sample.xlsx"), .xlsx, c)
            XCTAssertEqual(v.grid.table?[0, 0]?.text, "Owlink XLSX sample")
            assertFills(v, "xlsx \(c.name)")
            XCTAssertNil(v.tabBar, "one sheet: no tabs")
            XCTAssertNotNil(barItem(v, "viewer.share"), "no Share button")
            XCTAssertNil(barItem(v, "viewer.editAsText"), "an .xlsx offers Edit as Text")
            XCTAssertEqual(v.grid.collectionView.accessibilityIdentifier, "viewer.grid")
            try await snapshot(w, "xlsx-single-\(c.name)")
        }
    }

    func testXLSXMultiSheetAndTabs() async throws {
        for c in Self.configs {
            let (w, v) = try await spreadsheet(try sample("multi-sheet.xlsx"), .xlsx, c)
            let tabs = try XCTUnwrap(v.tabBar, "no sheet tabs")
            XCTAssertEqual(tabs.accessibilityIdentifier, "viewer.sheetTabs")
            XCTAssertTrue(tabs.accessibilityTraits.contains(.tabBar))
            XCTAssertEqual(v.tabButtons.map { $0.configuration?.title ?? $0.title(for: .normal) ?? "" }, ["Owls", "Sightings", "Notes"])
            XCTAssertTrue(v.tabButtons[0].accessibilityTraits.contains(.selected))
            XCTAssertEqual(v.grid.table?[1, 0]?.text, "Barn owl")
            assertFills(v, "multi \(c.name)")
            // VoiceOver: "A2, Barn owl"; the column and row headers are headers.
            let cv = v.grid.collectionView
            XCTAssertEqual(cv.cellForItem(at: SpreadsheetGridView.indexPath(row: 1, column: 0))?.accessibilityLabel, "A2, Barn owl")
            let colHeader = cv.cellForItem(at: SpreadsheetGridView.indexPath(row: -1, column: 1))
            XCTAssertEqual(colHeader?.accessibilityLabel, "Column B")
            XCTAssertTrue(colHeader?.accessibilityTraits.contains(.header) ?? false)
            XCTAssertEqual(cv.cellForItem(at: SpreadsheetGridView.indexPath(row: 2, column: -1))?.accessibilityLabel, "Row 3")
            try await snapshot(w, "xlsx-multi-\(c.name)")

            v.selectSheet(1)
            await v.loaded()
            w.layoutIfNeeded()
            cv.layoutIfNeeded()
            XCTAssertTrue(v.tabButtons[1].accessibilityTraits.contains(.selected))
            XCTAssertFalse(v.tabButtons[0].accessibilityTraits.contains(.selected))
            XCTAssertEqual(v.grid.table?.name, "Sightings")
            XCTAssertEqual(v.grid.table?[1, 0]?.text, "2024-03-15", "dates show as dates")
            // A column is as wide as its values: the date isn't cut short.
            let date = try XCTUnwrap(cv.cellForItem(at: SpreadsheetGridView.indexPath(row: 1, column: 0)) as? SpreadsheetGridCell)
            XCTAssertLessThanOrEqual(date.label.intrinsicContentSize.width, date.label.bounds.width + 0.5,
                                     "\(c.name): 2024-03-15 is truncated in a \(date.label.bounds.width) pt label")
            assertFills(v, "multi tab 2 \(c.name)")
            try await snapshot(w, "xlsx-multi-tab2-\(c.name)")
        }
    }

    func testCSV() async throws {
        for c in Self.configs {
            let (w, v) = try await spreadsheet(try sample("sample.csv"), .csv, c)
            XCTAssertEqual(v.grid.table?[1, 4]?.text, "Hunts by sound, in total darkness")
            assertFills(v, "csv \(c.name)")
            XCTAssertNil(v.tabBar)
            XCTAssertNotNil(barItem(v, "viewer.share"))
            XCTAssertNotNil(barItem(v, "viewer.editAsText"), "a CSV has Edit as Text")
            try await snapshot(w, "csv-\(c.name)")
        }
    }

    func testTruncationNotice() async throws {
        let csv = "Row,Owl,Count,Place,Note\n" + (1...400).map { "\($0),Barn owl,\($0 % 7),Old barn,ok" }.joined(separator: "\n") + "\n"
        let url = try file("big.csv", Data(csv.utf8))
        for c in Self.configs {
            let (w, v) = try await spreadsheet(url, .csv, c, limits: SpreadsheetLimits(maxCells: 500, maxBytes: 64_000_000))
            XCTAssertFalse(v.noticeLabel.isHidden, "no truncation notice")
            XCTAssertEqual(v.noticeLabel.text, "Showing the first 100 rows of 401.")
            XCTAssertGreaterThan(v.noticeLabel.convert(v.noticeLabel.bounds, to: v.view).height, 10)
            assertFills(v, "truncated \(c.name)")
            try await snapshot(w, "truncated-\(c.name)")
        }
    }

    func testErrorState() async throws {
        let url = try file("damaged.xlsx", Data("this is not a workbook".utf8))
        for c in Self.configs {
            let (w, v) = try await spreadsheet(url, .xlsx, c)
            XCTAssertEqual(v.state, .failed(.notAWorkbook))
            XCTAssertTrue(v.grid.isHidden)
            XCTAssertFalse(v.messageView.isHidden)
            XCTAssertNotNil(barItem(v, "viewer.share"), "Share stays available")
            try await snapshot(w, "error-\(c.name)")
        }
    }

    func testPasswordProtectedWorkbook() async throws {
        var bytes = OfficeFormat.oleMagic + [UInt8](repeating: 0, count: 504)
        bytes += "EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        bytes += [UInt8](repeating: 0, count: 512)
        let url = try file("secret.xlsx", Data(bytes))
        for c in Self.configs {
            let (w, v) = try await spreadsheet(url, .xlsx, c)
            XCTAssertEqual(v.state, .failed(.passwordProtected))
            XCTAssertFalse(v.messageView.isHidden)
            XCTAssertNotNil(barItem(v, "viewer.share"))
            try await snapshot(w, "password-\(c.name)")
        }
    }

    func testEmptySheet() async throws {
        let url = try file("empty.csv", Data())
        let (_, v) = try await spreadsheet(url, .csv, Self.configs[0])
        XCTAssertEqual(v.state, .empty)
        XCTAssertFalse(v.messageView.isHidden)
    }

    func testCopyCellAndEditAsText() async throws {
        let (_, v) = try await spreadsheet(try sample("sample.csv"), .csv, Self.configs[0])
        let board = UIPasteboard.withUniqueName()
        v.grid.pasteboard = board
        v.grid.copyCell(row: 1, column: 0)
        XCTAssertEqual(board.string, "Barn owl")
        var asked = 0
        v.onEditAsText = { asked += 1 }
        v.editAsText()
        XCTAssertEqual(asked, 1)
    }

    func testPinchZoomScalesTheGrid() async throws {
        let (_, v) = try await spreadsheet(try sample("multi-sheet.xlsx"), .xlsx, Self.configs[0])
        let before = v.grid.layout.scale
        let width = v.grid.collectionView.contentSize.width
        v.grid.setScale(before * 2, anchor: .zero)
        v.grid.collectionView.layoutIfNeeded()
        XCTAssertEqual(v.grid.layout.scale, before * 2, accuracy: 0.01)
        XCTAssertEqual(v.grid.collectionView.contentSize.width, width * 2, accuracy: 2)
    }

    // MARK: PDF

    private func pdfViewer(_ url: URL, _ c: Config) -> (UIWindow, PDFViewerController) {
        let v = PDFViewerController(document: PDFDocument(url: url), url: url, access: ScopedFileAccess(url))
        let w = host(v, c)
        v.view.layoutIfNeeded()
        return (w, v)
    }

    func testPDF() async throws {
        let url = try sample("sample.pdf")
        for c in Self.configs {
            let (w, v) = pdfViewer(url, c)
            try await Task.sleep(for: .milliseconds(300))
            w.layoutIfNeeded()
            XCTAssertEqual(v.pdfView.scaleFactor, v.pdfView.scaleFactorForSizeToFit, accuracy: 0.01, "not fitted to the width")
            let page = try XCTUnwrap(v.document?.page(at: 0))
            let pageWidth = v.pdfView.convert(page.bounds(for: v.pdfView.displayBox), from: page).width
            XCTAssertGreaterThan(pageWidth, v.view.bounds.width * 0.85, "the page is \(pageWidth) pt wide")
            // Page 1 starts below the bar, not behind it.
            let top = v.pdfView.convert(page.bounds(for: v.pdfView.displayBox), from: page).minY
            let barBottom = v.view.safeAreaInsets.top
            XCTAssertGreaterThanOrEqual(top, barBottom - 1, "\(c.name): page 1's top is at \(top), the bar ends at \(barBottom)")
            XCTAssertEqual(v.pageLabel.text?.trimmingCharacters(in: .whitespaces), "1 of 2")
            XCTAssertNotNil(barItem(v, "viewer.share"))
            XCTAssertNotNil(barItem(v, "viewer.pdf.search"))
            XCTAssertNotNil(barItem(v, "viewer.pdf.thumbnails"))
            XCTAssertNil(barItem(v, "viewer.editAsText"))
            try await snapshot(w, "pdf-\(c.name)")
            v.toggleThumbnails()
            w.layoutIfNeeded()
            XCTAssertFalse(v.thumbnailView.isHidden)
            XCTAssertEqual(v.thumbnailView.accessibilityIdentifier, "viewer.pdf.thumbnails")
            try await snapshot(w, "pdf-thumbnails-\(c.name)")
        }
    }

    func testPDFFitsAfterRotation() async throws {
        let url = try sample("sample.pdf")
        let (w, v) = pdfViewer(url, Self.configs[0])
        w.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        w.layoutIfNeeded()
        v.view.layoutIfNeeded()
        XCTAssertEqual(v.pdfView.scaleFactor, v.pdfView.scaleFactorForSizeToFit, accuracy: 0.01)
    }

    func testPDFPassword() async throws {
        let src = try XCTUnwrap(PDFDocument(url: try sample("sample.pdf")))
        let url = try tempDir().appendingPathComponent("locked.pdf")
        XCTAssertTrue(src.write(to: url, withOptions: [.userPasswordOption: "owl", .ownerPasswordOption: "owl-owner"]))
        let before = try Data(contentsOf: url)
        for c in Self.configs {
            let (w, v) = pdfViewer(url, c)
            XCTAssertTrue(v.isLocked)
            XCTAssertFalse(v.messageView.isHidden)
            XCTAssertNotNil(barItem(v, "viewer.share"))
            XCTAssertNil(barItem(v, "viewer.pdf.search"), "search before unlocking")
            try await snapshot(w, "pdf-password-\(c.name)")
            XCTAssertFalse(v.unlock(password: "wrong"))
            XCTAssertTrue(v.isLocked)
            XCTAssertTrue(v.unlock(password: "owl"))
            XCTAssertFalse(v.isLocked)
            XCTAssertTrue(v.messageView.isHidden)
            XCTAssertNotNil(barItem(v, "viewer.pdf.search"))
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "never written")
    }

    func testDamagedAndEmptyPDF() async throws {
        let url = try file("damaged.pdf", Data("%PDF-1.4 garbage".utf8))
        let c = Self.configs[0]
        let (w, v) = pdfViewer(url, c)
        XCTAssertNil(v.document)
        XCTAssertFalse(v.messageView.isHidden)
        XCTAssertNotNil(barItem(v, "viewer.share"))
        try await snapshot(w, "pdf-error-\(c.name)")
        // A valid PDF with no pages (PDFKit won't write one).
        let body = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n"
        let xref = body.utf8.count
        let pdf = body + "xref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \ntrailer << /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let emptyURL = try file("empty.pdf", Data(pdf.utf8))
        let (_, e) = pdfViewer(emptyURL, c)
        if let doc = e.document {
            XCTAssertEqual(doc.pageCount, 0)
            XCTAssertFalse(e.messageView.isHidden, "no empty state")
        }
    }

    // MARK: Quick Look

    /// The Quick Look child fills the safe area (not a corner of it).
    func testQuickLookFillsTheSafeArea() throws {
        let url = try file("letter.docx", Data(OfficeFormat.zipMagic))
        let v = QuickLookViewerController(url: url, format: .word, access: ScopedFileAccess(url))
        let w = host(v, Self.configs[0])
        w.layoutIfNeeded()
        let frame = v.preview.view.convert(v.preview.view.bounds, to: v.view)
        let safe = v.view.bounds.inset(by: v.view.safeAreaInsets)
        XCTAssertEqual(frame.minY, safe.minY, accuracy: 1)
        XCTAssertEqual(frame.width, safe.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(frame.maxY, safe.maxY - 1)
        XCTAssertNotNil(barItem(v, "viewer.share"))
    }
}
