import XCTest
import UIKit
import CedricCore

/// `TextDocument.load` refuses bytes the viewer route claims (a PDF read
/// in place of the text that was classified), so a launch reopen or a
/// recovery restore fails its open (its existing "couldn't open" path)
/// rather than putting the PDF, or unsaved text over it, in the editor.
/// "Open as Text" (`openBinaryAnyway`) still loads it.
@MainActor
final class EditorLoadRouteTests: XCTestCase {
    private func pdfBytes() throws -> Data {
        let b = Bundle(for: Self.self)
        return try Data(contentsOf: XCTUnwrap(b.url(forResource: "sample", withExtension: "pdf", subdirectory: "Samples")))
    }

    private func document(_ name: String) -> TextDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        return TextDocument(fileURL: url)
    }

    func testLoadRefusesPDFBytesInAnExtensionlessTextFile() throws {
        let pdf = try pdfBytes()
        XCTAssertFalse(TextCodec.looksBinary(pdf), "premise: the binary check alone accepts the sample PDF")
        let doc = document("notes")
        XCTAssertThrowsError(try doc.load(fromContents: pdf, ofType: nil))
        XCTAssertEqual(doc.text, "")
        XCTAssertNil(doc.onDisk, "nothing of the PDF was taken as the file's text")
        XCTAssertNil(doc.openedBytes(), "no opened copy of the PDF was kept")
    }

    func testOpenAsTextStillLoadsPDFBytes() throws {
        let doc = document("notes")
        doc.openBinaryAnyway = true
        XCTAssertNoThrow(try doc.load(fromContents: try pdfBytes(), ofType: nil))
        XCTAssertTrue(doc.text.hasPrefix("%PDF-"))
        doc.discardOpenedCopy()
    }

    func testTextStillLoads() throws {
        for (name, text) in [("notes", "plain\n"), ("table.csv", "a,b\n1,2\n"), ("README.md", "# Title\n"),
                             ("notes.txt", "hello\n"), ("pdf-notes", "% PDF-ish, not a header\n")] {
            let doc = document(name)
            XCTAssertNoThrow(try doc.load(fromContents: Data(text.utf8), ofType: nil), name)
            XCTAssertEqual(doc.text, text, name)
            doc.discardOpenedCopy()
        }
    }

    /// The editor has the file open and it is replaced on disk by a PDF:
    /// the reload's read is refused, and what was read before stays (the
    /// text, the on-disk snapshot, the opened copy). Nothing is written.
    func testReloadOfAFileReplacedByAPDFKeepsWhatWasRead() throws {
        let doc = document("notes")
        try doc.load(fromContents: Data("plain notes\n".utf8), ofType: nil)
        let before = doc.onDisk
        XCTAssertThrowsError(try doc.load(fromContents: try pdfBytes(), ofType: nil))
        XCTAssertEqual(doc.text, "plain notes\n")
        XCTAssertEqual(doc.onDisk, before)
        XCTAssertEqual(doc.openedBytes(), Data("plain notes\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: doc.fileURL.path), "load never writes the file")
        doc.discardOpenedCopy()
    }
}
