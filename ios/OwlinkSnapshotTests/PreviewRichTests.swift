import XCTest
import UIKit
import WebKit
import CedricCore

/// Mermaid and math in the preview (Mac 0.6.0), only with Draw Diagrams and
/// Math on: bundled, served by the app's handler, nothing fetched, the
/// page's own scripts still off. Off by default and for linked pages.
@MainActor
final class PreviewRichTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var temps: [URL] = []

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
        for t in temps { try? FileManager.default.removeItem(at: t) }
        temps = []
    }

    private let markdown = "# Home\n\nPrice $5 and $x^2$ here.\n\n$$\n\\frac{a}{b}\n$$\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n[other](other.md)\n"

    private func setUp(_ text: String? = nil) throws -> (PreviewController, URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("rich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        temps.append(temp)
        let doc = temp.appendingPathComponent("doc.md")
        try (text ?? markdown).write(to: doc, atomically: true, encoding: .utf8)
        try "# Other\n\n```mermaid\ngraph TD\n  X-->Y\n```\n".write(to: temp.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        let preview = PreviewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = preview
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        preview.documentURL = doc
        return (preview, doc)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(done(), "timed out: \(what)")
    }

    private func loaded(_ p: PreviewController) -> Bool {
        p.web.url != nil && p.web.url == p.pageURL && !p.web.isLoading
    }

    private func richState(_ p: PreviewController) async throws -> String? {
        try await p.web.callAsyncJavaScript("return document.documentElement.getAttribute('data-owlink-rich')",
                                            arguments: [:], in: nil, contentWorld: .defaultClient) as? String
    }

    func testBundledFilesAreInTheApp() {
        XCTAssertTrue(PreviewRichAssets.available, "Resources/Preview is in Owlink.app/Preview")
    }

    func testOffByDefaultKeepsTheStrictPage() async throws {
        let (p, _) = try setUp()
        XCTAssertFalse(p.drawDiagramsAndMath)
        p.show(markdown: markdown, palette: EditorPalettes.light)
        try await waitFor("loaded") { loaded(p) }
        let page = try XCTUnwrap(p.servedPageHTML)
        XCTAssertTrue(page.contains("script-src 'none'"))
        XCTAssertFalse(page.contains(PreviewRich.scheme))
        XCTAssertFalse(page.contains("math math-"), "no math markup without the switch")
        XCTAssertEqual(p.pageNeeds, [])
        XCTAssertFalse(p.richAssets.scriptOn)
        let state = try await richState(p)
        XCTAssertNil(state)
    }

    func testOnDrawsDiagramsAndMathFromTheBundle() async throws {
        let (p, _) = try setUp()
        p.show(markdown: markdown, palette: EditorPalettes.light)
        try await waitFor("loaded") { loaded(p) }
        p.drawDiagramsAndMath = true
        try await waitFor("rich page") { p.pageNeeds == [.mermaid, .math] && loaded(p) }
        let page = try XCTUnwrap(p.servedPageHTML)
        let csp = PreviewController.richCSP([.mermaid, .math])
        XCTAssertTrue(page.contains(csp))
        XCTAssertFalse(csp.contains("script-src 'unsafe-inline'"), "page scripts stay off")
        XCTAssertTrue(csp.contains("connect-src 'none'"))
        XCTAssertFalse(csp.contains("http"))
        var state: String?
        let end = Date().addingTimeInterval(20)
        while state != "done", Date() < end {
            state = try? await richState(p)
            if state != "done" { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertEqual(state, "done", "Mermaid and KaTeX finished")
        let drawn = try await p.web.callAsyncJavaScript(
            "return [document.querySelectorAll('.mermaid-diagram svg').length, document.querySelectorAll('.katex').length]",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(drawn?.first, 1)
        XCTAssertGreaterThanOrEqual(drawn?.last ?? 0, 2)
        XCTAssertTrue(p.richAssets.served.contains(PreviewRich.mermaidScript))
        XCTAssertTrue(p.richAssets.served.contains(PreviewRich.katexScript))
        // Off again: the strict page, and the handler refuses.
        p.drawDiagramsAndMath = false
        try await waitFor("strict again") { p.pageNeeds == [] && loaded(p) }
        XCTAssertFalse(p.richAssets.scriptOn)
        XCTAssertTrue(try XCTUnwrap(p.servedPageHTML).contains("script-src 'none'"))
    }

    func testPlainDocumentGetsNoScriptsAndAnotherDocumentResets() async throws {
        let (p, doc) = try setUp("# Plain\n\nNo diagrams.\n")
        p.drawDiagramsAndMath = true
        p.show(markdown: "# Plain\n\nNo diagrams.\n", palette: EditorPalettes.light)
        try await waitFor("loaded") { loaded(p) && p.servedPageHTML?.contains("Plain") == true }
        XCTAssertEqual(p.pageNeeds, [], "nothing to draw: the strict page")
        XCTAssertTrue(try XCTUnwrap(p.servedPageHTML).contains("script-src 'none'"))
        p.documentURL = doc.deletingLastPathComponent().appendingPathComponent("other.md")
        XCTAssertFalse(p.drawDiagramsAndMath, "another document starts off")
    }

    func testRichCSPAndPage() {
        XCTAssertEqual(PreviewController.richCSP([]), PreviewController.csp)
        let mermaid = PreviewController.richCSP([.mermaid])
        XCTAssertTrue(mermaid.contains("script-src cedric-asset://vendor/mermaid/mermaid.min.js cedric-asset://vendor/owlink-rich.js;"))
        XCTAssertFalse(mermaid.contains("katex"))
        let page = PreviewController.richPage("<html><head></head><body>x</body></html>", needs: [.math], dark: true)
        XCTAssertTrue(page.contains("katex.min.css\">\n</head>"))
        XCTAssertTrue(page.contains("data-dark=\"1\"></script>\n</body>"))
    }

    /// Folder grants past the kept twenty: adding the 21st through the
    /// registry drops the oldest (its folder let go) without touching the
    /// grant set while it is being changed (Sol round 2, must-fix 1).
    func testTwentyFirstFolderGrantDropsTheOldest() throws {
        let suite = "cedric-tests-grants-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let grants = PreviewFolderGrants(defaults: defaults)
        var folders: [URL] = []
        for k in 0...PreviewFolderGrants.maxKept {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("grant-\(k)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            temps.append(f)
            folders.append(f)
        }
        for f in folders.prefix(PreviewFolderGrants.maxKept) { XCTAssertTrue(grants.add(f)) }
        XCTAssertNotNil(grants.root(for: folders[0]))
        XCTAssertEqual((defaults.array(forKey: "previewFolderGrants") as? [Data])?.count, PreviewFolderGrants.maxKept)
        // The 21st: kept, and the oldest goes.
        XCTAssertTrue(grants.add(folders[PreviewFolderGrants.maxKept]))
        XCTAssertNotNil(grants.root(for: folders[PreviewFolderGrants.maxKept]))
        XCTAssertNil(grants.root(for: folders[0]), "the oldest grant is let go")
        XCTAssertNotNil(grants.root(for: folders[1]))
        XCTAssertEqual((defaults.array(forKey: "previewFolderGrants") as? [Data])?.count, PreviewFolderGrants.maxKept)
        // A fresh registry over the same bookmarks has the newest twenty.
        let reloaded = PreviewFolderGrants(defaults: defaults)
        XCTAssertNil(reloaded.root(for: folders[0]))
        XCTAssertNotNil(reloaded.root(for: folders[PreviewFolderGrants.maxKept]))
    }
}
