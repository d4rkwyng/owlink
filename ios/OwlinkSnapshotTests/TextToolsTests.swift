import XCTest
import UIKit
import CedricCore

@MainActor
final class TextToolsTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor(text: String, width: CGFloat = 1024) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 768))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testToolStates() {
        let jwt = "eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0."
        let text = "^[a-z]+$ \(jwt) ordinary"
        let editor = editor(text: text)
        let ns = text as NSString
        let regex = editor.textToolStates(selection: ns.range(of: "^[a-z]+$"))
        XCTAssertTrue(regex.explain)
        XCTAssertFalse(regex.decode)
        let decoded = editor.textToolStates(selection: ns.range(of: jwt))
        XCTAssertFalse(decoded.explain)
        XCTAssertTrue(decoded.decode)
        let plain = editor.textToolStates(selection: ns.range(of: "ordinary"))
        XCTAssertFalse(plain.explain)
        XCTAssertFalse(plain.decode)
        XCTAssertFalse(editor.textToolStates(selection: NSRange(location: 0, length: 0)).explain)
        editor.textView.selectedRange = ns.range(of: jwt)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.decodeSelection), withSender: nil))
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.explainRegex), withSender: nil))
        editor.textView.text = "ordinary"
        editor.textViewDidChange(editor.textView)
        XCTAssertFalse(editor.textToolStates(selection: NSRange(location: 0, length: 8)).explain)
    }

    func testTodoList() {
        let items = Todos.find("// TODO: first\n// FIXME: second\n", language: "swift")
        let controller = TodoListViewController(items: items) { _ in }
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 2)
        XCTAssertEqual(items.map(\.tag), ["TODO", "FIXME"])
        XCTAssertEqual(items.map(\.line), [1, 2])
        XCTAssertEqual(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 0)).accessibilityIdentifier, "tools.todo.2")
    }

    func testStatisticsAndGoalPersistence() async throws {
        let suite = "TextToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let text = "one two\nthree"
        let path = "/test/essay.txt"
        let controller = StatisticsViewController(text: text, selection: NSRange(location: 0, length: 7), filePath: path, defaults: defaults)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        windows.append(window)
        for _ in 0..<30 {
            if descendants(controller.view).compactMap({ $0.accessibilityLabel }).contains(where: { $0.contains("Document") && $0.contains("Words") && $0.contains("3") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let labels = descendants(controller.view).compactMap { $0 as? UILabel }.compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("Document") && $0.contains("Words") && $0.contains("3") })
        XCTAssertTrue(labels.contains { $0.contains("Selection") && $0.contains("Words") && $0.contains("2") })
        XCTAssertTrue(labels.contains { $0.contains("Document") && $0.contains("Characters") && $0.contains("13") })
        XCTAssertTrue(labels.contains { $0.contains("Document") && $0.contains("Lines") && $0.contains("2") })
        XCTAssertTrue(labels.contains { $0.contains("Selection") && $0.contains("Characters") && $0.contains("7") })
        XCTAssertTrue(labels.contains { $0.contains("Selection") && $0.contains("Lines") && $0.contains("1") })
        XCTAssertTrue(labels.contains { $0.contains("Document") && $0.contains("Reading time") && $0.contains("1") })
        let field = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "stats.goal" })
        XCTAssertEqual(WordGoal.parse("500"), 500)
        XCTAssertFalse(field.allTargets.isEmpty)
        XCTAssertNotNil(field.actions(forTarget: controller, forControlEvent: .editingChanged))
        field.text = "500"
        controller.goalChanged()
        XCTAssertNil(defaults.data(forKey: "statistics.fileWordGoals"))
        controller.goalEditingEnded()
        XCTAssertFalse(descendants(controller.view).compactMap { $0 as? UILabel }.contains { !$0.isHidden && ($0.text ?? "").contains("Could not") })
        let data = try XCTUnwrap(defaults.data(forKey: "statistics.fileWordGoals"))
        let goals = try JSONDecoder().decode([FileWordGoal].self, from: data)
        XCTAssertEqual(FileWordGoals.goal(for: path, in: goals), 500)
        let reopened = StatisticsViewController(text: text, selection: NSRange(location: 0, length: 0), filePath: path, defaults: defaults)
        reopened.loadViewIfNeeded()
        let saved = try XCTUnwrap(descendants(reopened.view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "stats.goal" })
        XCTAssertEqual(saved.text, "500")
        saved.text = ""
        reopened.goalChanged()
        reopened.goalEditingEnded()
        let cleared = StatisticsViewController(text: text, selection: NSRange(location: 0, length: 0), filePath: path, defaults: defaults)
        cleared.loadViewIfNeeded()
        let empty = try XCTUnwrap(descendants(cleared.view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "stats.goal" })
        XCTAssertTrue(empty.text?.isEmpty ?? true)
    }

    func testWideStatusShowsWords() async throws {
        let editor = editor(text: "one two three")
        let button = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "status.words" })
        for _ in 0..<30 {
            editor.view.layoutIfNeeded()
            if !button.isHidden { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.title(for: .normal), String(localized: "3 words"))
    }

    func testGoalDebouncesAndSavesOnDismissal() async throws {
        let suite = "TextToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StatisticsViewController(text: "one", selection: NSRange(location: 0, length: 0),
                                                  filePath: "/test/debounce", defaults: defaults)
        controller.loadViewIfNeeded()
        let field = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "stats.goal" })
        field.text = "1234"
        controller.goalChanged()
        XCTAssertNil(defaults.data(forKey: "statistics.fileWordGoals"))
        try await Task.sleep(for: .milliseconds(700))
        let data = try XCTUnwrap(defaults.data(forKey: "statistics.fileWordGoals"))
        XCTAssertEqual(FileWordGoals.goal(for: "/test/debounce", in: try JSONDecoder().decode([FileWordGoal].self, from: data)), 1234)
        field.text = "2000"
        controller.goalChanged()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        let saved = try XCTUnwrap(defaults.data(forKey: "statistics.fileWordGoals"))
        XCTAssertEqual(FileWordGoals.goal(for: "/test/debounce", in: try JSONDecoder().decode([FileWordGoal].self, from: saved)), 2000)
    }

    func testWordCountFormatting() {
        XCTAssertEqual(localizedWordCount(1), "1 \(String(localized: "word"))")
        XCTAssertEqual(localizedWordCount(1_234), "\(1_234.formatted()) \(String(localized: "words"))")
    }

    func testCompactStatusPreservesOtherLabels() async throws {
        let editor = editor(text: "one two three", width: 320)
        let views = descendants(editor.view)
        let words = try XCTUnwrap(views.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "status.words" })
        let language = try XCTUnwrap(views.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "editor.language" })
        let format = try XCTUnwrap(views.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "editor.format" })
        let position = try XCTUnwrap(views.compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "editor.status" })
        for _ in 0..<30 {
            editor.view.layoutIfNeeded()
            if words.title(for: .normal) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        editor.view.layoutIfNeeded()
        for control in [language, format, position] as [UIView] {
            XCTAssertGreaterThanOrEqual(control.bounds.width + 0.5, control.intrinsicContentSize.width)
        }
        XCTAssertTrue(words.isHidden || words.alpha == 0 || words.bounds.width < words.intrinsicContentSize.width)
        editor.hideKeyboardButton.isHidden = false
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        for control in [language, format, position] as [UIView] {
            XCTAssertGreaterThanOrEqual(control.bounds.width + 0.5, control.intrinsicContentSize.width)
        }
    }

    func testCountsStayVisibleWhileRecomputing() async throws {
        let editor = editor(text: "one")
        let button = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "status.words" })
        for _ in 0..<30 {
            if button.title(for: .normal) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(button.title(for: .normal), localizedWordCount(1))
        editor.textView.text = "one two"
        editor.textViewDidChange(editor.textView)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.title(for: .normal), localizedWordCount(1))
        for _ in 0..<30 {
            if button.title(for: .normal) == localizedWordCount(2) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(button.title(for: .normal), localizedWordCount(2))

        let stats = StatisticsViewController(text: "one", selection: NSRange(location: 0, length: 0), filePath: "/test/counts")
        stats.loadViewIfNeeded()
        for _ in 0..<30 {
            if descendants(stats.view).compactMap(\.accessibilityLabel).contains(where: { $0.contains("Document, Words") && $0.contains("1") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let before = descendants(stats.view).compactMap(\.accessibilityLabel)
        stats.update(text: "one two", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(descendants(stats.view).compactMap(\.accessibilityLabel), before)
        for _ in 0..<30 {
            if descendants(stats.view).compactMap(\.accessibilityLabel).contains(where: { $0.contains("Document, Words") && $0.contains("2") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(descendants(stats.view).compactMap(\.accessibilityLabel).contains { $0.contains("Document, Words") && $0.contains("2") })
    }

    func testRegexResultUsesMediumSheetOnPhone() async throws {
        let editor = editor(text: "^[a-z]+$")
        editor.loadViewIfNeeded()
        editor.textView.selectedRange = NSRange(location: 0, length: 8)
        editor.explainRegex()
        for _ in 0..<30 {
            if editor.presentedViewController is UINavigationController { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let nav = try XCTUnwrap(editor.presentedViewController as? UINavigationController)
        XCTAssertTrue(nav.viewControllers.first is ToolResultViewController)
        if editor.traitCollection.userInterfaceIdiom == .phone {
            XCTAssertEqual(nav.modalPresentationStyle, .pageSheet)
            XCTAssertEqual(nav.sheetPresentationController?.detents.count, 1)
            XCTAssertEqual(nav.sheetPresentationController?.detents.first?.identifier, .medium)
        }
    }
}
