import XCTest
import UIKit
import CedricCore

/// Settings › Font: the editor's monospaced family on the Mac's "fontName" key.
@MainActor
final class EditorFontFamilyTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var saved: [String: Any?] = [:]
    private let keys = [AppSettings.Key.fontName, AppSettings.Key.fontSize, AppSettings.Key.useProseFont,
                        AppSettings.Key.proseFontName, AppSettings.Key.proseFontSize]
    private let traits = UITraitCollection(horizontalSizeClass: .compact)

    override func setUp() async throws {
        for key in keys { saved[key] = AppSettings.defaults.object(forKey: key) }
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.fontName)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.fontSize)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.useProseFont)
        AppSettings.post()
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        for key in keys {
            if let value = saved[key] ?? nil { AppSettings.defaults.set(value, forKey: key) }
            else { AppSettings.defaults.removeObject(forKey: key) }
        }
        AppSettings.post()
    }

    private func editor(_ text: String, ext: String, language: Language) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(language)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    /// An installed monospaced face: Courier, Courier New or Menlo, else
    /// whatever the picker lists first.
    private func monoFace() throws -> (family: String, name: String) {
        let choices = AppSettings.editorFontChoices(current: nil).dropFirst()
        for family in ["Menlo", "Courier New", "Courier"] {
            if let c = choices.first(where: { $0.title == family }) { return (c.title, c.name) }
        }
        let c = try XCTUnwrap(choices.first, "no monospaced family installed")
        return (c.title, c.name)
    }

    private func isSystemMono(_ font: UIFont?, size: CGFloat) -> Bool {
        guard let font else { return false }
        return font == UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// `-OwlinkResetSettings` must bring the face back to SF Mono.
    func testLaunchResetClearsFontName() {
        XCTAssertTrue(AppSettings.launchResetKeys.contains("fontName"))
    }

    func testUnsetIsMonospacedSystemFontAtCurrentSize() {
        XCTAssertNil(AppSettings.fontName)
        let size = CGFloat(AppSettings.defaultFontSize(for: traits))
        let font = AppSettings.font(for: traits)
        XCTAssertTrue(isSystemMono(font, size: size))
        XCTAssertEqual(font.pointSize, size)
        AppSettings.fontSize = 21
        XCTAssertTrue(isSystemMono(AppSettings.font(for: traits), size: 21))
        XCTAssertTrue(isSystemMono(AppSettings.font(), size: 21))
    }

    func testChosenFamilyAppliesToOpenEditorAndKeepsSize() throws {
        let face = try monoFace()
        let editor = editor("let x = 1\n\tlet y = 2\n", ext: "swift", language: .swift)
        XCTAssertTrue(isSystemMono(editor.textView.font, size: editor.textView.font?.pointSize ?? 0))

        AppSettings.fontName = face.name
        XCTAssertEqual(AppSettings.defaults.string(forKey: "fontName"), face.name)
        let size = CGFloat(AppSettings.defaultFontSize(for: editor.traitCollection))
        let font = AppSettings.font(for: traits)
        XCTAssertEqual(font.familyName, face.family)
        XCTAssertEqual(font.fontName, face.name)
        XCTAssertEqual(editor.textView.font?.familyName, face.family, "the open editor follows the setting")
        XCTAssertEqual(editor.textView.font?.pointSize, size)
        XCTAssertEqual(editor.textView.typingAttributes[.font] as? UIFont, editor.textView.font)

        // Bigger / Smaller / Actual Size change only the size.
        AppSettings.fontSize = 20
        XCTAssertEqual(AppSettings.font(for: traits).fontName, face.name)
        XCTAssertEqual(AppSettings.font(for: traits).pointSize, 20)
        XCTAssertEqual(AppSettings.font().fontName, face.name)
        XCTAssertEqual(editor.textView.font?.fontName, face.name)
        XCTAssertEqual(editor.textView.font?.pointSize, 20)
        editor.biggerFont()
        XCTAssertEqual(editor.textView.font?.fontName, face.name)
        XCTAssertEqual(editor.textView.font?.pointSize, 21)
        AppSettings.resetFontSize()
        XCTAssertEqual(editor.textView.font?.fontName, face.name)
        XCTAssertEqual(editor.textView.font?.pointSize, size)

        // Tab stops follow the new face's width.
        let space = (" " as NSString).size(withAttributes: [.font: try XCTUnwrap(editor.textView.font)]).width
        let style = try XCTUnwrap(editor.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        let width = (style.defaultTabInterval / space).rounded()
        XCTAssertGreaterThanOrEqual(width, 1)
        XCTAssertEqual(style.defaultTabInterval, space * width, accuracy: 0.01)
        let stored = editor.textView.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(stored?.defaultTabInterval ?? 0, style.defaultTabInterval, accuracy: 0.01)
    }

    func testSystemChoiceRemovesKeyAndEditorFollows() throws {
        let face = try monoFace()
        let editor = editor("let x = 1\n", ext: "swift", language: .swift)
        AppSettings.fontName = face.name
        XCTAssertEqual(editor.textView.font?.fontName, face.name)

        AppSettings.fontName = nil
        XCTAssertNil(AppSettings.defaults.object(forKey: AppSettings.Key.fontName))
        let size = CGFloat(AppSettings.defaultFontSize(for: traits))
        XCTAssertTrue(isSystemMono(AppSettings.font(for: traits), size: size))
        XCTAssertTrue(isSystemMono(editor.textView.font, size: editor.textView.font?.pointSize ?? 0))

        // The picker's "SF Mono (System)" item stores "" (AppStorage); that reads as unset too.
        AppSettings.fontName = ""
        XCTAssertNil(AppSettings.defaults.object(forKey: AppSettings.Key.fontName))
        AppSettings.defaults.set("", forKey: AppSettings.Key.fontName)
        XCTAssertNil(AppSettings.fontName)
        XCTAssertTrue(isSystemMono(AppSettings.font(for: traits), size: size))
    }

    func testUnknownNameFallsBackWithoutClearingIt() {
        AppSettings.fontName = "NoSuchMono-Regular"
        let size = CGFloat(AppSettings.defaultFontSize(for: traits))
        XCTAssertTrue(isSystemMono(AppSettings.font(for: traits), size: size))
        XCTAssertEqual(AppSettings.defaults.string(forKey: AppSettings.Key.fontName), "NoSuchMono-Regular")
        XCTAssertEqual(AppSettings.fontName, "NoSuchMono-Regular")
    }

    func testPickerChoices() throws {
        let choices = AppSettings.editorFontChoices(current: nil)
        XCTAssertEqual(choices.first?.title, "SF Mono (System)")
        XCTAssertEqual(choices.first?.name, "")
        let rest = choices.dropFirst()
        XCTAssertFalse(rest.isEmpty)
        XCTAssertEqual(rest.map(\.title), rest.map(\.title).sorted())
        XCTAssertEqual(Set(rest.map(\.title)).count, rest.count, "one face per family")
        XCTAssertFalse(rest.contains { $0.title == "SF Mono" || $0.title.hasPrefix(".") || $0.name.hasPrefix(".") })
        for c in rest {
            let font = try XCTUnwrap(UIFont(name: c.name, size: 13), c.name)
            XCTAssertEqual(font.familyName, c.title)
            let t = font.fontDescriptor.symbolicTraits
            XCTAssertTrue(t.contains(.traitMonoSpace), c.name)
            XCTAssertFalse(t.contains(.traitBold) || t.contains(.traitItalic), c.name)
        }
        XCTAssertFalse(rest.contains { $0.title == "Helvetica" || $0.title == "Georgia" })

        let stray = AppSettings.editorFontChoices(current: "NoSuchMono-Regular")
        XCTAssertEqual(stray.last?.name, "NoSuchMono-Regular")
        XCTAssertEqual(stray.count, choices.count + 1)
        let listed = try XCTUnwrap(rest.first)
        XCTAssertEqual(AppSettings.editorFontChoices(current: listed.name).count, choices.count)
    }

    func testProseFontStillAppliesToProseButNotCode() throws {
        let face = try monoFace()
        AppSettings.useProseFont = true
        AppSettings.fontName = face.name
        XCTAssertEqual(AppSettings.font(for: .markdown, traits: traits), AppSettings.proseFont(for: traits))
        XCTAssertEqual(AppSettings.font(for: .plain, traits: traits), AppSettings.proseFont(for: traits))
        XCTAssertEqual(AppSettings.font(for: .swift, traits: traits).fontName, face.name)

        let markdown = editor("# Title\n", ext: "md", language: .markdown)
        let swift = editor("let x = 1\n", ext: "swift", language: .swift)
        XCTAssertEqual(markdown.textView.font, AppSettings.proseFont(for: markdown.traitCollection))
        XCTAssertEqual(swift.textView.font?.fontName, face.name)
    }
}
