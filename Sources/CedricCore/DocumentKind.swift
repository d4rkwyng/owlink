import Foundation

/// What a file opens as: text in the editor, a PDF in a read-only viewer
/// tab, an image in a read-only image tab, or an Office / iWork document in
/// a read-only Quick Look tab. Decided by the file's first bytes (`%PDF-`,
/// the image formats' signatures, a zip's or OLE2 compound file's header),
/// so a file without the usual extension still opens the right way; a file
/// named `.pdf` / `.png` / `.docx`… that doesn't start that way goes to its
/// viewer too, so it gets the viewer's clear "damaged" error instead of
/// opening as binary garbage in the editor. SVG stays text (it has the
/// HTML preview).
public enum DocumentKind: String, Codable, Sendable {
    case text
    case pdf
    case image
    case office
    /// A binary (DER) certificate or PKCS#7 bundle: a read-only certificate
    /// tab. PEM text stays `.text` (the editor shows a Certificate panel).
    case certificate

    /// The PDF header every PDF file starts with.
    public static let pdfMagic: [UInt8] = Array("%PDF-".utf8)
    /// How many bytes `detect(url:)` reads.
    public static let prefixLength = 32

    /// Whether `prefix` (a file's first bytes) starts with `%PDF-`.
    public static func hasPDFHeader<D: Collection>(_ prefix: D) -> Bool where D.Element == UInt8 {
        prefix.count >= pdfMagic.count && zip(prefix, pdfMagic).allSatisfy { $0 == $1 }
    }

    /// Whether `prefix` starts with a PDF version header: `%PDF-`, a
    /// digit, `.`, a digit (`%PDF-1.7`, `%PDF-2.0`). Stricter than
    /// `hasPDFHeader`, for names that say text (a `.csv` whose first field
    /// is `%PDF-` is still a CSV).
    public static func hasPDFVersionHeader<D: Collection>(_ prefix: D) -> Bool where D.Element == UInt8 {
        let b = Array(prefix.prefix(pdfMagic.count + 3))
        func digit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        return b.count == pdfMagic.count + 3 && hasPDFHeader(b) && digit(b[5]) && b[6] == UInt8(ascii: ".") && digit(b[7])
    }

    public static func hasPDFExtension(_ fileName: String) -> Bool {
        (fileName as NSString).pathExtension.lowercased() == "pdf"
    }

    /// The kind from a file's first bytes and its name. A zip without an
    /// Office or iWork extension is `.text` here; `detect(url:)` looks
    /// inside it.
    public static func detect<D: Collection>(prefix: D, fileName: String) -> DocumentKind where D.Element == UInt8 {
        let bytes = Array(prefix.prefix(prefixLength))
        if hasPDFHeader(bytes) { return .pdf }
        if ImageFormat.detect(bytes) != nil { return .image }
        if OfficeFormat.detect(prefix: bytes, fileName: fileName) != nil { return .office }
        if Certificates.isDERFile(prefix: bytes, fileName: fileName) { return .certificate }
        if hasPDFExtension(fileName) { return .pdf }
        if ImageFormat.forExtension(fileName) != nil { return .image }
        return .text
    }

    /// Reads the first few bytes of the file (not the whole file); for a
    /// zip with no telling extension, its central directory's names. A file
    /// that can't be read is `.text`, unless its name says otherwise (the
    /// caller's own read reports why); a package directory (`.pages`,
    /// `.rtfd`) goes by its name.
    public static func detect(url: URL) -> DocumentKind {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue {
            return OfficeFormat.forDirectory(url.lastPathComponent) != nil ? .office : .text
        }
        var prefix: [UInt8] = []
        if let h = try? FileHandle(forReadingFrom: url) {
            prefix = Array((try? h.read(upToCount: prefixLength)) ?? Data())
            try? h.close()
        }
        let kind = detect(prefix: prefix, fileName: url.lastPathComponent)
        if kind == .text, OfficeFormat.isZip(prefix), let names = try? ZipArchive(url: url).entries.map(\.name),
           OfficeFormat.fromZipEntries(names) != nil {
            return .office
        }
        return kind
    }
}

/// Where a PDF tab was: kept with the session so it comes back on the same
/// page at the same zoom.
public struct PDFTabState: Codable, Equatable, Sendable {
    /// The page shown at the top, 0-based.
    public var page: Int
    /// The zoom (1 = actual size); nil when the page is fitted to the
    /// window (the default).
    public var scale: Double?
    /// The page-thumbnails sidebar is shown.
    public var showsThumbnails: Bool

    public init(page: Int = 0, scale: Double? = nil, showsThumbnails: Bool = false) {
        self.page = page
        self.scale = scale
        self.showsThumbnails = showsThumbnails
    }

    private enum CodingKeys: String, CodingKey { case page, scale, showsThumbnails }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = max(0, try c.decodeIfPresent(Int.self, forKey: .page) ?? 0)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        showsThumbnails = try c.decodeIfPresent(Bool.self, forKey: .showsThumbnails) ?? false
    }

    /// The page to show in a document of `pageCount` pages (a saved page
    /// past the end: the last page).
    public func clampedPage(pageCount: Int) -> Int { max(0, min(page, pageCount - 1)) }

    /// Zoom limits, as a percentage the status bar can show.
    public static let minScale = 0.1, maxScale = 16.0
    public static func clampScale(_ s: Double) -> Double { min(max(s, minScale), maxScale) }
}

/// "Go to Page": what the user typed, as a 0-based page index.
public enum PageNumberInput {
    /// `"3"` → 2. Nil for anything that isn't a page in 1…pageCount.
    public static func parse(_ s: String, pageCount: Int) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), n >= 1, n <= pageCount else { return nil }
        return n - 1
    }
}

/// Text taken out of a PDF (Open as Text), with the editor's line endings.
public enum PDFText {
    public static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Files Cedric refuses before reading a byte (security audit L2): a named
/// pipe blocks forever, `/dev/zero` never ends, a socket can't be read.
/// Folders are left to the caller (an `.rtfd` or Pages bundle is one).
public enum SpecialFile {
    /// What the file is when it isn't a regular file or folder, else nil
    /// (also nil when it doesn't exist). Symbolic links are followed.
    public static func kind(atPath path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR: return nil
        case S_IFIFO: return "a named pipe"
        case S_IFCHR, S_IFBLK: return "a device"
        case S_IFSOCK: return "a socket"
        default: return "not a regular file"
        }
    }
}

/// 1-based line, column or page numbers from outside (a link, the command
/// line, a dialog) as 0-based indexes, clamped without overflow
/// (`Int.min - 1` would trap).
public enum OneBased {
    /// `n` (1-based) as an index in `0..<count`; 0 when count is 0.
    public static func index(_ n: Int, count: Int) -> Int {
        guard count > 0, n > 1 else { return 0 }
        return min(n, count) - 1
    }
}
