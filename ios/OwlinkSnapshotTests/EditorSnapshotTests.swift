import XCTest
import UIKit
import CedricCore
import CedricAI

/// Drives the real editor (the app's own sources, compiled into this
/// hostless test bundle) in a window without SpringBoard: open a sample,
/// type, save and read the file back; Cedric's offline hint and its fix;
/// the Markdown preview; Settings. Renders PNGs of iPhone and iPad layouts
/// in light and dark into $OWLINK_SNAPSHOTS (or the temp folder).
///
/// Why not only XCUITest: on the build Mac the simulator's SpringBoard
/// never draws a home screen, so apps can't be launched there. These tests
/// need no SpringBoard; OwlinkUITests covers the same on a working
/// simulator or a device.
@MainActor
final class EditorSnapshotTests: XCTestCase {
    var windows: [UIWindow] = []

    override func setUp() async throws {
        for k in [AppSettings.Key.fontSize, AppSettings.Key.wrap, AppSettings.Key.owlHints, AppSettings.Key.theme] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
    }

    static var outDir: URL {
        let env = ProcessInfo.processInfo.environment["OWLINK_SNAPSHOTS"]
        let url = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("owlink-snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh copy of a bundled sample in a temp folder.
    func sample(_ name: String) throws -> URL {
        let b = Bundle(for: Self.self)
        let src = try XCTUnwrap(b.url(forResource: (name as NSString).deletingPathExtension,
                                      withExtension: (name as NSString).pathExtension, subdirectory: "Samples"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    func open(_ url: URL) async throws -> TextDocument {
        let doc = TextDocument(fileURL: url)
        let ok = await withCheckedContinuation { c in doc.open { c.resume(returning: $0) } }
        XCTAssertTrue(ok, "couldn't open \(url.lastPathComponent)")
        return doc
    }

    func show(_ doc: TextDocument, size: CGSize, dark: Bool, regular: Bool = false, readMode: Bool = false) -> (UIWindow, EditorViewController) {
        let editor = EditorViewController(document: doc, readModeOnOpen: readMode)
        let nav = UINavigationController(rootViewController: editor)
        let w = UIWindow(frame: CGRect(origin: .zero, size: size))
        w.overrideUserInterfaceStyle = dark ? .dark : .light
        w.rootViewController = nav
        if regular {
            nav.traitOverrides.horizontalSizeClass = .regular
            nav.traitOverrides.verticalSizeClass = .regular
            nav.traitOverrides.userInterfaceIdiom = .pad
        }
        w.makeKeyAndVisible()
        w.layoutIfNeeded()
        windows.append(w)
        return (w, editor)
    }

    func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    func snapshot(_ w: UIWindow, _ name: String) throws -> URL {
        w.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { ctx in
            if !w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) { w.layer.render(in: ctx.cgContext) }
        }
        let url = Self.outDir.appendingPathComponent(name + ".png")
        try XCTUnwrap(img.pngData()).write(to: url)
        add(XCTAttachment(image: img))
        return url
    }

    static let iPhone = CGSize(width: 402, height: 874)
    static let iPad = CGSize(width: 1032, height: 1376)

    // MARK: Behaviour

    func testRailOwlIsAboveNavigationSiblingsForHitTesting() async throws {
        let doc = try await open(try sample("sample.swift"))
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        let nav = try XCTUnwrap(editor.navigationController)
        let cover = UIView(frame: nav.view.bounds)
        nav.view.addSubview(cover)
        let frame = CGRect(x: 300, y: 400, width: OwlSprite.size, height: OwlSprite.size)
        editor.owlSprite.isHidden = false
        editor.setOwlFrame(frame, inRail: true)
        let point = editor.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nav.view)
        XCTAssertTrue(nav.view.hitTest(point, with: nil)?.isDescendant(of: editor.owlSprite) == true)
        editor.willMove(toParent: nil)
        XCTAssertTrue(editor.owlSprite.superview === editor.view)
        cover.removeFromSuperview()
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testLineNumbersFollowSettingAndEditorInsets() async throws {
        let previous = AppSettings.defaults.object(forKey: AppSettings.Key.lineNumbers)
        defer {
            if let previous { AppSettings.defaults.set(previous, forKey: AppSettings.Key.lineNumbers) }
            else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.lineNumbers) }
            AppSettings.post()
        }
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.lineNumbers)
        let doc = try await open(try sample("sample.swift"))
        let (window, editor) = show(doc, size: Self.iPhone, dark: false)
        func gutter(in view: UIView) -> LineNumberGutter? {
            if let g = view as? LineNumberGutter { return g }
            return view.subviews.lazy.compactMap { gutter(in: $0) }.first
        }
        let numbers = try XCTUnwrap(gutter(in: editor.view))
        window.layoutIfNeeded()
        XCTAssertFalse(numbers.isHidden)
        let withNumbers = editor.textView.textContainerInset.left
        XCTAssertFalse(numbers.rows.isEmpty)
        XCTAssertGreaterThan(LineNumberGutter.width(lineCount: 10_000, font: numbers.font),
                             LineNumberGutter.width(lineCount: 999, font: numbers.font))
        AppSettings.lineNumbers = false
        window.layoutIfNeeded()
        XCTAssertTrue(numbers.isHidden)
        XCTAssertLessThan(editor.textView.textContainerInset.left, withNumbers)
        AppSettings.lineNumbers = true
        window.layoutIfNeeded()
        XCTAssertFalse(numbers.isHidden)
        XCTAssertEqual(editor.textView.textContainerInset.left, withNumbers, accuracy: 0.5)
        AppSettings.lineNumbers = false
        editor.revealLine(2)
        XCTAssertFalse(numbers.isHidden)
        XCTAssertEqual(numbers.highlight, 2)
        AppSettings.post()
        window.layoutIfNeeded()
        XCTAssertFalse(numbers.isHidden, "unrelated settings must not clear the jump override")
        AppSettings.lineNumbers = true
        AppSettings.lineNumbers = false
        window.layoutIfNeeded()
        XCTAssertTrue(numbers.isHidden)
        AppSettings.lineNumbers = true
        window.layoutIfNeeded()
        XCTAssertNil(numbers.highlight)
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testLineNumbersScrollAndWrap() async throws {
        let previous = AppSettings.defaults.object(forKey: AppSettings.Key.lineNumbers)
        defer {
            if let previous { AppSettings.defaults.set(previous, forKey: AppSettings.Key.lineNumbers) }
            else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.lineNumbers) }
            AppSettings.post()
        }
        AppSettings.lineNumbers = true
        let doc = try await open(try sample("sample.swift"))
        let longLine = String(repeating: "wrapped words ", count: 10)
        doc.text = Array(repeating: longLine, count: 2000).joined(separator: "\n")
        let (window, editor) = show(doc, size: Self.iPhone, dark: false)
        func gutter(in view: UIView) -> LineNumberGutter? {
            if let g = view as? LineNumberGutter { return g }
            return view.subviews.lazy.compactMap { gutter(in: $0) }.first
        }
        let numbers = try XCTUnwrap(gutter(in: editor.view))
        let textView = editor.textView
        let index = editor.lineIndex
        editor.revealLine(1500)
        window.layoutIfNeeded()
        await spin(0.1)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(textView.contentOffset.y, 1000)
        XCTAssertGreaterThan(numbers.rows.count, 1)
        for row in numbers.rows {
            XCTAssertGreaterThanOrEqual(row.midY, 0)
            XCTAssertLessThanOrEqual(row.midY, numbers.bounds.height)
            let position = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: index.starts[row.line - 1]))
            XCTAssertEqual(row.midY, textView.caretRect(for: position).midY - textView.bounds.minY, accuracy: 1)
        }
        for (first, next) in zip(numbers.rows, numbers.rows.dropFirst()) {
            XCTAssertEqual(next.line, first.line + 1)
            XCTAssertGreaterThan(next.midY, first.midY)
        }
        let first = try XCTUnwrap(numbers.rows.first)
        let nextStart = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: index.starts[first.line]))
        XCTAssertGreaterThan(textView.caretRect(for: nextStart).midY - textView.bounds.minY - first.midY,
                             textView.font?.lineHeight ?? 0, "the logical line must wrap")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testWrapToggleAndFixedGutter() async throws {
        let previousWrap = AppSettings.defaults.object(forKey: AppSettings.Key.wrap)
        let previousNumbers = AppSettings.defaults.object(forKey: AppSettings.Key.lineNumbers)
        defer {
            if let previousWrap { AppSettings.defaults.set(previousWrap, forKey: AppSettings.Key.wrap) }
            else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.wrap) }
            if let previousNumbers { AppSettings.defaults.set(previousNumbers, forKey: AppSettings.Key.lineNumbers) }
            else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.lineNumbers) }
            AppSettings.post()
        }
        AppSettings.wrap = true
        AppSettings.lineNumbers = true
        let doc = try await open(try sample("sample.swift"))
        let longLine = String(repeating: "wide words ", count: 400)
        doc.text = longLine + "\nsecond line\nthird line"
        let (window, editor) = show(doc, size: Self.iPhone, dark: false)
        let textView = editor.textView
        func gutter(in view: UIView) -> LineNumberGutter? {
            if let g = view as? LineNumberGutter { return g }
            return view.subviews.lazy.compactMap { gutter(in: $0) }.first
        }
        let numbers = try XCTUnwrap(gutter(in: editor.view))
        let second = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: (longLine as NSString).length + 1))
        window.layoutIfNeeded()
        let wrappedY = textView.caretRect(for: second).midY
        try snapshot(window, "wordwrap-on-iphone")

        AppSettings.wrap = false
        window.layoutIfNeeded()
        await spin(0.1)
        window.layoutIfNeeded()
        let far = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: 3300))
        let farRect = textView.caretRect(for: far)
        XCTAssertGreaterThan(textView.textContainer.size.width, textView.bounds.width * 2)
        XCTAssertGreaterThan(farRect.minX, textView.bounds.width * 2)
        XCTAssertGreaterThan(textView.contentSize.width, textView.bounds.width)
        XCTAssertGreaterThanOrEqual(textView.contentSize.width, farRect.maxX)
        XCTAssertTrue(textView.showsHorizontalScrollIndicator)
        try snapshot(window, "wordwrap-off-iphone")
        let unwrappedY = textView.caretRect(for: second).midY
        XCTAssertGreaterThan(wrappedY - unwrappedY, textView.font?.lineHeight ?? 0)
        let gutterX = numbers.frame.minX
        textView.setContentOffset(CGPoint(x: min(500, textView.contentSize.width - textView.bounds.width), y: 0), animated: false)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(textView.contentOffset.x, 0)
        XCTAssertEqual(numbers.frame.minX, gutterX, accuracy: 0.5)
        XCTAssertEqual(numbers.rows.map(\.line), [1, 2, 3])
        try snapshot(window, "wordwrap-off-iphone-scrolled")
        for row in numbers.rows {
            let position = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: editor.lineIndex.starts[row.line - 1]))
            XCTAssertEqual(row.midY, textView.caretRect(for: position).midY - textView.bounds.minY, accuracy: 1)
        }

        AppSettings.wrap = true
        window.layoutIfNeeded()
        await spin(0.1)
        window.layoutIfNeeded()
        XCTAssertTrue(textView.textContainer.widthTracksTextView)
        XCTAssertLessThanOrEqual(textView.textContainer.size.width, textView.bounds.width)
        XCTAssertLessThanOrEqual(textView.contentSize.width, textView.bounds.width + 1)
        XCTAssertLessThanOrEqual(abs(textView.contentOffset.x + textView.adjustedContentInset.left), 1)
        XCTAssertGreaterThan(textView.caretRect(for: second).midY - unwrappedY, textView.font?.lineHeight ?? 0)
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testUnwrappedRevealColumnAndGoToLineInBothModes() async throws {
        let previousWrap = AppSettings.defaults.object(forKey: AppSettings.Key.wrap)
        let previousNumbers = AppSettings.defaults.object(forKey: AppSettings.Key.lineNumbers)
        defer {
            if let previousWrap { AppSettings.defaults.set(previousWrap, forKey: AppSettings.Key.wrap) }
            else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.wrap) }
            if let previousNumbers { AppSettings.defaults.set(previousNumbers, forKey: AppSettings.Key.lineNumbers) }
            else { AppSettings.defaults.removeObject(forKey: AppSettings.Key.lineNumbers) }
            AppSettings.post()
        }
        AppSettings.wrap = false
        AppSettings.lineNumbers = true
        for readMode in [false, true] {
            let doc = try await open(try sample("sample.swift"))
            let longLine = String(repeating: "wide words ", count: 100)
            doc.text = longLine + "\nsecond line"
            let (window, editor) = show(doc, size: Self.iPhone, dark: false, readMode: readMode)
            let textView = editor.textView
            XCTAssertEqual(textView.isEditable, !readMode)
            window.layoutIfNeeded()
            func gutter(in view: UIView) -> LineNumberGutter? {
                if let g = view as? LineNumberGutter { return g }
                return view.subviews.lazy.compactMap { gutter(in: $0) }.first
            }
            let numbers = try XCTUnwrap(gutter(in: editor.view))
            let column = 800
            editor.revealRange(NSRange(location: column, length: 4))
            window.layoutIfNeeded()
            let position = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: column))
            let caret = textView.caretRect(for: position)
            XCTAssertGreaterThan(textView.contentOffset.x, 0)
            XCTAssertGreaterThanOrEqual(caret.minX, textView.bounds.minX + numbers.bounds.width - 0.5)
            XCTAssertLessThanOrEqual(caret.maxX, textView.bounds.maxX)
            editor.revealLine(2)
            window.layoutIfNeeded()
            let lineStart = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: (longLine as NSString).length + 1))
            let lineCaret = textView.caretRect(for: lineStart)
            XCTAssertGreaterThanOrEqual(lineCaret.minX, textView.bounds.minX)
            XCTAssertLessThanOrEqual(lineCaret.maxX, textView.bounds.maxX)
            XCTAssertGreaterThanOrEqual(lineCaret.midY, textView.bounds.minY)
            XCTAssertLessThanOrEqual(lineCaret.midY, textView.bounds.maxY)
            await withCheckedContinuation { c in doc.close { _ in c.resume() } }
        }
    }

    func testOpenTypeSaveReadBack() async throws {
        let url = try sample("sample.swift")
        let doc = try await open(url)
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        XCTAssertEqual(doc.language.language, .swift)
        XCTAssertEqual(doc.encoding, .utf8)
        XCTAssertTrue(editor.textView.text.contains("struct Owl"))
        editor.textView.selectedRange = NSRange(location: (editor.textView.text as NSString).length, length: 0)
        editor.textView.insertText("// typed in the test\n")
        XCTAssertTrue(doc.hasUnsavedChanges)
        let saved = await withCheckedContinuation { c in
            doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        let back = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(back.hasSuffix("// typed in the test\n"), "file on disk: \(back.suffix(60))")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    /// The hide-keyboard button shows only while editing and resigns.
    func testHideKeyboardButton() async throws {
        let doc = try await open(try sample("sample.swift"))
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        XCTAssertTrue(editor.hideKeyboardButton.isHidden, "shown without the keyboard")
        XCTAssertEqual(editor.hideKeyboardButton.accessibilityLabel, "Hide Keyboard")
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        XCTAssertFalse(editor.hideKeyboardButton.isHidden, "not shown while editing")
        editor.hideKeyboardButton.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(editor.textView.isFirstResponder, "didn't resign")
        XCTAssertTrue(editor.hideKeyboardButton.isHidden)
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testKeepsCRLFAndLatin1OnSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("legacy.txt")
        try XCTUnwrap("caf\u{e9}\r\nna\u{ef}ve\r\n".data(using: .isoLatin1)).write(to: url)
        let doc = try await open(url)
        let (_, editor) = show(doc, size: Self.iPhone, dark: false)
        XCTAssertEqual(doc.lineEnding, .crlf)
        XCTAssertEqual(editor.textView.text, "café\nnaïve\n")
        editor.textView.insertText("x")
        let saved = await withCheckedContinuation { c in doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) } }
        XCTAssertTrue(saved)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.contains(0xE9), "not Latin-1/Windows-1252 any more")
        XCTAssertNotNil(String(data: data, encoding: .isoLatin1)?.range(of: "\r\n"), "CRLF lost")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testOwlHintAndFixIt() async throws {
        let doc = try await open(try sample("sample.swift"))
        let (w, editor) = show(doc, size: Self.iPhone, dark: false)
        for _ in 0..<30 where editor.owl.visible == nil { await spin(0.2) }
        let shown = try XCTUnwrap(editor.owl.visible, "no hint")
        XCTAssertTrue(shown.hint.title.contains("spaces"), shown.hint.title)
        XCTAssertFalse(editor.owlSprite.isHidden)
        editor.openHint()
        XCTAssertFalse(editor.hintBar.isHidden)
        try snapshot(w, "test-owl-hint")
        editor.applyFix()
        XCTAssertFalse(editor.textView.text.contains("struct Owl {   "))
        XCTAssertTrue(editor.textView.undoManager?.canUndo ?? false, "the fix should be undoable")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testMarkdownPreviewTurnsOn() async throws {
        let doc = try await open(try sample("README.md"))
        let (_, editor) = show(doc, size: Self.iPad, dark: false, regular: true)
        XCTAssertEqual(doc.language.language, .markdown)
        editor.togglePreview()
        XCTAssertTrue(editor.previewOn)
        XCTAssertNotNil(editor.preview)
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
    }

    func testBuiltInSaysNeedsDeviceInSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(BuiltInEngine().unavailableReason, BuiltInPlatform.unavailableReason)
        XCTAssertEqual(BuiltInPlatform.unavailableReason, "Built-in model: needs a real device.")
        #endif
        // iPhone offers only the small model.
        let phone = ModelCatalog.bundled()?.offered(on: .iPhone) ?? []
        XCTAssertFalse(phone.isEmpty)
        XCTAssertTrue(phone.allSatisfy { $0.parametersB <= 2 })
    }

    // MARK: Screenshots

    func testScreenshots() async throws {
        for (device, size, regular) in [("iphone", Self.iPhone, false), ("ipad", Self.iPad, true)] {
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                let swift = try await open(try sample("sample.swift"))
                let (w1, e1) = show(swift, size: size, dark: dark, regular: regular)
                for _ in 0..<30 where e1.owl.visible == nil { await spin(0.2) }
                await spin(0.3)
                try snapshot(w1, "\(device)-\(mode)-swift")
                await withCheckedContinuation { c in swift.close { _ in c.resume() } }
                w1.isHidden = true

                let md = try await open(try sample("README.md"))
                let (w2, e2) = show(md, size: size, dark: dark, regular: regular)
                e2.togglePreview()
                await spin(2.5)   // WebKit renders out of process
                try snapshot(w2, "\(device)-\(mode)-markdown-preview")
                await withCheckedContinuation { c in md.close { _ in c.resume() } }
                w2.isHidden = true
            }
        }
        // Dracula, and Settings.
        AppSettings.theme = .dracula
        let doc = try await open(try sample("sample.swift"))
        let (w, _) = show(doc, size: Self.iPhone, dark: true)
        await spin(1.2)
        try snapshot(w, "iphone-dracula-swift")
        let settings = UIWindow(frame: CGRect(origin: .zero, size: Self.iPhone))
        settings.rootViewController = UIHostingSettings.make()
        settings.isHidden = false
        windows.append(settings)
        await spin(0.8)
        try snapshot(settings, "iphone-settings")
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
        AppSettings.theme = .system
        print("Snapshots in \(Self.outDir.path)")
    }
}
