import Foundation
import Testing
@testable import CedricCore

/// 0.6.1 bug 2: a sidebar click on a binary file (a pcap, for example)
/// must not decode the whole file into text before the tab is shown.
/// `TextCodec.decodeForOpen` sniffs `looksBinary` on the first 8 KB and
/// returns empty text (Open Anyway decodes later with `decode`).
@Suite struct BinaryOpenDecodeTests {
    /// libpcap little-endian magic, then bytes with NULs so the first 8 KB
    /// look binary.
    static func pcapLike(_ bytes: Int, seed: UInt64 = 70) -> Data {
        var d = Data([0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0x7F, 0, 0, 0])
        var s = seed
        while d.count < bytes {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            var v = s
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0.prefix(min(8, bytes - d.count))) }
        }
        return d
    }

    @Test func looksBinaryOnAPcapPrefix() {
        let data = Self.pcapLike(5_000_000)
        #expect(TextCodec.looksBinary(data))
        #expect(TextCodec.looksBinary(data.prefix(TextCodec.binarySample)))
    }

    @Test func decodeForOpenDoesNotMaterializeTextForABinaryFile() {
        let data = Self.pcapLike(2_000_000)
        let opened = TextCodec.decodeForOpen(data)
        #expect(opened != nil)
        #expect(opened?.looksBinary == true)
        #expect(opened?.text.isEmpty == true,
                "a binary file is not decoded into text until Open Anyway (got \(opened?.text.count ?? -1) characters)")
    }

    @Test func decodeStillProducesTextForOpenAnyway() {
        let data = Self.pcapLike(8_192 * 2)
        let forced = TextCodec.decode(data)
        #expect(forced?.looksBinary == true)
        #expect((forced?.text.count ?? 0) > 1000, "Open Anyway still decodes the bytes as text")
    }

    @Test func decodeForOpenLeavesATextFileAlone() {
        let data = Data(String(repeating: "access point channel 6 rssi=-70\n", count: 200).utf8)
        let opened = TextCodec.decodeForOpen(data)
        let full = TextCodec.decode(data)
        #expect(opened?.looksBinary == false)
        #expect(opened?.text == full?.text)
        #expect(opened?.encoding == full?.encoding)
        #expect(opened?.lineEnding == full?.lineEnding)
    }

    /// TIMING SENSITIVE: decodeForOpen of a 5 MB pcap-like buffer must stay
    /// near a looksBinary sniff, not a full 8-bit decode. Generous margin
    /// (Timing.best, scaled CPU plus a wall-clock guard).
    @Test func decodeForOpenOfALargeBinaryFileStaysUnderBudget() {
        let data = Self.pcapLike(5_000_000)
        let r = Timing.best(of: 5) {
            let d = TextCodec.decodeForOpen(data)
            #expect(d?.looksBinary == true)
            #expect(d?.text.isEmpty == true)
        }
        // A sniff of 8 KB is well under 1 ms on an M-series Mac; 20 ms
        // scaled and a 2 s wall guard leave room for a loaded CI runner.
        #expect(r.scaled < 0.020, "5 MB binary decodeForOpen: \(r.description)")
        #expect(r.wall < 2, "5 MB binary decodeForOpen: \(r.description)")
    }
}
