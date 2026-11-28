import Compression
import Foundation

/// A read-only zip reader, just enough for Office documents (an `.xlsx`
/// sheet as CSV, telling a `.docx` from an `.xlsx` by what is inside):
/// the central directory, then stored or deflated entries, inflated with
/// Apple's Compression (raw DEFLATE). No zip64, no encryption, no
/// third-party code.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var method: UInt16
        public var compressedSize: Int
        public var size: Int
        public var localHeaderOffset: Int
    }

    public enum ZipError: Error, Equatable {
        case notAZip, damaged, unsupported(String), missing(String), tooLarge
    }

    public let entries: [Entry]
    private let data: Data

    /// Entries bigger than this aren't inflated (a hostile "zip bomb").
    public static let maxEntrySize = 512 * 1024 * 1024

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        let n = data.count
        guard n >= 22 else { throw ZipError.notAZip }
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // The end-of-central-directory record: in the last 64 KB + 22 bytes.
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_535)
        while i >= stop {
            if data[data.startIndex + i] == 0x50, u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var list: [Entry] = []
        list.reserveCapacity(count)
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4B50 else { throw ZipError.damaged }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let offset = u32(p + 42)
            guard p + 46 + nameLen <= n else { throw ZipError.damaged }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            list.append(Entry(name: name, method: method, compressedSize: csize, size: size, localHeaderOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// An entry's bytes, inflated.
    public func contents(of name: String) throws -> Data {
        guard let e = entry(name) else { throw ZipError.missing(name) }
        return try contents(of: e)
    }

    public func contents(of e: Entry, maxBytes: Int = Self.maxEntrySize) throws -> Data {
        guard e.size <= maxBytes else { throw ZipError.tooLarge }
        return try inflatedPrefix(of: e, maxBytes: e.size)
    }

    /// Borrow the compressed input from the archive and allocate only the requested output.
    public func inflatedPrefix(of e: Entry, maxBytes: Int) throws -> Data {
        let h = e.localHeaderOffset
        guard data.count >= 30, (0...data.count - 30).contains(h),
              e.size >= 0, e.compressedSize >= 0, maxBytes >= 0 else { throw ZipError.damaged }
        func u16(_ o: Int) -> Int {
            Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8
        }
        guard u16(h) == 0x4B50, u16(h + 2) == 0x0403 else { throw ZipError.damaged }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard e.compressedSize <= data.count - start else { throw ZipError.damaged }
        let count = min(e.size, maxBytes)
        switch e.method {
        case 0:
            guard e.size == e.compressedSize else { throw ZipError.damaged }
            let first = data.startIndex + start
            return data.subdata(in: first..<(first + count))
        case 8:
            if count == 0 { return Data() }
            guard e.compressedSize > 0 else { throw ZipError.damaged }
            var out = Data(count: count)
            let written = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, count,
                                              src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start),
                                              e.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == count else { throw ZipError.damaged }
            return out
        default: throw ZipError.unsupported("compression method \(e.method)")
        }
    }
}
