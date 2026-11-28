import XCTest
import UniformTypeIdentifiers
@testable import CedricCore

/// Where Owlink for iPhone and iPad opens a file: PDF, spreadsheets (.xlsx,
/// .xlsm, .csv, .tsv: the grid) and other Office / iWork files in
/// read-only viewers, everything else in the text editor. Decided by the
/// name's extension and UTType (plus a `%PDF-` header on a file with no or
/// an odd extension), never by sniffing the whole file.
final class DocumentViewerRouteTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let zip: [UInt8] = OfficeFormat.zipMagic + [0x14, 0x00, 0x00, 0x00]
    private let ole: [UInt8] = OfficeFormat.oleMagic
    private let pdf: [UInt8] = Array("%PDF-1.7\n%\u{e2}".utf8)

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func route(_ name: String, _ bytes: [UInt8]) throws -> DocumentViewerRoute {
        DocumentViewerRoute.route(for: try file(name, bytes))
    }

    // MARK: Office and iWork -> Quick Look

    func testOOXMLByExtension() throws {
        XCTAssertEqual(try route("book.xlsx", zip), .spreadsheet(.xlsx))
        XCTAssertEqual(try route("book.xlsm", zip), .spreadsheet(.xlsx))
        XCTAssertEqual(try route("letter.docx", zip), .quickLook(.word))
        XCTAssertEqual(try route("letter.docm", zip), .quickLook(.word))
        XCTAssertEqual(try route("letter.dotx", zip), .quickLook(.word))
        XCTAssertEqual(try route("deck.pptx", zip), .quickLook(.presentation))
        XCTAssertEqual(try route("deck.pptm", zip), .quickLook(.presentation))
        XCTAssertEqual(try route("UPPER.XLSX", zip), .spreadsheet(.xlsx))
    }

    /// A password-protected .xlsx is an OLE2 container (EncryptedPackage):
    /// the grid, which says it is protected, not Quick Look.
    func testEncryptedXLSXGoesToTheGrid() throws {
        XCTAssertEqual(try route("secret.xlsx", ole), .spreadsheet(.xlsx))
        XCTAssertEqual(try route("secret.xlsm", ole), .spreadsheet(.xlsx))
    }

    func testLegacyOfficeByExtension() throws {
        XCTAssertEqual(try route("old.xls", ole), .quickLook(.spreadsheet))
        XCTAssertEqual(try route("old.doc", ole), .quickLook(.word))
        XCTAssertEqual(try route("old.dot", ole), .quickLook(.word))
        XCTAssertEqual(try route("old.ppt", ole), .quickLook(.presentation))
    }

    /// Mac parity: a damaged `.docx` / `.xlsx` (not a zip) still goes to
    /// the viewer, which says it can't show it, rather than the editor.
    func testDamagedOfficeFileStillGoesToTheViewer() throws {
        XCTAssertEqual(try route("broken.docx", Array("not a zip at all".utf8)), .quickLook(.word))
        XCTAssertEqual(try route("empty.xlsx", []), .spreadsheet(.xlsx), "the grid says it can't read it")
    }

    /// An RTF saved with a `.doc` name is text (Mac parity).
    func testRTFNamedDocIsText() throws {
        XCTAssertEqual(try route("notes.doc", Array("{\\rtf1\\ansi hello}".utf8)), .editor)
    }

    func testIWorkFilesNeedTheZipHeader() throws {
        XCTAssertEqual(try route("report.pages", zip), .quickLook(.pages))
        XCTAssertEqual(try route("budget.numbers", zip), .quickLook(.numbers))
        XCTAssertEqual(try route("talk.key", zip), .quickLook(.keynote))
        // A `.key` file is far more often a PEM private key: text.
        XCTAssertEqual(try route("server.key", Array("-----BEGIN PRIVATE KEY-----\nMIIB\n".utf8)), .editor)
    }

    func testPackageDirectories() throws {
        for (name, format) in [("styled.rtfd", OfficeFormat.rtfd), ("report.pages", .pages),
                               ("budget.numbers", .numbers), ("talk.key", .keynote)] {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertEqual(DocumentViewerRoute.route(for: url), .quickLook(format), name)
        }
        let plain = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(DocumentViewerRoute.route(for: plain), .editor)
    }

    // MARK: PDF

    func testPDFByExtensionHeaderAndUpperCase() throws {
        XCTAssertEqual(try route("paper.pdf", pdf), .pdf)
        XCTAssertEqual(try route("REPORT.PDF", pdf), .pdf)
        XCTAssertEqual(try route("scan", pdf), .pdf, "no extension, %PDF- header")
        XCTAssertEqual(try route("download.bin", pdf), .pdf, "an odd extension, %PDF- header")
        // Named .pdf but damaged: the PDF viewer (it says it can't open it).
        XCTAssertEqual(try route("damaged.pdf", Array("garbage".utf8)), .pdf)
    }

    // MARK: Text stays in the editor

    func testTextFilesGoToTheEditor() throws {
        XCTAssertEqual(try route("notes.txt", Array("hello".utf8)), .editor)
        XCTAssertEqual(try route("README.md", Array("# Title".utf8)), .editor)
        XCTAssertEqual(try route("data.json", Array("{}".utf8)), .editor)
        XCTAssertEqual(try route("main.swift", Array("let x = 1".utf8)), .editor)
        // A text file that happens to start with "%PDF-" is still text.
        XCTAssertEqual(try route("about-pdf.txt", pdf), .editor)
    }

    /// CSV and TSV open in the read-only grid (Edit as Text opens the
    /// editor), whatever they hold: never Quick Look.
    func testCSVAndTSVGoToTheGrid() throws {
        XCTAssertEqual(try route("table.csv", Array("a,b\n1,2\n".utf8)), .spreadsheet(.csv))
        XCTAssertEqual(try route("TABLE.CSV", Array("a,b\n".utf8)), .spreadsheet(.csv))
        XCTAssertEqual(try route("table.tsv", Array("a\tb\n".utf8)), .spreadsheet(.tsv))
        XCTAssertEqual(try route("empty.csv", []), .spreadsheet(.csv))
        XCTAssertEqual(try route("sheet.csv", zip), .spreadsheet(.csv))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "sheet.csv", prefix: zip,
                                                 contentType: .commaSeparatedText), .spreadsheet(.csv))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "data.csv", prefix: Array("%PDF-,x\n".utf8)), .spreadsheet(.csv))
        XCTAssertTrue(SpreadsheetFormat.csv.isText && SpreadsheetFormat.tsv.isText && !SpreadsheetFormat.xlsx.isText)
    }

    func testOtherBinaryFilesKeepTodaysEditorPath() throws {
        XCTAssertEqual(try route("archive.zip", zip), .editor)
        XCTAssertEqual(try route("blob", [0x00, 0x01, 0x02, 0xFF]), .editor)
        XCTAssertEqual(try route("blob", zip), .editor, "an extension-less zip: no looking inside")
        XCTAssertEqual(try route("mail.msg", ole), .editor, "an OLE file with no Office name")
        XCTAssertEqual(try route("photo.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .editor,
                       "no image viewer on iOS")
    }

    // MARK: UTType

    /// A file whose name says nothing (`.bin`) but whose content type, from
    /// the file provider, is an Office type.
    func testUTTypeOnlyIdentification() throws {
        let sheet = try XCTUnwrap(UTType("org.openxmlformats.spreadsheetml.sheet"))
        let doc = try XCTUnwrap(UTType("com.microsoft.word.doc"))
        let ppt = try XCTUnwrap(UTType("org.openxmlformats.presentationml.presentation"))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: zip, contentType: sheet), .spreadsheet(.xlsx))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: ole, contentType: doc), .quickLook(.word))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment", prefix: zip, contentType: ppt), .quickLook(.presentation))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: [], contentType: .pdf), .pdf)
        if let numbers = UTType("com.apple.iwork.numbers.sffnumbers") {
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: zip, contentType: numbers), .quickLook(.numbers))
        }
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: zip, contentType: .zip), .editor)
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: [], contentType: .plainText), .editor)
    }

    /// Text metadata (a provider's plain-text type) doesn't take a known
    /// viewer file away from its viewer: a `.pdf` name or `%PDF-` header,
    /// a recognized Office / iWork name with its header.
    func testTextContentTypeDoesNotBeatAKnownViewerFile() throws {
        for type in [UTType.plainText, .text, .utf8PlainText] {
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "sample.pdf", prefix: pdf, contentType: type), .pdf)
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "damaged.pdf", prefix: [], contentType: type), .pdf)
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "scan", prefix: pdf, contentType: type), .pdf)
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "book.xlsx", prefix: zip, contentType: type), .spreadsheet(.xlsx))
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "letter.docx", prefix: zip, contentType: type), .quickLook(.word))
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "old.xls", prefix: ole, contentType: type), .quickLook(.spreadsheet))
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "talk.key", prefix: zip, contentType: type), .quickLook(.keynote))
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "styled.rtfd", prefix: [UInt8](), contentType: type,
                                                     isDirectory: true), .quickLook(.rtfd))
            // Still text: a PEM key named .key, an RTF named .doc, no telling name or header.
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "server.key", prefix: Array("-----BEGIN".utf8), contentType: type), .editor)
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "notes.doc", prefix: Array("{\\rtf1".utf8), contentType: type), .editor)
            XCTAssertEqual(DocumentViewerRoute.route(fileName: "attachment.bin", prefix: zip, contentType: type), .editor)
        }
    }

    /// The other way: a text name wins over viewer metadata (a .txt the
    /// provider calls a PDF or a spreadsheet is still the editor's; a CSV
    /// is still the grid's).
    func testTextNameBeatsViewerContentType() throws {
        let sheet = try XCTUnwrap(UTType("org.openxmlformats.spreadsheetml.sheet"))
        for name in ["notes.txt", "README.md"] {
            XCTAssertEqual(DocumentViewerRoute.route(fileName: name, prefix: pdf, contentType: .pdf), .editor, name)
            XCTAssertEqual(DocumentViewerRoute.route(fileName: name, prefix: zip, contentType: sheet), .editor, name)
        }
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "table.csv", prefix: pdf, contentType: .pdf), .spreadsheet(.csv))
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "table.csv", prefix: zip, contentType: sheet), .spreadsheet(.csv))
    }

    func testKindNames() {
        XCTAssertEqual(OfficeFormat.spreadsheet.kindName, "Excel spreadsheet")
        XCTAssertEqual(OfficeFormat.word.kindName, "Word document")
        XCTAssertEqual(OfficeFormat.keynote.kindName, "Keynote presentation")
        XCTAssertEqual(SpreadsheetFormat.xlsx.kindName, "Excel spreadsheet")
        XCTAssertEqual(SpreadsheetFormat.csv.kindName, "CSV file")
        XCTAssertEqual(SpreadsheetFormat.tsv.kindName, "TSV file")
    }

    // MARK: Launch reopen and crash-recovery restore

    /// A launch reopen and a crash-recovery restore open only the text
    /// editor. A file that routes to a viewer is not opened there: the
    /// reopen forgets its last-open record (and ends as "not opened"), and
    /// a pending recovery record is never cleared (its text stays offered).
    func testEditorOnlyOpenSkipsViewerFiles() {
        let viewerRoutes: [DocumentViewerRoute] = [.pdf, .quickLook(.spreadsheet), .quickLook(.rtfd), .spreadsheet(.xlsx)]
        for route in viewerRoutes {
            let reopen = DocumentViewerRoute.editorOnlyOpen(route, reopening: true)
            XCTAssertFalse(reopen.opensEditor, "\(route)")
            XCTAssertTrue(reopen.forgetsLastOpenDocument, "\(route)")
            XCTAssertFalse(reopen.clearsRecoveryRecord, "\(route)")
            let restore = DocumentViewerRoute.editorOnlyOpen(route, reopening: false)
            XCTAssertFalse(restore.opensEditor, "\(route)")
            XCTAssertFalse(restore.forgetsLastOpenDocument, "\(route)")
            XCTAssertFalse(restore.clearsRecoveryRecord, "\(route)")
        }
        // CSV and TSV are text: a reopen (after Edit as Text) or a restore
        // opens them in the editor, as before they opened in the grid.
        for route in [DocumentViewerRoute.editor, .spreadsheet(.csv), .spreadsheet(.tsv)] {
            for reopening in [true, false] {
                let text = DocumentViewerRoute.editorOnlyOpen(route, reopening: reopening)
                XCTAssertTrue(text.opensEditor, "\(route)")
                XCTAssertFalse(text.forgetsLastOpenDocument, "\(route)")
                XCTAssertFalse(text.clearsRecoveryRecord, "\(route)")
            }
        }
    }

    /// The bundled PDF has no NUL bytes, so the editor's binary check alone
    /// would open it as text: the reopen has to ask the route first.
    func testSamplePDFReopenIsNotTheEditors() throws {
        let pdfURL = samples.appendingPathComponent("sample.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pdfURL.path), "ios/Samples not reachable from this test host")
        XCTAssertFalse(TextCodec.looksBinary(try Data(contentsOf: pdfURL)), "premise: the text heuristic accepts it")
        let decision = DocumentViewerRoute.editorOnlyOpen(DocumentViewerRoute.route(for: pdfURL), reopening: true)
        XCTAssertFalse(decision.opensEditor)
        XCTAssertTrue(decision.forgetsLastOpenDocument)
    }

    /// After a swap, the bytes themselves route to the viewer: an
    /// extensionless file classified as text, then replaced by a PDF,
    /// is a PDF by its header. The editor's own read (`TextDocument.load`)
    /// should refuse those bytes unless "Open as Text"; that load-time
    /// refusal is deferred (e0fe06b reverted b36cb8f). See
    /// EditorLoadRouteTests (strict XCTExpectFailure) and
    /// ~/Orchestrator/scratch/ios-docpreview/reload-race-spec.md.
    func testEditorLoadRefusesViewerContentSwappedInAfterClassification() throws {
        let pdfURL = samples.appendingPathComponent("sample.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pdfURL.path), "ios/Samples not reachable from this test host")
        let pdfBytes = try Data(contentsOf: pdfURL)
        let url = try file("notes", Array("plain notes\n".utf8))
        XCTAssertEqual(DocumentViewerRoute.route(for: url), .editor, "premise: classified as the editor's")
        try pdfBytes.write(to: url)
        let read = try Data(contentsOf: url)
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "notes", prefix: read), .pdf)
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "paper.pdf", prefix: read), .pdf)
        // "Open as Text" is a load-time bypass of this route, not a route itself.
    }

    /// Text, Markdown, and extensionless text still route to the editor,
    /// including a text-named file whose first bytes look like a PDF; CSV
    /// routes to the grid, and its editor-only opens still open the editor.
    func testEditorLoadKeepsText() {
        let cases: [(String, String)] = [
            ("notes.txt", "hello\n"), ("README.md", "# Title\n"),
            ("notes", "plain text, no extension\n"), ("notes", "%PDF notes (no dash)\n"),
            ("pdf-notes", "% PDF-ish\n"), ("Makefile", "all:\n\techo hi\n"),
            // A text name keeps the editor whatever the first bytes are (as the route).
            ("paper.txt", "%PDF-1.7 pasted into a text file\n"),
        ]
        for (name, text) in cases {
            XCTAssertEqual(DocumentViewerRoute.route(fileName: name, prefix: Data(text.utf8)), .editor, name)
        }
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "empty", prefix: Data()), .editor)
        for name in ["table.csv", "data.csv"] {
            let r = DocumentViewerRoute.route(fileName: name, prefix: Data("a,b\n".utf8))
            XCTAssertEqual(r, .spreadsheet(.csv), name)
            XCTAssertTrue(DocumentViewerRoute.editorOnlyOpen(r, reopening: true).opensEditor, name)
        }
    }

    // MARK: The bundled samples

    private var samples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ios/Samples")
    }

    func testBundledSamplesRoute() throws {
        let pdfURL = samples.appendingPathComponent("sample.pdf")
        let xlsxURL = samples.appendingPathComponent("sample.xlsx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pdfURL.path), "ios/Samples not reachable from this test host")
        XCTAssertEqual(DocumentViewerRoute.route(for: pdfURL), .pdf)
        XCTAssertEqual(DocumentViewerRoute.route(for: xlsxURL), .spreadsheet(.xlsx))
        XCTAssertEqual(DocumentViewerRoute.route(for: samples.appendingPathComponent("multi-sheet.xlsx")), .spreadsheet(.xlsx))
        XCTAssertEqual(DocumentViewerRoute.route(for: samples.appendingPathComponent("sample.csv")), .spreadsheet(.csv))
        XCTAssertEqual(DocumentViewerRoute.route(for: samples.appendingPathComponent("sample.swift")), .editor)
        let sheet = try XLSXSheet.firstSheetCSV(url: xlsxURL)
        XCTAssertEqual(sheet.name, "Owls")
        XCTAssertTrue(sheet.csv.hasPrefix("Owlink XLSX sample"), sheet.csv)
        XCTAssertTrue(sheet.csv.contains("Barn owl,12"), sheet.csv)
    }
}
