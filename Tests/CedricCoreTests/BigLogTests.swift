import Foundation
import Testing
@testable import CedricCore

/// 0.5.2 crashed opening any text file past 25 M characters on macOS 26
/// (an NSCountableTextLocation compare: exception in TextKit layout,
/// 30/45/55 MiB logs; 20 MiB opened). 25 M characters is where large mode
/// starts (`sizeThreshold`), and large mode handed TextKit every line
/// through the chunking content storage. A log of ordinary lines keeps
/// TextKit's own paragraphs now; only a line over `lineThreshold` gets
/// chunks. A generated ~31 MiB log in a temp folder, read back from disk
/// as the app reads it (no fixture in the repo).
@Suite(.offPool) struct BigLogTests {
    static func log(bytes: Int) -> String {
        var s = ""
        s.reserveCapacity(bytes + 200)
        var i = 0
        while s.utf8.count < bytes {
            s += "2026-11-24T01:36:37.\(i % 1_000_000)Z INFO  worker-\(i % 32) request id=\(i) status=200 path=/api/v1/items/\(i % 977)\n"
            i += 1
        }
        return s
    }

    static func roundTrip(_ text: String) throws -> NSString {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-biglog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(text.utf8).write(to: url)
        return try String(contentsOf: url, encoding: .utf8) as NSString
    }

    @Test func a30MiBLogIsLargeWithoutChunks() throws {
        let text = try Self.roundTrip(Self.log(bytes: 31 * 1024 * 1024))
        let index = LineIndex(text)
        #expect(index.length > LargeDocument.sizeThreshold)
        #expect(index.lineCount > 300_000 && index.longestLine < 200)
        #expect(LargeDocument.reason(for: index) == .size, "large mode: colouring, spell check and the owl pause")
        #expect(!LargeDocument.needsChunks(index), "no line needs chunks: TextKit lays out its own paragraphs")
        // Every line is one element whatever the chunk limit: a chunk is the line itself.
        for line in [0, index.lineCount / 2, index.lineCount - 2] {
            let r = NSRange(location: index.starts[line], length: index.lineLength(line))
            #expect(LargeDocument.chunks(of: r, in: text, limit: LargeDocument.chunkLength) == [r])
        }
    }

    @Test func a20MiBLogWasNeverLarge() throws {
        // Why 20 MiB lived: under 25 M characters large mode never started.
        let index = LineIndex(try Self.roundTrip(Self.log(bytes: 20 * 1024 * 1024)))
        #expect(index.length < LargeDocument.sizeThreshold)
        #expect(LargeDocument.reason(for: index) == nil)
        #expect(!LargeDocument.needsChunks(index))
    }

    @Test func aLongLineInABigLogGetsChunksThatTileIt() throws {
        let long = String(repeating: "0123456789abcdef", count: 1_875)   // 30,000
        let base = Self.log(bytes: 30 * 1024 * 1024)
        let text = try Self.roundTrip(base + long + "\n" + "tail line\n")
        var index = LineIndex(text)
        #expect(LargeDocument.reason(for: index) == .size)
        #expect(LargeDocument.needsChunks(index))
        let line = index.line(containing: (base as NSString).length + 10)
        let r = NSRange(location: index.starts[line], length: index.lineLength(line))
        #expect(r.location > LargeDocument.sizeThreshold, "the long line is past 25 M characters")
        let chunks = LargeDocument.chunks(of: r, in: text, limit: LargeDocument.chunkLength)
        #expect(chunks.first?.location == r.location && chunks.last.map(NSMaxRange) == NSMaxRange(r))
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        #expect(chunks.allSatisfy { $0.length > 0 && $0.length <= LargeDocument.chunkLength })
        for c in chunks {
            #expect(LargeDocument.chunk(containing: c.location, line: r, in: text, limit: LargeDocument.chunkLength) == c)
            #expect(LargeDocument.chunk(containing: NSMaxRange(c) - 1, line: r, in: text, limit: LargeDocument.chunkLength) == c)
        }

        // Pasting the long line into the big log (no chunks yet): the edit turns them on.
        let plain = try Self.roundTrip(base + "short\n")
        index = LineIndex(plain)
        #expect(!LargeDocument.needsChunks(index))
        let at = (base as NSString).length
        let after = (base + long + "\nshort\n") as NSString
        let first = index.replace(NSRange(location: at, length: 0), newLength: (long as NSString).length + 1, in: after)
        #expect(LargeDocument.needsChunks(afterEditOf: first..<(first + 2), in: index))
        #expect(!LargeDocument.needsChunks(afterEditOf: 0..<1, in: index))
    }
}
