import XCTest
import UIKit
import PDFKit
import WebKit
import CedricCore

@MainActor
final class MarkdownExportSnapshotTests: XCTestCase {
    func testProseFontSettingsDefaultsAndLanguageSelection() {
        let defaults = AppSettings.defaults
        let oldEnabled = defaults.object(forKey: AppSettings.Key.useProseFont)
        let oldName = defaults.object(forKey: AppSettings.Key.proseFontName)
        let oldSize = defaults.object(forKey: AppSettings.Key.proseFontSize)
        let oldEditorSize = defaults.object(forKey: AppSettings.Key.fontSize)
        defer {
            restore(AppSettings.Key.useProseFont, oldEnabled)
            restore(AppSettings.Key.proseFontName, oldName)
            restore(AppSettings.Key.proseFontSize, oldSize)
            restore(AppSettings.Key.fontSize, oldEditorSize)
            AppSettings.post()
        }

        defaults.removeObject(forKey: AppSettings.Key.useProseFont)
        defaults.removeObject(forKey: AppSettings.Key.proseFontName)
        defaults.removeObject(forKey: AppSettings.Key.proseFontSize)
        defaults.removeObject(forKey: AppSettings.Key.fontSize)
        let traits = UITraitCollection(horizontalSizeClass: .compact)
        XCTAssertFalse(AppSettings.useProseFont)
        XCTAssertEqual(AppSettings.proseFontSize, 15)

        AppSettings.useProseFont = true
        let editorFont = AppSettings.font(for: traits)
        XCTAssertTrue(editorFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertEqual(AppSettings.font(for: .swift, traits: traits), editorFont)
        XCTAssertEqual(AppSettings.font(for: .markdown, traits: traits), AppSettings.proseFont(for: traits))
        XCTAssertEqual(AppSettings.font(for: .plain, traits: traits), AppSettings.proseFont(for: traits))

        AppSettings.proseFontName = ProseFont.systemSerif
        let serif = AppSettings.font(for: .markdown, traits: traits)
        let systemSerifName = UIFont.systemFont(ofSize: serif.pointSize).fontDescriptor.withDesign(.serif)?.postscriptName
        XCTAssertEqual(serif.fontDescriptor.postscriptName, systemSerifName)
        AppSettings.useProseFont = false
        XCTAssertEqual(AppSettings.font(for: .markdown, traits: traits), editorFont)
    }

    func testExportHTMLAndRenderedPDF() async throws {
        let markdown = "# Hello export"
        let html = await withCheckedContinuation { continuation in
            MarkdownExportIOS.renderPage(markdown: markdown, title: "Export", folder: nil) { page, _, _ in
                continuation.resume(returning: page)
            }
        }
        XCTAssertEqual(html, MarkdownExport.page(markdown: markdown, title: "Export"))
        XCTAssertTrue(html.contains("script-src 'none'"))

        let hostile = #"<script>alert(1)</script><img src="https://evil.example/t.png" onerror="alert(2)">Hello export"#
        let sandboxed = await withCheckedContinuation { continuation in
            MarkdownExportIOS.renderPage(markdown: hostile, title: "Export", folder: nil, remote: false) { page, _, _ in
                continuation.resume(returning: page)
            }
        }
        XCTAssertEqual(sandboxed, MarkdownExport.page(markdown: hostile, title: "Export", remote: false))
        XCTAssertFalse(sandboxed.localizedCaseInsensitiveContains("<script"))
        XCTAssertTrue(sandboxed.contains("default-src 'none'"))
        XCTAssertTrue(sandboxed.contains("connect-src 'none'"))

        let result = await withCheckedContinuation { continuation in
            MarkdownExportIOS.makePDF(html: sandboxed, folder: nil, openedRoot: nil, vaultRoot: nil) { result in
                continuation.resume(returning: result)
            }
        }
        let data = try result.get()
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertFalse(data.isEmpty)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Hello export") == true)
    }

    private func render(_ markdown: String, folder: URL? = nil) async -> String {
        await withCheckedContinuation { continuation in
            MarkdownExportIOS.renderPage(markdown: markdown, title: "Export", folder: folder) { page, _, _ in
                continuation.resume(returning: page)
            }
        }
    }

    private func pagedPDF(_ html: String, folder: URL? = nil) async throws -> (PDFDocument, MarkdownExportIOS.PDFLayout) {
        let result = await withCheckedContinuation { continuation in
            MarkdownExportIOS.makePagedPDF(html: html, folder: folder, openedRoot: nil, vaultRoot: nil) { result in
                continuation.resume(returning: result)
            }
        }
        let (data, layout) = try result.get()
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        return (try XCTUnwrap(PDFDocument(data: data)), layout)
    }

    private func assertFullSizePages(_ pdf: PDFDocument, file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<pdf.pageCount {
            let box = pdf.page(at: i)!.bounds(for: .mediaBox)
            XCTAssertEqual(box.width, MarkdownExportIOS.pageWidth, accuracy: 1, "page \(i)", file: file, line: line)
            XCTAssertEqual(box.height, MarkdownExportIOS.pageHeight, accuracy: 1, "page \(i)", file: file, line: line)
        }
    }

    func testPDFPagesAreCutBetweenBlocksAtFullPageSize() async throws {
        XCTAssertEqual(MarkdownExportIOS.pageHeight, (760 * 11 / 8.5).rounded())

        // Short: one page, padded to the full page size.
        let (short, shortLayout) = try await pagedPDF(await render("# Hello export"))
        XCTAssertEqual(short.pageCount, 1)
        XCTAssertEqual(shortLayout.cuts.count, 2)
        assertFullSizePages(short)

        // Tall: many headings and paragraphs, several pages, all full size.
        let tall = (1...40).map { "## Section \($0)\n\nParagraph \($0) of the tall export, with enough words to wrap across the page width at least once or twice in the preview style." }
            .joined(separator: "\n\n")
        let (pdf, layout) = try await pagedPDF(await render(tall))
        XCTAssertGreaterThan(layout.total, MarkdownExportIOS.pageHeight)
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.pageCount, layout.cuts.count - 1)
        XCTAssertEqual(layout.cuts, PageBreaks.cuts(total: layout.total, pageHeight: MarkdownExportIOS.pageHeight, boundaries: layout.bottoms))
        assertFullSizePages(pdf)
        // Every inner cut lies on a block bottom (each fits between blocks here).
        for cut in layout.cuts.dropFirst().dropLast() {
            XCTAssertTrue(layout.bottoms.contains(cut), "cut \(cut) is not a block bottom")
        }
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Section 1") == true)
        XCTAssertTrue(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Section 40") == true)
    }

    func testBlockThatWouldNotFitMovesToTheNextPage() async throws {
        // A code block most of a page tall, then a long paragraph that
        // can't fit under it: the paragraph starts page 2, not page 1.
        let code = (1...38).map { "line \($0)" }.joined(separator: "\n")
        let paragraph = "SECONDBLOCK " + Array(repeating: "This paragraph is long enough that it cannot fit in what is left of the first page.", count: 25).joined(separator: " ")
        let (pdf, layout) = try await pagedPDF(await render("```\n\(code)\n```\n\n\(paragraph)"))
        let h = MarkdownExportIOS.pageHeight
        XCTAssertEqual(layout.cuts, PageBreaks.cuts(total: layout.total, pageHeight: h, boundaries: layout.bottoms))
        let firstBottom = try XCTUnwrap(layout.bottoms.min())
        XCTAssertGreaterThanOrEqual(firstBottom, h / 2, "the code block should be over half a page")
        XCTAssertLessThan(firstBottom, h, "the code block should fit on one page")
        XCTAssertGreaterThan(layout.total, h)
        XCTAssertEqual(layout.cuts[1], firstBottom)
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        let first = pdf.page(at: 0)?.string ?? ""
        XCTAssertTrue(first.contains("line 38"))
        XCTAssertFalse(first.contains("SECONDBLOCK"))
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("SECONDBLOCK") == true)
        assertFullSizePages(pdf)
    }

    func testPDFLinksIntoTheFolderAreRelinkedRelative() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Part\n".write(to: folder.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        try "# Note\n".write(to: folder.appendingPathComponent("sub/note.md"), atomically: true, encoding: .utf8)
        let html = await render("[Other](other.md#part)\n\n[Note](sub/note.md)", folder: folder)
        let (pdf, _) = try await pagedPDF(html, folder: folder)
        let urls = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations.compactMap(\.url) }
        XCTAssertFalse(urls.contains { $0.scheme == PreviewFolder.scheme }, "\(urls)")
        let hrefs = urls.map(\.absoluteString)
        XCTAssertTrue(hrefs.contains("other.md#part"), "\(hrefs)")
        XCTAssertTrue(hrefs.contains("sub/note.md"), "\(hrefs)")
    }

    func testPDFRelinkKeepsFragmentAndSkipsOtherLinks() throws {
        let folder = URL(fileURLWithPath: "/tmp/notes/a", isDirectory: true)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).pdfData { $0.beginPage() }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        func link(_ s: String) -> PDFAnnotation {
            let a = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .link, withProperties: nil)
            a.url = URL(string: s)
            page.addAnnotation(a)
            return a
        }
        let heading = link("cedric-doc://doc/tmp/notes/b/c.md#intro")
        let plain = link("cedric-doc://doc/tmp/notes/a/x%20y.md")
        let web = link("https://example.com/p#q")
        MarkdownExportIOS.relink(page, savedIn: folder)
        XCTAssertEqual(heading.url?.absoluteString, "../b/c.md#intro")
        XCTAssertEqual(plain.url?.absoluteString, "x%20y.md")
        XCTAssertEqual(web.url?.absoluteString, "https://example.com/p#q")
    }

    func testPDFExportWebViewKeepsJavaScriptOffAndNoScripts() async throws {
        var seen: [WKWebViewConfiguration] = []
        MarkdownExportIOS.probeConfiguration = { seen.append($0) }
        defer { MarkdownExportIOS.probeConfiguration = nil }
        _ = try await pagedPDF(await render("# Probe"))
        let configuration = try XCTUnwrap(seen.first)
        XCTAssertEqual(seen.count, 1)
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
        XCTAssertNotNil(configuration.urlSchemeHandler(forURLScheme: PreviewFolder.scheme))
        // (WebKit has no way to list script message handlers; the export
        // configuration never adds one.)
    }

    private func restore(_ key: String, _ value: Any?) {
        if let value { AppSettings.defaults.set(value, forKey: key) }
        else { AppSettings.defaults.removeObject(forKey: key) }
    }
}
