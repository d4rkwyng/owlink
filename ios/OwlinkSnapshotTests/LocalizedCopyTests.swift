import XCTest

/// The copy Mac 0.5.1 localized (settings units, the Go to Line
/// placeholder) and the iOS strings like it go through `String(localized:)`,
/// the iOS app's approach. Checked in the sources, as the Mac's
/// UICoverageTests does.
final class LocalizedCopyTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Owlink/\(name)"), encoding: .utf8)
    }

    func testUnitsPlaceholdersAndLabelsAreLocalized() throws {
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(settings.contains(#"Text(String(localized: "\(Int(fontSize)) pt"))"#))
        XCTAssertTrue(settings.contains(#"Text(String(localized: "\(Int(proseFontSize)) pt"))"#))
        XCTAssertFalse(settings.contains(#"Text("\(Int(fontSize)) pt")"#))
        let editor = try source("EditorViewController.swift")
        XCTAssertTrue(editor.contains(#"$0.placeholder = String(localized: "1–\(self.lineIndex.lineCount)")"#))
        let hint = try source("OwlHintBar.swift")
        XCTAssertTrue(hint.contains(#"accessibilityLabel = String(localized: "Cedric: \(hint.title)")"#))
        let typos = try source("FixTypos.swift")
        XCTAssertTrue(typos.contains(#"word = String(localized: "“\(c.word)”")"#))
    }
}
