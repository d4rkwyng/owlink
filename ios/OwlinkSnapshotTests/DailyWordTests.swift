import XCTest
import UIKit
import CedricCore

@MainActor
final class DailyWordTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var suites: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_795_348_800)

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites = []
    }

    private func counter(calendar: Calendar = .current) -> DailyWordCounter {
        let suite = "daily-tests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return DailyWordCounter(defaults: defaults, calendar: calendar, now: { self.clock })
    }

    private func editor(_ text: String, counter: DailyWordCounter) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        editor.dailyWords = counter
        editor.dailyIdleInterval = 0.01
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private func changed(_ counter: DailyWordCounter) -> XCTestExpectation {
        expectation(forNotification: DailyWordCounter.changed, object: counter, handler: nil)
    }

    private func waitForChange(_ expectation: XCTestExpectation) async {
        await fulfillment(of: [expectation], timeout: 2)
    }

    private func targetField(in view: UIView) -> UITextField? {
        if view.accessibilityIdentifier == "stats.dailyTarget" { return view as? UITextField }
        for child in view.subviews {
            if let field = targetField(in: child) { return field }
        }
        return nil
    }

    func testDebouncedNetChangesAcrossDocumentsAndDeletion() async throws {
        let counter = counter()
        let first = editor("old words", counter: counter)
        let second = editor("other", counter: counter)
        XCTAssertEqual(counter.wordsToday, 0)

        var update = changed(counter)
        first.textView.text = "old words new extra"
        first.textViewDidChange(first.textView)
        XCTAssertEqual(counter.wordsToday, 0)
        await waitForChange(update)
        XCTAssertEqual(counter.wordsToday, 2)

        update = changed(counter)
        second.textView.text = "other added"
        second.textViewDidChange(second.textView)
        await waitForChange(update)
        XCTAssertEqual(counter.wordsToday, 3)

        update = changed(counter)
        first.textView.text = "old words new"
        first.textViewDidChange(first.textView)
        await waitForChange(update)
        XCTAssertEqual(counter.wordsToday, 2)

        update = changed(counter)
        first.textView.text = "old"
        first.textViewDidChange(first.textView)
        await waitForChange(update)
        XCTAssertEqual(counter.wordsToday, 0)
    }

    func testSaveCommitsPendingEditAndCloseDropsBaseline() async throws {
        let counter = counter()
        let editor = editor("base", counter: counter)
        let update = changed(counter)
        editor.textView.text = "base written"
        editor.textViewDidChange(editor.textView)
        XCTAssertNotNil(editor.document.onSaved)
        editor.document.onSaved?()
        XCTAssertEqual(counter.wordsToday, 1)
        await waitForChange(update)

        editor.stopDailyWordTracking()
        editor.textView.text = "base written more"
        editor.commitDailyWords()
        XCTAssertEqual(counter.wordsToday, 1, "after close the next count is a fresh baseline, not words written")
        editor.textView.text = "base written more again"
        editor.commitDailyWords()
        XCTAssertEqual(counter.wordsToday, 2)
    }

    func testReloadRebaselinesWithoutCountingExistingWords() async throws {
        let counter = counter()
        let editor = editor("one two", counter: counter)
        var update = changed(counter)
        editor.textView.text = "one two three"
        editor.textViewDidChange(editor.textView)
        await waitForChange(update)
        XCTAssertEqual(counter.wordsToday, 1)

        editor.document.text = "replacement text has four"
        editor.document.onReload?()
        XCTAssertEqual(counter.wordsToday, 1)
        update = changed(counter)
        editor.textView.text = "replacement text has four added"
        editor.textViewDidChange(editor.textView)
        await waitForChange(update)
        XCTAssertEqual(counter.wordsToday, 2)
    }

    func testOversizedTextIsDroppedWithoutCounting() {
        let counter = counter()
        let editor = editor("this text is longer than ten", counter: counter)
        editor.dailyWordCountLimit = 10
        editor.commitDailyWords()
        XCTAssertEqual(counter.wordsToday, 0)
        editor.textView.text = "small document"
        editor.commitDailyWords()
        XCTAssertEqual(counter.wordsToday, 0, "a dropped key starts with a baseline rather than counting prior content")
    }

    func testTargetZeroClearsInvalidInputErrorsAndValidInputIsCanonical() throws {
        let counter = counter()
        let stats = StatisticsViewController(text: "", selection: NSRange(location: 0, length: 0),
                                             filePath: "/test", dailyWords: counter)
        stats.loadViewIfNeeded()
        let field = try XCTUnwrap(targetField(in: stats.view))
        field.text = "000500"
        stats.saveDailyTarget()
        XCTAssertEqual(counter.target, 500)
        XCTAssertEqual(DailyWordDefaults.target(in: try XCTUnwrap(UserDefaults(suiteName: suites.last!))), 500)
        XCTAssertEqual(field.text, "500")

        field.text = "0"
        stats.saveDailyTarget()
        XCTAssertNil(counter.target)
        XCTAssertNil(DailyWordDefaults.target(in: try XCTUnwrap(UserDefaults(suiteName: suites.last!))))
        XCTAssertEqual(field.text, "")

        field.text = "10000001"
        stats.saveDailyTarget()
        XCTAssertNil(counter.target)
        XCTAssertNotNil(field.accessibilityValue)
        XCTAssertFalse(try XCTUnwrap(targetError(in: stats.view)).isHidden)

        field.text = "not a number"
        stats.saveDailyTarget()
        XCTAssertFalse(try XCTUnwrap(targetError(in: stats.view)).isHidden)
    }

    func testLateBaselineCountsEditsOnceAndPersists() async throws {
        let counter = counter()
        let text = String(repeating: "word ", count: 21_000)
        let editor = editor(text, counter: counter)
        editor.textView.text = text + "new words"
        editor.commitDailyWords()
        XCTAssertEqual(counter.wordsToday, 0)
        for _ in 0..<200 where counter.wordsToday != 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(counter.wordsToday, 2)
        editor.commitDailyWords()
        XCTAssertEqual(counter.wordsToday, 2)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suites.last!))
        let day = DailyWords.dayString(for: clock, calendar: .current)
        XCTAssertEqual(DailyWordDefaults.words(on: day, defaults: defaults), 2)
    }

    func testExplicitRollAtLocalMidnightAndGetterIsPure() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21))!
        clock = firstDay
        let counter = counter(calendar: calendar)
        counter.rebaseline(key: "doc", words: 10)
        counter.note(key: "doc", words: 15)
        XCTAssertEqual(counter.wordsToday, 5)

        clock = calendar.date(byAdding: .day, value: 1, to: firstDay)!
        XCTAssertEqual(counter.wordsToday, 5, "reading the value does not roll or notify")
        let rollover = expectation(forNotification: DailyWordCounter.changed, object: counter, handler: nil)
        counter.roll()
        XCTAssertEqual(counter.wordsToday, 0)
        wait(for: [rollover], timeout: 0.1)
        counter.note(key: "doc", words: 15)
        XCTAssertEqual(counter.wordsToday, 0)
        counter.note(key: "doc", words: 16)
        XCTAssertEqual(counter.wordsToday, 1)
    }

    private func targetError(in view: UIView) -> UILabel? {
        if view.accessibilityIdentifier == "stats.dailyTargetError" { return view as? UILabel }
        for child in view.subviews {
            if let label = targetError(in: child) { return label }
        }
        return nil
    }
}
