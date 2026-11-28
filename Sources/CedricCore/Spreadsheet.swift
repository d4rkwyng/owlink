import Foundation

// The read-only spreadsheet grid's model (Owlink for iPhone and iPad):
// an .xlsx / .xlsm workbook's sheets, or a CSV / TSV file, as cells to
// show. Read with ZipArchive, Foundation's XMLParser and `CSV`; nothing
// here writes. Each sheet stops at a cap (`SpreadsheetLimits`) and says so.

/// How much of a sheet is read: at most `maxCells` cells (whole rows), and
/// at most `maxBytes` of a sheet's XML (or a CSV file) looked at.
public struct SpreadsheetLimits: Sendable, Equatable {
    public var maxCells: Int
    public var maxBytes: Int

    public init(maxCells: Int, maxBytes: Int) {
        self.maxCells = maxCells
        self.maxBytes = maxBytes
    }

    /// 100,000 cells; 64 MB of sheet XML or CSV.
    public static let standard = SpreadsheetLimits(maxCells: 100_000, maxBytes: 64_000_000)
    /// Excel's widest sheet (XFD): cells past it are ignored.
    public static let maxColumns = 16_384
    static let maxRows = 1_048_576

    static func rowIndex(attribute: String?, previous: Int) -> Int? {
        if let attribute {
            guard let value = Int(attribute), (1...maxRows).contains(value) else { return nil }
            return value - 1
        }
        guard (-1..<(maxRows - 1)).contains(previous) else { return nil }
        return previous + 1
    }
}

public enum SpreadsheetError: Error, Equatable, Sendable {
    /// Not a zip, a damaged zip, or a zip that isn't a workbook.
    case notAWorkbook
    /// An encrypted workbook (an OLE2 container with an EncryptedPackage).
    case passwordProtected
    /// The workbook names a sheet whose part is missing or unreadable.
    case damaged
    /// A CSV / TSV file that isn't text.
    case notText
}

public struct SpreadsheetCell: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case text, number, boolean, error, date }
    public var text: String
    public var kind: Kind

    public init(_ text: String, kind: Kind = .text) {
        self.text = text
        self.kind = kind
    }

    /// Numbers, dates and booleans line up on the right, as in Excel.
    public var alignsRight: Bool { kind == .number || kind == .date }
}

/// One sheet's cells, sparse (a far cell doesn't make a big grid).
public struct SpreadsheetTable: Sendable, Equatable {
    public var name: String
    /// Rows and columns to show: through the last row and column with a value.
    public private(set) var rowCount = 0
    public private(set) var columnCount = 0
    public private(set) var cellCount = 0
    /// Rows were left out (a cap).
    public var truncated = false
    /// When truncated: the rows the sheet has, if known.
    public var totalRows: Int?
    public var truncatedColumns = false
    private var rows: [Int: [Int: SpreadsheetCell]] = [:]

    public init(name: String) { self.name = name }

    public subscript(row: Int, column: Int) -> SpreadsheetCell? { rows[row]?[column] }

    public var isEmpty: Bool { cellCount == 0 }

    /// The cells of one row, by column.
    public func row(_ r: Int) -> [Int: SpreadsheetCell] { rows[r] ?? [:] }

    mutating func set(_ cell: SpreadsheetCell, row: Int, column: Int) {
        if rows[row]?[column] == nil { cellCount += 1 }
        rows[row, default: [:]][column] = cell
        rowCount = max(rowCount, row + 1)
        columnCount = max(columnCount, column + 1)
    }

    /// "Showing the first 500 rows of 2,000." when rows were left out.
    public var truncationNotice: String? {
        let columns = truncatedColumns ? String(localized: "Showing the first 16,384 columns.") : ""
        guard truncated else { return columns.isEmpty ? nil : columns }
        let suffix = columns.isEmpty ? "" : " " + columns
        let shown = Self.grouped(rowCount)
        if let totalRows, totalRows > rowCount {
            return String(localized: "Showing the first \(shown) rows of \(Self.grouped(totalRows)).") + suffix
        }
        return String(localized: "Showing the first \(shown) rows.") + suffix
    }

    /// 12345 → "12,345" (US English, whatever the device's region).
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(abs(n)))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// 0 → "A", 25 → "Z", 26 → "AA", 16383 → "XFD".
    public static func columnName(_ index: Int) -> String {
        var n = index + 1
        var s: [Character] = []
        while n > 0 {
            let r = (n - 1) % 26
            s.append(Character(UnicodeScalar(UInt8(65 + r))))
            n = (n - 1) / 26
        }
        return String(s.reversed())
    }

    /// (row 2, column 1) → "B3".
    public static func cellName(row: Int, column: Int) -> String { columnName(column) + String(row + 1) }
}

// MARK: Workbook (.xlsx, .xlsm)

public struct Workbook: Sendable {
    public struct Sheet: Sendable, Equatable {
        public var name: String
        /// The sheet's part in the zip ("xl/worksheets/sheet1.xml"); nil when unknown.
        public var path: String?
        public var isHidden: Bool
        /// A chart sheet: no cells.
        public var isChart: Bool
    }

    public let sheets: [Sheet]
    /// The workbook counts dates from 1904 (old Mac Excel), not 1900.
    public let date1904: Bool
    private let zip: ZipArchive
    private let shared: [String]
    private let styles: [NumberStyle]

    public init(url: URL, limits: SpreadsheetLimits = .standard) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    public init(data: Data, limits: SpreadsheetLimits = .standard) throws {
        if Array(data.prefix(8)) == OfficeFormat.oleMagic {
            throw Self.isEncryptedPackage(data) ? SpreadsheetError.passwordProtected : SpreadsheetError.notAWorkbook
        }
        guard let zip = try? ZipArchive(data: data) else { throw SpreadsheetError.notAWorkbook }
        self.zip = zip
        guard let workbookEntry = zip.entry("xl/workbook.xml") else {
            // No workbook part: a workbook only if it still has sheets.
            let parts = zip.entries.map(\.name).filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            guard !parts.isEmpty else { throw SpreadsheetError.notAWorkbook }
            sheets = parts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.enumerated().map { i, p in
                Sheet(name: "Sheet\(i + 1)", path: p, isHidden: false, isChart: false)
            }
            date1904 = false
            shared = try Self.sharedStrings(zip, limits: limits)
            styles = try Self.numberStyles(zip, limits: limits)
            return
        }
        let wb = try Self.metadata(zip, entry: workbookEntry, limits: limits)
        let rels = try zip.entry("xl/_rels/workbook.xml.rels").map { try Self.metadata(zip, entry: $0, limits: limits) }.map { XMLScan.elements($0, named: "Relationship") } ?? []
        var targets: [String: String] = [:]
        for r in rels {
            if let id = r["Id"], let t = r["Target"] { targets[id] = t }
        }
        var list: [Sheet] = []
        for (i, s) in XMLScan.elements(wb, named: "sheet").enumerated() {
            let rid = s.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value
            let path = rid.flatMap { targets[$0] }.map { t in
                XLSXSheet.normalize(t.hasPrefix("/") ? String(t.dropFirst()) : "xl/" + t)
            }
            let state = s["state"] ?? "visible"
            list.append(Sheet(name: s["name"] ?? "Sheet\(i + 1)", path: path,
                              isHidden: state == "hidden" || state == "veryHidden",
                              isChart: path?.contains("chartsheets/") ?? false))
        }
        if list.isEmpty {
            throw SpreadsheetError.notAWorkbook
        }
        sheets = list
        let pr = XMLScan.elements(wb, named: "workbookPr").first?["date1904"]?.lowercased()
        date1904 = pr == "1" || pr == "true"
        shared = try Self.sharedStrings(zip, limits: limits)
        styles = try Self.numberStyles(zip, limits: limits)
    }

    /// An OLE2 compound file holding an "EncryptedPackage" stream (its
    /// directory names are UTF-16): how Office saves an .xlsx with a
    /// password to open.
    static func isEncryptedPackage(_ data: Data) -> Bool {
        let name = Data("EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return data.range(of: name) != nil
    }

    static func sharedStrings(_ zip: ZipArchive, limits: SpreadsheetLimits) throws -> [String] {
        guard let e = zip.entry("xl/sharedStrings.xml") else { return [] }
        guard let d = try? zip.prefix(of: e, maxBytes: limits.maxBytes) else { throw SpreadsheetError.damaged }
        return XLSXSheet.sharedStrings(d.data)
    }

    private static func metadata(_ zip: ZipArchive, entry: ZipArchive.Entry, limits: SpreadsheetLimits) throws -> Data {
        do { return try zip.contents(of: entry, maxBytes: limits.maxBytes) }
        catch { throw SpreadsheetError.damaged }
    }

    static func numberStyles(_ zip: ZipArchive, limits: SpreadsheetLimits) throws -> [NumberStyle] {
        guard let entry = zip.entry("xl/styles.xml") else { return [] }
        let d = try metadata(zip, entry: entry, limits: limits)
        let p = StylesParser()
        let x = XMLParser(data: d)
        x.delegate = p
        x.parse()
        return p.xfs.map { id in
            if let code = p.custom[id] { return NumberStyle(code: code) }
            return NumberStyle(builtIn: id)
        }
    }

    /// The sheet at `index` (in workbook order), read up to `limits`.
    public func table(at index: Int, limits: SpreadsheetLimits = .standard) throws -> SpreadsheetTable {
        let sheet = sheets[index]
        var table = SpreadsheetTable(name: sheet.name)
        if sheet.isChart { return table }
        guard let path = sheet.path, let e = zip.entry(path), let (xml, cut) = try? zip.prefix(of: e, maxBytes: limits.maxBytes) else {
            throw SpreadsheetError.damaged
        }
        let p = SheetReader(shared: shared, styles: styles, date1904: date1904, maxCells: limits.maxCells)
        let x = XMLParser(data: xml)
        x.delegate = p
        p.parser = x
        // Not a worksheet at all (and not cut short by a cap).
        let parsed = x.parse()
        if p.invalidCoordinate { throw SpreadsheetError.damaged }
        if !parsed, !cut, !p.stoppedEarly, !p.sawSheetData { throw SpreadsheetError.damaged }
        for (r, cells) in p.committed {
            for (c, cell) in cells { table.set(cell, row: r, column: c) }
        }
        if p.capped || cut {
            table.truncated = true
            if let dim = p.dimensionRows {
                table.totalRows = dim
            } else if !cut {
                table.totalRows = p.lastRow + 1
            }
        }
        return table
    }
}

extension ZipArchive {
    /// The first `maxBytes` of an entry, inflated, and whether that was
    /// less than all of it. A deflated entry is only inflated that far.
    func prefix(of e: Entry, maxBytes: Int) throws -> (data: Data, truncated: Bool) {
        (try inflatedPrefix(of: e, maxBytes: maxBytes), e.size > maxBytes)
    }
}

/// A number format, as far as showing a value needs: a date or time, a
/// percent, or as stored (Excel's General).
struct NumberStyle: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case general, percent(decimals: Int), date(date: Bool, time: Bool, seconds: Bool) }
    var kind: Kind

    init(kind: Kind) { self.kind = kind }

    /// Excel's built-in formats (ids below 164).
    init(builtIn id: Int) {
        switch id {
        case 9: kind = .percent(decimals: 0)
        case 10: kind = .percent(decimals: 2)
        case 14, 15, 16, 17: kind = .date(date: true, time: false, seconds: false)
        case 18, 20: kind = .date(date: false, time: true, seconds: false)
        case 19, 21, 45, 46, 47: kind = .date(date: false, time: true, seconds: true)
        case 22: kind = .date(date: true, time: true, seconds: false)
        case 27...36, 50...58: kind = .date(date: true, time: false, seconds: false) // East Asian dates
        default: kind = .general
        }
    }

    /// A custom format code: the first section, with quoted text,
    /// escapes and bracketed parts (colors, locales; but [h] [m] [s] are
    /// elapsed time) left out.
    init(code: String) {
        var plain = ""
        var it = code.makeIterator()
        var section = ""
        while let ch = it.next() {
            if ch == ";" { break }
            section.append(ch)
        }
        var chars = Array(section)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\"":
                i += 1
                while i < chars.count, chars[i] != "\"" { i += 1 }
            case "\\", "_", "*":
                i += 1 // the next character is literal (or padding)
            case "[":
                var inner = ""
                i += 1
                while i < chars.count, chars[i] != "]" { inner.append(chars[i]); i += 1 }
                let l = inner.lowercased()
                if !l.isEmpty, l.allSatisfy({ $0 == "h" || $0 == "m" || $0 == "s" }) { plain += l }
            default:
                plain.append(ch)
            }
            i += 1
        }
        chars = Array(plain.lowercased())
        let hasY = chars.contains("y"), hasD = chars.contains("d"), hasH = chars.contains("h"), hasS = chars.contains("s")
        let hasM = chars.contains("m")
        if hasY || hasD || hasH || hasS || (hasM && !chars.contains("0") && !chars.contains("#")) {
            let time = hasH || hasS
            kind = .date(date: hasY || hasD || (hasM && !time), time: time, seconds: hasS)
        } else if plain.contains("%") {
            let decimals = plain.split(separator: ".").dropFirst().first.map { $0.filter { $0 == "0" }.count } ?? 0
            kind = decimals <= 15 ? .percent(decimals: decimals) : .general
        } else {
            kind = .general
        }
    }

    static let general = NumberStyle(kind: .general)
    /// 9999-12-31, Excel's last date (1900 system).
    static let maxSerial = 2_958_465.0

    /// A stored number as this format shows it.
    func display(_ raw: String, date1904: Bool) -> SpreadsheetCell {
        guard let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite else { return SpreadsheetCell(raw, kind: .number) }
        switch kind {
        case .general:
            return SpreadsheetCell(Self.general(v), kind: .number)
        case .percent(let decimals):
            return SpreadsheetCell(String(format: "%.\(decimals)f%%", v * 100), kind: .number)
        case let .date(date, time, seconds):
            // Outside Excel's dates (it shows ####): the number itself.
            let lastDay = date1904 ? 2_957_003.0 : Self.maxSerial
            guard v >= 0, (v * 86_400).rounded() < (lastDay + 1) * 86_400 else { return SpreadsheetCell(Self.general(v), kind: .number) }
            return SpreadsheetCell(Self.dateText(serial: v, date1904: date1904, date: date, time: time, seconds: seconds), kind: .date)
        }
    }

    /// Excel's General: whole numbers as integers, others to 15 significant digits.
    static func general(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.15g", v)
        if s.contains("e") { s = s.replacingOccurrences(of: "e", with: "E") }
        return s
    }

    /// A serial date as "2024-03-15", "2024-03-15 12:00" or "18:00:00".
    static func dateText(serial: Double, date1904: Bool, date: Bool, time: Bool, seconds: Bool) -> String {
        var totalSeconds = Int64((min(max(serial, 0), maxSerial + 1) * 86_400).rounded())
        if totalSeconds < 0 { totalSeconds = 0 }
        var day = Int(totalSeconds / 86_400)
        let secs = Int(totalSeconds % 86_400)
        var parts: [String] = []
        if date || !time {
            if !date1904 && day == 60 {
                parts.append("1900-02-29") // Lotus 1-2-3's leap day, kept by Excel
            } else {
                // Days since 1970-01-01.
                if date1904 {
                    day -= 24_107
                } else {
                    day -= day < 60 ? 25_568 : 25_569
                }
                parts.append(civil(day))
            }
        }
        if time {
            let h = secs / 3600, m = secs / 60 % 60, s = secs % 60
            parts.append(seconds ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", h, m))
        }
        return parts.joined(separator: " ")
    }

    /// Days since 1970-01-01 → "yyyy-mm-dd" (proleptic Gregorian; no time
    /// zone or calendar setting involved).
    static func civil(_ days: Int) -> String {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

private func localName(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
}

/// styles.xml: the custom number formats, and each cellXfs entry's format id.
private final class StylesParser: NSObject, XMLParserDelegate {
    var custom: [Int: String] = [:]
    var xfs: [Int] = []
    private var inCellXfs = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch localName(name) {
        case "numFmt":
            if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { custom[id] = code }
        case "cellXfs": inCellXfs = true
        case "xf" where inCellXfs: xfs.append(a["numFmtId"].flatMap(Int.init) ?? 0)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if localName(name) == "cellXfs" { inCellXfs = false }
    }
}

/// A worksheet's cells, a row at a time: a row is kept only when it is
/// whole (its </row> was read) and fits under the cell cap. Past the cap
/// the rows are only counted.
private final class SheetReader: NSObject, XMLParserDelegate {
    let shared: [String]
    let styles: [NumberStyle]
    let date1904: Bool
    let maxCells: Int
    weak var parser: XMLParser?

    var committed: [(Int, [(Int, SpreadsheetCell)])] = []
    var cellTotal = 0
    var capped = false
    var stoppedEarly = false
    var invalidCoordinate = false
    var sawSheetData = false
    var dimensionRows: Int?
    var lastRow = -1

    private var row = -1, col = -1, nextCol = 0
    private var pending: [(Int, SpreadsheetCell)] = []
    private var type = "n", style = 0
    private var value: String?, inline: String?
    private var inV = false, inIS = false, inT = false, inRPh = false
    private var text = ""

    init(shared: [String], styles: [NumberStyle], date1904: Bool, maxCells: Int) {
        self.shared = shared
        self.styles = styles
        self.date1904 = date1904
        self.maxCells = maxCells
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch localName(name) {
        case "dimension":
            // "A1:J2000" → 2000 rows ("A1" alone: one cell, or an empty sheet).
            if let ref = a["ref"], let last = ref.split(separator: ":").last, let r = XLSXSheet.cellRef(String(last)) {
                dimensionRows = ref.contains(":") ? r.row + 1 : nil
            }
        case "sheetData": sawSheetData = true
        case "row":
            guard let index = SpreadsheetLimits.rowIndex(attribute: a["r"], previous: row) else {
                invalidCoordinate = true
                parser.abortParsing()
                return
            }
            row = index
            nextCol = 0
            pending.removeAll(keepingCapacity: true)
        case "c":
            if let r = a["r"] {
                guard let ref = XLSXSheet.cellRef(r) else {
                    invalidCoordinate = true
                    parser.abortParsing()
                    return
                }
                row = ref.row
                col = ref.col
            } else {
                guard row >= 0, nextCol < SpreadsheetLimits.maxColumns else {
                    invalidCoordinate = true
                    parser.abortParsing()
                    return
                }
                col = nextCol
            }
            nextCol = col + 1
            type = a["t"] ?? "n"
            style = a["s"].flatMap(Int.init) ?? 0
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
        switch localName(name) {
        case "v": inV = false; value = text
        case "t": inT = false
        case "is": inIS = false
        case "rPh": inRPh = false
        case "c":
            guard !capped, row >= 0, col >= 0, col < SpreadsheetLimits.maxColumns, let cell = cell() else { return }
            guard pending.count < maxCells - cellTotal else {
                capped = true
                pending.removeAll()
                if dimensionRows != nil { stoppedEarly = true; parser.abortParsing() }
                return
            }
            pending.append((col, cell))
        case "row":
            guard row >= 0 else { return }
            lastRow = max(lastRow, row)
            if capped { return }
            if pending.isEmpty { return }
            if cellTotal + pending.count > maxCells {
                capped = true
                // The total is known: nothing left to read.
                if dimensionRows != nil { stoppedEarly = true; parser.abortParsing() }
                return
            }
            cellTotal += pending.count
            committed.append((row, pending))
            pending = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capped { return }
        if inV { text += string } else if inT { inline? += string }
    }

    private func cell() -> SpreadsheetCell? {
        let out: SpreadsheetCell?
        switch type {
        case "s": out = value.flatMap { Int($0) }.flatMap { $0 >= 0 && $0 < shared.count ? SpreadsheetCell(shared[$0]) : nil }
        case "inlineStr": out = (inline ?? value).map { SpreadsheetCell($0) }
        case "str": out = value.map { SpreadsheetCell($0) }
        case "b": out = value.map { SpreadsheetCell($0 == "1" || $0.lowercased() == "true" ? "TRUE" : "FALSE", kind: .boolean) }
        case "e": out = value.map { SpreadsheetCell($0, kind: .error) }
        case "d": out = value.map { SpreadsheetCell($0, kind: .date) }
        default:
            let st = style >= 0 && style < styles.count ? styles[style] : .general
            out = value.map { st.display($0, date1904: date1904) }
        }
        guard let out, !out.text.isEmpty else { return nil }
        return out
    }
}

// MARK: CSV and TSV

/// A CSV / TSV file as a grid, through `CSV` (its delimiter detection and
/// RFC 4180 quoting), with the same caps as a sheet.
public enum DelimitedText {
    public static func table(url: URL, limits: SpreadsheetLimits = .standard) throws -> SpreadsheetTable {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let data = try h.read(upToCount: limits.maxBytes + 1) ?? Data()
        return try table(data: data, fileName: url.lastPathComponent, limits: limits)
    }

    /// `data` longer than `limits.maxBytes` is read up to its last line
    /// break before the cap.
    public static func table(data: Data, fileName: String, limits: SpreadsheetLimits = .standard) throws -> SpreadsheetTable {
        var bytes = data
        var cut = false
        if bytes.count > limits.maxBytes {
            cut = true
            bytes = bytes.prefix(limits.maxBytes)
            if let nl = bytes.lastIndex(of: 0x0A) { bytes = bytes[bytes.startIndex...nl] }
        }
        var t = SpreadsheetTable(name: fileName)
        if bytes.isEmpty { return t }
        guard let decoded = TextCodec.decode(Data(bytes)), !decoded.looksBinary else { throw SpreadsheetError.notText }
        let text = decoded.text as NSString
        // Every record holds at least one cell: no more than the cap's
        // worth of records is parsed (the rest are only counted).
        let parsed = CSV.parse(text, dialect: CSV.dialect(for: text, fileName: fileName), maxRows: limits.maxCells + 1,
                               stopUnclosedQuoteAtLineEnd: true, maxColumns: SpreadsheetLimits.maxColumns, maxCells: limits.maxCells)
        t.truncatedColumns = parsed.truncatedColumns
        for (r, fields) in parsed.rows.enumerated() {
            for (c, f) in fields.enumerated() where !f.isEmpty {
                let isNumber = Double(f.trimmingCharacters(in: .whitespaces)) != nil
                t.set(SpreadsheetCell(f, kind: isNumber ? .number : .text), row: r, column: c)
            }
        }
        // Every record shown counts, so an empty last row (",,") and
        // trailing empty columns still show.
        t.pad(rows: parsed.rows.count, columns: parsed.columnCount)
        if parsed.truncated || cut { t.truncated = true }
        if t.truncated, !cut {
            t.totalRows = parsed.truncated ? records(text, quote: 0x22) : parsed.rows.count
        }
        return t
    }

    /// Records in `text` (blank lines skipped, line breaks inside quotes
    /// not counted), without keeping them.
    static func records(_ text: NSString, quote: UInt16) -> Int {
        let n = text.length
        var buf = [UInt16](repeating: 0, count: n)
        text.getCharacters(&buf, range: NSRange(location: 0, length: n))
        var count = 0, inQuotes = false, blank = true
        for u in buf {
            if u == quote { inQuotes.toggle(); blank = false; continue }
            if !inQuotes, u == 10 || u == 13 {
                if !blank { count += 1 }
                blank = true
            } else if u != 0xFEFF {
                blank = false
            }
        }
        return blank ? count : count + 1
    }
}

extension SpreadsheetTable {
    mutating func pad(rows: Int, columns: Int) {
        rowCount = max(rowCount, rows)
        if rows > 0 { columnCount = max(columnCount, columns) }
    }
}
