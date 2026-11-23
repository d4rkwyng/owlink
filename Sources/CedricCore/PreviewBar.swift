import Foundation

/// The preview pane's quick-actions bar: which controls a preview has.
public enum PreviewBarItem: String, CaseIterable, Sendable {
    /// CSV: "N rows" and the button that puts the grid back in file order.
    case rowCount, sortReset
    case refresh, syncScroll, zoomOut, zoomIn
    case back, forward, home, openInBrowser
    /// Markdown: Export ▸ HTML / PDF.
    case export
    case allowJavaScript, allowNetwork
    case detach

    /// The bar's controls, left to right, for a preview of `language`
    /// (`certificate`: the Certificate panel, which has no zoom or sync).
    public static func items(for language: Language, certificate: Bool) -> [PreviewBarItem] {
        if certificate { return [.refresh, .detach] }
        switch language {
        case .csv: return [.rowCount, .sortReset, .refresh, .syncScroll, .zoomOut, .zoomIn, .detach]
        case .markdown: return [.back, .forward, .home, .openInBrowser, .refresh, .syncScroll, .zoomOut, .zoomIn, .export, .allowJavaScript, .allowNetwork, .detach]
        default: return [.back, .forward, .home, .openInBrowser, .refresh, .syncScroll, .zoomOut, .zoomIn, .allowJavaScript, .allowNetwork, .detach]
        }
    }

    /// The CSV grid's data rows ("12,345 rows"; "50,000+ rows" when the
    /// grid stopped reading before the end).
    public static func rowCountText(rows: Int, capped: Bool) -> String {
        let n = rows.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        if capped { return String(localized: "\(n)+ rows") }
        return rows == 1 ? String(localized: "1 row") : String(localized: "\(n) rows")
    }
}

/// The preview's zoom (page zoom for Markdown/HTML, the grid's font for CSV).
public enum PreviewZoom {
    public static let ladder: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    public static var min: Double { ladder.first! }
    public static var max: Double { ladder.last! }

    /// The next rung up (`in`) or down from `z`; at an end, the end.
    public static func step(_ z: Double, in zoomIn: Bool) -> Double {
        let eps = 0.001
        if zoomIn { return ladder.first { $0 > z + eps } ?? max }
        return ladder.last { $0 < z - eps } ?? min
    }

    public static func canStep(_ z: Double, in zoomIn: Bool) -> Bool { zoomIn ? z < max - 0.001 : z > min + 0.001 }

    public static func percent(_ z: Double) -> String { "\(Int((z * 100).rounded()))%" }
}
