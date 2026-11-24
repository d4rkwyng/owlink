import XCTest
import WebKit
import CedricCore

/// The Markdown preview's YAML front matter (0.5.2 (17)): one collapsed
/// line, "Front matter · <title>", that opens without page JavaScript (a
/// `<details>` block); the reader's choice is kept as a preference, read
/// from the app's own content world, never through a bridge in the page.
@MainActor
final class FrontMatterPreviewTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var saved: Any?

    override func setUp() async throws {
        saved = AppSettings.defaults.object(forKey: AppSettings.Key.previewFrontMatterExpanded)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.previewFrontMatterExpanded)
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        AppSettings.defaults.set(saved, forKey: AppSettings.Key.previewFrontMatterExpanded)
    }

    static let doc = """
    ---
    title: Owls of the World
    hero:
      icon: owl.png
      alt: A barn owl
      links:
        - text: Home
          url: /
    tags: [birds, night]
    ---
    # Owls of the World

    Owls hunt at night.
    """

    private func preview(_ text: String = doc) -> PreviewController {
        let preview = PreviewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = preview
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        preview.show(markdown: text, palette: EditorPalettes.light)
        return preview
    }

    /// Runs in the app's content world (page script is off).
    private func js(_ preview: PreviewController, _ script: String) async throws -> Any? {
        try await preview.web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private struct Block: Equatable { var open: Bool; var summary: String; var height: Double; var tableShown: Bool }

    private func block(_ preview: PreviewController, open: Bool? = nil) async throws -> Block {
        let script = """
        const d = document.querySelector('details.frontmatter');
        if (!d || !document.querySelector('h1')) return null;
        const t = d.querySelector('table');
        return { open: d.open, summary: d.querySelector('summary').textContent,
                 height: d.getBoundingClientRect().height, table: !!t && t.getBoundingClientRect().height > 0 && (t.checkVisibility ? t.checkVisibility() : true) };
        """
        for _ in 0..<200 {
            if let d = try await js(preview, script) as? [String: Any], let o = d["open"] as? Bool,
               open == nil || o == open {
                return Block(open: o, summary: d["summary"] as? String ?? "",
                             height: (d["height"] as? NSNumber)?.doubleValue ?? 0, tableShown: d["table"] as? Bool ?? false)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("no front matter block in the page")
        return Block(open: false, summary: "", height: 0, tableShown: false)
    }

    private func snapshot(_ preview: PreviewController, _ name: String) async throws {
        let image = try await preview.web.takeSnapshot(configuration: nil)
        let a = XCTAttachment(image: image)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testCollapsedByDefaultAsOneLine() async throws {
        let p = preview()
        let b = try await block(p)
        XCTAssertFalse(b.open)
        XCTAssertEqual(b.summary, "Front matter · Owls of the World")
        XCTAssertFalse(b.tableShown, "the values show while collapsed")
        XCTAssertLessThan(b.height, 40, "more than one line collapsed")
        try await snapshot(p, "front-matter-collapsed")
        // Page script stays off; no user scripts, no handlers.
        let config = p.web.configuration
        XCTAssertFalse(config.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(config.userContentController.userScripts.isEmpty)
        XCTAssertTrue(PreviewController.csp.contains("script-src 'none'"))
        XCTAssertFalse(PreviewController.frontMatterStateScript.contains("messageHandlers"))
    }

    /// A tap opens it (the `open` the page itself toggles); the next
    /// render keeps it open and so does the next preview, from the
    /// preference. Closing it again is kept too.
    func testTheReadersChoiceIsKept() async throws {
        let p = preview()
        _ = try await block(p, open: false)
        _ = try await js(p, "document.querySelector('details.frontmatter').open = true; return true;")
        // An edit re-renders the page.
        p.show(markdown: Self.doc + "\nMore.\n", palette: EditorPalettes.light)
        let reopened = try await block(p, open: true)
        XCTAssertTrue(reopened.tableShown)
        XCTAssertTrue(AppSettings.previewFrontMatterExpanded)
        XCTAssertGreaterThan(reopened.height, 60)
        try await snapshot(p, "front-matter-expanded")
        let next = preview()
        _ = try await block(next, open: true)
        _ = try await js(next, "document.querySelector('details.frontmatter').open = false; return true;")
        next.show(markdown: Self.doc, palette: EditorPalettes.light)
        _ = try await block(next, open: false)
        XCTAssertFalse(AppSettings.previewFrontMatterExpanded)
    }

    /// The summary is a native disclosure: VoiceOver reads it as a button
    /// that is collapsed or expanded (WebKit's own `<summary>` semantics),
    /// its name the summary line with the title.
    func testSummaryIsANativeDisclosure() async throws {
        let p = preview()
        _ = try await block(p)
        let html = Markdown.render(Self.doc, options: .preview(vault: nil))
        XCTAssertTrue(html.contains("<details class=\"frontmatter\" data-line=\"0\">\n<summary>Front matter · Owls of the World</summary>"))
        XCTAssertFalse(html.contains("role="), "no ARIA overriding the native semantics")
    }
}
