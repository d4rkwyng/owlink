import XCTest
import UIKit
import PDFKit
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

    private func restore(_ key: String, _ value: Any?) {
        if let value { AppSettings.defaults.set(value, forKey: key) }
        else { AppSettings.defaults.removeObject(forKey: key) }
    }
}
