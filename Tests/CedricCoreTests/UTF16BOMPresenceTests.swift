import Foundation
import Testing
@testable import CedricCore

/// 0.6.1 review (Astra), UTF-16 and its BOM:
///
/// 1. Follow saw a UTF-16 log truncated to nothing before its writer wrote
///    the new BOM: only a UTF-8 BOM at offset zero was read as the new
///    version's, so the UTF-16 one was appended as text (U+FEFF), every
///    byte stamped as shown, and an unedited save wrote two BOMs.
/// 2. A UTF-16 file without a BOM (recognised by its zero bytes) was held
///    as the same encoding as one with, so a save always wrote a BOM, and
///    a reload's ⌘Z between the two looked clean.
///
/// Every check here is against the literal bytes on disk.
@Suite struct UTF16BOMPresenceTests {
    static func units(_ s: String, bigEndian: Bool) -> [UInt8] { UTF16FollowTests.units(s, bigEndian: bigEndian) }
    static func scalars(_ s: String?) -> [UInt32]? { UTF16FollowTests.scalars(s) }

    // MARK: 1. Follow, truncated to nothing, then a new BOM

    /// Follows `start`, truncates the file to nothing, polls, then makes
    /// each write (polling after each). Returns the text shown, the tab's
    /// encoding and line ending as the events left them, the last Shown,
    /// and the file's bytes at the end.
    static func followTruncated(_ start: [UInt8], as enc: TextEncoding, writes: [[UInt8]])
        throws -> (text: String, encoding: TextEncoding, ending: LineEnding, last: FileTail.Shown?, disk: [UInt8], resets: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-utf16-trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("u16.log")
        try Data(start).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: enc))
        var text = d.text, encoding = d.encoding, ending = d.lineEnding
        let events = UTF16FollowTests.Events()
        let callbacks = DispatchQueue(label: "utf16-trunc")
        let tail = FileTail(url: url, encoding: enc, offset: UInt64(used), held: UInt64(data.count - used),
                            callbackQueue: callbacks, startedFrom: stamp, lineEnding: d.lineEnding,
                            stamped: { events.add($0, $1) })
        tail.start()
        var applied = 0
        func catchUp() {
            tail.poll()
            _ = tail.isWatching
            callbacks.sync {}
            let got = events.all
            for (e, s) in got[applied...] {
                switch e {
                case .appended(let a): text += a
                case .reset(let r):
                    text = r
                    if let le = s.lineEnding { ending = le }
                    if let en = s.encoding { encoding = en }
                }
            }
            applied = got.count
        }
        catchUp()
        let cut = try FileHandle(forWritingTo: url)
        try cut.truncate(atOffset: 0)
        try cut.close()
        catchUp()
        for w in writes {
            let fh = try FileHandle(forWritingTo: url)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(w))
            try fh.close()
            catchUp()
        }
        tail.stop()
        let resets = events.all.filter { if case .reset = $0.0 { return true }; return false }.count
        return (text, encoding, ending, events.all.last?.1, try [UInt8](Data(contentsOf: url)), resets)
    }

    /// Truncated, then written again without a BOM: appended as text, and
    /// saved without one (the empty reset is UTF-16 without a BOM).
    @Test(arguments: [TextEncoding.utf16LE, .utf16BE])
    func noBOMAfterATruncationSavesNoBOM(enc: TextEncoding) throws {
        let be = enc == .utf16BE
        func u(_ s: String) -> [UInt8] { Self.units(s, bigEndian: be) }
        let r = try Self.followTruncated(u("\u{FEFF}old\n"), as: enc, writes: [u("new\n")])
        #expect(r.text == "new\n")
        #expect(r.disk == u("new\n"))
        #expect(r.last?.bytes == UInt64(r.disk.count))
        let saved = try #require(DocumentFormat(encoding: r.encoding, lineEnding: r.ending).encoded(r.text))
        #expect([UInt8](saved) == r.disk, "[\(enc)]: no BOM written where the file has none")
    }

    // MARK: 2. BOM presence through decode, snapshot, dirty and save

    typealias Tab = ReloadUndoFormatTests.Tab

    /// Opened without a BOM and saved unedited: the same bytes, no BOM.
    @Test(arguments: [false, true])
    func aBOMlessFileIsSavedWithoutOne(bigEndian: Bool) throws {
        let plain = Self.units("plain text, no BOM\n", bigEndian: bigEndian)
        let tab = try Tab(opening: plain)
        #expect(tab.text == "plain text, no BOM\n")
        #expect(try tab.saved() == plain, "an unedited save writes no BOM")
        // Asked for in the order it has (Reopen with Encoding, a reload in
        // the tab's base encoding): the bytes still decide.
        let asked = try #require(TextCodec.decode(Data(plain), as: bigEndian ? .utf16BE : .utf16LE))
        #expect(try #require(DocumentFormat(encoding: asked.encoding, lineEnding: asked.lineEnding).encoded(asked.text)) == Data(plain))
    }

    /// Revert a BOM-less file to the same text with a BOM, then ⌘Z: unsaved
    /// (only the BOM differs), and ⌘S writes no BOM; redo is clean again.
    /// And the other way: a file with a BOM reverted to one without.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func aBOMOnlyRevertIsUnsavedAfterUndoAndSavesTheOldBOM(bigEndian: Bool, oldHasBOM: Bool) throws {
        func u(_ s: String) -> [UInt8] { Self.units(s, bigEndian: bigEndian) }
        let bom = u("\u{FEFF}")
        let body = u("same words\n")
        var tab = try Tab(opening: (oldHasBOM ? bom : []) + u("draft\n"))
        #expect(try tab.saved() == (oldHasBOM ? bom : []) + u("draft\n"), "opened: saved back as it is")
        tab.type("same words\n")
        // Another app saved the same words, with the other BOM state.
        let disk = (oldHasBOM ? [] : bom) + body
        try tab.reload(disk)
        #expect(tab.text == "same words\n" && !tab.isDirty)
        #expect(try tab.saved() == disk, "the reloaded version's own bytes")
        try tab.undo()
        #expect(tab.text == "same words\n")
        #expect(tab.isDirty && tab.edited.encodingDiffers && !tab.edited.textDiffers,
                "[be \(bigEndian), BOM \(oldHasBOM)]: unsaved by the BOM alone")
        #expect(try tab.saved() == (oldHasBOM ? bom : []) + body,
                "[be \(bigEndian), BOM \(oldHasBOM)]: ⌘S writes the edited version's BOM, or none")
        try tab.redo()
        #expect(!tab.isDirty, "redo: the file's own format again, clean")
        #expect(try tab.saved() == disk)
    }
}
