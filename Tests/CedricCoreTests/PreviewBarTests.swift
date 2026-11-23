import Foundation
import Testing
@testable import CedricCore

@Suite struct PreviewBarTests {
    @Test func markdownHasEveryWebControlAndExport() {
        let items = PreviewBarItem.items(for: .markdown, certificate: false)
        #expect(items == [.back, .forward, .home, .refresh, .syncScroll, .zoomOut, .zoomIn, .export, .allowJavaScript, .allowNetwork, .detach])
    }

    @Test func htmlHasNoExport() {
        let items = PreviewBarItem.items(for: .html, certificate: false)
        #expect(!items.contains(.export))
        #expect(items.contains(.allowJavaScript) && items.contains(.allowNetwork))
        #expect(!items.contains(.rowCount) && !items.contains(.sortReset))
    }

    @Test func csvHasSortResetAndRowCountNoWebToggles() {
        let items = PreviewBarItem.items(for: .csv, certificate: false)
        #expect(items == [.rowCount, .sortReset, .refresh, .syncScroll, .zoomOut, .zoomIn, .detach])
    }

    @Test func certificatePanelOnlyRefreshesAndDetaches() {
        #expect(PreviewBarItem.items(for: .plain, certificate: true) == [.refresh, .detach])
    }

    @Test func zoomStepsUpAndDownThroughTheLadder() {
        #expect(PreviewZoom.step(1, in: true) == 1.1)
        #expect(PreviewZoom.step(1, in: false) == 0.9)
        #expect(PreviewZoom.step(1.1, in: false) == 1)
        // Off the ladder: to the next rung in that direction.
        #expect(PreviewZoom.step(1.05, in: true) == 1.1)
        #expect(PreviewZoom.step(1.05, in: false) == 1)
        // At the ends it stays.
        #expect(PreviewZoom.step(PreviewZoom.max, in: true) == PreviewZoom.max)
        #expect(PreviewZoom.step(PreviewZoom.min, in: false) == PreviewZoom.min)
        #expect(!PreviewZoom.canStep(PreviewZoom.max, in: true))
        #expect(PreviewZoom.canStep(PreviewZoom.max, in: false))
    }

    @Test func zoomPercentLabel() {
        #expect(PreviewZoom.percent(1) == "100%")
        #expect(PreviewZoom.percent(1.25) == "125%")
        #expect(PreviewZoom.percent(0.67) == "67%")
    }

    @Test func rowCountText() {
        #expect(PreviewBarItem.rowCountText(rows: 0, capped: false) == "0 rows")
        #expect(PreviewBarItem.rowCountText(rows: 1, capped: false) == "1 row")
        #expect(PreviewBarItem.rowCountText(rows: 12345, capped: false) == "12,345 rows")
        #expect(PreviewBarItem.rowCountText(rows: 50000, capped: true) == "50,000+ rows")
    }
}
