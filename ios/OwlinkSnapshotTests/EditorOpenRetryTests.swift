import XCTest
import UIKit
import CedricCore

/// The browser's editor open, its failed-open prompt, and the "Open as
/// Text" retry (`EditorOpenRequest`, as `DocumentBrowserViewController.
/// presentDocument` uses it), driven through a real `UIDocument.open`.
///
/// Sol r2 #1: a .csv the grid hands to the editor (Edit as Text) is
/// replaced by a PDF containing NUL bytes before the coordinated read. The
/// read fails as binary, and the prompt used to offer "Open as Text",
/// whose retry dropped the editor-only restriction and put the PDF in the
/// writable editor. An editor-only open (Edit as Text, a recovery restore,
/// a launch reopen) never loads a viewer file, retry or not.
@MainActor
final class EditorOpenRetryTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The bundled sample PDF with NUL bytes in a comment after its header:
    /// still a PDF, and binary to the editor's check.
    private func pdfWithNULs() throws -> Data {
        let b = Bundle(for: Self.self)
        let sample = try Data(contentsOf: XCTUnwrap(b.url(forResource: "sample", withExtension: "pdf", subdirectory: "Samples")))
        var data = Data("%PDF-1.7\n%".utf8) + Data([0x00, 0x00, 0xE2, 0xE3, 0x0A])
        data += sample.drop(while: { $0 != 0x0A }).dropFirst()
        XCTAssertTrue(TextCodec.looksBinary(data), "premise: the editor's binary check rejects it")
        XCTAssertEqual(DocumentViewerRoute.route(fileName: "table.csv", prefix: data), .pdf, "premise: routes to the PDF viewer")
        return data
    }

    private func open(_ doc: TextDocument) async -> Bool {
        await withCheckedContinuation { done in doc.open { done.resume(returning: $0) } }
    }

    private func close(_ doc: TextDocument) async {
        await withCheckedContinuation { done in doc.close { _ in done.resume() } }
        doc.discardOpenedCopy()
    }

    private func recoveryRecord(_ url: URL) -> RecoveryRecord {
        RecoveryRecord(documentPath: url.path, displayName: url.lastPathComponent, bookmark: nil, savedAt: Date(),
                       text: "unsaved,text\n", encoding: .utf8, lineEnding: .lf)
    }

    /// Edit as Text of a .csv, replaced by a NUL-containing PDF before the
    /// read: no "Open as Text" prompt, and confirming the retry anyway
    /// (its request) still never loads the PDF into the editor.
    func testOpenAsTextRetryOfAReplacedCSVNeverLoadsThePDF() async throws {
        let csv = Data("a,b\n1,2\n".utf8)
        let pdf = try pdfWithNULs()
        let editorOnly: [(String, EditorOpenRequest)] = [
            ("Edit as Text", EditorOpenRequest(asText: true)),
            ("restore", EditorOpenRequest(recovered: recoveryRecord(URL(fileURLWithPath: "/tmp/table.csv")))),
            ("reopen", EditorOpenRequest(reopening: true)),
        ]
        for (label, request) in editorOnly {
            let url = try file("table.csv", csv)
            XCTAssertTrue(request.editorOnly, label)
            XCTAssertTrue(request.mayOpenInEditor(url), "\(label): premise: the CSV is the editor's when checked")
            try pdf.write(to: url)   // replaced between the check and the coordinated read

            let doc = request.makeDocument(url)
            let ok = await open(doc)
            XCTAssertFalse(ok, "\(label): the replacement PDF is not opened")
            XCTAssertFalse(doc.mayPresentInEditor, "\(label): the read bytes are the PDF's")
            let failed = request.failedOpen(document: doc, fileLooksBinary: true)
            XCTAssertNotEqual(failed, .offerOpenAsText, "\(label): no Open as Text for a viewer file")
            XCTAssertEqual(failed, request.reopening ? .quiet : .couldNotOpen, label)
            XCTAssertEqual(doc.text, "", label)
            XCTAssertNil(doc.openedBytes(), "\(label): no opened copy of the PDF")
            doc.discardOpenedCopy()

            // The retry (as if the prompt had been confirmed) keeps the
            // editor-only restriction, and the editor's read refuses the PDF.
            let retry = request.openingAsText
            XCTAssertTrue(retry.binaryOK, label)
            XCTAssertTrue(retry.editorOnly, "\(label): the retry is still editor-only")
            XCTAssertEqual(retry.recovered, request.recovered, label)
            XCTAssertFalse(retry.mayOpenInEditor(url), "\(label): the retry's route check refuses the PDF")
            let again = retry.makeDocument(url)
            XCTAssertTrue(again.openBinaryAnyway, label)
            let reopened = await open(again)
            XCTAssertFalse(reopened, "\(label): Open as Text still doesn't load the PDF into the editor")
            XCTAssertEqual(again.text, "", label)
            XCTAssertNil(again.openedBytes(), label)
            XCTAssertEqual(retry.failedOpen(document: again, fileLooksBinary: true), request.reopening ? .quiet : .couldNotOpen, label)
            again.discardOpenedCopy()
            XCTAssertEqual(try Data(contentsOf: url), pdf, "\(label): the file is never written")
        }
    }

    /// The successful-read case (a PDF with no NUL bytes, which the
    /// binary check accepts) is refused by the editor-only read as well.
    func testEditorOnlyReadRefusesAPDFWithoutNULs() async throws {
        let b = Bundle(for: Self.self)
        let sample = try Data(contentsOf: XCTUnwrap(b.url(forResource: "sample", withExtension: "pdf", subdirectory: "Samples")))
        XCTAssertFalse(TextCodec.looksBinary(sample), "premise")
        let url = try file("table.csv", Data("a,b\n".utf8))
        let request = EditorOpenRequest(asText: true)
        XCTAssertTrue(request.mayOpenInEditor(url))
        try sample.write(to: url)
        let doc = request.makeDocument(url)
        let ok = await open(doc)
        XCTAssertFalse(ok)
        XCTAssertFalse(doc.mayPresentInEditor)
        XCTAssertEqual(request.failedOpen(document: doc, fileLooksBinary: false), .couldNotOpen)
        XCTAssertNil(doc.openedBytes())
        doc.discardOpenedCopy()
    }

    /// Real text keeps its paths: a CSV that merely starts with "%PDF-"
    /// opens in the editor (Edit as Text), a CSV with NUL bytes still gets
    /// the prompt and opens as text, and an ordinary (not editor-only)
    /// binary file's Open as Text still opens it.
    func testTextAndOpenAsTextStillOpen() async throws {
        let lookalike = try file("table.csv", Data("%PDF-,x\n1,2\n".utf8))
        let asText = EditorOpenRequest(asText: true)
        XCTAssertTrue(asText.mayOpenInEditor(lookalike))
        let doc = asText.makeDocument(lookalike)
        let ok = await open(doc)
        XCTAssertTrue(ok)
        XCTAssertTrue(doc.mayPresentInEditor)
        XCTAssertEqual(doc.text, "%PDF-,x\n1,2\n")
        await close(doc)

        let nulCSV = try file("table.csv", Data("a,b\n1,\u{0}\u{0}2\n".utf8))
        let first = asText.makeDocument(nulCSV)
        let firstOK = await open(first)
        XCTAssertFalse(firstOK)
        XCTAssertEqual(asText.failedOpen(document: first, fileLooksBinary: true), .offerOpenAsText)
        first.discardOpenedCopy()
        let retry = asText.openingAsText
        XCTAssertTrue(retry.mayOpenInEditor(nulCSV))
        let second = retry.makeDocument(nulCSV)
        let secondOK = await open(second)
        XCTAssertTrue(secondOK)
        XCTAssertTrue(second.mayPresentInEditor)
        XCTAssertTrue(second.text.hasPrefix("a,b\n"))
        await close(second)

        let blob = try file("blob", Data([0x00, 0x01, 0x02, 0x41, 0x0A]))
        let plain = EditorOpenRequest()
        XCTAssertFalse(plain.editorOnly)
        let b1 = plain.makeDocument(blob)
        let b1OK = await open(b1)
        XCTAssertFalse(b1OK)
        XCTAssertEqual(plain.failedOpen(document: b1, fileLooksBinary: true), .offerOpenAsText)
        b1.discardOpenedCopy()
        let b2 = plain.openingAsText.makeDocument(blob)
        let b2OK = await open(b2)
        XCTAssertTrue(b2OK)
        await close(b2)
        // Not binary and still unreadable: no prompt.
        XCTAssertEqual(plain.failedOpen(document: b1, fileLooksBinary: false), .couldNotOpen)
        XCTAssertEqual(plain.openingAsText.failedOpen(document: b1, fileLooksBinary: true), .couldNotOpen,
                       "the retry itself doesn't prompt again")
    }

    /// The editor-only refusal is for the open only: once open, a reload
    /// keeps today's behavior (the reload-race spec's recovery-record
    /// ordering is unchanged).
    func testEditorOnlyRefusalEndsWithTheOpen() async throws {
        let url = try file("table.csv", Data("a,b\n".utf8))
        let doc = EditorOpenRequest(asText: true).makeDocument(url)
        XCTAssertTrue(doc.refusesViewerContent)
        let ok = await open(doc)
        XCTAssertTrue(ok)
        XCTAssertFalse(doc.refusesViewerContent, "cleared once the open finishes")
        await close(doc)

        let failed = EditorOpenRequest(reopening: true).makeDocument(try file("table.csv", try pdfWithNULs()))
        let failedOK = await open(failed)
        XCTAssertFalse(failedOK)
        XCTAssertFalse(failed.refusesViewerContent, "cleared on a failed open too")
        failed.discardOpenedCopy()
        XCTAssertFalse(EditorOpenRequest().makeDocument(url).refusesViewerContent, "an ordinary open never refuses")
    }
}
