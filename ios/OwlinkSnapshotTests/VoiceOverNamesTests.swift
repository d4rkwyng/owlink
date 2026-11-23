import XCTest
import UIKit
import CedricCore

/// VoiceOver names for the fields Mac 0.5.1 named (Ask Cedric's scope and
/// question, Go to Line), plus the server address in Settings. Find and
/// Replace use the system find navigator, which names its own fields; new
/// documents come from the system document browser (no name field).
@MainActor
final class VoiceOverNamesTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for w in windows { w.rootViewController?.dismiss(animated: false); w.isHidden = true; w.rootViewController = nil }
        windows = []
    }

    func testAskCedricNamesMatchTheMac() {
        XCTAssertEqual(AskCedricView.scopeAccessibilityLabel, String(localized: "Asking about"))
        XCTAssertEqual(AskCedricView.questionAccessibilityLabel, String(localized: "Question for Cedric"))
    }

    /// The views use the names (SwiftUI's accessibility tree isn't
    /// reachable from a unit test, so the source is checked, as the Mac's
    /// UICoverageTests does).
    func testViewsApplyTheNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let ask = try String(contentsOf: root.appendingPathComponent("Owlink/AskCedricView.swift"), encoding: .utf8)
        XCTAssertTrue(ask.contains(".accessibilityLabel(Self.scopeAccessibilityLabel)"))
        XCTAssertTrue(ask.contains(".accessibilityLabel(Self.questionAccessibilityLabel)"))
        XCTAssertFalse(ask.contains(#".accessibilityLabel(String(localized: "Context"))"#))
        let settings = try String(contentsOf: root.appendingPathComponent("Owlink/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains(#".accessibilityLabel(String(localized: "Server address"))"#))
    }

    func testGoToLineFieldHasAName() throws {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = "one\ntwo\nthree\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        editor.goToLine()
        let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController
                                  ?? editor.navigationController?.presentedViewController as? UIAlertController)
        let field = try XCTUnwrap(alert.textFields?.first)
        XCTAssertEqual(field.accessibilityLabel, String(localized: "Line number"))
        XCTAssertEqual(field.accessibilityLabel, EditorViewController.goToLineAccessibilityLabel)
        XCTAssertEqual(field.placeholder?.hasPrefix("1–"), true, "the range stays the placeholder")
    }
}
