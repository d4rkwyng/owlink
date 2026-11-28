import Foundation
import UniformTypeIdentifiers

/// Where Owlink for iPhone and iPad opens a file: a PDF in the read-only
/// PDF viewer, an Office or iWork document in the read-only Quick Look
/// viewer, anything else in the text editor (today's path, with its
/// "binary file" alert for other binaries).
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
        // Text by its name or type (.csv, .txt, .md, .json, .swift…) is
        // always the editor's, whatever its first bytes are.
        if !e.isEmpty, let named = UTType(filenameExtension: e), named.conforms(to: .text) { return .editor }
        if let contentType, contentType.conforms(to: .text) { return .editor }

        if DocumentKind.hasPDFExtension(fileName) { return .pdf }
        if let named = OfficeFormat.ooxml[e] ?? OfficeFormat.ole[e] ?? OfficeFormat.iwork[e] {
            if let f = OfficeFormat.detect(prefix: bytes, fileName: fileName) { return .quickLook(f) }
            // A zip with a legacy name (a .docx saved as .doc): the viewer,
            // which reads what it really is. iWork without the zip header
            // and RTF with an Office name fall through (text).
            if OfficeFormat.isZip(bytes), OfficeFormat.ole[e] != nil { return .quickLook(named) }
        }
        if let contentType {
            if contentType.conforms(to: .pdf) { return .pdf }
            if let f = officeFormat(for: contentType), !bytes.starts(with: Array("{\\rtf".utf8)) {
                let isIWork = f == .pages || f == .numbers || f == .keynote
                if !isIWork || OfficeFormat.isZip(bytes) { return .quickLook(f) }
            }
        }
        // No or an odd extension: a PDF header still makes it a PDF.
        if DocumentKind.hasPDFHeader(bytes) { return .pdf }
        return .editor
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
