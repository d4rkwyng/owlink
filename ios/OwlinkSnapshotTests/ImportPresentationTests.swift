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
        XCTAssertTrue(gate.beginReveal(source))
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
        XCTAssertTrue(gate.beginReveal(source))
        if gate.delegateOwns(source) { alerts += 1 }   // failedToImportDocumentAt
        if gate.finishReveal(source) { alerts += 1 }   // completion(nil, error)
        XCTAssertEqual(alerts, 1)
    }

    /// The source may come back spelled differently (`..`, a trailing slash).
    func testSourceSpellingIsNormalized() {
        var gate = ImportPresentationGate()
        XCTAssertTrue(gate.beginReveal(URL(fileURLWithPath: "/tmp/owlink-import/x/../Inbox/sample.pdf")))
        XCTAssertFalse(gate.delegateOwns(source))
        XCTAssertTrue(gate.finishReveal(source))
    }

    /// A new document (the browser's + button) has no reveal: its import
    /// callback is the only one, and it presents.
    func testImportWithNoRevealIsTheDelegates() {
        var gate = ImportPresentationGate()
        XCTAssertTrue(gate.delegateOwns(dest))
        XCTAssertTrue(gate.beginReveal(source))
        XCTAssertTrue(gate.delegateOwns(dest), "another file's import is still the delegate's")
        XCTAssertFalse(gate.finishReveal(dest))
    }

    /// Two Open In requests for one source while the first reveal runs:
    /// the second starts no second UIKit reveal (coalesced). The delegate
    /// stays out until the one reveal finishes; its completion presents or
    /// alerts once, and after it a new Open In reveals again.
    func testOverlappingRevealsForOneSourceCoalesce() {
        var gate = ImportPresentationGate()
        var shown = 0
        XCTAssertTrue(gate.beginReveal(source))
        XCTAssertFalse(gate.beginReveal(source), "a second request while the first reveal runs is coalesced")
        XCTAssertFalse(gate.beginReveal(URL(fileURLWithPath: "/tmp/owlink-import/Inbox/./sample.pdf")),
                       "the same source spelled differently is coalesced too")
        XCTAssertFalse(gate.delegateOwns(source), "the in-flight reveal still owns it")
        // The one reveal fails: failedToImportDocumentAt, then the completion.
        if gate.delegateOwns(source) { shown += 1 }
        if gate.finishReveal(source) { shown += 1 }
        XCTAssertEqual(shown, 1, "one alert, no second presentation")
        // Nothing else was started, so nothing else finishes or presents.
        XCTAssertFalse(gate.finishReveal(source))
        XCTAssertEqual(shown, 1)
        // The reveal is over: callbacks with no reveal are the delegate's again.
        XCTAssertTrue(gate.delegateOwns(source))
        XCTAssertTrue(gate.beginReveal(source), "a later Open In reveals again")
        XCTAssertTrue(gate.finishReveal(source))
    }
}
