import Darwin
import Foundation
import Testing
@testable import CedricCore

/// BigBuffer (a big file's bytes, mapped so freeing them gives the memory
/// back at once) and the reads that use it: the same bytes as before,
/// whichever side of `minimum` a buffer starts or grows to.
@Suite struct BigBufferTests {
    /// Bytes written and read back, at sizes on both sides of `minimum`,
    /// and growth across it keeps what was there.
    @Test func allocateGrowAndFreeKeepTheBytes() throws {
        for n in [0, 1, 4096, BigBuffer.minimum - 1, BigBuffer.minimum, BigBuffer.minimum + 4097] {
            let p = try #require(BigBuffer.allocate(n), "room for \(n)")
            let used = max(n, 1)
            memset(p, 0x5A, used)
            #expect(p.load(fromByteOffset: used - 1, as: UInt8.self) == 0x5A)
            BigBuffer.free(p, count: n)
        }
        // Small to big (malloc to mapped), big to bigger (mapped to mapped),
        // small to small (realloc): the first bytes survive each.
        for (from, to) in [(1000, BigBuffer.minimum + 10), (BigBuffer.minimum, 2 * BigBuffer.minimum), (100, 5000)] {
            let p = try #require(BigBuffer.allocate(from))
            let bytes = p.assumingMemoryBound(to: UInt8.self)
            for i in 0..<from { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
            let q = try #require(BigBuffer.grow(p, count: from, to: to), "\(from) → \(to)")
            let grown = q.assumingMemoryBound(to: UInt8.self)
            #expect((0..<from).allSatisfy { grown[$0] == UInt8(truncatingIfNeeded: $0 &* 31) }, "\(from) → \(to) kept its bytes")
            grown[to - 1] = 7
            BigBuffer.free(q, count: to)
        }
    }

    /// A file over `minimum` reads (mapped buffer) to exactly its bytes,
    /// read whole, with a short hint (the buffer grows from malloc to
    /// mapped while read), and under a limit it is over (refused).
    @Test func aBigFileReadsTheSameWhicheverWayItsBufferGrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-bigbuffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.log")
        let line = Array("0123456789 a line of a big log\n".utf8)
        var big = Data(capacity: BigBuffer.minimum + line.count * 2)
        while big.count <= BigBuffer.minimum + line.count { big.append(contentsOf: line) }
        big.append(contentsOf: [0xC3, 0xA9, 0x0A]) // é, so it isn't all ASCII at the very end
        try big.write(to: file)

        #expect(try TextCodec.snapshot(of: file) == big, "read whole into a mapped buffer")
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(try TextCodec.readAll(fd, url: file, sizeHint: 1000, limit: nil) == big, "grown from a small buffer past the minimum")
        _ = lseek(fd, 0, SEEK_SET)
        do {
            let data = try TextCodec.readAll(fd, url: file, sizeHint: 1000, limit: BigBuffer.minimum + 5)
            Issue.record("read \(data.count) bytes past the limit")
        } catch {
            #expect(TextCodec.isTooLarge(error), "refused as too large: \(error)")
        }
    }

    /// A big CRLF file's LF text (written into a mapped buffer) is the
    /// file's text with each CRLF as LF, its line ending CRLF.
    @Test func aBigCRLFFileDecodesThroughAMappedBuffer() throws {
        let line = "a line ending in CRLF, long enough\r\n"
        let count = BigBuffer.minimum / line.utf8.count + 2
        let data = Data(String(repeating: line, count: count).utf8)
        let d = try #require(TextCodec.decode(data, shareBytes: true))
        #expect(d.lineEnding == .crlf && !d.mixedLineEndings)
        let ns = d.text as NSString
        #expect(ns.length == data.count - count)
        #expect(d.text.hasPrefix("a line ending in CRLF, long enough\na line"))
        #expect(!d.text.contains("\r"))
    }
}
