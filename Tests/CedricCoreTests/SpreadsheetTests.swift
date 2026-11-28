import Foundation
import Testing
@testable import CedricCore

/// The read-only spreadsheet grid's model (iOS): every sheet of an .xlsx
/// workbook in order, with its strings, numbers, booleans, errors and
/// dates as Excel shows them, and CSV / TSV through `CSV`. Capped, with a
/// notice; damaged and password-protected files are told apart.
@Suite struct SpreadsheetTests {

    // MARK: Fixtures

    /// A workbook from its parts: sheets as (name, sheetData XML, extra
    /// worksheet XML before sheetData), shared strings, styles.
    static func workbook(_ sheets: [(name: String, rows: String)], shared: [String] = [],
                         sharedXML: String? = nil, styles: String? = nil, date1904: Bool = false,
                         hidden: Set<String> = [], dimension: [String: String] = [:],
                         reversedFiles: Bool = false) throws -> Data {
        var parts: [(String, String)] = []
        let n = sheets.count
        // reversedFiles: the first sheet in the workbook lives in the
        // last sheetN.xml, so order must come from workbook.xml.
        func file(_ i: Int) -> Int { reversedFiles ? n - i : i + 1 }
        let sheetElems = sheets.enumerated().map { i, s in
            "<sheet name=\"\(s.name)\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"\(hidden.contains(s.name) ? " state=\"hidden\"" : "")/>"
        }.joined()
        parts.append(("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"))
        parts.append(("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            \(date1904 ? "<workbookPr date1904=\"1\"/>" : "<workbookPr/>")<sheets>\(sheetElems)</sheets></workbook>
            """))
        let rels = sheets.indices.map { i in
            "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(file(i)).xml\"/>"
        }.joined()
        parts.append(("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"))
        let sst = sharedXML ?? shared.map { "<si><t xml:space=\"preserve\">\($0)</t></si>" }.joined()
        parts.append(("xl/sharedStrings.xml", "<?xml version=\"1.0\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(sst)</sst>"))
        if let styles {
            parts.append(("xl/styles.xml", "<?xml version=\"1.0\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(styles)</styleSheet>"))
        }
        for (i, s) in sheets.enumerated() {
            let dim = dimension[s.name].map { "<dimension ref=\"\($0)\"/>" } ?? ""
            parts.append(("xl/worksheets/sheet\(file(i)).xml", "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(dim)<sheetData>\(s.rows)</sheetData></worksheet>"))
        }
        return TestZip.make(parts.map { ($0.0, Data($0.1.utf8)) })
    }

    /// Styles with these number formats as cellXfs 0, 1, 2… (built-in ids
    /// or custom codes, which get ids from 164). cellStyleXfs holds a
    /// date style too, which must not count.
    static func styles(_ formats: [Any]) -> String {
        var custom: [(Int, String)] = []
        var ids: [Int] = []
        for f in formats {
            if let id = f as? Int { ids.append(id) } else if let code = f as? String {
                let id = 164 + custom.count
                custom.append((id, code))
                ids.append(id)
            }
        }
        let numFmts = custom.isEmpty ? "" : "<numFmts count=\"\(custom.count)\">" + custom.map { "<numFmt numFmtId=\"\($0.0)\" formatCode=\"\(xmlEscape($0.1))\"/>" }.joined() + "</numFmts>"
        return numFmts + "<cellStyleXfs count=\"1\"><xf numFmtId=\"14\"/></cellStyleXfs><cellXfs count=\"\(ids.count)\">"
            + ids.map { "<xf numFmtId=\"\($0)\" fontId=\"0\" applyNumberFormat=\"1\"/>" }.joined() + "</cellXfs>"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    func text(_ t: SpreadsheetTable, _ ref: String) -> String? {
        guard let r = XLSXSheet.cellRef(ref) else { return nil }
        return t[r.row, r.col]?.text
    }

    func kind(_ t: SpreadsheetTable, _ ref: String) -> SpreadsheetCell.Kind? {
        guard let r = XLSXSheet.cellRef(ref) else { return nil }
        return t[r.row, r.col]?.kind
    }

    // MARK: Workbook structure

    @Test func everySheetInWorkbookOrder() throws {
        let data = try Self.workbook([
            ("Owls", "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>"),
            ("Habitats", "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>1</v></c></row>"),
            ("Notes", "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>2</v></c></row>"),
        ], shared: ["Snowy owl", "Tundra", "Read only"], hidden: ["Notes"], reversedFiles: true)
        let wb = try Workbook(data: data)
        #expect(wb.sheets.map(\.name) == ["Owls", "Habitats", "Notes"])
        #expect(wb.sheets.map(\.isHidden) == [false, false, true])
        #expect(try text(wb.table(at: 0), "A1") == "Snowy owl")
        #expect(try text(wb.table(at: 1), "A1") == "Tundra")
        #expect(try text(wb.table(at: 2), "A1") == "Read only")
        #expect(try wb.table(at: 1).name == "Habitats")
    }

    @Test func sharedStringsWithRichTextRunsAndInlineStrings() throws {
        let sst = "<si><r><rPr><b/></rPr><t>Snowy</t></r><r><t xml:space=\"preserve\"> owl</t></r></si>"
            + "<si><t>Barn</t><rPh sb=\"0\" eb=\"1\"><t>BAHN</t></rPh></si>"
            + "<si><t>Tom &amp; Jerry &lt;3</t></si>"
        let rows = "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c><c r=\"C1\" t=\"s\"><v>2</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>Great horned</t></is></c>"
            + "<c r=\"B2\" t=\"inlineStr\"><is><r><t>Elf</t></r><r><t> owl</t></r></is></c>"
            + "<c r=\"C2\" t=\"s\"><v>99</v></c></row>"
        let t = try Workbook(data: Self.workbook([("S", rows)], sharedXML: sst)).table(at: 0)
        #expect(text(t, "A1") == "Snowy owl")
        #expect(text(t, "B1") == "Barn", "phonetic runs aren't the text")
        #expect(text(t, "C1") == "Tom & Jerry <3")
        #expect(text(t, "A2") == "Great horned")
        #expect(text(t, "B2") == "Elf owl")
        #expect(text(t, "C2") == nil, "an out-of-range shared string index is an empty cell")
        #expect(kind(t, "A1") == .text)
    }

    @Test func numbersBooleansErrorsAndFormulaStrings() throws {
        let rows = "<row r=\"1\">"
            + "<c r=\"A1\"><v>3.5</v></c><c r=\"B1\"><v>1E-3</v></c><c r=\"C1\"><v>0.30000000000000004</v></c>"
            + "<c r=\"D1\"><v>12</v></c><c r=\"E1\"><v>-42</v></c><c r=\"F1\" s=\"1\"><v>0.25</v></c>"
            + "<c r=\"G1\" s=\"2\"><v>0.125</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\" t=\"b\"><v>1</v></c><c r=\"B2\" t=\"b\"><v>0</v></c>"
            + "<c r=\"C2\" t=\"e\"><v>#DIV/0!</v></c><c r=\"D2\" t=\"str\"><f>A1&amp;\"x\"</f><v>owl</v></c>"
            + "<c r=\"E2\"><f>SUM(A1:B1)</f></c><c r=\"F2\" t=\"n\"><f>1+1</f><v>2</v></c></row>"
        let t = try Workbook(data: Self.workbook([("S", rows)], styles: Self.styles([0, 9, 10]))).table(at: 0)
        #expect(text(t, "A1") == "3.5")
        #expect(text(t, "B1") == "0.001")
        #expect(text(t, "C1") == "0.3", "General shows 15 significant digits")
        #expect(text(t, "D1") == "12")
        #expect(text(t, "E1") == "-42")
        #expect(text(t, "F1") == "25%")
        #expect(text(t, "G1") == "12.50%")
        #expect(kind(t, "A1") == .number)
        #expect(text(t, "A2") == "TRUE" && kind(t, "A2") == .boolean)
        #expect(text(t, "B2") == "FALSE")
        #expect(text(t, "C2") == "#DIV/0!" && kind(t, "C2") == .error)
        #expect(text(t, "D2") == "owl" && kind(t, "D2") == .text)
        #expect(text(t, "E2") == nil, "a formula with no cached value is empty")
        #expect(text(t, "F2") == "2")
    }

    // MARK: Dates

    @Test func dates1900() throws {
        // xf 0 General, 1 built-in 14 (date), 2 custom yyyy-mm-dd, 3 custom
        // d-mmm-yy, 4 built-in 22 (date and time), 5 built-in 20 (h:mm),
        // 6 custom hh:mm:ss, 7 a number format with "m" in quotes (not a date).
        let st = Self.styles([0, 14, "yyyy-mm-dd", "d-mmm-yy", 22, 20, "hh:mm:ss", "0.00\" mm\"", "[$-409]mmmm d, yyyy;@"])
        let rows = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>1</v></c><c r=\"B1\" s=\"1\"><v>59</v></c><c r=\"C1\" s=\"1\"><v>61</v></c>"
            + "<c r=\"D1\" s=\"2\"><v>45366</v></c><c r=\"E1\" s=\"3\"><v>45366</v></c><c r=\"F1\" s=\"4\"><v>45366.5</v></c>"
            + "<c r=\"G1\" s=\"5\"><v>0.75</v></c><c r=\"H1\" s=\"6\"><v>0.5208449074074074</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\"><v>45366</v></c><c r=\"B2\" s=\"7\"><v>2.5</v></c><c r=\"C2\" s=\"8\"><v>45366</v></c>"
            + "<c r=\"D2\" t=\"d\"><v>2024-03-15T00:00:00Z</v></c><c r=\"E2\" s=\"1\"><v>60</v></c></row>"
        let t = try Workbook(data: Self.workbook([("S", rows)], styles: st)).table(at: 0)
        #expect(text(t, "A1") == "1900-01-01")
        #expect(text(t, "B1") == "1900-02-28")
        #expect(text(t, "C1") == "1900-03-01", "Excel's phantom 1900-02-29 is serial 60")
        #expect(text(t, "E2") == "1900-02-29")
        #expect(text(t, "D1") == "2024-03-15")
        #expect(text(t, "E1") == "2024-03-15")
        #expect(text(t, "F1") == "2024-03-15 12:00")
        #expect(text(t, "G1") == "18:00")
        #expect(text(t, "H1") == "12:30:01")
        #expect(kind(t, "D1") == .date)
        #expect(text(t, "A2") == "45366", "General is not a date")
        #expect(text(t, "B2") == "2.5", "quoted text in a format isn't a date part")
        #expect(text(t, "C2") == "2024-03-15", "a locale prefix and a text section")
        #expect(text(t, "D2") == "2024-03-15T00:00:00Z", "an ISO date cell shows as stored")
    }

    @Test func dates1904() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c><c r=\"B1\" s=\"1\"><v>43904</v></c><c r=\"C1\" s=\"2\"><v>43904.25</v></c></row>"
        let wb = try Workbook(data: Self.workbook([("S", rows)], styles: Self.styles([0, 14, 22]), date1904: true))
        #expect(wb.date1904)
        let t = try wb.table(at: 0)
        #expect(text(t, "A1") == "1904-01-01")
        #expect(text(t, "B1") == "2024-03-15")
        #expect(text(t, "C1") == "2024-03-15 06:00")
    }

    // MARK: Layout

    @Test func emptyCellsAndGaps() throws {
        // Row 2 missing; B1 missing; C1 has a style but no value; row 4's
        // cells have no r (they follow on from the row's start).
        let rows = "<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"C1\" s=\"0\"/><c r=\"D1\"><v>4</v></c></row>"
            + "<row r=\"3\"><c r=\"B3\" t=\"inlineStr\"><is><t>gap</t></is></c></row>"
            + "<row><c><v>7</v></c><c><v>8</v></c></row>"
        let t = try Workbook(data: Self.workbook([("S", rows)])).table(at: 0)
        #expect(t.rowCount == 4)
        #expect(t.columnCount == 4)
        #expect(text(t, "A1") == "1")
        #expect(text(t, "B1") == nil)
        #expect(text(t, "C1") == nil)
        #expect(text(t, "D1") == "4")
        #expect(t[1, 0] == nil)
        #expect(text(t, "B3") == "gap")
        #expect(text(t, "A4") == "7" && text(t, "B4") == "8")
        #expect(t.cellCount == 5)
        #expect(!t.truncated && t.truncationNotice == nil)
    }

    @Test func sparseFarCellsDontAllocateTheGrid() throws {
        let t = try Workbook(data: Self.workbook([("S", "<row r=\"50000\"><c r=\"ZZ50000\"><v>1</v></c></row>")])).table(at: 0)
        #expect(t.rowCount == 50_000)
        #expect(t.columnCount == 702)
        #expect(t.cellCount == 1)
        #expect(t[49_999, 701]?.text == "1")
    }

    @Test func emptySheet() throws {
        let wb = try Workbook(data: Self.workbook([("Blank", ""), ("Data", "<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>")]))
        let t = try wb.table(at: 0)
        #expect(t.isEmpty && t.rowCount == 0 && t.columnCount == 0)
        #expect(try !wb.table(at: 1).isEmpty)
    }

    @Test func columnLetters() {
        let cases: [(Int, String)] = [(0, "A"), (1, "B"), (25, "Z"), (26, "AA"), (27, "AB"), (51, "AZ"), (52, "BA"),
                                      (701, "ZZ"), (702, "AAA"), (16_383, "XFD")]
        for (i, s) in cases {
            #expect(SpreadsheetTable.columnName(i) == s, "\(i)")
            #expect(XLSXSheet.cellRef(s + "1")?.col == i, "\(s)")
        }
        #expect(SpreadsheetTable.cellName(row: 2, column: 1) == "B3")
    }

    // MARK: Caps

    static func bigSheet(rows: Int, columns: Int) -> String {
        var s = ""
        s.reserveCapacity(rows * columns * 24)
        for r in 1...rows {
            s += "<row r=\"\(r)\">"
            for c in 0..<columns { s += "<c r=\"\(SpreadsheetTable.columnName(c))\(r)\"><v>\(r * 100 + c)</v></c>" }
            s += "</row>"
        }
        return s
    }

    @Test func hugeSheetStopsAtTheCellCap() throws {
        let data = try Self.workbook([("Big", Self.bigSheet(rows: 2_000, columns: 10))], dimension: ["Big": "A1:J2000"])
        let limits = SpreadsheetLimits(maxCells: 5_000, maxBytes: 64_000_000)
        let t = try Workbook(data: data).table(at: 0, limits: limits)
        #expect(t.truncated)
        #expect(t.rowCount == 500)
        #expect(t.cellCount == 5_000)
        #expect(t.totalRows == 2_000)
        #expect(t[499, 9]?.text == "50009")
        #expect(t[500, 0] == nil)
        #expect(t.truncationNotice == "Showing the first 500 rows of 2,000.")
        // No <dimension>: the rows past the cap are still counted.
        let noDim = try Workbook(data: Self.workbook([("Big", Self.bigSheet(rows: 2_000, columns: 10))])).table(at: 0, limits: limits)
        #expect(noDim.totalRows == 2_000)
    }

    @Test func theDefaultCapIs100KCells() throws {
        #expect(SpreadsheetLimits.standard.maxCells == 100_000)
        let t = try Workbook(data: Self.workbook([("Big", Self.bigSheet(rows: 15_000, columns: 10))])).table(at: 0)
        #expect(t.truncated)
        #expect(t.rowCount == 10_000)
        #expect(t.totalRows == 15_000)
        #expect(t.truncationNotice == "Showing the first 10,000 rows of 15,000.")
    }

    @Test func byteCapStopsReadingTheSheet() throws {
        let data = try Self.workbook([("Big", Self.bigSheet(rows: 2_000, columns: 10))])
        let t = try Workbook(data: data).table(at: 0, limits: SpreadsheetLimits(maxCells: 1_000_000, maxBytes: 20_000))
        #expect(t.truncated)
        #expect(t.rowCount > 10 && t.rowCount < 2_000)
        #expect(t.totalRows == nil, "how many rows there are isn't known")
        #expect(t.truncationNotice == "Showing the first \(t.rowCount) rows.")
        // Every row shown is whole.
        #expect(t[t.rowCount - 1, 9] != nil)
    }

    // MARK: Damaged and protected files

    @Test func corruptFilesAreErrors() throws {
        #expect(throws: SpreadsheetError.notAWorkbook) { try Workbook(data: Data("not a zip at all, just text".utf8)) }
        #expect(throws: SpreadsheetError.notAWorkbook) { try Workbook(data: Data()) }
        let good = try Self.workbook([("S", "<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>")])
        #expect(throws: SpreadsheetError.notAWorkbook) { try Workbook(data: good.prefix(good.count / 2)) }
        // A zip that isn't a workbook (a .docx renamed .xlsx).
        let docx = TestZip.make([("[Content_Types].xml", Data("<Types/>".utf8)), ("word/document.xml", Data("<w:document/>".utf8))])
        #expect(throws: SpreadsheetError.notAWorkbook) { try Workbook(data: docx) }
        // A workbook whose sheet part is missing.
        let noPart = TestZip.make([
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"urn:r\"><sheets><sheet name=\"A\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet9.xml\"/></Relationships>".utf8)),
        ])
        let wb = try Workbook(data: noPart)
        #expect(throws: SpreadsheetError.damaged) { try wb.table(at: 0) }
        // An OLE2 file that isn't encrypted OOXML (a legacy .xls).
        #expect(throws: SpreadsheetError.notAWorkbook) { try Workbook(data: TestCFB.make(streams: ["Workbook"])) }
    }

    @Test func encryptedWorkbookIsPasswordProtected() throws {
        let enc = TestCFB.make(streams: ["EncryptionInfo", "EncryptedPackage"])
        #expect(throws: SpreadsheetError.passwordProtected) { try Workbook(data: enc) }
    }

    // MARK: CSV and TSV

    @Test func csvThroughTheCSVReader() throws {
        let csv = "Owl,Count,Note\nBarn owl,12,\"likes barns, mostly\"\n\"Snowy\nowl\",3.5,\nTawny owl,,\"said \"\"hoo\"\"\"\n"
        let t = try DelimitedText.table(data: Data(csv.utf8), fileName: "owls.csv")
        #expect(t.name == "owls.csv")
        #expect(t.rowCount == 4 && t.columnCount == 3)
        #expect(text(t, "A1") == "Owl")
        #expect(text(t, "C2") == "likes barns, mostly")
        #expect(text(t, "A3") == "Snowy\nowl")
        #expect(text(t, "B3") == "3.5" && kind(t, "B3") == .number)
        #expect(text(t, "C4") == "said \"hoo\"")
        #expect(kind(t, "A2") == .text)
        #expect(!t.truncated)
    }

    @Test func tsvByName() throws {
        let t = try DelimitedText.table(data: Data("a,b\tc\n1\t2\n".utf8), fileName: "x.tsv")
        #expect(text(t, "A1") == "a,b" && text(t, "B1") == "c" && text(t, "B2") == "2")
    }

    @Test func csvEncodingsAndEmpty() throws {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("é,ü\n".data(using: .utf16LittleEndian)!)
        #expect(text(try DelimitedText.table(data: utf16, fileName: "u.csv"), "B1") == "ü")
        #expect(try DelimitedText.table(data: Data(), fileName: "e.csv").isEmpty)
        #expect(try DelimitedText.table(data: Data("\n\n".utf8), fileName: "e.csv").isEmpty)
        #expect(throws: SpreadsheetError.notText) {
            try DelimitedText.table(data: Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0, 0xFF, 0x00, 0x01, 0x00]), fileName: "zip.csv")
        }
    }

    @Test func csvCaps() throws {
        let csv = (1...3_000).map { "\($0),a,b,c" }.joined(separator: "\n") + "\n"
        let t = try DelimitedText.table(data: Data(csv.utf8), fileName: "big.csv", limits: SpreadsheetLimits(maxCells: 4_000, maxBytes: 64_000_000))
        #expect(t.truncated && t.rowCount == 1_000 && t.totalRows == 3_000)
        #expect(t.truncationNotice == "Showing the first 1,000 rows of 3,000.")
        let b = try DelimitedText.table(data: Data(csv.utf8), fileName: "big.csv", limits: SpreadsheetLimits(maxCells: 1_000_000, maxBytes: 1_000))
        #expect(b.truncated && b.totalRows == nil)
        #expect(b[b.rowCount - 1, 3]?.text == "c", "the last row shown is whole")
    }

    // MARK: Bundled samples

    private var samples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ios/Samples")
    }

    @Test func bundledSamples() throws {
        let multi = samples.appendingPathComponent("multi-sheet.xlsx")
        guard FileManager.default.fileExists(atPath: multi.path) else { return } // ios/Samples not reachable from this host
        let wb = try Workbook(url: multi)
        #expect(wb.sheets.count >= 2)
        #expect(try text(wb.table(at: 0), "A1") == "Owl")
        let csv = try DelimitedText.table(url: samples.appendingPathComponent("sample.csv"))
        #expect(text(csv, "A1") == "Owl")
        #expect(try text(Workbook(url: samples.appendingPathComponent("sample.xlsx")).table(at: 0), "A1") == "Owlink XLSX sample")
    }
}

/// A stored (uncompressed) zip, with real CRCs.
enum TestZip {
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
        }
        return ~c
    }

    static func make(_ entries: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: Int, _ d: inout Data) { le16(v & 0xFFFF, &d); le16((v >> 16) & 0xFFFF, &d) }
        for (name, body) in entries {
            let n = Data(name.utf8), crc = Int(crc32(body)), offset = out.count
            le32(0x0403_4B50, &out); le16(20, &out); le16(0, &out); le16(0, &out); le16(0, &out); le16(0, &out)
            le32(crc, &out); le32(body.count, &out); le32(body.count, &out); le16(n.count, &out); le16(0, &out)
            out.append(n); out.append(body)
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le16(0, &central); le32(crc, &central); le32(body.count, &central); le32(body.count, &central)
            le16(n.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le32(0, &central); le32(offset, &central); central.append(n)
        }
        let cdOffset = out.count
        out.append(central)
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out); le16(entries.count, &out); le16(entries.count, &out)
        le32(central.count, &out); le32(cdOffset, &out); le16(0, &out)
        return out
    }
}

/// A minimal OLE2 compound file: the header, one FAT sector, and a
/// directory sector naming the root and these streams (empty). Enough to
/// tell an encrypted OOXML package ("EncryptedPackage") from a legacy file.
enum TestCFB {
    static func make(streams: [String]) -> Data {
        var d = Data(OfficeFormat.oleMagic)
        func le16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
        d.append(Data(count: 16))            // CLSID
        le16(0x3E); le16(3); le16(0xFFFE)    // minor, major (v3), byte order
        le16(9); le16(6)                     // 512-byte sectors, 64-byte mini sectors
        d.append(Data(count: 10))            // reserved, directory sector count (0 in v3)
        le32(1)                              // FAT sectors
        le32(1)                              // first directory sector
        le32(0); le32(0x1000)                // transaction, mini stream cutoff
        le32(-2 & 0xFFFF_FFFF); le32(0)      // no mini FAT
        le32(-2 & 0xFFFF_FFFF); le32(0)      // no DIFAT sectors
        le32(0)                              // DIFAT[0]: the FAT is sector 0
        for _ in 1..<109 { le32(-1 & 0xFFFF_FFFF) }
        // Sector 0: the FAT (sector 0 FAT, 1 end of chain for the directory).
        var fat = Data()
        func f32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { fat.append(contentsOf: $0) } }
        f32(0xFFFF_FFFD); f32(0xFFFF_FFFE)
        while fat.count < 512 { f32(0xFFFF_FFFF) }
        d.append(fat)
        // Sector 1: the directory, 128 bytes an entry.
        var dir = Data()
        for (i, name) in (["Root Entry"] + streams).enumerated() {
            var e = Data()
            let u = Array(name.utf16)
            for c in u { e.append(UInt8(c & 0xFF)); e.append(UInt8(c >> 8)) }
            e.append(contentsOf: [0, 0])
            e.append(Data(count: 64 - e.count))
            let nameLen = (u.count + 1) * 2
            e.append(UInt8(nameLen & 0xFF)); e.append(UInt8(nameLen >> 8))
            e.append(i == 0 ? 5 : 2)                  // root storage, or stream
            e.append(1)                               // black
            func w32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { e.append(contentsOf: $0) } }
            w32(0xFFFF_FFFF)                          // left sibling
            w32(i > 0 && i < streams.count ? UInt32(i + 1) : 0xFFFF_FFFF) // right sibling
            w32(i == 0 && !streams.isEmpty ? 1 : 0xFFFF_FFFF)            // child
            e.append(Data(count: 16 + 4 + 16))        // CLSID, state, times
            w32(i == 0 ? 0xFFFF_FFFE : 0)             // start sector
            w32(0); w32(0)                            // size
            dir.append(e)
        }
        while dir.count < 512 { dir.append(Data(count: 1)) }
        d.append(dir)
        return d
    }
}
