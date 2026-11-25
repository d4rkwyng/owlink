import XCTest
import UIKit
import WebKit
import CedricCore

/// The ••• menu, the Markdown format bar (Ask Cedric open and closed) and
/// the preview's front-matter block at compact and regular width, each at
/// extra small, the default (large), XXXL and accessibility XXXL Dynamic
/// Type: the same checks as at the default size, plus a snapshot of each
/// (attachments, and PNGs in EditorSnapshotTests.outDir named
/// `traits-<what>-<width>-<size>.png`). Traits are set with
/// `traitOverrides`, as OverflowMenuTests, AskFormatBarTests and
/// EditorSnapshotTests do. These add to the UI tests; they don't replace them.
@MainActor
final class SizeClassDynamicTypeSnapshotTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var savedFrontMatter: Any?

    struct Config: CustomStringConvertible {
        let width: UIUserInterfaceSizeClass
        let size: UIContentSizeCategory
        var widthName: String { width == .compact ? "compact" : "regular" }
        var sizeName: String {
            switch size {
            case .extraSmall: return "xs"
            case .large: return "default"
            case .extraExtraExtraLarge: return "xxxl"
            case .accessibilityExtraExtraExtraLarge: return "ax-xxxl"
            default: return size.rawValue
            }
        }
        var windowSize: CGSize { width == .compact ? CGSize(width: 402, height: 874) : CGSize(width: 1032, height: 1376) }
        var description: String { "\(widthName) width, \(sizeName)" }
    }

    static let sizes: [UIContentSizeCategory] = [.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
    static let configs: [Config] = [UIUserInterfaceSizeClass.compact, .regular].flatMap { w in sizes.map { Config(width: w, size: $0) } }

    override func setUp() async throws {
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.showContextBar)
        savedFrontMatter = AppSettings.defaults.object(forKey: AppSettings.Key.previewFrontMatterExpanded)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.previewFrontMatterExpanded)
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.showContextBar)
        AppSettings.defaults.set(savedFrontMatter, forKey: AppSettings.Key.previewFrontMatterExpanded)
    }

    // MARK: Helpers

    private func window(_ root: UIViewController, _ config: Config) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: config.windowSize))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return window
    }

    private func markdownEditor(_ config: Config) -> (UIWindow, EditorViewController) {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "# Owls\n\nHoot **hoot**.\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = config.width
        nav.traitOverrides.preferredContentSizeCategory = config.size
        if config.width == .regular {
            nav.traitOverrides.verticalSizeClass = .regular
            nav.traitOverrides.userInterfaceIdiom = .pad
        }
        return (window(nav, config), editor)
    }

    private func save(_ image: UIImage, _ name: String) throws {
        try XCTUnwrap(image.pngData()).write(to: EditorSnapshotTests.outDir.appendingPathComponent(name + ".png"))
        let a = XCTAttachment(image: image)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func render(_ view: UIView) -> UIImage {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { ctx in
            if view.window == nil || !view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) {
                view.layer.render(in: ctx.cgContext)
            }
        }
    }

    /// Every command in a menu, with the submenu titles above it (as
    /// OverflowMenuTests flattens it).
    private func flatten(_ element: UIMenuElement, path: [String] = []) -> [(title: String, path: [String])] {
        switch element {
        case let menu as UIMenu:
            let inner = menu.options.contains(.displayInline) || menu.title.isEmpty ? path : path + [menu.title]
            return menu.children.flatMap { flatten($0, path: inner) }
        case let action as UIAction:
            return action.attributes.contains(.hidden) ? [] : [(action.title, path)]
        case let command as UICommand:
            return command.attributes.contains(.hidden) ? [] : [(command.title, path)]
        default:
            return []
        }
    }

    /// How many distinct colors a sample of the image's pixels has (2+:
    /// something is drawn on the background).
    private func colors(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = 64, h = 64
        var pixels = [UInt32](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Set(pixels).count : 0
    }

    /// The top of the page as WebKit draws it (its PDF), as an image.
    private func pagePicture(_ preview: PreviewController) async throws -> UIImage {
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: preview.web.bounds.size)
        let data = try await preview.web.pdf(configuration: config)
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!), "no PDF of the preview")
        let page = try XCTUnwrap(pdf.page(at: 1), "an empty PDF of the preview")
        let box = page.getBoxRect(.mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: box.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: box.size))
            ctx.cgContext.translateBy(x: 0, y: box.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.drawPDFPage(page)
        }
    }

    // MARK: (a) The ••• menu

    /// At every width and text size: the editor has its ••• overflow
    /// items; no command is listed twice; Focus Preview is listed once, in
    /// the Preview submenu; every item has a title.
    func testOverflowMenuAtEverySizeClassAndTextSize() throws {
        for config in Self.configs {
            try XCTContext.runActivity(named: "••• menu, \(config)") { _ in
                let (window, editor) = markdownEditor(config)
                XCTAssertEqual(editor.traitCollection.preferredContentSizeCategory, config.size, "\(config): the text size didn't reach the editor")
                XCTAssertEqual(editor.traitCollection.horizontalSizeClass, config.width, "\(config): the width didn't reach the editor")
                XCTAssertNotNil(editor.navigationItem.additionalOverflowItems, "\(config): no ••• menu items")
                let menu = UIMenu(children: editor.moreMenuItems())
                let items = flatten(menu)
                XCTAssertFalse(items.isEmpty, "\(config): an empty ••• menu")
                XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty }, "\(config): an item without a title")
                let dupes = Dictionary(grouping: items.map(\.title), by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                XCTAssertEqual(dupes, [], "\(config): listed more than once")
                let focus = items.filter { $0.title == "Focus Preview" }
                XCTAssertEqual(focus.count, 1, "\(config): Focus Preview \(focus.count) times")
                XCTAssertEqual(focus.first?.path, ["Preview"], "\(config): Focus Preview not in the Preview submenu")
                try save(render(window), "traits-menu-\(config.widthName)-\(config.sizeName)")
            }
        }
    }

    // MARK: (b) The format bar, Ask Cedric closed and open

    /// At every width and text size: the format bar is the text's input
    /// accessory, 44 pt high with 44-pt buttons (the large content viewer
    /// stands in for bigger text), every button named; under Ask Cedric
    /// it is off the keyboard, and the same bar is back after Done.
    func testFormatBarWithAskCedricClosedAndOpenAtEverySizeClassAndTextSize() throws {
        for config in Self.configs {
            try XCTContext.runActivity(named: "format bar, \(config)") { _ in
                let (window, editor) = markdownEditor(config)
                let bar = try XCTUnwrap(editor.contextBar, "\(config): no format bar for Markdown")
                editor.textView.becomeFirstResponder()
                XCTAssertTrue(editor.textView.inputAccessoryView === bar, "\(config): the format bar isn't on the keyboard")
                bar.traitOverrides.preferredContentSizeCategory = config.size
                bar.frame = CGRect(x: 0, y: 0, width: config.windowSize.width, height: 44)
                bar.layoutIfNeeded()
                XCTAssertEqual(bar.bounds.height, 44, "\(config): the bar's height")
                XCTAssertFalse(bar.buttons.isEmpty, "\(config): no buttons")
                for (id, button) in bar.buttons {
                    XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44), "\(config): \(id) isn't 44 × 44")
                    XCTAssertFalse((button.accessibilityLabel ?? "").isEmpty, "\(config): \(id) has no name")
                    XCTAssertTrue(button.showsLargeContentViewer, "\(config): \(id) has no large content viewer")
                }
                XCTAssertTrue(bar.interactions.contains { $0 is UILargeContentViewerInteraction }, "\(config): no large content viewer on the bar")
                try save(render(bar), "traits-formatbar-ask-closed-\(config.widthName)-\(config.sizeName)")

                editor.askCedric()
                XCTAssertTrue(editor.askIsOpen, "\(config): Ask Cedric didn't open")
                guard let sheet = editor.presentedViewController else {
                    // An iPad at regular width docks Ask Cedric beside the
                    // text: the text stays in use, and so does its bar.
                    XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .pad, "\(config): no Ask Cedric sheet on a phone")
                    XCTAssertEqual(config.width, .regular, "\(config): docked at compact width")
                    XCTAssertTrue(editor.textView.inputAccessoryView === bar, "\(config): the format bar left with Ask Cedric docked")
                    try save(render(window), "traits-formatbar-ask-open-\(config.widthName)-\(config.sizeName)")
                    editor.closeAskPanel()
                    XCTAssertFalse(editor.askIsOpen, "\(config): Ask Cedric's panel didn't close")
                    XCTAssertTrue(editor.textView.inputAccessoryView === bar, "\(config): the format bar didn't stay after the panel closed")
                    return
                }
                XCTAssertNil(editor.textView.inputAccessoryView, "\(config): the format bar is on the keyboard under Ask Cedric")
                try save(render(window), "traits-formatbar-ask-open-\(config.widthName)-\(config.sizeName)")

                // Done: the sheet dismisses itself (the appearance callbacks
                // by hand, as AskFormatBarTests: no app host here).
                sheet.dismiss(animated: false)
                sheet.beginAppearanceTransition(false, animated: false)
                sheet.endAppearanceTransition()
                XCTAssertTrue(editor.textView.inputAccessoryView === bar, "\(config): the format bar didn't come back after Ask Cedric")
            }
        }
    }

    // MARK: (c) The front-matter block

    static let frontMatterDoc = """
    ---
    title: Owls of the World
    hero:
      icon: owl.png
      alt: A barn owl
    tags: [birds, night]
    ---
    # Owls of the World

    Owls hunt at night.
    """

    private struct Block { var open: Bool; var summary: String; var height: Double; var tableShown: Bool; var summaryLines: Double }

    private func block(_ preview: PreviewController) async throws -> Block? {
        let script = """
        const d = document.querySelector('details.frontmatter');
        if (!d || !document.querySelector('h1')) return null;
        const s = d.querySelector('summary');
        const t = d.querySelector('table');
        // Lines of the summary's text: its text boxes grouped by their top
        // (boxes on one line share a top within half a box's height).
        const r = document.createRange(); r.selectNodeContents(s);
        const boxes = [...r.getClientRects()].filter(b => b.width > 0).sort((a, b) => a.top - b.top);
        let lines = 0, lastTop = -1e9;
        for (const b of boxes) { if (b.top - lastTop > b.height / 2) { lines += 1; lastTop = b.top; } }
        return { open: d.open, summary: s.textContent, height: d.getBoundingClientRect().height,
                 lines: lines,
                 table: !!t && t.getBoundingClientRect().height > 0 && (t.checkVisibility ? t.checkVisibility() : true) };
        """
        for _ in 0..<200 {
            if let d = try await preview.web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any],
               let open = d["open"] as? Bool {
                return Block(open: open, summary: d["summary"] as? String ?? "",
                             height: (d["height"] as? NSNumber)?.doubleValue ?? 0,
                             tableShown: d["table"] as? Bool ?? false,
                             summaryLines: (d["lines"] as? NSNumber)?.doubleValue ?? 0)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// At every width and text size: one collapsed "Front matter · <title>"
    /// line, the values hidden; the page zoom follows Dynamic Type (never
    /// smaller at a bigger size).
    func testFrontMatterBlockAtEverySizeClassAndTextSize() async throws {
        for width in [UIUserInterfaceSizeClass.compact, .regular] {
            var zooms: [Double] = []
            for size in Self.sizes {
                let config = Config(width: width, size: size)
                let preview = PreviewController()
                preview.traitOverrides.horizontalSizeClass = config.width
                preview.traitOverrides.preferredContentSizeCategory = config.size
                _ = window(preview, Config(width: width, size: size))
                preview.show(markdown: Self.frontMatterDoc, palette: EditorPalettes.light)
                let b = try await block(preview)
                let found = try XCTUnwrap(b, "\(config): no front matter block in the page")
                XCTAssertFalse(found.open, "\(config): open by default")
                XCTAssertEqual(found.summary, "Front matter · Owls of the World", config.description)
                XCTAssertFalse(found.tableShown, "\(config): the values show while collapsed")
                XCTAssertEqual(found.summaryLines, 1, "\(config): the collapsed summary isn't one line")
                zooms.append(preview.pageZoom)
                // This bundle has no app host, so WebKit never composites the
                // web view on screen (takeSnapshot is blank). Its PDF of the
                // page's top is drawn by WebKit itself, at the same zoom.
                let image = try await pagePicture(preview)
                XCTAssertGreaterThan(colors(image), 1, "\(config): a blank preview picture")
                try save(image, "traits-frontmatter-\(config.widthName)-\(config.sizeName)")
            }
            XCTAssertEqual(zooms, zooms.sorted(), "\(width == .compact ? "compact" : "regular"): the preview's zoom shrank as the text grew: \(zooms)")
            XCTAssertGreaterThan(zooms.last ?? 0, zooms.first ?? 0, "the preview's zoom doesn't follow Dynamic Type: \(zooms)")
        }
    }
}
