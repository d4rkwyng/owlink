import Foundation
import Testing
@testable import CedricCore

/// Whether a file has a UTF-8 BOM is decided by each version's own bytes,
/// never kept from the version a tab read before. A tab keeps the base
/// encoding (detected, or UTF-8 picked by hand, with or without BOM) and
/// reads every new version in it: Reload (EditorWindowController passes
/// the tab's encoding to DocumentRead.read), and Follow File's start and
/// its reset after a rotation or truncation (FileTail.decodeWhole, the
/// reset's FileTail.Shown.encoding taken by the tab as
/// EditorTools.tailEvent does). Then a save with no edit writes the new
/// version back byte for byte: a BOM it has is kept, and one it hasn't
/// is never added.
/// 0.5.4 at 38003f0: a tab that had read a BOM was UTF-8 with BOM, and a
/// reload of a version without one saved a BOM; Follow's reset kept the
/// tab's encoding, so a rotation added or dropped a BOM on save.
@Suite struct BOMPerVersionTests {
    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The format a tab keeps for its text (EditorDocument.apply).
    struct Tab {
        var encoding: TextEncoding
        var lineEnding: LineEnding
        var breaks: LineBreaks?
        var text: String
        var stamp: DiskStamp?

        init(_ d: DecodedText, stamp: DiskStamp?) {
            encoding = d.encoding
            lineEnding = d.lineEnding
            breaks = d.mixedLineEndings ? d.lineBreaks : nil
            text = d.text
            self.stamp = stamp
        }

        /// ⌘S with no edit (EditorDocument.encoded, DocumentWrite).
        func save(to url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [UInt8] {
            let data = try #require(TextCodec.encodeDocument(text, encoding: encoding, lineEnding: lineEnding, lineBreaks: breaks),
                                    sourceLocation: sourceLocation)
            try DocumentWrite.write(data, to: url, expecting: stamp)
            return [UInt8](try Data(contentsOf: url))
        }
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bom-per-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An external writer replacing the file (a new inode, renamed over it).
    func replace(_ url: URL, with bytes: [UInt8]) throws {
        let next = url.deletingLastPathComponent().appendingPathComponent("next-\(UUID().uuidString)")
        try Data(bytes).write(to: next)
        #expect(rename(next.path, url.path) == 0)
    }

    /// Versions: (first, then, what the tab shows of `then`).
    static let changes: [(String, [UInt8], [UInt8], String)] = {
        let b = bom
        let plain = Array("old one\nold two\n".utf8), next = Array("new one\r\nnew two\r\n".utf8)
        return [
            ("BOM -> no BOM", b + plain, next, "new one\nnew two\n"),
            ("no BOM -> BOM", plain, b + next, "new one\nnew two\n"),
            ("BOM -> BOM", b + plain, b + next, "new one\nnew two\n"),
            ("two BOMs -> no BOM", b + b + plain, next, "new one\nnew two\n"),
            ("no BOM -> two BOMs", plain, b + b + next, "\u{FEFF}new one\nnew two\n"),
            ("BOM -> BOM alone", b + plain, b, ""),
            ("BOM alone -> no BOM", b, next, "new one\nnew two\n"),
        ]
    }()

    /// Each base a tab can have: detected, UTF-8 picked by hand (Reopen
    /// with Encoding), and UTF-8 with BOM picked by hand.
    static let bases: [TextEncoding?] = [nil, .utf8, .utf8BOM]

    /// Opened then saved unedited: the same bytes, whatever the base
    /// (UTF-8 with BOM picked for a file without one reads it as it is).
    @Test func openThenSaveKeepsEachVersionsBOM() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = Self.bom
        for bytes in [b + Array("x\r\n".utf8), Array("x\r\n".utf8), b + b + Array("x\n".utf8), b, []] {
            for base in Self.bases {
                let url = dir.appendingPathComponent("open.txt")
                try Data(bytes).write(to: url)
                let (d, stamp) = try DocumentRead.read(url, encoding: base)
                let saved = try Tab(d, stamp: stamp).save(to: url)
                #expect(saved == bytes, "\(bytes) opened as \(base?.rawValue ?? "detected"): saved bytes")
                #expect(d.encoding == (bytes.starts(with: b) ? .utf8BOM : .utf8),
                        "\(bytes) opened as \(base?.rawValue ?? "detected"): encoding")
            }
        }
    }

    /// Reload (a clean tab, the file replaced): the tab passes its
    /// encoding to DocumentRead.read (EditorWindowController's reload,
    /// background catch-up with shareBytes, Reload/Revert to Saved, a
    /// restored or reopened tab), then saves unedited.
    @Test func reloadThenSaveKeepsTheNewVersionsBOM() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (note, first, then, shown) in Self.changes {
            for base in Self.bases {
                for share in [false, true] {
                    let label = "\(note), opened as \(base?.rawValue ?? "detected")\(share ? ", shared" : "")"
                    let url = dir.appendingPathComponent("reload.txt")
                    try Data(first).write(to: url)
                    let (d0, s0) = try DocumentRead.read(url, encoding: base)
                    let tab = Tab(d0, stamp: s0)
                    try replace(url, with: then)
                    let (d, stamp) = try DocumentRead.read(url, encoding: tab.encoding, shareBytes: share)
                    let reloaded = Tab(d, stamp: stamp)
                    #expect(reloaded.text == shown, "\(label): text")
                    #expect(reloaded.encoding == (then.starts(with: Self.bom) ? .utf8BOM : .utf8), "\(label): encoding")
                    let saved = try reloaded.save(to: url)
                    #expect(saved == then, "\(label): saved bytes")
                }
            }
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(FileTail.Event, FileTail.Shown)] = []
        func add(_ e: FileTail.Event, _ s: FileTail.Shown) { lock.lock(); list.append((e, s)); lock.unlock() }
        var all: [(FileTail.Event, FileTail.Shown)] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// A tab following `url`, as EditorTools.startFollowing starts it and
    /// tailEvent applies each event.
    final class Following {
        var tab: Tab
        let tail: FileTail
        let events = Events()
        let callbacks = DispatchQueue(label: "bom-per-version")
        var applied = 0

        init(_ url: URL, tab opened: Tab) throws {
            let (data, stamp) = try FileTail.readStamped(url)
            let (d, used) = try #require(FileTail.decodeWhole(data, as: opened.encoding))
            tab = Tab(d, stamp: stamp.showing(UInt64(used)))
            let events = self.events
            tail = FileTail(url: url, encoding: d.encoding, offset: UInt64(used), held: UInt64(data.count - used),
                            callbackQueue: callbacks, startedFrom: stamp, lineEnding: d.lineEnding,
                            stamped: { events.add($0, $1) })
            tail.start()
        }

        /// Checks now and applies what came, as tailEvent does.
        func catchUp() {
            tail.poll()
            _ = tail.isWatching
            callbacks.sync {}
            let all = events.all
            for (e, shown) in all[applied...] {
                switch e {
                case .appended(let s):
                    tab.text += s
                case .reset(let s):
                    if let le = shown.lineEnding { tab.lineEnding = le }
                    tab.breaks = shown.lineBreaks
                    if let enc = shown.encoding { tab.encoding = enc }
                    tab.text = s
                }
                tab.stamp = shown.stamp
            }
            applied = all.count
        }
    }

    /// Follow File: the followed file rotated (renamed away, a new one put
    /// in its place); Follow stopped, the tab saved unedited.
    @Test func followRotationThenSaveKeepsTheNewVersionsBOM() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (note, first, then, shown) in Self.changes {
            for base in Self.bases {
                let label = "\(note), opened as \(base?.rawValue ?? "detected")"
                let url = dir.appendingPathComponent("follow.log")
                try Data(first).write(to: url)
                let (d0, s0) = try DocumentRead.read(url, encoding: base)
                let f = try Following(url, tab: Tab(d0, stamp: s0))
                f.catchUp()
                try replace(url, with: then)
                f.catchUp()
                f.tail.stop()
                #expect(f.events.all.count == 1, "\(label): one reset")
                #expect(f.tab.text == shown, "\(label): text")
                #expect(f.tab.encoding == (then.starts(with: Self.bom) ? .utf8BOM : .utf8), "\(label): encoding")
                let saved = try f.tab.save(to: url)
                #expect(saved == then, "\(label): saved bytes")
            }
        }
    }

    /// Follow File: the file truncated to nothing, then written again (a
    /// log cleared in place): the new bytes are a new version, BOM or not.
    @Test func followTruncatedThenRewrittenKeepsTheNewVersionsBOM() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = Self.bom
        let plain = Array("old\n".utf8), next = Array("new\n".utf8)
        for (note, first, then) in [("BOM -> no BOM", b + plain, next), ("no BOM -> BOM", plain, b + next),
                                    ("BOM -> BOM", b + plain, b + next)] {
            for base in Self.bases {
                let label = "\(note), opened as \(base?.rawValue ?? "detected")"
                let url = dir.appendingPathComponent("cleared.log")
                try Data(first).write(to: url)
                let (d0, s0) = try DocumentRead.read(url, encoding: base)
                let f = try Following(url, tab: Tab(d0, stamp: s0))
                f.catchUp()
                #expect(truncate(url.path, 0) == 0)
                f.catchUp()
                let fh = try FileHandle(forWritingTo: url)
                try fh.seekToEnd()
                try fh.write(contentsOf: Data(then))
                try fh.close()
                f.catchUp()
                f.tail.stop()
                #expect(f.tab.text == "new\n", "\(label): text")
                #expect(f.tab.encoding == (then.starts(with: b) ? .utf8BOM : .utf8), "\(label): encoding")
                let saved = try f.tab.save(to: url)
                #expect(saved == then, "\(label): saved bytes")
            }
        }
    }
}
