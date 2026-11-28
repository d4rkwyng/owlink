import Foundation
import UniformTypeIdentifiers

/// Where Owlink for iPhone and iPad opens a file: a PDF in the read-only
/// PDF viewer, an .xlsx / .xlsm workbook or a .csv / .tsv file in the
/// read-only spreadsheet grid, any other Office or iWork document in the
/// read-only Quick Look viewer, anything else in the text editor (today's
/// path, with its "binary file" alert for other binaries).
///
/// Decided by the file's name (its extension), its content type (UTType),
/// and only the first 32 bytes: a `%PDF-` header on a file whose name isn't
/// a text type, as on the Mac (`DocumentKind`), and the zip / OLE2 / RTF
/// header `OfficeFormat.detect(prefix:fileName:)` uses to tell a real Office
/// file from text with an Office name. Never by sniffing the whole file.
/// Unlike the Mac there is no image or certificate viewer here, and a file
/// with no telling name or type isn't looked inside (an extension-less zip
/// or OLE2 file stays with the editor).
public enum DocumentViewerRoute: Equatable, Sendable {
    case editor
    case pdf
    case spreadsheet(SpreadsheetFormat)
    case quickLook(OfficeFormat)

    /// Office and iWork content types, most specific first. iWork types
    /// still need the zip header (a `.key` file is far more often a PEM
    /// private key, which is text, and gets the Keynote type by its name).
    public static let officeTypes: [(String, OfficeFormat)] = [
        ("org.openxmlformats.wordprocessingml.document", .word),
        ("org.openxmlformats.wordprocessingml.template", .word),
        ("com.microsoft.word.doc", .word),
        ("com.microsoft.word.dot", .word),
        ("org.openxmlformats.spreadsheetml.sheet", .spreadsheet),
        ("com.microsoft.excel.xls", .spreadsheet),
        ("org.openxmlformats.presentationml.presentation", .presentation),
        ("com.microsoft.powerpoint.ppt", .presentation),
        ("com.apple.iwork.pages.sffpages", .pages),
        ("com.apple.iwork.pages.pages", .pages),
        ("com.apple.iwork.numbers.sffnumbers", .numbers),
        ("com.apple.iwork.numbers.numbers", .numbers),
        ("com.apple.iwork.keynote.sffkey", .keynote),
        ("com.apple.iwork.keynote.key", .keynote),
    ]

    /// The Office format a content type names, if any.
    public static func officeFormat(for type: UTType) -> OfficeFormat? {
        for (id, format) in officeTypes {
            if type.identifier == id { return format }
            if let t = UTType(id), type.conforms(to: t) { return format }
        }
        return nil
    }

    /// The route from a file's name, its first bytes (up to 32 are looked
    /// at), its content type if known, and whether it is a directory.
    public static func route<D: Collection>(fileName: String, prefix: D, contentType: UTType? = nil,
                                            isDirectory: Bool = false) -> DocumentViewerRoute where D.Element == UInt8 {
        if isDirectory {
            // A package Quick Look shows (.rtfd, an iWork package), by its name.
            return OfficeFormat.forDirectory(fileName).map { .quickLook($0) } ?? .editor
        }
        let bytes = Array(prefix.prefix(DocumentKind.prefixLength))
        let e = OfficeFormat.ext(fileName)
        // CSV and TSV by name: the grid, whatever they hold (it says when
        // a file isn't text; Edit as Text opens the editor).
        if let sheet = SpreadsheetFormat.delimited[e] { return .spreadsheet(sheet) }
        // An .xlsx / .xlsm by name: the grid, for a zip, for an encrypted
        // workbook (an OLE2 container), and for a damaged one (the grid
        // says it can't read it). An RTF with the name stays text.
        if SpreadsheetFormat.workbookExtensions.contains(e), !bytes.starts(with: Array("{\\rtf".utf8)) {
            return .spreadsheet(.xlsx)
        }
        // Text by its name (.csv, .txt, .md, .json, .swift…) is always the
        // editor's, whatever its first bytes or content type are.
        if !e.isEmpty, let named = UTType(filenameExtension: e), named.conforms(to: .text) { return .editor }

        // A known viewer file by its name or header goes to its viewer even
        // when the content type says text (a provider's plain-text metadata).
        if DocumentKind.hasPDFExtension(fileName) { return .pdf }
        if let named = OfficeFormat.ooxml[e] ?? OfficeFormat.ole[e] ?? OfficeFormat.iwork[e] {
            if let f = OfficeFormat.detect(prefix: bytes, fileName: fileName) { return .quickLook(f) }
            // A zip with a legacy name (a .docx saved as .doc): the viewer,
            // which reads what it really is. iWork without the zip header
            // and RTF with an Office name fall through (text).
            if OfficeFormat.isZip(bytes), OfficeFormat.ole[e] != nil { return .quickLook(named) }
        }
        // No or an odd extension: a PDF header still makes it a PDF.
        if DocumentKind.hasPDFHeader(bytes) { return .pdf }
        // Otherwise text by its type is the editor's.
        if let contentType, contentType.conforms(to: .text) { return .editor }
        if let contentType {
            if contentType.conforms(to: .pdf) { return .pdf }
            if let f = officeFormat(for: contentType), !bytes.starts(with: Array("{\\rtf".utf8)) {
                // An OOXML workbook by its type alone: the grid.
                if f == .spreadsheet, OfficeFormat.isZip(bytes), let sheet = UTType("org.openxmlformats.spreadsheetml.sheet"),
                   contentType.conforms(to: sheet) {
                    return .spreadsheet(.xlsx)
                }
                let isIWork = f == .pages || f == .numbers || f == .keynote
                if !isIWork || OfficeFormat.isZip(bytes) { return .quickLook(f) }
            }
        }
        return .editor
    }

    /// What a path that only ever opens the text editor (a launch reopen,
    /// a crash-recovery restore) does with a file, by its current route.
    public struct EditorOnlyOpen: Equatable, Sendable {
        /// The file is the editor's: open it in a `TextDocument`.
        public var opensEditor: Bool
        /// A reopen of a viewer file: forget the last-open record (the
        /// reopen ends as "not opened").
        public var forgetsLastOpenDocument: Bool
        /// Never: a recovery record's text stays, offered for its own
        /// document if that ever routes to the editor again.
        public var clearsRecoveryRecord: Bool
    }

    /// A viewer file (PDF, Office, iWork, RTFD) is never opened in the
    /// writable editor by a reopen or a restore: the editor's own binary
    /// check accepts PDFs with no NUL bytes. CSV and TSV are text: they
    /// open in the grid by default, but a reopen (of a file last edited
    /// with Edit as Text) or a restore opens the editor, as before.
    public static func editorOnlyOpen(_ route: DocumentViewerRoute, reopening: Bool) -> EditorOnlyOpen {
        let editor: Bool
        switch route {
        case .editor: editor = true
        case .spreadsheet(let f): editor = f.isText
        case .pdf, .quickLook: editor = false
        }
        return EditorOnlyOpen(opensEditor: editor, forgetsLastOpenDocument: !editor && reopening, clearsRecoveryRecord: false)
    }

    /// Reads the first 32 bytes (not the whole file) and the content type.
    /// A file that can't be read goes by its name and type (the viewer or
    /// editor then reports why it can't open it).
    public static func route(for url: URL) -> DocumentViewerRoute {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue {
            return route(fileName: url.lastPathComponent, prefix: [UInt8](), isDirectory: true)
        }
        var prefix: [UInt8] = []
        if let h = try? FileHandle(forReadingFrom: url) {
            prefix = Array((try? h.read(upToCount: DocumentKind.prefixLength)) ?? Data())
            try? h.close()
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return route(fileName: url.lastPathComponent, prefix: prefix, contentType: type)
    }
}

/// What the read-only spreadsheet grid opens.
public enum SpreadsheetFormat: String, Equatable, Sendable {
    /// An Office Open XML workbook (.xlsx, .xlsm).
    case xlsx
    case csv, tsv

    /// Plain text (Edit as Text opens it in the editor).
    public var isText: Bool { self != .xlsx }

    static let delimited: [String: SpreadsheetFormat] = ["csv": .csv, "tsv": .tsv]
    static let workbookExtensions: Set<String> = ["xlsx", "xlsm"]

    /// "Excel spreadsheet · 12 KB".
    public var kindName: String {
        switch self {
        case .xlsx: String(localized: "Excel spreadsheet")
        case .csv: String(localized: "CSV file")
        case .tsv: String(localized: "TSV file")
        }
    }
}

extension OfficeFormat {
    /// What the viewer calls the file ("Excel spreadsheet · 12 KB"), as
    /// the Mac's Quick Look tab does.
    public var kindName: String {
        switch self {
        case .word: String(localized: "Word document")
        case .spreadsheet: String(localized: "Excel spreadsheet")
        case .presentation: String(localized: "PowerPoint presentation")
        case .pages: String(localized: "Pages document")
        case .numbers: String(localized: "Numbers spreadsheet")
        case .keynote: String(localized: "Keynote presentation")
        case .rtfd: String(localized: "RTFD document")
        }
    }
}
