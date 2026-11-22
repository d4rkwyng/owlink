import Foundation
import Testing
@testable import CedricCore

@Suite struct CSVTests {
    func rows(_ s: String, _ d: UInt16 = 44) -> [[String]] { CSV.parse(s as NSString, delimiter: d).rows }

    @Test func plainRecords() {
        #expect(rows("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
        #expect(rows("a,b\n1,2") == [["a", "b"], ["1", "2"]]) // no final newline
        #expect(rows("a,,c\n,\n") == [["a", "", "c"], ["", ""]])
    }

    @Test func quotedFieldsWithDelimitersQuotesAndNewlines() {
        let t = CSV.parse("name,note\n\"Smith, J\",\"said \"\"hi\"\"\"\n\"two\nlines\",x\nlast,\"\"\n" as NSString)
        #expect(t.rows == [["name", "note"], ["Smith, J", "said \"hi\""], ["two\nlines", "x"], ["last", ""]])
        // Each record's first line, counting the line break inside the quotes.
        #expect(t.rowLines == [0, 1, 2, 4])
        #expect(t.columnCount == 2)
    }

    @Test func crlfAndCrLineEnds() {
        #expect(rows("a,b\r\n1,2\r\n") == [["a", "b"], ["1", "2"]])
        #expect(rows("a,b\r1,2\r") == [["a", "b"], ["1", "2"]])
        #expect(rows("\"x\r\ny\",z\r\n") == [["x\r\ny", "z"]])
    }

    @Test func raggedRowsAndBlankLines() {
        let t = CSV.parse("a,b,c\n1\n\n1,2,3,4\n\n" as NSString)
        #expect(t.rows == [["a", "b", "c"], ["1"], ["1", "2", "3", "4"]])
        #expect(t.columnCount == 4)
        #expect(t.rowLines == [0, 1, 3])
        // A quoted empty field is a record, not a blank line.
        #expect(rows("a\n\"\"") == [["a"], [""]])
    }

    @Test func quoteInsideAnUnquotedFieldIsLiteral() {
        #expect(rows("5\" disk,ok\n") == [["5\" disk", "ok"]])
        #expect(rows("\"a\"b,c\n") == [["ab", "c"]]) // text after a closing quote is kept
        #expect(rows("\"never closed,x\n") == [["never closed,x\n"]])
    }

    @Test func rowStartsAreEditorOffsets() {
        let text = "h1,h2\n\"é,\nx\",2\nlast,3\n" as NSString
        let t = CSV.parse(text)
        #expect(t.rowStarts == [0, 6, text.range(of: "last").location])
        #expect(CSV.fieldOffset(in: text, rowStart: 6, column: 0, delimiter: 44) == 7) // inside the quote
        #expect(CSV.fieldOffset(in: text, rowStart: 6, column: 1, delimiter: 44) == text.range(of: ",2\n").location + 1)
        #expect(CSV.fieldOffset(in: text, rowStart: t.rowStarts[2], column: 1, delimiter: 44) == text.range(of: "3").location)
    }

    @Test func maxRowsTruncates() {
        let body = (0..<100).map { "\($0),x" }.joined(separator: "\n")
        let t = CSV.parse(body as NSString, maxRows: 10)
        #expect(t.rows.count == 10)
        #expect(t.truncated)
        #expect(!CSV.parse(body as NSString).truncated)
    }

    @Test func sniffsTheDelimiter() {
        #expect(CSV.delimiter(for: "a,b,c\n1,2,3\n") == 44)
        #expect(CSV.delimiter(for: "a\tb\tc\n1\t2\t3\n") == 9)
        #expect(CSV.delimiter(for: "a;b;c\n1,5;2,5;3\n") == 59) // European decimals
        #expect(CSV.delimiter(for: "a|b\n1|2\n") == 124)
        // Commas inside quotes don't count.
        #expect(CSV.delimiter(for: "\"a,b,c\";d\n\"1,2,3\";4\n") == 59)
        // The extension wins for .tsv; nothing at all: comma.
        #expect(CSV.delimiter(for: "a,b\n", fileName: "x.tsv") == 9)
        #expect(CSV.delimiter(for: "just words\n") == 44)
    }

    @Test func sortsNumbersByValueAndTextNaturally() {
        let r = [["n", "name"], ["10", "b"], ["9", "a10"], ["", "a9"], ["9", "A2"]]
        #expect(CSV.sortedOrder(r, column: 0, ascending: true) == [2, 4, 1, 3]) // stable, blanks last
        #expect(CSV.sortedOrder(r, column: 0, ascending: false).first == 1)
        #expect(CSV.sortedOrder(r, column: 1, ascending: true) == [4, 3, 2, 1])
    }

    @Test func sortedTSVRowsRetainFieldOffsets() {
        let text = "name\tvalue\n\"😀\nitem\"\t10\nother\t2\n" as NSString
        let dialect = CSV.dialect(for: text, fileName: "data.tsv")
        let table = CSV.parse(text, dialect: dialect)
        let order = CSV.sortedOrder(table.rows, column: 1, ascending: true)
        #expect(order == [2, 1])
        #expect(CSV.fieldOffset(in: text, rowStart: table.rowStarts[order[1]], column: 0, dialect: dialect)
                == text.range(of: "😀").location)
    }

    @Test func callerCanCapWideRowsWithoutRetainingAllCells() {
        let text = "a,b,c,d\n1,2,3,4" as NSString
        let table = CSV.parse(text, dialect: CSV.Dialect(delimiter: 44), maxColumns: 2)
        #expect(table.rows == [["a", "b"], ["1", "2"]])
        #expect(table.columnCount == 2)
        #expect(table.truncatedColumns)
        #expect(!CSV.parse(text, dialect: CSV.Dialect(delimiter: 44)).truncatedColumns)
    }

    @Test func languageAndPreview() {
        #expect(LanguageDetector.language(forFileName: "data.csv") == .csv)
        #expect(LanguageDetector.language(forFileName: "data.TSV") == .csv)
        #expect(Language.csv.hasPreview)
    }
}
