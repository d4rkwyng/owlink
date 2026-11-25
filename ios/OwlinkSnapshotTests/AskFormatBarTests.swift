import XCTest
import UIKit
import CedricCore

/// The Markdown format bar (the context bar, the text view's input
/// accessory) is off the keyboard while the Ask Cedric sheet is up, and
/// the same bar is back however the sheet goes: Done (SwiftUI's dismiss,
/// which the sheet delegate never hears about), a swipe down, or a
/// dismissal by the editor. Every one of them ends with the sheet's
/// `viewDidDisappear` while it is being dismissed. This test bundle has no
/// app or scene, so a presentation starts but never finishes here: the
/// window's appearance callbacks are sent by hand. The real Done and swipe
/// down are UI tests (testFormatBarHiddenUnderAskCedric).
@MainActor
final class AskFormatBarTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.showContextBar)
    }

    private func markdownEditor() -> EditorViewController {
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.showContextBar)
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "# Owls\n\nHoot **hoot**.\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = .compact
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private func openAskSheet(_ editor: EditorViewController) throws -> UIViewController {
        editor.askCedric()
        return try XCTUnwrap(editor.presentedViewController, "Ask Cedric didn't present a sheet")
    }

    /// The sheet goes: dismissed, then the appearance callbacks.
    private func sheetGoes(_ sheet: UIViewController, by dismisser: UIViewController) {
        dismisser.dismiss(animated: false)
        sheet.beginAppearanceTransition(false, animated: false)
        sheet.endAppearanceTransition()
    }

    func testBarHiddenUnderTheSheetAndBackAfterDone() throws {
        let editor = markdownEditor()
        let bar = try XCTUnwrap(editor.contextBar, "no format bar for Markdown")
        XCTAssertTrue(editor.textView.inputAccessoryView === bar)
        editor.textView.becomeFirstResponder()
        let sheet = try openAskSheet(editor)
        XCTAssertNil(editor.textView.inputAccessoryView, "the format bar is still on the keyboard under Ask Cedric")
        // Done: the sheet dismisses itself.
        sheetGoes(sheet, by: sheet)
        XCTAssertTrue(editor.textView.inputAccessoryView === bar, "the format bar didn't come back (the same bar)")
        XCTAssertTrue(editor.contextBar === bar)
    }

    func testBarBackAfterTheEditorDismissesTheSheet() throws {
        let editor = markdownEditor()
        let bar = try XCTUnwrap(editor.contextBar)
        let sheet = try openAskSheet(editor)
        XCTAssertNil(editor.textView.inputAccessoryView)
        sheetGoes(sheet, by: editor)
        XCTAssertTrue(editor.textView.inputAccessoryView === bar)
    }

    /// The setting off: nothing comes back either way.
    func testBarStaysOffWhenTheSettingIsOff() throws {
        let editor = markdownEditor()
        AppSettings.showContextBar = false
        editor.updateContextBar()
        XCTAssertNil(editor.textView.inputAccessoryView)
        let sheet = try openAskSheet(editor)
        sheetGoes(sheet, by: sheet)
        XCTAssertNil(editor.textView.inputAccessoryView)
    }
}
