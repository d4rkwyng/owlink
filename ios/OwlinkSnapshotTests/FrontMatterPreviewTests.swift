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

    private func record(_ preview: PreviewController) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            preview.recordFrontMatterState { done.resume() }
        }
    }

    /// Codex review of 0.5.2 (17), must-fix 2: two previews rendered
    /// collapsed; the reader expands the first and it goes; then the
    /// second, untouched, goes. "Expanded" stays: only a change from the
    /// state a page was rendered with is the reader's.
    func testAnUntouchedPreviewKeepsTheReadersChoice() async throws {
        let first = preview()
        let second = preview()
        _ = try await block(first, open: false)
        _ = try await block(second, open: false)
        _ = try await js(first, "document.querySelector('details.frontmatter').open = true; return true;")
        await record(first)
        XCTAssertTrue(AppSettings.previewFrontMatterExpanded)
        await record(second)
        XCTAssertTrue(AppSettings.previewFrontMatterExpanded, "the untouched preview wrote collapsed over the reader's choice")
        // Read twice, kept once: the first preview's page now stands for
        // expanded, so the reader closing it is a change again.
        await record(first)
        XCTAssertTrue(AppSettings.previewFrontMatterExpanded)
        _ = try await js(first, "document.querySelector('details.frontmatter').open = false; return true;")
        await record(first)
        XCTAssertFalse(AppSettings.previewFrontMatterExpanded)
    }

    /// A read counts only for the page it was made on, and only as a
    /// change from what that page was rendered with.
    func testWhatAReadKeeps() {
        XCTAssertEqual(PreviewController.frontMatterChange(read: true, renderedOpen: false, readFor: 3, shown: 3), true)
        XCTAssertEqual(PreviewController.frontMatterChange(read: false, renderedOpen: true, readFor: 3, shown: 3), false)
        XCTAssertNil(PreviewController.frontMatterChange(read: false, renderedOpen: false, readFor: 3, shown: 3), "untouched")
        XCTAssertNil(PreviewController.frontMatterChange(read: true, renderedOpen: true, readFor: 3, shown: 3), "untouched")
        XCTAssertNil(PreviewController.frontMatterChange(read: true, renderedOpen: false, readFor: 3, shown: 4), "the page was replaced")
        XCTAssertNil(PreviewController.frontMatterChange(read: true, renderedOpen: false, readFor: 3, shown: nil), "no page any more")
        XCTAssertNil(PreviewController.frontMatterChange(read: nil, renderedOpen: false, readFor: 3, shown: 3), "no block")
    }

    /// Codex review of 0.5.2 (17), should-fix 2: a long title in a narrow
    /// preview at a large text size: one line, cut with an ellipsis, the
    /// whole title still the summary's text.
    func testALongTitleIsOneLine() async throws {
        let title = String(repeating: "Owls of the World ", count: 12).trimmingCharacters(in: .whitespaces)
        let p = preview("---\ntitle: \(title)\n---\n# Owls\n")
        p.view.window?.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        p.view.window?.layoutIfNeeded()
        _ = try await block(p)
        _ = try await js(p, "document.querySelector('details.frontmatter').style.fontSize = '20px'; return true;")
        let r = try await js(p, """
        const s = document.querySelector('details.frontmatter > summary');
        const cs = getComputedStyle(s);
        return { h: s.getBoundingClientRect().height, line: parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.4,
                 cut: s.scrollWidth > s.clientWidth, overflow: cs.textOverflow, text: s.textContent };
        """) as? [String: Any]
        let height = (r?["h"] as? NSNumber)?.doubleValue ?? 0
        let line = (r?["line"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertLessThan(height, line * 1.6 + 4, "the summary wrapped: \(r ?? [:])")
        XCTAssertEqual(r?["cut"] as? Bool, true, "a long title isn't cut")
        XCTAssertEqual(r?["overflow"] as? String, "ellipsis")
        XCTAssertEqual(r?["text"] as? String, "Front matter · " + title)
        try await snapshot(p, "front-matter-long-title")
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
