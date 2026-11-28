import Foundation

/// An `.xlsx` workbook's first sheet as CSV (File › Open Sheet as CSV),
/// read with ZipArchive and Foundation's XMLParser: no third-party code.
///
/// Cells: shared strings (`t="s"`), inline strings (`t="inlineStr"`),
/// formula strings (`t="str"`), booleans (TRUE / FALSE), errors (#DIV/0!)
/// and numbers, written as stored (`3.5`, `1E-3`; a date is its serial
/// number, since number formats aren't applied). A formula's cached value
/// is used; a formula with no cached value is an empty cell. Rows and
/// columns keep their places (gaps are empty cells), and every row is as
/// wide as the widest.
public enum XLSXSheet {
    public enum XLSXError: Error, Equatable { case noSheet }

    /// The first sheet's name and its CSV.
    public static func firstSheetCSV(_ zip: ZipArchive) throws -> (name: String, csv: String) {
        let (name, path) = firstSheet(zip)
        guard let path, zip.entry(path) != nil else { throw XLSXError.noSheet }
        let shared = (try? zip.contents(of: "xl/sharedStrings.xml")).map(sharedStrings) ?? []
        let rows = try cells(zip.contents(of: path), shared: shared)
        return (name ?? "Sheet1", csv(rows))
    }

    public static func firstSheetCSV(url: URL) throws -> (name: String, csv: String) {
        try firstSheetCSV(ZipArchive(url: url))
    }

    /// The workbook's first `<sheet>` and its part, through the workbook's
    /// relationships; else `xl/worksheets/sheet1.xml`.
    static func firstSheet(_ zip: ZipArchive) -> (String?, String?) {
        let fallback = zip.entry("xl/worksheets/sheet1.xml") != nil ? "xl/worksheets/sheet1.xml"
            : zip.entries.map(\.name).filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }.sorted().first
        guard let wb = try? zip.contents(of: "xl/workbook.xml") else { return (nil, fallback) }
        let sheets = XMLScan.elements(wb, named: "sheet")
        guard let first = sheets.first else { return (nil, fallback) }
        let name = first["name"]
        // r:id, whatever the prefix is bound to.
        let rid = first.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value
        guard let rid, let rels = try? zip.contents(of: "xl/_rels/workbook.xml.rels"),
              let target = XMLScan.elements(rels, named: "Relationship").first(where: { $0["Id"] == rid })?["Target"] else {
            return (name, fallback)
        }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        return (name, normalize(path))
    }

    /// "xl/worksheets/../worksheets/sheet1.xml" → "xl/worksheets/sheet1.xml".
    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { _ = out.popLast() } else if part != "." { out.append(part) }
        }
        return out.joined(separator: "/")
    }

    /// The shared strings, in order (rich text runs joined).
    public static func sharedStrings(_ xml: Data) -> [String] {
        let d = SharedStringsParser()
        let p = XMLParser(data: xml)
        p.delegate = d
        p.parse()
        return d.strings
    }

    /// The sheet's cells as rows of strings.
    public static func cells(_ xml: Data, shared: [String]) -> [[String]] {
        let d = SheetParser(shared: shared)
        let p = XMLParser(data: xml)
        p.delegate = d
        p.parse()
        var rows: [[String]] = []
        let width = (d.cells.keys.map(\.col).max() ?? -1) + 1
        let height = (d.cells.keys.map(\.row).max() ?? -1) + 1
        guard width > 0 else { return [] }
        rows = Array(repeating: Array(repeating: "", count: width), count: height)
        for (k, v) in d.cells { rows[k.row][k.col] = v }
        return rows
    }

    /// "B12" → (row 11, column 1); nil for anything else.
    public static func cellRef(_ s: String) -> (row: Int, col: Int)? {
        var col = 0, row = 0, letters = 0, digits = 0
        for u in s.utf8 {
            switch u {
            case 65...90 where digits == 0: col = col * 26 + Int(u - 64); letters += 1
            case 97...122 where digits == 0: col = col * 26 + Int(u - 96); letters += 1
            case 48...57: row = row * 10 + Int(u - 48); digits += 1
            case 36: continue // $A$1
            default: return nil
            }
            if letters > 3 || digits > 7 { return nil }
        }
        guard letters > 0, digits > 0, (1...SpreadsheetLimits.maxRows).contains(row), col <= SpreadsheetLimits.maxColumns else { return nil }
        return (row - 1, col - 1)
    }

    /// Rows as CSV: commas, LF line endings, fields with a comma, quote
    /// or line break quoted (quotes doubled).
    public static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    static func quote(_ f: String) -> String {
        guard f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return f }
        return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inSI = false, inT = false, inRPh = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch local(name) {
        case "si": inSI = true; current = ""
        case "t" where inSI && !inRPh: inT = true
        case "rPh": inRPh = true // phonetic hints, not the text
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch local(name) {
        case "si": inSI = false; strings.append(current)
        case "t": inT = false
        case "rPh": inRPh = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    struct Key: Hashable { var row: Int; var col: Int }
    let shared: [String]
    var cells: [Key: String] = [:]
    private var row = -1, col = -1, nextCol = 0
    private var type = "n"
    private var value: String?, inline: String?
    private var inV = false, inIS = false, inT = false, inRPh = false
    private var text = ""

    init(shared: [String]) { self.shared = shared }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch local(name) {
        case "row":
            row = a["r"].flatMap(Int.init).map { $0 - 1 } ?? row + 1
            nextCol = 0
        case "c":
            if let r = a["r"], let ref = XLSXSheet.cellRef(r) {
                row = ref.row
                col = ref.col
            } else {
                col = nextCol
            }
            nextCol = col + 1
            type = a["t"] ?? "n"
            value = nil
            inline = nil
        case "v": inV = true; text = ""
        case "is": inIS = true; inline = ""
        case "t" where inIS && !inRPh: inT = true
        case "rPh": inRPh = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch local(name) {
        case "v": inV = false; value = text
        case "t": inT = false
        case "is": inIS = false
        case "rPh": inRPh = false
        case "c":
            guard row >= 0, col >= 0 else { return }
            let out: String?
            switch type {
            case "s": out = value.flatMap(Int.init).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil }
            case "inlineStr": out = inline ?? value
            case "b": out = value.map { $0 == "1" ? "TRUE" : "FALSE" }
            default: out = value // n, str, e: as stored (a formula's cached value)
            }
            if let out, !out.isEmpty { cells[Key(row: row, col: col)] = out }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV { text += string } else if inT { inline? += string }
    }
}

private func local(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
}

/// The attributes of every element with this (local) name.
enum XMLScan {
    static func elements(_ xml: Data, named: String) -> [[String: String]] {
        final class D: NSObject, XMLParserDelegate {
            let want: String
            var found: [[String: String]] = []
            init(_ w: String) { want = w }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                if local(name) == want { found.append(a) }
            }
        }
        let d = D(named)
        let p = XMLParser(data: xml)
        p.delegate = d
        p.parse()
        return d.found
    }
}
