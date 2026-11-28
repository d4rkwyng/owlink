import Foundation

/// CSV and TSV for the spreadsheet preview: an RFC 4180 parser (quoted
/// fields with embedded delimiters, doubled quotes and line breaks; CRLF,
/// LF or CR line ends) and a delimiter sniffer. It reads UTF-16 code
/// units, so offsets are the editor's (NSString) offsets. Pure and
/// thread-safe: the app parses on a background queue.
public enum CSV {
    /// The delimiters the sniffer picks from.
    public static let candidates: [UInt16] = [44, 9, 59, 124] // , tab ; |

    /// How a file is written, as the sniffer reads it.
    public struct Dialect: Sendable, Equatable {
        public var delimiter: UInt16
        /// Spaces after a delimiter (and at a line's start) aren't part of
        /// the field, and a quote after them opens a quoted field (Python's
        /// csv `skipinitialspace`): `name, age` and `x, "a, b"`. Never for tabs.
        public var skipInitialSpace: Bool
        /// Spaces before a delimiter (and at a line's end) aren't part of
        /// an unquoted field either: padded columns such as `a  | b`.
        public var trimTrailingSpace: Bool
        /// Every line starts and ends with the delimiter (`| a | b |`):
        /// the empty first and last fields are dropped, and a `|---|---|`
        /// rule row is skipped.
        public var edgeDelimiters: Bool
        /// The first line is Excel's `sep=;` hint: it isn't a record.
        public var skipFirstLine: Bool

        public init(delimiter: UInt16 = 44, skipInitialSpace: Bool = false, trimTrailingSpace: Bool = false,
                    edgeDelimiters: Bool = false, skipFirstLine: Bool = false) {
            self.delimiter = delimiter
            self.skipInitialSpace = skipInitialSpace
            self.trimTrailingSpace = trimTrailingSpace
            self.edgeDelimiters = edgeDelimiters
            self.skipFirstLine = skipFirstLine
        }
    }

    public struct Table: Sendable, Equatable {
        /// The records, in file order (the first is the header). Ragged
        /// rows are kept as they are; `columnCount` is the widest.
        public var rows: [[String]] = []
        /// Where each record starts (UTF-16 offset in the parsed text).
        public var rowStarts: [Int] = []
        /// The 0-based line each record starts on.
        public var rowLines: [Int] = []
        public var columnCount = 0
        /// Stopped at `maxRows` (or the text was cut short by the caller).
        public var truncated = false
        /// More fields existed than the caller chose to retain.
        public var truncatedColumns = false
        public var delimiter: UInt16 = 44
        public var dialect = Dialect()
        /// The 0-based line where a quoted field opens and never closes
        /// (the rest of the file is then one field, as in Excel and
        /// Python's csv), nil when every quote closes.
        public var unclosedQuoteLine: Int?

        public init() {}
    }

    /// The delimiter for a file (see `dialect(for:fileName:)`).
    public static func delimiter(for text: NSString, fileName: String? = nil) -> UInt16 {
        dialect(for: text, fileName: fileName).delimiter
    }

    /// How the file is written. The delimiter: an Excel `sep=X` first
    /// line, else tab for .tsv and .tab, pipe for .psv, else whichever of
    /// comma, tab, semicolon and pipe splits the first lines (quotes
    /// respected, blank lines ignored) into the same number of fields
    /// most often, more fields winning a tie; commas that are all decimal
    /// commas (`1,5;2,3`) lose to another consistent delimiter. Comma when
    /// nothing splits. Then whether spaces pad the fields (most delimiters
    /// followed, or preceded, by a space) and whether the lines are pipe
    /// tables. Reads at most the first 64 K characters (50 lines).
    public static func dialect(for text: NSString, fileName: String? = nil) -> Dialect {
        let total = text.length
        let n = min(total, 65_536)
        var i = 0
        if n > 0, text.character(at: 0) == 0xFEFF { i = 1 }
        var forced: UInt16?
        var skipFirst = false
        // Excel's hint: "sep=;" alone on the first line.
        if let (d, next) = sepHint(text, from: i, limit: n) { forced = d; skipFirst = true; i = next }
        if forced == nil, let ext = fileName.map({ ($0 as NSString).pathExtension.lowercased() }) {
            if ext == "tsv" || ext == "tab" { forced = 9 }
            if ext == "psv" { forced = 124 }
        }
        let cands = forced.map { [$0] } ?? candidates
        let k = cands.count
        var counts: [[Int]] = Array(repeating: [], count: k)
        var line = Array(repeating: 0, count: k)
        var spaceAfter = Array(repeating: 0, count: k), spaceBefore = Array(repeating: 0, count: k)
        var inner = Array(repeating: 0, count: k) // not at a line's end
        var decimalCommas = 0
        var edgeLines = 0, lines = 0
        var inQuotes = false
        var fieldStart = true // only spaces (or nothing) since the line start or a candidate
        var lineFirst: UInt16 = 0, lineLast: UInt16 = 0
        var blank = true
        func ch(_ j: Int) -> UInt16 { j < n ? text.character(at: j) : 0 }
        func endLine() {
            if !blank {
                for c in 0..<k { counts[c].append(line[c]) }
                lines += 1
                if lineFirst == 124 && lineLast == 124 { edgeLines += 1 }
            }
            line = Array(repeating: 0, count: k)
            blank = true
            fieldStart = true
            lineFirst = 0; lineLast = 0
        }
        while i < n && lines < 50 {
            let c = text.character(at: i)
            if inQuotes {
                if c == 34 {
                    if ch(i + 1) == 34 { i += 2; continue }
                    inQuotes = false
                }
                lineLast = c
                i += 1
                continue
            }
            if c == 10 || c == 13 {
                if c == 13, ch(i + 1) == 10 { i += 1 }
                endLine()
                i += 1
                continue
            }
            if c != 32 && c != 9 || cands.contains(c) {
                if blank { lineFirst = c }
                blank = false
                lineLast = c
            }
            if c == 34 && fieldStart {
                inQuotes = true
                fieldStart = false
            } else if let ci = cands.firstIndex(of: c) {
                line[ci] += 1
                let next = ch(i + 1)
                if next != 10 && next != 13 && i + 1 < n {
                    inner[ci] += 1
                    if next == 32 { spaceAfter[ci] += 1 }
                }
                if i > 0, text.character(at: i - 1) == 32 { spaceBefore[ci] += 1 }
                if c == 44, i > 0, isDigit(text.character(at: i - 1)), isDigit(next) { decimalCommas += 1 }
                fieldStart = true
            } else if c != 32 {
                fieldStart = false
            }
            i += 1
        }
        // The last line, if the text ends there (not cut at 64 K), or if it is all there is.
        if !blank && (n == total || lines == 0) { endLine() }

        struct Fit { var consistency = 0.0; var fields = 0; var total = 0 }
        var fits = Array(repeating: Fit(), count: k)
        for c in 0..<k {
            let cs = counts[c]
            guard !cs.isEmpty else { continue }
            var freq: [Int: Int] = [:]
            for v in cs where v > 0 { freq[v, default: 0] += 1 }
            // The most common non-zero count (the larger on a tie).
            guard let mode = freq.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }) else { continue }
            fits[c] = Fit(consistency: Double(mode.value) / Double(cs.count), fields: mode.key, total: cs.reduce(0, +))
        }
        var best: (score: Double, index: Int)? = nil
        for c in 0..<k where fits[c].fields > 0 {
            var score = fits[c].consistency * 1000 + Double(min(fits[c].fields, 999))
            // Decimal commas: every comma between digits, and another delimiter fits.
            if cands[c] == 44, fits[c].total > 0, decimalCommas * 10 >= fits[c].total * 9,
               fits.indices.contains(where: { $0 != c && fits[$0].fields > 0 && fits[$0].consistency >= 0.8 }) {
                score -= 2000
            }
            if best == nil || score > best!.score { best = (score, c) }
        }
        let ci = best?.index
        var d = Dialect(delimiter: ci.map { cands[$0] } ?? forced ?? 44, skipFirstLine: skipFirst)
        if let ci, d.delimiter != 9 {
            // "Comma followed by space", consistently: 60 % of the delimiters inside lines.
            d.skipInitialSpace = inner[ci] > 0 && spaceAfter[ci] * 10 >= inner[ci] * 6
            d.trimTrailingSpace = fits[ci].total > 0 && spaceBefore[ci] * 10 >= fits[ci].total * 6
            d.edgeDelimiters = d.delimiter == 124 && lines > 0 && edgeLines == lines
            if d.edgeDelimiters { d.skipInitialSpace = true; d.trimTrailingSpace = true }
        }
        return d
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    /// `sep=X` (one character, then the line's end) at `from`: X and where the next line starts.
    private static func sepHint(_ text: NSString, from: Int, limit: Int) -> (UInt16, Int)? {
        guard limit - from >= 5 else { return nil }
        let head = text.substring(with: NSRange(location: from, length: 4)).lowercased()
        guard head == "sep=" else { return nil }
        let d = text.character(at: from + 4)
        guard d != 10 && d != 13 else { return nil }
        var j = from + 5
        if j < limit {
            // The hint is the whole line.
            guard text.character(at: j) == 10 || text.character(at: j) == 13 else { return nil }
            if text.character(at: j) == 13 { j += 1 }
            if j < limit, text.character(at: j) == 10 { j += 1 }
        }
        return (d, j)
    }

    /// Parses `text` (all of it, or the first `maxRows` records). Blank
    /// lines are skipped.
    public static func parse(_ text: NSString, delimiter: UInt16 = 44, maxRows: Int = .max) -> Table {
        parse(text, dialect: Dialect(delimiter: delimiter), maxRows: maxRows)
    }

    /// `stopUnclosedQuoteAtLineEnd` (the preview grid): a quoted field that
    /// never closes ends at its line's end instead of swallowing the rest
    /// of the file, so the rows after it still show (the warning says where).
    public static func parse(_ text: NSString, dialect: Dialect, maxRows: Int = .max,
                             stopUnclosedQuoteAtLineEnd: Bool = false, maxColumns: Int = .max,
                             maxCells: Int = .max) -> Table {
        let n = text.length
        var buf = [UInt16](repeating: 0, count: n)
        text.getCharacters(&buf, range: NSRange(location: 0, length: n))
        return parse(buf, dialect: dialect, maxRows: maxRows,
                     stopUnclosedQuoteAtLineEnd: stopUnclosedQuoteAtLineEnd, maxColumns: maxColumns, maxCells: maxCells)
    }

    public static func parse(_ u: [UInt16], delimiter d: UInt16 = 44, maxRows: Int = .max) -> Table {
        parse(u, dialect: Dialect(delimiter: d), maxRows: maxRows)
    }

    public static func parse(_ u: [UInt16], dialect: Dialect, maxRows: Int = .max,
                             stopUnclosedQuoteAtLineEnd: Bool = false, maxColumns: Int = .max,
                             maxCells: Int = .max) -> Table {
        var t = Table()
        let d = dialect.delimiter
        t.delimiter = d
        t.dialect = dialect
        let skipSpace = dialect.skipInitialSpace && d != 32
        let trimEnd = dialect.trimTrailingSpace && d != 32
        let n = u.count
        var i = 0
        var line = 0
        if n > 0, u[0] == 0xFEFF { i = 1 } // a byte-order mark
        if dialect.skipFirstLine {
            while i < n, u[i] != 10, u[i] != 13 { i += 1 }
            if i < n, u[i] == 13 { i += 1 }
            if i < n, u[i] == 10 { i += 1 }
            line = 1
        }
        var field: [UInt16] = []
        field.reserveCapacity(64)
        var row: [String] = []
        var remaining = maxCells
        while i < n {
            if t.rows.count >= maxRows { t.truncated = true; break }
            let rowStart = i, rowLine = line
            row.removeAll(keepingCapacity: true)
            var sawQuote = false
            // One record.
            while true {
                field.removeAll(keepingCapacity: true)
                if skipSpace { while i < n, u[i] == 32 { i += 1 } }
                var kept = 0 // characters of a quoted field, never trimmed
                if i < n, u[i] == 34 {
                    // Quoted: up to the closing quote; "" is a quote.
                    sawQuote = true
                    i += 1
                    let open = i, openLine = line
                    var closed = false
                    while i < n {
                        let c = u[i]
                        if c == 34 {
                            if i + 1 < n, u[i + 1] == 34 { field.append(34); i += 2; continue }
                            i += 1
                            closed = true
                            break
                        }
                        if c == 10 || (c == 13 && !(i + 1 < n && u[i + 1] == 10)) { line += 1 }
                        field.append(c)
                        i += 1
                    }
                    if !closed {
                        if t.unclosedQuoteLine == nil { t.unclosedQuoteLine = openLine }
                        if stopUnclosedQuoteAtLineEnd {
                            // Back to the quote: the field is the rest of its line.
                            i = open
                            line = openLine
                            field.removeAll(keepingCapacity: true)
                            while i < n, u[i] != 10, u[i] != 13 { field.append(u[i]); i += 1 }
                        }
                    }
                    kept = field.count
                }
                // Unquoted (or what follows a closing quote, kept as is).
                while i < n {
                    let c = u[i]
                    if c == d || c == 10 || c == 13 { break }
                    field.append(c)
                    i += 1
                }
                // Padding after a closing quote, or (padded columns) after an unquoted field.
                if kept > 0 && skipSpace || trimEnd {
                    while field.count > kept, field.last == 32 { field.removeLast() }
                }
                if row.count < max(1, maxColumns) {
                    if row.count >= remaining && !dialect.edgeDelimiters {
                        if row.count > 0 || sawQuote || !field.allSatisfy({ $0 == 32 || $0 == 9 }) || (i < n && u[i] == d) {
                            t.truncated = true
                            return t
                        }
                    }
                    row.append(String(decoding: field, as: UTF16.self))
                } else {
                    t.truncatedColumns = true
                }
                if i >= n { break }
                let c = u[i]
                i += 1
                if c == d { continue }
                // Line end: CRLF, LF or CR.
                if c == 13, i < n, u[i] == 10 { i += 1 }
                line += 1
                break
            }
            // A blank line (spaces only, too).
            if row.count == 1 && !sawQuote && row[0].allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
            if dialect.edgeDelimiters {
                if row.count > 1, row[0].isEmpty { row.removeFirst() }
                if row.count > 1, row[row.count - 1].isEmpty { row.removeLast() }
                if !sawQuote, row.allSatisfy(isRule) { continue } // |---|:--:|
            }
            guard row.count <= remaining else { t.truncated = true; break }
            remaining -= row.count
            t.rows.append(row)
            t.rowStarts.append(rowStart)
            t.rowLines.append(rowLine)
            t.columnCount = max(t.columnCount, row.count)
        }
        return t
    }

    /// A pipe table's rule cell: `---`, `:--`, `:-:`.
    private static func isRule(_ s: String) -> Bool {
        let core = s.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return !core.isEmpty && core.allSatisfy { $0 == "-" }
    }

    /// Where field `column` of the record starting at `rowStart` begins
    /// (inside its quotes for a quoted field), for putting the caret
    /// there. Past the last field: the record's end.
    public static func fieldOffset(in text: NSString, rowStart: Int, column: Int, delimiter d: UInt16) -> Int {
        fieldOffset(in: text, rowStart: rowStart, column: column, dialect: Dialect(delimiter: d))
    }

    /// The same, for the grid's column `column` in `dialect` (after its
    /// padding; a pipe table's dropped first field counted).
    public static func fieldOffset(in text: NSString, rowStart: Int, column: Int, dialect: Dialect) -> Int {
        let d = dialect.delimiter
        let skipSpace = dialect.skipInitialSpace && d != 32
        let n = text.length
        var i = max(0, min(rowStart, n))
        var target = column
        if dialect.edgeDelimiters {
            var j = i
            while j < n, text.character(at: j) == 32 { j += 1 }
            if j < n, text.character(at: j) == d { target += 1 }
        }
        var col = 0
        var inQuotes = false
        var fieldStart = i
        var atStart = true // only padding since fieldStart
        while i < n {
            let c = text.character(at: i)
            if c == 34 && (inQuotes || atStart && (i == fieldStart || skipSpace)) {
                if inQuotes, i + 1 < n, text.character(at: i + 1) == 34 { i += 2; continue }
                inQuotes.toggle()
                atStart = false
            } else if !inQuotes {
                if c == 10 || c == 13 { break }
                if c == d {
                    if col == target { break }
                    col += 1
                    fieldStart = i + 1
                    atStart = true
                } else if c != 32 {
                    atStart = false
                }
            }
            i += 1
        }
        guard col == target else { return i }
        var p = fieldStart
        if skipSpace { while p < n, text.character(at: p) == 32 { p += 1 } }
        if p < n, text.character(at: p) == 34 { return p + 1 }
        return p
    }

    /// Compares two cells for sorting: as numbers when both are, else
    /// in Finder order (numbers inside text by value, case-insensitive).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ta = a.trimmingCharacters(in: .whitespaces), tb = b.trimmingCharacters(in: .whitespaces)
        if let x = Double(ta), let y = Double(tb) { return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        return ta.localizedStandardCompare(tb)
    }

    /// The data rows' order (indexes into `rows`, header excluded) sorted
    /// by `column`. Stable: equal cells keep file order.
    public static func sortedOrder(_ rows: [[String]], column: Int, ascending: Bool) -> [Int] {
        let idx = Array(rows.indices.dropFirst())
        return idx.sorted { i, j in
            let a = column < rows[i].count ? rows[i][column] : ""
            let b = column < rows[j].count ? rows[j][column] : ""
            // Blank cells last, either way.
            let ba = a.allSatisfy(\.isWhitespace), bb = b.allSatisfy(\.isWhitespace)
            if ba != bb { return bb }
            let r = compare(a, b)
            if r == .orderedSame { return i < j }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}
