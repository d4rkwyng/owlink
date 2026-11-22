import XCTest
import UIKit
import CedricCore

@MainActor
final class DailyWordTests: XCTestCase {
    func testEditorCountsAfterPauseAcrossDocumentsAndDeletion() async throws {
        let suite = "daily-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = DailyWordCounter(defaults: defaults)
        var windows: [UIWindow] = []
        defer { for window in windows { window.isHidden = true; window.rootViewController = nil } }

        func editor(_ text: String) -> EditorViewController {
            let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
            doc.text = text
            let editor = EditorViewController(document: doc, readModeOnOpen: false)
            editor.dailyWords = counter
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = UINavigationController(rootViewController: editor)
            window.makeKeyAndVisible()
            windows.append(window)
            return editor
        }

        let first = editor("old words")
        let second = editor("other")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counter.wordsToday, 0)
        first.textView.text = "old words new words"
        first.textViewDidChange(first.textView)
        second.textView.text = "other added"
        second.textViewDidChange(second.textView)
        XCTAssertEqual(counter.wordsToday, 0)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(counter.wordsToday, 3)
        first.textView.text = ""
        first.textViewDidChange(first.textView)
        first.commitDailyWords()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.wordsToday, 0)
        XCTAssertEqual(DailyWordCounter(defaults: defaults).wordsToday, 0)
    }

    func testTargetFieldPersistsAndClears() throws {
        let suite = "daily-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = DailyWordCounter(defaults: defaults)
        let stats = StatisticsViewController(text: "", selection: NSRange(location: 0, length: 0),
                                             filePath: "/test", defaults: defaults, dailyWords: counter)
        stats.loadViewIfNeeded()
        func find(_ view: UIView) -> UITextField? {
            if view.accessibilityIdentifier == "stats.dailyTarget" { return view as? UITextField }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let field = try XCTUnwrap(find(stats.view))
        XCTAssertNil(counter.target)
        field.text = "500"
        stats.saveDailyTarget()
        XCTAssertEqual(DailyWordDefaults.target(in: defaults), 500)
        field.text = ""
        stats.saveDailyTarget()
        XCTAssertNil(DailyWordDefaults.target(in: defaults))
    }
}
