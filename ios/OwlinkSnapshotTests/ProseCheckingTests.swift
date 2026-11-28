import XCTest
import UIKit
import CedricCore

/// Spelling and grammar: the system's checker in Markdown and plain text,
/// off for code, data files and large documents, by the Mac's two settings.
@MainActor
final class ProseCheckingTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var oldSpelling: Any?
    private var oldGrammar: Any?

    override func setUp() async throws {
        oldSpelling = AppSettings.defaults.object(forKey: AppSettings.Key.checkSpellingWhileTyping)
        oldGrammar = AppSettings.defaults.object(forKey: AppSettings.Key.checkGrammarInProse)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.checkSpellingWhileTyping)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.checkGrammarInProse)
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        restore(oldSpelling, AppSettings.Key.checkSpellingWhileTyping)
        restore(oldGrammar, AppSettings.Key.checkGrammarInProse)
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { AppSettings.defaults.set(value, forKey: key) } else { AppSettings.defaults.removeObject(forKey: key) }
    }

    private func editor(_ text: String = "Some prose with a mispeled word.\n", fileName: String = "notes.md",
                        language: Language? = nil) -> EditorViewController {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(fileName)
        let doc = TextDocument(fileURL: url)
        doc.text = text
        doc.language = .forFile(named: fileName, content: text)
        if let language { doc.language.choose(language) }
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func assertGrammar(_ editor: EditorViewController, _ expectedOn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        if #available(iOS 27.0, *) {
            XCTAssertEqual(editor.textView.grammarCheckingType, expectedOn ? .yes : .no, file: file, line: line)
        }
    }

    // MARK: Settings

    func testSettingsDefaultOnAndPersist() {
        XCTAssertNil(AppSettings.defaults.object(forKey: "checkSpellingWhileTyping"))
        XCTAssertNil(AppSettings.defaults.object(forKey: "checkGrammarInProse"))
        XCTAssertTrue(AppSettings.checkSpellingWhileTyping)
        XCTAssertTrue(AppSettings.checkGrammarInProse)
        AppSettings.checkSpellingWhileTyping = false
        AppSettings.checkGrammarInProse = false
        XCTAssertEqual(AppSettings.defaults.object(forKey: "checkSpellingWhileTyping") as? Bool, false)
        XCTAssertEqual(AppSettings.defaults.object(forKey: "checkGrammarInProse") as? Bool, false)
        XCTAssertFalse(AppSettings.checkSpellingWhileTyping)
        XCTAssertFalse(AppSettings.checkGrammarInProse)
        AppSettings.checkSpellingWhileTyping = true
        AppSettings.checkGrammarInProse = true
        XCTAssertEqual(AppSettings.defaults.object(forKey: "checkSpellingWhileTyping") as? Bool, true)
        XCTAssertTrue(AppSettings.checkGrammarInProse)
    }

    /// `-OwlinkResetSettings` must bring both back to their default (on).
    func testLaunchResetClearsProseChecking() {
        XCTAssertTrue(AppSettings.launchResetKeys.contains("checkSpellingWhileTyping"))
        XCTAssertTrue(AppSettings.launchResetKeys.contains("checkGrammarInProse"))
    }

    // MARK: Which documents

    func testMarkdownAndPlainTextAreChecked() {
        for (name, language) in [("notes.md", Language.markdown), ("notes.txt", .plain)] {
            let editor = editor(fileName: name)
            XCTAssertEqual(editor.document.language.language, language)
            XCTAssertEqual(editor.textView.spellCheckingType, .yes, name)
            assertGrammar(editor, true)
            editor.textView.becomeFirstResponder()
            editor.textViewDidBeginEditing(editor.textView)
            XCTAssertEqual(editor.textView.spellCheckingType, .yes, name)
            assertGrammar(editor, true)
            // The substitutions stay off.
            XCTAssertEqual(editor.textView.autocorrectionType, .no)
            XCTAssertEqual(editor.textView.smartQuotesType, .no)
            XCTAssertEqual(editor.textView.smartDashesType, .no)
            XCTAssertEqual(editor.textView.smartInsertDeleteType, .no)
            XCTAssertEqual(editor.textView.inlinePredictionType, .no)
        }
    }

    func testCodeIsNotChecked() {
        let editor = editor("// A comment with a mispeled word\nlet x = 1\n", fileName: "main.swift")
        XCTAssertEqual(editor.document.language.language, .swift)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        assertGrammar(editor, false)
        editor.textView.becomeFirstResponder()
        editor.textViewDidBeginEditing(editor.textView)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        assertGrammar(editor, false)
    }

    func testDataFilesAreNotChecked() {
        let json = editor("{\"name\": \"valeu\"}\n", fileName: "config.json")
        XCTAssertEqual(json.document.language.language, .json)
        XCTAssertEqual(json.textView.spellCheckingType, .no)
        assertGrammar(json, false)
        let csv = editor("name,value\nfoo,valeu\n", fileName: "table.csv", language: .plain)
        XCTAssertEqual(csv.document.language.language, .plain)
        XCTAssertEqual(csv.textView.spellCheckingType, .no)
        assertGrammar(csv, false)
        let pem = editor("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", fileName: "cert.pem", language: .plain)
        XCTAssertEqual(pem.textView.spellCheckingType, .no)
    }

    // MARK: Following changes

    func testSpellingSettingTogglesMarkdownEditor() {
        let editor = editor()
        editor.textView.becomeFirstResponder()
        XCTAssertEqual(editor.textView.spellCheckingType, .yes)
        AppSettings.checkSpellingWhileTyping = false
        settle()
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        editor.textViewDidBeginEditing(editor.textView)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        AppSettings.checkSpellingWhileTyping = true
        settle()
        XCTAssertEqual(editor.textView.spellCheckingType, .yes)
    }

    /// Spelling off: the system checks nothing (grammar goes with it, as
    /// the Mac's automatic text checking does, 0.5.4), and no completion
    /// (inline predictions, math results, autocorrection) comes back.
    func testSpellingOffTakesGrammarAndCompletionWithIt() {
        let editor = editor()
        editor.textView.becomeFirstResponder()
        editor.textViewDidBeginEditing(editor.textView)
        XCTAssertTrue(editor.systemGrammar)
        assertGrammar(editor, true)
        AppSettings.checkSpellingWhileTyping = false
        settle()
        XCTAssertTrue(AppSettings.checkGrammarInProse, "the grammar setting itself is kept")
        XCTAssertFalse(editor.systemGrammar)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        assertGrammar(editor, false)
        editor.textViewDidBeginEditing(editor.textView)
        assertGrammar(editor, false)
        XCTAssertEqual(editor.textView.autocorrectionType, .no)
        XCTAssertEqual(editor.textView.inlinePredictionType, .no)
        if #available(iOS 18.0, *) { XCTAssertEqual(editor.textView.mathExpressionCompletionType, .no) }
        AppSettings.checkSpellingWhileTyping = true
        settle()
        XCTAssertTrue(editor.systemGrammar)
        XCTAssertEqual(editor.textView.spellCheckingType, .yes)
        assertGrammar(editor, true)
    }

    func testGrammarSettingFollowsInProseOnly() {
        let markdown = editor()
        let swift = editor("let x = 1\n", fileName: "main.swift")
        AppSettings.checkGrammarInProse = false
        settle()
        XCTAssertEqual(AppSettings.defaults.object(forKey: AppSettings.Key.checkGrammarInProse) as? Bool, false)
        assertGrammar(markdown, false)
        assertGrammar(swift, false)
        // Grammar off leaves spelling alone.
        XCTAssertEqual(markdown.textView.spellCheckingType, .yes)
        AppSettings.checkGrammarInProse = true
        settle()
        assertGrammar(markdown, true)
        assertGrammar(swift, false)
    }

    func testLanguageChangeTurnsCheckingOff() {
        let editor = editor()
        XCTAssertEqual(editor.textView.spellCheckingType, .yes)
        editor.setLanguage(.swift)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        assertGrammar(editor, false)
        editor.setLanguage(.markdown)
        XCTAssertEqual(editor.textView.spellCheckingType, .yes)
        assertGrammar(editor, true)
    }

    func testLargeDocumentPausesChecking() {
        let editor = editor(String(repeating: "a", count: LargeDocument.lineThreshold + 1), fileName: "long.txt")
        XCTAssertEqual(editor.writingLargeReason, .longLine)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        assertGrammar(editor, false)
        editor.textView.becomeFirstResponder()
        editor.textViewDidBeginEditing(editor.textView)
        XCTAssertEqual(editor.textView.spellCheckingType, .no)
        editor.replaceAllText(with: "short\ntext")
        XCTAssertNil(editor.writingLargeReason)
        XCTAssertEqual(editor.textView.spellCheckingType, .yes)
        assertGrammar(editor, true)
    }

    // MARK: Edit › Spelling and Grammar

    func testMenuCommandsToggleSettingsAndShowState() {
        let editor = editor("let x = 1\n", fileName: "main.swift")
        let spelling = UICommand(title: "Check Spelling While Typing", action: #selector(EditorViewController.toggleCheckSpelling))
        let grammar = UICommand(title: "Check Grammar in Prose", action: #selector(EditorViewController.toggleCheckGrammar))
        // Enabled whenever an editor is open, code included.
        XCTAssertTrue(editor.canPerformAction(spelling.action, withSender: nil))
        XCTAssertTrue(editor.canPerformAction(grammar.action, withSender: nil))
        editor.validate(spelling)
        editor.validate(grammar)
        XCTAssertEqual(spelling.state, .on)
        XCTAssertEqual(grammar.state, .on)
        editor.toggleCheckSpelling()
        editor.toggleCheckGrammar()
        XCTAssertFalse(AppSettings.checkSpellingWhileTyping)
        XCTAssertFalse(AppSettings.checkGrammarInProse)
        editor.validate(spelling)
        editor.validate(grammar)
        XCTAssertEqual(spelling.state, .off)
        XCTAssertEqual(grammar.state, .off)
        editor.toggleCheckSpelling()
        XCTAssertTrue(AppSettings.checkSpellingWhileTyping)
    }
}
