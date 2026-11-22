import XCTest
import UIKit
import CedricCore

@MainActor
final class MarkdownContextBarTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var previousSetting: Any?

    override func setUp() async throws {
        previousSetting = AppSettings.defaults.object(forKey: AppSettings.Key.showContextBar)
        AppSettings.showContextBar = true
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        if let previousSetting { AppSettings.defaults.set(previousSetting, forKey: AppSettings.Key.showContextBar) }
        else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.showContextBar) }
        AppSettings.post()
    }

    private func editor(_ language: Language, text: String = "x", readMode: Bool = false) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(language)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: readMode)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    func testBarFollowsLanguageAndSetting() throws {
        let markdown = editor(.markdown)
        let bar = try XCTUnwrap(markdown.contextBar)
        XCTAssertTrue(markdown.textView.inputAccessoryView === bar)
        func buttonIDs(_ view: UIView) -> [String] {
            if let button = view as? UIButton, let id = button.accessibilityIdentifier, id.hasPrefix("contextbar.") { return [id] }
            return view.subviews.flatMap(buttonIDs)
        }
        XCTAssertEqual(buttonIDs(bar), ContextBarSet.items(for: .markdown).map { "contextbar.\($0.id)" })
        let swift = editor(.swift)
        XCTAssertNil(swift.textView.inputAccessoryView)
        swift.setLanguage(.markdown)
        XCTAssertNotNil(swift.textView.inputAccessoryView)
        AppSettings.showContextBar = false
        XCTAssertNil(markdown.textView.inputAccessoryView)
        XCTAssertNil(swift.textView.inputAccessoryView)
    }

    func testCommandsUndoAndFence() {
        let editor = editor(.markdown, text: "x\nline\n- task\n```\ncode\n```\n")
        let original = editor.textView.text!
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 0, length: 1)
        editor.markdownBoldMenu(nil)
        XCTAssertTrue(editor.textView.text.hasPrefix("**x**"))
        XCTAssertTrue(editor.document.hasUnsavedChanges)
        XCTAssertEqual(editor.lineIndex.length, (editor.textView.text as NSString).length)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, original)
        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        editor.markdownHeading2Menu(nil)
        XCTAssertTrue(editor.textView.text.contains("## line"))
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, original)
        editor.textView.selectedRange = (original as NSString).range(of: "task")
        editor.toggleCheckboxMenu(nil)
        XCTAssertTrue(editor.textView.text.contains("- [ ] task"))
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, original)
        editor.textView.selectedRange = (original as NSString).range(of: "code")
        editor.markdownHeading2Menu(nil)
        XCTAssertEqual(editor.textView.text, original)
    }

    func testReadModeAndReadOnlyRefuse() {
        let editor = editor(.markdown, readMode: true)
        editor.textView.selectedRange = NSRange(location: 0, length: 1)
        editor.markdownBoldMenu(nil)
        XCTAssertEqual(editor.textView.text, "x")
        editor.startEditing()
        editor.setEditLock(.documentLocked, true)
        editor.markdownBoldMenu(nil)
        XCTAssertEqual(editor.textView.text, "x")
    }

    func testStatusBarClearsHardwareAccessory() throws {
        let editor = editor(.markdown)
        editor.textView.becomeFirstResponder()
        let bar = try XCTUnwrap(editor.contextBar)
        editor.view.addSubview(bar)
        let height = editor.view.bounds.height
        bar.frame = CGRect(x: 0, y: height - 78, width: editor.view.bounds.width, height: 44)
        let keyboard = CGRect(x: 0, y: height - 34, width: editor.view.bounds.width, height: 34)
        XCTAssertEqual(editor.statusBottom(keyboard: keyboard, homeInset: 34), height - 78, accuracy: 0.5)
        let softwareKeyboard = CGRect(x: 0, y: height - 350, width: editor.view.bounds.width, height: 350)
        XCTAssertEqual(editor.statusBottom(keyboard: softwareKeyboard, homeInset: 34), height - 350, accuracy: 0.5)
        let hiddenKeyboard = CGRect(x: 0, y: height, width: editor.view.bounds.width, height: 350)
        XCTAssertEqual(editor.statusBottom(keyboard: hiddenKeyboard, homeInset: 34), height, accuracy: 0.5)
        bar.removeFromSuperview()
        XCTAssertEqual(editor.statusBottom(keyboard: keyboard, homeInset: 34), height, accuracy: 0.5)
    }

    func testHeadingAccessibilityFollowsCaret() throws {
        let editor = editor(.markdown, text: "Body\n###### Heading\n")
        let bar = try XCTUnwrap(editor.contextBar)
        let heading = try XCTUnwrap(bar.buttons["heading"])
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        bar.refreshInlineSelectionStates()
        XCTAssertEqual(heading.accessibilityValue, String(localized: "Body"))
        editor.textView.selectedRange = NSRange(location: 8, length: 0)
        bar.refreshInlineSelectionStates()
        XCTAssertEqual(heading.accessibilityValue, String(localized: "Heading 6"))
        XCTAssertEqual(bar.accessibilityContainerType, .semanticGroup)
        XCTAssertTrue(heading.showsLargeContentViewer)
        XCTAssertTrue(heading.isPointerInteractionEnabled)
    }

    func testCommandIsSeparateFromTyping() async throws {
        let editor = editor(.markdown)
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 1, length: 0)
        editor.textView.insertText("y")
        try await Task.sleep(for: .milliseconds(50))
        editor.textView.selectedRange = NSRange(location: 0, length: 1)
        editor.markdownBoldMenu(nil)
        XCTAssertEqual(editor.textView.text, "**x**y")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "xy")
    }

    func testSnapshots() throws {
        let editor = editor(.markdown)
        let env = ProcessInfo.processInfo.environment["OWLINK_SNAPSHOTS"]
        let dir = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("owlink-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (device, width) in [("iphone", CGFloat(402)), ("ipad", CGFloat(1032))] {
            for dark in [false, true] {
                let bar = MarkdownContextBar(editor: editor)
                bar.frame = CGRect(x: 0, y: 0, width: width, height: 44)
                bar.applyPalette(EditorTheme.system.palette(systemIsDark: dark))
                bar.layoutIfNeeded()
                let renderer = UIGraphicsImageRenderer(bounds: bar.bounds)
                let image = renderer.image { bar.layer.render(in: $0.cgContext) }
                let mode = dark ? "dark" : "light"
                try XCTUnwrap(image.pngData()).write(to: dir.appendingPathComponent("contextbar-\(device)-\(mode).png"))
                add(XCTAttachment(image: image))
            }
        }
    }
}
