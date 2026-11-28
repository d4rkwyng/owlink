import XCTest
import CedricCore

/// Recent hints can be reopened (Mac 0.5.3): from the owl's menu, with the
/// shared replay deciding whether the hint still applies to the text.
@MainActor
final class RecentHintsTests: XCTestCase {
    private func shown(_ id: String, range: NSRange?, offset: Int = 0, seen: String? = nil, replacement: String? = nil) -> EditorOwl.Shown {
        EditorOwl.Shown(hint: OwlHint(id: id, kind: .fix, title: "Hint \(id)", range: range, replacement: replacement, source: "rules"),
                        offset: offset, generation: 1, seen: seen)
    }

    func testRecentKeepsTheLastShownMostRecentFirst() {
        let owl = EditorOwl()
        for i in 0..<10 { owl.markShown(shown("h\(i)", range: nil)) }
        XCTAssertEqual(owl.recent.count, EditorOwl.recentLimit)
        XCTAssertEqual(owl.recent.first?.hint.id, "h9")
        owl.markShown(shown("h5", range: nil))
        XCTAssertEqual(owl.recent.first?.hint.id, "h5")
        XCTAssertEqual(owl.recent.filter { $0.hint.id == "h5" }.count, 1, "once")
    }

    func testShowAgainKeepsFixWhileTheTextIsThere() {
        let owl = EditorOwl()
        let text: NSString = "Fix teh word."
        // The hint's range is relative to its window (offset 2).
        owl.markShown(shown("typo", range: NSRange(location: 2, length: 3), offset: 2, seen: "teh", replacement: "the"))
        XCTAssertEqual(owl.recent.first?.documentRange, NSRange(location: 4, length: 3))
        let stale = owl.showAgain(owl.recent[0], text: text, generation: 2)
        XCTAssertFalse(stale)
        XCTAssertEqual(owl.visible?.hint.id, "typo")
        let fix = owl.fix(in: text)
        XCTAssertEqual(fix?.range, NSRange(location: 4, length: 3))
        XCTAssertEqual(fix?.replacement, "the")
    }

    func testShowAgainAfterAnEditIsTitleOnly() {
        let owl = EditorOwl()
        owl.markShown(shown("typo", range: NSRange(location: 4, length: 3), seen: "teh", replacement: "the"))
        let changed: NSString = "Fix the word."
        XCTAssertTrue(owl.showAgain(owl.recent[0], text: changed, generation: 3))
        XCTAssertEqual(owl.visible?.hint.title, "Hint typo")
        XCTAssertNil(owl.visible?.hint.range)
        XCTAssertNil(owl.fix(in: changed), "no Fix it on changed text")
    }

    func testDismissedHintCanBeShownAgain() {
        let owl = EditorOwl()
        owl.markShown(shown("tip", range: nil))
        owl.showAgain(owl.recent[0], text: "x", generation: 1)
        owl.dismissCurrent()
        XCTAssertNil(owl.visible)
        owl.showAgain(owl.recent[0], text: "x", generation: 1)
        XCTAssertEqual(owl.visible?.hint.id, "tip")
    }
}
