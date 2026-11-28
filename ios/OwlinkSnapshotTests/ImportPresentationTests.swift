import XCTest
import CedricCore

/// Open In with import: UIKit calls the browser's `didImportDocumentAt`
/// (or `failedToImportDocumentAt`) and then `revealDocument`'s completion
/// for the same import. Exactly one of them presents it, and exactly one
/// alert shows when it fails.
final class ImportPresentationTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/owlink-import/Inbox/sample.pdf")
    private let dest = URL(fileURLWithPath: "/tmp/owlink-import/Documents/sample.pdf")

    func testDoubleCallbackPresentsOnce() {
        var gate = ImportPresentationGate()
        var presents = 0
        gate.beginReveal(source)
        // UIKit's order: the delegate first, then the completion.
        if gate.delegateOwns(source) { presents += 1 }
        if gate.finishReveal(source) { presents += 1 }
        XCTAssertEqual(presents, 1)
        // A late or repeated callback for the same import presents nothing.
        if gate.finishReveal(source) { presents += 1 }
        XCTAssertEqual(presents, 1)
    }

    func testFailedImportAlertsOnce() {
        var gate = ImportPresentationGate()
        var alerts = 0
        gate.beginReveal(source)
        if gate.delegateOwns(source) { alerts += 1 }   // failedToImportDocumentAt
        if gate.finishReveal(source) { alerts += 1 }   // completion(nil, error)
        XCTAssertEqual(alerts, 1)
    }

    /// The source may come back spelled differently (`..`, a trailing slash).
    func testSourceSpellingIsNormalized() {
        var gate = ImportPresentationGate()
        gate.beginReveal(URL(fileURLWithPath: "/tmp/owlink-import/x/../Inbox/sample.pdf"))
        XCTAssertFalse(gate.delegateOwns(source))
        XCTAssertTrue(gate.finishReveal(source))
    }

    /// A new document (the browser's + button) has no reveal: its import
    /// callback is the only one, and it presents.
    func testImportWithNoRevealIsTheDelegates() {
        var gate = ImportPresentationGate()
        XCTAssertTrue(gate.delegateOwns(dest))
        gate.beginReveal(source)
        XCTAssertTrue(gate.delegateOwns(dest), "another file's import is still the delegate's")
        XCTAssertFalse(gate.finishReveal(dest))
    }
}
