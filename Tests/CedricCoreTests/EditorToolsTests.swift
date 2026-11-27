import Foundation
import Testing
@testable import CedricCore

@Suite struct TextToolTests {
    func t(_ tool: TextTool, _ s: String) throws -> String { try TextTools.apply(tool, to: s) }

    @Test func sortLines() throws {
        #expect(try t(.sortAscending, "pear\napple\nBanana\n") == "apple\nBanana\npear\n")
        #expect(try t(.sortDescending, "pear\napple\nBanana") == "pear\nBanana\napple")
        // Natural order: item2 before item10.
        #expect(try t(.sortAscending, "item10\nitem2\nitem1") == "item1\nitem2\nitem10")
    }

    @Test func sortNumeric() throws {
        #expect(try t(.sortNumeric, "10 ten\n-3 minus\n2.5 x\nnone\n1,000 k\n 7 seven\n") == "-3 minus\n2.5 x\n 7 seven\n10 ten\n1,000 k\nnone\n")
        // Equal keys and non-numeric lines keep their order.
        #expect(try t(.sortNumeric, "b\n1 x\na\n1 y") == "1 x\n1 y\nb\na")
    }

    @Test func removeDuplicates() throws {
        #expect(try t(.removeDuplicateLines, "a\nb\na\nc\nb\n") == "a\nb\nc\n")
        #expect(try t(.removeDuplicateLines, "a\nA") == "a\nA")
    }

    @Test func trimTrailing() throws {
        #expect(try t(.trimTrailingWhitespace, "a  \n\tb\t \n  \nc") == "a\n\tb\n\nc")
    }

    @Test func cases() throws {
        #expect(try t(.uppercase, "straße é") == "STRASSE É")
        #expect(try t(.lowercase, "HeLLo ÉCOLE") == "hello école")
        #expect(try t(.titleCase, "the QUICK brown-fox don't stop 2nd") == "The Quick Brown-Fox Don't Stop 2nd")
    }

    @Test func jsonPrettyAndMinify() throws {
        let src = #"{"b":1,"a":[1, 2.50, {"x":null}],"e":{}, "s":"q\"\u00e9/"}"#
        let pretty = try t(.jsonPrettyPrint, src)
        #expect(pretty == """
        {
          "b": 1,
          "a": [
            1,
            2.50,
            {
              "x": null
            }
          ],
          "e": {},
          "s": "q\\"\\u00e9/"
        }
        """)
        // Key order and number spelling survive; minify round-trips.
        #expect(try t(.jsonMinify, pretty) == #"{"b":1,"a":[1,2.50,{"x":null}],"e":{},"s":"q\"\u00e9/"}"#)
        #expect(try t(.jsonPrettyPrint, "[]\n") == "[]\n")
    }

    @Test func invalidJSONSaysWhere() {
        #expect(throws: TextToolError.self) { try t(.jsonPrettyPrint, "{\"a\": 1,}") }
        do {
            _ = try t(.jsonMinify, "{\n  \"a\": tru\n}")
            Issue.record("should throw")
        } catch let e as TextToolError {
            guard case .invalidJSON(let m) = e else { Issue.record("wrong error \(e)"); return }
            #expect(m.contains("line 2"))
        } catch { Issue.record("\(error)") }
        #expect(throws: TextToolError.self) { try t(.jsonMinify, "") }
        #expect(throws: TextToolError.self) { try t(.jsonMinify, "[1] 2") }
        #expect(throws: TextToolError.self) { try t(.jsonMinify, "[01]") }
        #expect(throws: TextToolError.self) { try t(.jsonMinify, "\"open") }
    }

    #if os(macOS)   // iOS has no XMLDocument: the tool isn't offered there
    @Test func xmlPretty() throws {
        let out = try t(.xmlPrettyPrint, "<root b=\"2\" a=\"1\"><item>x</item><empty/><!-- c --></root>")
        #expect(out.contains("<root b=\"2\" a=\"1\">"))
        #expect(out.contains("\n    <item>x</item>"))
        #expect(out.contains("<empty/>") || out.contains("<empty></empty>"))
        #expect(!out.hasPrefix("<?xml"))
        #expect(throws: TextToolError.self) { try t(.xmlPrettyPrint, "<a><b></a>") }
    }
    #endif

    @Test func base64() throws {
        #expect(try t(.base64Encode, "héllo") == "aMOpbGxv")
        #expect(try t(.base64Decode, "aMOp\nbGxv") == "héllo")
        #expect(try t(.base64Decode, "aGk") == "hi") // missing padding
        #expect(throws: TextToolError.self) { try t(.base64Decode, "@@@") }
        #expect(throws: TextToolError.notUTF8) { try t(.base64Decode, "//79") }
    }

    @Test func url() throws {
        #expect(try t(.urlEncode, "a b&c=d/é~") == "a%20b%26c%3Dd%2F%C3%A9~")
        #expect(try t(.urlDecode, "a%20b%26c%3Dd%2F%C3%A9~") == "a b&c=d/é~")
        #expect(throws: TextToolError.self) { try t(.urlDecode, "%E9%") }
    }

    @Test func joinAndReverse() throws {
        #expect(try t(.joinLines, "one\n   two  \n\nthree\n") == "one two three\n")
        #expect(try t(.reverseLines, "1\n2\n3\n") == "3\n2\n1\n")
        #expect(try t(.reverseLines, "1\n2\n3") == "3\n2\n1")
    }

    @Test func everyToolHasAName() {
        #expect(Set(TextTool.allCases.map(\.displayName)).count == TextTool.allCases.count)
    }
}

@Suite struct LineDiffTests {
    func check(_ a: [String], _ b: [String]) -> [LineDiff.Op] {
        let ops = LineDiff.diff(a, b)
        #expect(LineDiff.apply(ops, a: a, b: b) == b)
        return ops
    }

    func editCount(_ ops: [LineDiff.Op]) -> Int {
        ops.filter { if case .equal = $0 { return false }; return true }.count
    }

    @Test func classicExample() {
        // Myers' paper: ABCABBA → CBABAC has D = 5.
        let ops = check("ABCABBA".map(String.init), "CBABAC".map(String.init))
        #expect(editCount(ops) == 5)
    }

    @Test func edges() {
        #expect(check([], []) == [])
        #expect(check([], ["a"]) == [.insert(0)])
        #expect(check(["a"], []) == [.delete(0)])
        #expect(check(["a", "b"], ["a", "b"]) == [.equal(0, 0), .equal(1, 1)])
        _ = check(["x", "a", "b", "c", "y"], ["a", "b", "c"])
    }

    @Test func randomisedIsMinimalAgainstLCS() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...14, using: &rng)).map { _ in ["a", "b", "c", "d"].randomElement(using: &rng)! }
            let b = (0..<Int.random(in: 0...14, using: &rng)).map { _ in ["a", "b", "c", "d"].randomElement(using: &rng)! }
            let ops = check(a, b)
            // Minimal: edits = n + m - 2·LCS.
            var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0..<a.count { for j in 0..<b.count { dp[i + 1][j + 1] = a[i] == b[j] ? dp[i][j] + 1 : max(dp[i][j + 1], dp[i + 1][j]) } }
            #expect(editCount(ops) == a.count + b.count - 2 * dp[a.count][b.count])
        }
    }

    @Test func sideBySideRows() {
        let a = ["one", "two", "three", "four"]
        let b = ["one", "TWO", "three", "four", "five"]
        let rows = LineDiff.rows(check(a, b))
        #expect(rows == [.init(.same, 0, 0), .init(.changed, 1, 1), .init(.same, 2, 2), .init(.same, 3, 3), .init(.added, nil, 4)])
        let rows2 = LineDiff.rows(check(["a", "x", "y", "b"], ["a", "z", "b"]))
        #expect(rows2 == [.init(.same, 0, 0), .init(.changed, 1, 1), .init(.removed, 2, nil), .init(.same, 3, 2)])
    }

    @Test func bigFilesWithFewChangesAreFast() {
        let a = (0..<50_000).map { "line \($0)" }
        var b = a
        b[100] = "changed"; b.remove(at: 20_000); b.insert("new", at: 40_000)
        let start = Date()
        let ops = check(a, b)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(editCount(ops) == 4)
    }

    @Test func linesSplitting() {
        #expect(LineDiff.lines("") == [])
        #expect(LineDiff.lines("a\nb\n") == ["a", "b"])
        #expect(LineDiff.lines("a\n\n") == ["a", ""])
    }
}

@Suite struct FileSearchTests {
    /// A tree with included, excluded, binary and oversized files.
    func makeTree() throws -> URL {
        let root = tempDir()
        let fm = FileManager.default
        func write(_ rel: String, _ s: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try s.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("a.swift", "let needle = 1\nlet x = 2\n// NEEDLE again, needle twice\n")
        try write("src/b.swift", "func needle() {}\n")
        try write("src/notes.md", "a needle in markdown\n")
        try write(".git/config", "needle in git\n")
        try write("node_modules/pkg/index.js", "needle\n")
        try write("build/out.swift", "needle\n")
        try write("src/dist/gen.swift", "needle\n")
        var bin = Data("needle".utf8); bin.append(contentsOf: [0, 1, 2, 0])
        try bin.write(to: root.appendingPathComponent("blob.bin"))
        // 21 MB: over the 20 MB limit.
        let big = Data(repeating: UInt8(ascii: "n"), count: 21 * 1024 * 1024)
        try big.write(to: root.appendingPathComponent("big.log"))
        try "x".data(using: .utf16)!.write(to: root.appendingPathComponent("utf16.txt")) // BOM + NULs, not binary
        return root
    }

    func search(_ o: FileSearchOptions) throws -> ([FileSearchResult], FileSearchSummary) {
        var out: [FileSearchResult] = []
        let s = try FileSearch(o).run { out.append($0) }
        return (out, s)
    }

    @Test func walksWithDefaultExcludes() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let (rs, sum) = try search(FileSearchOptions(root: root, query: "needle"))
        #expect(rs.map { "\($0.relativePath):\($0.line)" } == ["a.swift:1", "a.swift:3", "src/b.swift:1", "src/notes.md:1"])
        #expect(rs[1].ranges.count == 2)      // case-insensitive: NEEDLE and needle on one line
        #expect(rs[1].column == 4)
        #expect(rs[1].text == "// NEEDLE again, needle twice")
        #expect(sum.skippedBinary == 1)
        #expect(sum.skippedLarge == 1)
        #expect(sum.filesMatched == 3)
        #expect(sum.results == 4)
    }

    /// The files behind skippedBinary/skippedLarge are listed, each with
    /// its reason, so the replace preview can list what its summary counts.
    @Test func skippedFilesAreListedWithTheirReason() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, sum) = try search(FileSearchOptions(root: root, query: "needle"))
        #expect(sum.skippedFiles.map { "\($0.relativePath):\($0.reason)" } == ["big.log:tooLarge", "blob.bin:binary"])
        #expect(sum.skippedFiles.count == sum.skippedBinary + sum.skippedLarge)
        #expect(sum.skippedFiles.allSatisfy { $0.url.lastPathComponent == $0.relativePath })
    }

    @Test func caseRegexAndGlobs() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var o = FileSearchOptions(root: root, query: "needle", caseSensitive: true, include: ["*.swift"])
        var (rs, _) = try search(o)
        #expect(rs.map(\.relativePath) == ["a.swift", "a.swift", "src/b.swift"])
        #expect(rs[1].ranges.count == 1)
        o = FileSearchOptions(root: root, query: #"func \w+\("#, regex: true, exclude: [])
        (rs, _) = try search(o)
        #expect(rs.map(\.relativePath) == ["src/b.swift"])
        // No excludes: the excluded folders are searched too.
        o = FileSearchOptions(root: root, query: "needle", exclude: [])
        (rs, _) = try search(o)
        #expect(Set(rs.map(\.relativePath)).isSuperset(of: [".git/config", "node_modules/pkg/index.js", "build/out.swift", "src/dist/gen.swift"]))
        // A path glob.
        o = FileSearchOptions(root: root, query: "needle", include: ["src/*.md"])
        (rs, _) = try search(o)
        #expect(rs.map(\.relativePath) == ["src/notes.md"])
        #expect(FileSearchOptions.globs("*.swift, *.md;*.txt") == ["*.swift", "*.md", "*.txt"])
        #expect(throws: FindEngine.FindError.self) { try search(FileSearchOptions(root: root, query: "(", regex: true)) }
    }

    /// Astra batch 9b: files under a folder whose name starts with a
    /// combining mark, first-level or nested, keep their own relative
    /// paths (a text prefix test fused "root/" and the mark and fell back
    /// to the basename, so two files showed as "a.txt"), and path and name
    /// filters and `**/` see them by the "/" bytes.
    @Test func combiningMarkFoldersKeepTheirPathsAndFilters() throws {
        let root = tempDir()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for rel in ["\u{301}m/a.txt", "\u{301}n/a.txt", "x/\u{301}n/b.txt", "plain/c.txt"] {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "needle\n".write(to: u, atomically: true, encoding: .utf8)
        }
        func rels(_ o: FileSearchOptions) throws -> Set<[UInt8]> { Set(try search(o).0.map { Array($0.relativePath.utf8) }) }
        func bytes(_ a: [String]) -> Set<[UInt8]> { Set(a.map { Array($0.utf8) }) }
        #expect(try rels(FileSearchOptions(root: root, query: "needle", exclude: []))
                == bytes(["\u{301}m/a.txt", "\u{301}n/a.txt", "x/\u{301}n/b.txt", "plain/c.txt"]))
        // A name exclude matches the nested mark-leading folder too.
        #expect(try rels(FileSearchOptions(root: root, query: "needle", exclude: ["\u{301}n"])) == bytes(["\u{301}m/a.txt", "plain/c.txt"]))
        // A path exclude matches the first-level one by its path, not its basename.
        #expect(try rels(FileSearchOptions(root: root, query: "needle", exclude: ["\u{301}m/*"]))
                == bytes(["\u{301}n/a.txt", "x/\u{301}n/b.txt", "plain/c.txt"]))
        // `**/` before a mark-leading name, at the top and nested.
        #expect(try rels(FileSearchOptions(root: root, query: "needle", include: ["**/\u{301}m/a.txt"], exclude: [])) == bytes(["\u{301}m/a.txt"]))
        #expect(FileSearch.glob("**/\u{301}n/b.txt", "x/\u{301}n/b.txt"))
        #expect(FileSearch.glob("**/\u{301}n/*.txt", "\u{301}n/a.txt"))
    }

    @Test func capsResults() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try String(repeating: "hit\n", count: 300).write(to: root.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)
        var o = FileSearchOptions(root: root, query: "hit")
        o.maxResults = 100
        let (rs, sum) = try search(o)
        #expect(rs.count == 100)
        #expect(sum.truncated)
    }

    @Test func streamsAndCancels() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let q = DispatchQueue(label: "test")
        let (results, summary): ([FileSearchResult], FileSearchSummary) = try await withCheckedThrowingContinuation { cont in
            let box = Box()
            FileSearch(FileSearchOptions(root: root, query: "needle")).start(callbackQueue: q, batch: { box.add($0) }, done: { r in
                switch r {
                case .success(let s): cont.resume(returning: (box.items, s))
                case .failure(let e): cont.resume(throwing: e)
                }
            })
        }
        #expect(results.count == 4)
        #expect(!summary.cancelled)
        let s = FileSearch(FileSearchOptions(root: root, query: "needle"))
        s.cancel()
        let sum = try s.run { _ in }
        #expect(sum.cancelled)
        #expect(sum.results == 0)
    }

    final class Box: @unchecked Sendable {
        var items: [FileSearchResult] = []
        func add(_ b: [FileSearchResult]) { items += b }
    }

    @Test func globs() {
        #expect(FileSearch.glob("*.swift", "a.swift"))
        #expect(!FileSearch.glob("*.swift", "a.swiftx"))
        #expect(FileSearch.glob("**/*.md", "a/b/c.md"))
        #expect(FileSearch.glob("**/*.md", "c.md"))
        #expect(FileSearch.glob("file?.[ch]", "file1.h"))
    }
}

@Suite(.serialized) struct FileTailTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [FileTail.Event] = []
        func add(_ e: FileTail.Event) { lock.lock(); list.append(e); lock.unlock() }
        var all: [FileTail.Event] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func waitFor(_ events: Events, count: Int) async {
        for _ in 0..<200 where events.all.count < count { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    static func isReset(_ e: FileTail.Event) -> Bool { if case .reset = e { return true } else { return false } }

    /// The text a viewer shows after these events.
    static func shown(_ events: [FileTail.Event]) -> String? {
        var text: String?
        for e in events {
            switch e {
            case .reset(let t): text = t
            case .appended(let t): text = (text ?? "") + t
            }
        }
        return text
    }

    func append(_ url: URL, _ s: String) throws {
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(s.utf8))
        try fh.close()
    }

    @Test func appendTruncateAndRotate() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        try "one\n".write(to: url, atomically: false, encoding: .utf8)
        let events = Events()
        let tail = FileTail(url: url, offset: 4, callbackQueue: DispatchQueue(label: "t")) { events.add($0) }
        tail.start()
        defer { tail.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(events.all.isEmpty)

        try append(url, "two\r\nthr")
        await waitFor(events, count: 1)
        try append(url, "ee\n")
        await waitFor(events, count: 2)
        #expect(events.all == [.appended("two\nthr"), .appended("ee\n")])

        // Truncate in place.
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data("fresh\n".utf8))
        try fh.close()
        // Truncate and write are two steps: the tail may see them as one
        // .reset("fresh\n"), or as .reset("") then .appended("fresh\n") when
        // it looks in between. Either way: a reset first, then this text.
        for _ in 0..<200 where Self.shown(Array(events.all.dropFirst(2))) != "fresh\n" {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let truncated = Array(events.all.dropFirst(2))
        #expect(truncated.first.map(Self.isReset) == true)
        #expect(truncated.dropFirst().allSatisfy { !Self.isReset($0) })
        #expect(Self.shown(truncated) == "fresh\n")

        // Rotate: move away, create a new file at the path.
        let seen = events.all.count
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("app.log.1"))
        try await Task.sleep(nanoseconds: 100_000_000)
        try "rotated\n".write(to: url, atomically: false, encoding: .utf8)
        await waitFor(events, count: seen + 1)
        #expect(events.all.last == .reset("rotated\n"))
        try append(url, "after\n")
        await waitFor(events, count: seen + 2)
        #expect(events.all.last == .appended("after\n"))
    }

    /// Lets every check the tail has queued run, and every event it sent
    /// reach `events`: no sleeps. The tail's queue is serial (`isWatching`
    /// waits on it), and so is the callback queue.
    func settle(_ tail: FileTail, _ callbacks: DispatchQueue) {
        _ = tail.isWatching
        callbacks.sync {}
    }

    func appendBytes(_ url: URL, _ bytes: [UInt8]) throws {
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(bytes))
        try fh.close()
    }

    /// Follow's first read and a reset share one decode: a character cut
    /// in half at the end is left out, and the offset stops before it.
    @Test func decodeWholeLeavesAHalfCharacterOut() throws {
        let le = try #require(FileTail.decodeWhole(Data([0xFF, 0xFE, 0x61, 0x00, 0x62]), as: .utf16LE))
        #expect(le.0.text == "a" && le.1 == 4)
        let be = try #require(FileTail.decodeWhole(Data([0xFE, 0xFF, 0x00, 0x61, 0x00]), as: .utf16BE))
        #expect(be.0.text == "a" && be.1 == 4)
        let bomAndHalf = try #require(FileTail.decodeWhole(Data([0xFF, 0xFE, 0x61]), as: .utf16LE))
        #expect(bomAndHalf.0.text == "" && bomAndHalf.1 == 2)
        let even = try #require(FileTail.decodeWhole(Data([0xFF, 0xFE, 0x61, 0x00]), as: .utf16LE))
        #expect(even.0.text == "a" && even.1 == 4)
        // UTF-8 cut inside "é" (c3 a9).
        let u8 = try #require(FileTail.decodeWhole(Data([0x61, 0xC3]), as: .utf8))
        #expect(u8.0.text == "a" && u8.1 == 1)
    }

    /// Codex 0.5.4 review: Follow started on a UTF-16 file cut mid-character
    /// failed to decode it (odd UTF-16 is refused), kept the stale text,
    /// and followed from the full size, so the next append was read out of
    /// alignment. Started where decodeWhole stops, the tail completes the
    /// character from the append.
    @Test func followStartedOnAUTF16FileCutMidCharacter() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        // BOM, "ab", half of "c".
        let data = Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00, 0x63])
        try data.write(to: url)
        let (first, used) = try #require(FileTail.decodeWhole(data, as: .utf16LE))
        #expect(first.text == "ab" && used == 6)
        let events = Events()
        let callbacks = DispatchQueue(label: "t")
        // As the app starts it: the half character counts as read, held.
        let tail = FileTail(url: url, encoding: .utf16LE, offset: UInt64(used), held: UInt64(data.count - used),
                            callbackQueue: callbacks, stamped: { e, _ in events.add(e) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        #expect(events.all.isEmpty, "the half character alone shows nothing")
        try appendBytes(url, [0x00, 0x64, 0x00])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all == [.appended("cd")])
    }

    /// An append of an odd number of UTF-16 bytes keeps the odd byte for
    /// the next one (Foundation decodes it by dropping the byte).
    @Test func aUTF16AppendWithAnOddByteKeepsIt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        try Data([0xFF, 0xFE]).write(to: url)
        let events = Events()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, encoding: .utf16LE, offset: 2, callbackQueue: callbacks) { events.add($0) }
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        try appendBytes(url, [0x61, 0x00, 0x62])
        tail.poll()
        settle(tail, callbacks)
        try appendBytes(url, [0x00, 0x63, 0x00])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all == [.appended("a"), .appended("bc")])
    }

    /// A followed UTF-16 log replaced by one cut mid-character (odd size,
    /// the writer still busy): the reset shows the whole characters and
    /// keeps the half for the next append.
    @Test func aUTF16ResetCutMidCharacterKeepsTheHalf() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        let start = Data([0xFF, 0xFE]) + "start\n".data(using: .utf16LittleEndian)!
        try start.write(to: url)
        let events = Events()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, encoding: .utf16LE, offset: UInt64(start.count), callbackQueue: callbacks) { events.add($0) }
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        #expect(events.all.isEmpty)

        // Replaced (a new file renamed over it): BOM, "ab", half of "c".
        let next = dir.appendingPathComponent("next.log")
        try Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00, 0x63]).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        try #require(events.all == [.reset("ab")])
        try appendBytes(url, [0x00, 0x64, 0x00])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all == [.reset("ab"), .appended("cd")])
    }

    /// 0.2.1 review M5: closing a followed tab stops its tail (EditorWindowController.windowWillClose);
    /// a stopped tail, or one freed without `stop`, holds no descriptor or timer.
    @Test func stopLeavesNoDescriptor() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fd.log")
        try "x\n".write(to: url, atomically: false, encoding: .utf8)
        func waitOpen(_ n: Int) async {
            for _ in 0..<200 where FileTail.descriptorsOpen(on: url) != n { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(FileTail.descriptorsOpen(on: url) == 0)
        let tail = FileTail(url: url, offset: 2, callbackQueue: DispatchQueue(label: "t")) { _ in }
        tail.start()
        await waitOpen(1)
        #expect(FileTail.descriptorsOpen(on: url) == 1 && tail.isWatching, "following holds one descriptor")
        tail.stop()
        await waitOpen(0)
        #expect(FileTail.descriptorsOpen(on: url) == 0 && !tail.isWatching, "stop closes it")
        tail.poll()
        try append(url, "after stop\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(FileTail.descriptorsOpen(on: url) == 0 && !tail.isWatching, "and nothing reopens it")
        // Freed without stop: deinit cancels the source, which closes it.
        var loose: FileTail? = FileTail(url: url, offset: 0, callbackQueue: DispatchQueue(label: "t2")) { _ in }
        loose?.start()
        await waitOpen(1)
        #expect(FileTail.descriptorsOpen(on: url) == 1)
        loose = nil
        await waitOpen(0)
        #expect(FileTail.descriptorsOpen(on: url) == 0, "deinit closes it")
        // Stopped while waiting for a rotated file: the retry timer goes too.
        let gone = dir.appendingPathComponent("gone.log")
        let waiting = FileTail(url: gone, offset: 0, callbackQueue: DispatchQueue(label: "t3")) { _ in }
        waiting.start()
        for _ in 0..<100 where !waiting.isWatching { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(waiting.isWatching, "a missing file is waited for")
        waiting.stop()
        #expect(!waiting.isWatching)
        try "late\n".write(to: gone, atomically: false, encoding: .utf8)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(FileTail.descriptorsOpen(on: gone) == 0 && !waiting.isWatching, "the file showing up later opens nothing")
    }

    @Test func splitMultibyteCharacterIsHeldBack() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u.log")
        try Data().write(to: url)
        let events = Events()
        let tail = FileTail(url: url, offset: 0, callbackQueue: DispatchQueue(label: "t")) { events.add($0) }
        tail.start()
        defer { tail.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let e = Array("é".utf8)
        var fh = try FileHandle(forWritingTo: url)
        try fh.write(contentsOf: Data([UInt8(ascii: "a"), e[0]]))
        try fh.close()
        await waitFor(events, count: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data([e[1], UInt8(ascii: "\n")]))
        try fh.close()
        await waitFor(events, count: 2)
        #expect(events.all == [.appended("a"), .appended("é\n")])
    }

    final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [UInt64?] = []
        func add(_ n: UInt64?) { lock.lock(); list.append(n); lock.unlock() }
        var all: [UInt64?] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// Codex 0.5.4 review 2: Follow stamped its tab with the whole file's
    /// size while the text left out bytes the tail held back, so stopping
    /// Follow and pressing ⌘S wrote the shorter text over them. Each event
    /// now says how many bytes the text shown stands for: never the held
    /// back half character or trailing CR.
    @Test func eachEventSaysHowManyBytesItShows() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        try Data([0xFF, 0xFE]).write(to: url)
        let events = Events(), shown = Shown()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, encoding: .utf16LE, offset: 2, callbackQueue: callbacks) { e, n in
            events.add(e); shown.add(n)
        }
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        // "a" and half of "b": 5 bytes on disk, 4 shown.
        try appendBytes(url, [0x61, 0x00, 0x62])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all == [.appended("a")])
        #expect(shown.all == [4], "the odd byte isn't shown")
        // The rest of "b" and a CR that may start a CRLF: 8 on disk, 6 shown.
        try appendBytes(url, [0x00, 0x0D, 0x00])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all == [.appended("a"), .appended("b")])
        #expect(shown.all == [4, 6], "the held CR isn't shown")
        try appendBytes(url, [0x0A, 0x00])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all == [.appended("a"), .appended("b"), .appended("\n")])
        #expect(shown.all == [4, 6, 10], "all of it once the CRLF is whole")

        // Replaced by a file cut mid-character: the reset shows 4 of 5.
        let next = dir.appendingPathComponent("next.log")
        try Data([0xFF, 0xFE, 0x63, 0x00, 0x64]).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all.last == .reset("c"))
        #expect(shown.all.last == 4)
    }

    /// A reset that can't decode shows UTF-8 with replacements: not the
    /// file's bytes, nor are appends after it.
    @Test func aLossyResetShowsNoBytes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        let start = Data([0xFF, 0xFE, 0x61, 0x00])
        try start.write(to: url)
        let events = Events(), shown = Shown()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, encoding: .utf16LE, offset: 4, callbackQueue: callbacks) { e, n in
            events.add(e); shown.add(n)
        }
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        // A lone low surrogate before two more characters: not UTF-16,
        // even with the last character or two cut off.
        let next = dir.appendingPathComponent("next.log")
        try Data([0xFF, 0xFE, 0x00, 0xDC, 0x61, 0x00, 0x62, 0x00]).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        try #require(events.all.count == 1 && Self.isReset(events.all[0]))
        #expect(shown.all == [nil])
        try appendBytes(url, [0x62, 0x00])
        tail.poll()
        settle(tail, callbacks)
        #expect(events.all.count == 2)
        #expect(shown.all == [nil, nil])
    }

    /// The stamp Follow gives its tab: with bytes left out, the file no
    /// longer matches it, so ⌘S asks instead of writing over them.
    @Test func aStampShowingFewerBytesIsAChange() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        let odd = Data([0xFF, 0xFE, 0x61, 0x00, 0x62])
        try odd.write(to: url)
        let (_, used) = try #require(FileTail.decodeWhole(odd, as: .utf16LE))
        let stamp = try #require(DiskStamp.of(url))
        #expect(DiskStamp.changed(known: stamp.showing(UInt64(used)), current: DiskStamp.of(url)))
        #expect(DiskStamp.changed(known: stamp.showing(nil), current: DiskStamp.of(url)))
        #expect(!DiskStamp.changed(known: stamp.showing(UInt64(odd.count)), current: DiskStamp.of(url)))
        #expect(stamp.showing(UInt64(odd.count)) == stamp)
    }

    final class Stamps: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(FileTail.Event, FileTail.Shown)] = []
        func add(_ e: FileTail.Event, _ s: FileTail.Shown) { lock.lock(); list.append((e, s)); lock.unlock() }
        var all: [(FileTail.Event, FileTail.Shown)] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// Codex 0.5.4 review 3: Follow stamped its tab with the path's stamp
    /// when a tail event reached the main thread. A same-size file put in
    /// place after the tail read (an atomic replace) lent the old text its
    /// identity and date, and ⌘S after stopping wrote the old text over
    /// it. Each event now carries the stamp the bytes were read at.
    @Test func anAppendCarriesTheStampItWasReadAt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\n".utf8).write(to: url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: 4, callbackQueue: callbacks, stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        // The viewer is busy: the event waits. Resumed on every way out:
        // a suspended queue released crashes, and a throw before `resume`
        // left it suspended.
        callbacks.suspend()
        var suspended = true
        defer { if suspended { callbacks.resume() } }
        try appendBytes(url, Array("two\n".utf8))
        tail.poll()
        _ = tail.isWatching   // read, and queued for the viewer
        let read = try #require(DiskStamp.of(url))
        // A same-size file put in its place before the viewer gets to it.
        let next = dir.appendingPathComponent("next.log")
        try Data("ONE\nTWO\n".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        let replaced = try #require(DiskStamp.of(url))
        #expect(replaced.size == read.size && replaced.identity != read.identity)
        callbacks.resume()
        suspended = false
        settle(tail, callbacks)
        let first = try #require(got.all.first)
        #expect(first.0 == .appended("two\n"))
        #expect(first.1.bytes == 8)
        #expect(first.1.stamp == read, "the stamp of the file the bytes came from")
        #expect(DiskStamp.changed(known: first.1.stamp, current: DiskStamp.of(url)),
                "…so the file put there since is a change: ⌘S asks")
    }

    /// The same for a reset: the stamp of the file the reset read, not of
    /// one put there after.
    @Test func aResetCarriesTheStampItWasReadAt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\n".utf8).write(to: url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: 4, callbackQueue: callbacks, stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        callbacks.suspend()
        var suspended = true
        defer { if suspended { callbacks.resume() } }
        let b = dir.appendingPathComponent("b.log"), c = dir.appendingPathComponent("c.log")
        try Data("bb\n".utf8).write(to: b)
        #expect(rename(b.path, url.path) == 0)
        tail.poll()
        _ = tail.isWatching
        let read = try #require(DiskStamp.of(url))
        try Data("cc\n".utf8).write(to: c)
        #expect(rename(c.path, url.path) == 0)
        callbacks.resume()
        suspended = false
        settle(tail, callbacks)
        let first = try #require(got.all.first)
        #expect(first.0 == .reset("bb\n"))
        #expect(first.1.stamp == read)
        #expect(DiskStamp.changed(known: first.1.stamp, current: DiskStamp.of(url)))
    }

    /// Follow's first read: the bytes and the stamp of the file they came
    /// from, from one descriptor; a FIFO put at the path is refused, not
    /// waited on.
    @Test func readStampedReadsOneFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        #expect(data == Data("one\n".utf8))
        #expect(stamp == DiskStamp.of(url))
        let fifo = dir.appendingPathComponent("p")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try FileTail.readStamped(fifo) }
        #expect(throws: (any Error).self) { try FileTail.readStamped(dir.appendingPathComponent("gone")) }
    }

    /// 0.5.4 QA (follow round 2): a file put in place of the followed one
    /// after Follow's first read but before the tail watched was taken as
    /// the file followed; a larger one then had its tail appended to the
    /// old text, stamped as the new file whole, and ⌘S after stopping
    /// wrote that mix over it. The tail starts from the first read's
    /// identity: a different file is a reset.
    @Test func aRotationBeforeTheTailStartsIsAReset() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        // Rotated to a larger file before the tail starts.
        let next = dir.appendingPathComponent("next.log")
        try Data("NEW FILE\nmore\n".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(data.count), callbackQueue: callbacks, startedFrom: stamp,
                            stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        tail.poll()
        settle(tail, callbacks)
        let first = try #require(got.all.first)
        #expect(first.0 == .reset("NEW FILE\nmore\n"), "the new file whole, not its tail after the old text")
        #expect(first.1.bytes == 14)
        #expect(first.1.stamp == DiskStamp.of(url))
    }

    /// Sol round 3: a rotation whose reset read failed had already taken
    /// the new file's identity, so the next check saw the same file and
    /// appended the new file's bytes past the old offset to the old text,
    /// stamped as the new file: ⌘S after stopping wrote that mix over it.
    /// The identity is taken only once the reset read succeeds.
    @Test func aRotationWhoseResetReadFailsIsResetLater() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(data.count), callbackQueue: callbacks, startedFrom: stamp,
                            stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        #expect(got.all.isEmpty)
        // Rotated to a larger file; its first reset read fails.
        tail.failResetReads(1)
        let next = dir.appendingPathComponent("next.log")
        try Data("NEW FILE\nmore\n".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        tail.poll()
        settle(tail, callbacks)
        let events = got.all
        #expect(!events.contains { if case .appended = $0.0 { return true } else { return false } },
                "no part of the new file appended to the old text: \(events.map(\.0))")
        let last = try #require(events.last)
        #expect(last.0 == .reset("NEW FILE\nmore\n"), "the new file whole, once it reads")
        #expect(last.1.bytes == 14)
        #expect(last.1.stamp == DiskStamp.of(url))
    }

    /// 0.5.4 QA review 3: a truncation (same inode) whose reset read
    /// failed was forgotten. Grown past the old offset again before the
    /// next check, the file's bytes from the old offset on were appended
    /// to the old text and stamped as current. The reset stays pending
    /// until a reset read succeeds.
    @Test func aTruncationWhoseResetReadFailsIsResetAfterItRegrows() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old line one\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(data.count), callbackQueue: callbacks, startedFrom: stamp,
                            stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        // Every reset read fails for now (the watcher may check too).
        tail.failResetReads(1000)
        let inode = DiskStamp.of(url)?.identity
        #expect(truncate(url.path, 0) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(got.all.isEmpty, "the reset read failed: nothing shown yet")
        // The same file grows past the old offset again.
        try appendBytes(url, Array("NEW CONTENT, LONGER\n".utf8))
        #expect(DiskStamp.of(url)?.identity == inode, "the same file")
        tail.poll()
        settle(tail, callbacks)
        tail.failResetReads(0)
        tail.poll()
        settle(tail, callbacks)
        let events = got.all
        #expect(!events.contains { if case .appended = $0.0 { return true } else { return false } },
                "no part of the regrown file appended to the old text: \(events.map(\.0))")
        let last = try #require(events.last)
        #expect(last.0 == .reset("NEW CONTENT, LONGER\n"), "the file whole, once it reads")
        #expect(last.1.bytes == 20)
        #expect(last.1.stamp == DiskStamp.of(url))
    }

    /// What a tab following `url` shows, and the bytes ⌘S would write
    /// after Follow stops (EditorDocument.encoded and appendFollowedBreaks).
    final class FollowedTab: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "", ending = LineEnding.lf, breaks: LineBreaks?
        func show(_ d: DecodedText) {
            lock.lock(); defer { lock.unlock() }
            text = d.text; ending = d.lineEnding; breaks = d.mixedLineEndings ? d.lineBreaks : nil
        }
        func event(_ e: FileTail.Event, _ s: FileTail.Shown) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .appended(let added):
                if let odd = s.lineBreaks {
                    if breaks == nil { breaks = LineBreaks(dominant: ending) }
                    breaks?.append(odd, at: (text as NSString).length)
                }
                text += added
            case .reset(let all):
                text = all
                if let le = s.lineEnding { ending = le }
                breaks = s.lineBreaks
            }
        }
        var shown: String { lock.lock(); defer { lock.unlock() }; return text }
        var saved: Data? {
            lock.lock(); defer { lock.unlock() }
            if let breaks { return TextCodec.encode(breaks.output(text), encoding: .utf8, lineEnding: .lf) }
            return TextCodec.encode(text, encoding: .utf8, lineEnding: ending)
        }
    }

    /// 0.5.4 QA review 3: a CR at the end of Follow's first read (or a
    /// reset's) was taken as a break; the LF that finished that CRLF then
    /// came as a second one, and a save wrote two breaks for one. It is
    /// held, as an append holds it, and the CRLF is saved as it is.
    @Test func aCRLFSplitAtFollowsFirstReadIsOneBreak() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\ntwo\r".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: .utf8))
        #expect(d.text == "one\ntwo" && used == 7, "the trailing CR is held: \(d.text.debugDescription) \(used)")
        let tab = FollowedTab()
        tab.show(d)
        let callbacks = DispatchQueue(label: "t")
        // As the app starts it: the held CR counts as read.
        let tail = FileTail(url: url, offset: UInt64(used), held: UInt64(data.count - used), callbackQueue: callbacks,
                            startedFrom: stamp, lineEnding: d.lineEnding, stamped: { tab.event($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        try appendBytes(url, Array("\nthree\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        #expect(tab.shown == "one\ntwo\nthree\n", "\(tab.shown.debugDescription)")
        #expect(tab.saved == (try Data(contentsOf: url)), "saved as the file is: \(String(decoding: tab.saved ?? Data(), as: UTF8.self).debugDescription)")
    }

    /// The same across a reset: a rotated file ending in a CR.
    @Test func aCRLFSplitAtAResetIsOneBreak() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: .utf8))
        let tab = FollowedTab()
        tab.show(d)
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(used), callbackQueue: callbacks, startedFrom: stamp,
                            lineEnding: d.lineEnding, stamped: { tab.event($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        let next = dir.appendingPathComponent("next.log")
        try Data("x\ny\r".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(tab.shown == "x\ny", "the reset holds the CR: \(tab.shown.debugDescription)")
        try appendBytes(url, Array("\nz\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        #expect(tab.shown == "x\ny\nz\n", "\(tab.shown.debugDescription)")
        #expect(tab.saved == (try Data(contentsOf: url)), "saved as the file is: \(String(decoding: tab.saved ?? Data(), as: UTF8.self).debugDescription)")
    }

    /// Sol, 0.5.4 QA round 4: the CR held at Follow's first read was
    /// counted out of the bytes read, so `old\r` rewritten in place as
    /// `new` (the size the tail thought it had read) went unseen, and the
    /// LF after it showed `old\n`, stamped as the file. The held bytes
    /// count as read: the file cut below them is a reset.
    @Test func aFileRewrittenBelowAHeldCRAtTheFirstReadIsAReset() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old\r".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: .utf8))
        #expect(d.text == "old" && used == 3)
        let tab = FollowedTab()
        tab.show(d)
        // Rewritten in place (same file) before the tail's first look.
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data("new".utf8))
        try fh.close()
        #expect(DiskStamp.of(url)?.identity == stamp.identity, "the same file")
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(used), held: UInt64(data.count - used), callbackQueue: callbacks,
                            startedFrom: stamp, lineEnding: d.lineEnding, stamped: { tab.event($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        #expect(tab.shown == "new", "the rewrite is a reset: \(tab.shown.debugDescription)")
        try appendBytes(url, Array("\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        #expect(tab.shown == "new\n", "\(tab.shown.debugDescription)")
        #expect(tab.saved == (try Data(contentsOf: url)), "saved as the file is: \(String(decoding: tab.saved ?? Data(), as: UTF8.self).debugDescription)")
    }

    /// The same after a reset: a CR held there counts as read, so the file
    /// cut to the bytes shown is seen (a reset, stamped as the file now).
    @Test func aFileCutBelowAResetsHeldCRIsAReset() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: .utf8))
        final class Got: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [(FileTail.Event, FileTail.Shown)] = []
            func add(_ e: FileTail.Event, _ s: FileTail.Shown) { lock.lock(); list.append((e, s)); lock.unlock() }
            var all: [(FileTail.Event, FileTail.Shown)] { lock.lock(); defer { lock.unlock() }; return list }
        }
        let got = Got()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(used), callbackQueue: callbacks, startedFrom: stamp,
                            lineEnding: d.lineEnding, stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        let next = dir.appendingPathComponent("next.log")
        try Data("ab\r".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(got.all.last?.0 == .reset("ab") && got.all.last?.1.bytes == 2, "\(got.all.map(\.0))")
        let before = got.all.count
        #expect(truncate(url.path, 2) == 0)
        tail.poll()
        settle(tail, callbacks)
        let after = got.all.dropFirst(before)
        #expect(after.contains { $0.0 == .reset("ab") }, "the cut is a reset: \(after.map(\.0))")
        let last = try #require(got.all.last)
        #expect(last.1.bytes == 2 && last.1.stamp == DiskStamp.of(url), "stamped as the file now")
    }

    /// Writes `bytes` at `offset` in `url` in one write (the same file).
    func overwrite(_ url: URL, at offset: UInt64, _ bytes: [UInt8]) throws {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: offset)
        try fh.write(contentsOf: Data(bytes))
    }

    /// 0.5.4 QA leftovers 2: the bytes held at Follow's first read were
    /// kept, and decoded with the next append as they were then. A writer
    /// that rewrote them before the first look (`C2` finished as `C3 A9`,
    /// a CR rewritten as `X` and an LF) was shown as `©` or a CRLF, stamped
    /// as the file, so ⌘S wrote that over the file's real bytes. The held
    /// bytes are reread with the append.
    @Test(arguments: [(Array("abc".utf8) + [0xC2], Array("abc".utf8) + [0xC3, 0xA9], "abc", "abcé"),
                      (Array("old\r".utf8), Array("oldX\n".utf8), "old", "oldX\n")])
    func heldBytesRewrittenBeforeTheFirstLookAreShownAsTheFileHasThem(_ c: ([UInt8], [UInt8], String, String)) throws {
        let (first, now, shownFirst, shownNow) = c
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data(first).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: .utf8))
        #expect(d.text == shownFirst && used == shownFirst.utf8.count, "the last byte is held")
        let tab = FollowedTab()
        tab.show(d)
        let got = Stamps()
        // The held byte rewritten (and the file grown) in one write, in place.
        try overwrite(url, at: UInt64(used), Array(now[used...]))
        #expect(DiskStamp.of(url)?.identity == stamp.identity, "the same file")
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(used), held: UInt64(data.count - used), callbackQueue: callbacks,
                            startedFrom: stamp, lineEnding: d.lineEnding, stamped: { tab.event($0, $1); got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        #expect(tab.shown == shownNow, "as the file has it: \(tab.shown.debugDescription)")
        #expect(tab.saved == Data(now), "saved as the file is: \(String(decoding: tab.saved ?? Data(), as: UTF8.self).debugDescription)")
        let last = try #require(got.all.last)
        #expect(last.1.bytes == UInt64(now.count) && last.1.stamp == DiskStamp.of(url), "stamped as the file now")
    }

    /// The same for the bytes a reset held.
    @Test(arguments: [(Array("ab".utf8) + [0xC2], Array("ab".utf8) + [0xC3, 0xA9], "ab", "abé"),
                      (Array("ab\r".utf8), Array("abX\n".utf8), "ab", "abX\n")])
    func heldBytesRewrittenAfterAResetAreShownAsTheFileHasThem(_ c: ([UInt8], [UInt8], String, String)) throws {
        let (first, now, shownFirst, shownNow) = c
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("old\n".utf8).write(to: url)
        let (data, stamp) = try FileTail.readStamped(url)
        let (d, used) = try #require(FileTail.decodeWhole(data, as: .utf8))
        let tab = FollowedTab()
        tab.show(d)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: UInt64(used), held: UInt64(data.count - used), callbackQueue: callbacks,
                            startedFrom: stamp, lineEnding: d.lineEnding, stamped: { tab.event($0, $1); got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        let next = dir.appendingPathComponent("next.log")
        try Data(first).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(tab.shown == shownFirst, "the reset holds the last byte: \(tab.shown.debugDescription)")
        try overwrite(url, at: UInt64(shownFirst.utf8.count), Array(now[shownFirst.utf8.count...]))
        tail.poll()
        settle(tail, callbacks)
        #expect(tab.shown == shownNow, "as the file has it: \(tab.shown.debugDescription)")
        #expect(tab.saved == Data(now), "saved as the file is: \(String(decoding: tab.saved ?? Data(), as: UTF8.self).debugDescription)")
        let last = try #require(got.all.last)
        #expect(last.1.bytes == UInt64(now.count) && last.1.stamp == DiskStamp.of(url), "stamped as the file now")
    }

    /// decodeWhole finds the CR to hold in the bytes (one decode), also
    /// before a UTF-16 odd byte (maybe the first half of the LF).
    @Test func decodeWholeHoldsACRFoundInTheBytes() throws {
        #expect(FileTail.heldCR(Data("ab\r".utf8), .utf8) == 2)
        #expect(FileTail.heldCR(Data("ab\r\n".utf8), .utf8) == nil)
        #expect(FileTail.heldCR(Data("\r".utf8), .utf8) == 0)
        #expect(FileTail.heldCR(Data(), .utf8) == nil)
        let le = Data([0xFF, 0xFE, 0x61, 0x00, 0x0D, 0x00])
        #expect(FileTail.heldCR(le, .utf16LE) == 4)
        #expect(FileTail.heldCR(le + [0x0A], .utf16LE) == 4, "CR, then half an LF")
        #expect(FileTail.heldCR(Data([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x0D, 0x00]), .utf16BE) == 4)
        let (d, used) = try #require(FileTail.decodeWhole(le + [0x0A], as: .utf16LE))
        #expect(d.text == "a" && used == 4)
        let (u8, n) = try #require(FileTail.decodeWhole(Data("one\ntwo\r".utf8), as: .utf8))
        #expect(u8.text == "one\ntwo" && n == 7 && u8.lineEnding == .lf)
    }

    /// 0.5.4 QA (follow round 2): an append that didn't decode was skipped
    /// (its bytes counted as read), and the next good append stamped the
    /// whole file's size: ⌘S then dropped the skipped bytes with no
    /// question. After a skip no event shows a size, until a reset.
    @Test func aSkippedAppendLeavesTheTextLossy() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\n".utf8).write(to: url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: 4, callbackQueue: callbacks, stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        // Not UTF-8 however it's cut: skipped.
        try appendBytes(url, [0xFF, 0xFE, 0xFF, 0xFE, 0xFF])
        tail.poll()
        settle(tail, callbacks)
        try appendBytes(url, Array("two\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        let appended = got.all.filter { $0.0 == .appended("two\n") }
        try #require(appended.count == 1)
        #expect(appended[0].1.bytes == nil, "no size: the skipped bytes aren't in the text")
        #expect(DiskStamp.changed(known: appended[0].1.stamp, current: DiskStamp.of(url)), "so ⌘S asks")
        // A faithful reset makes it whole again.
        let next = dir.appendingPathComponent("next.log")
        try Data("fresh\n".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(got.all.last?.0 == .reset("fresh\n"))
        #expect(got.all.last?.1.bytes == 6)
    }

    /// 0.5.4 QA (follow round 2): truncated or rotated to an empty file,
    /// the reset never came (readToEnd says nil at the end), so the old
    /// text and offset stayed; a file growing back past that offset was
    /// then followed as an append to the old text.
    @Test func anEmptyRotationIsAReset() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\ntwo\n".utf8).write(to: url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: 8, callbackQueue: callbacks, stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        let next = dir.appendingPathComponent("next.log")
        try Data().write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        #expect(got.all.map(\.0) == [.reset("")])
        #expect(got.all.first?.1.bytes == 0)
        // Grows back past the old offset: followed from the new start.
        try appendBytes(url, Array("ABCDEFGHIJ\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        #expect(Self.shown(got.all.map(\.0)) == "ABCDEFGHIJ\n")
    }

    /// 0.5.4 QA (should round 2): appended text comes with every break as
    /// LF, so a CRLF line appended to an LF log, saved after Follow
    /// stopped, became LF; and a rotation kept the previous file's breaks.
    /// Each event now carries the breaks of the text it shows.
    @Test func eventsCarryTheirLineBreaks() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.log")
        try Data("one\n".utf8).write(to: url)
        let got = Stamps()
        let callbacks = DispatchQueue(label: "t")
        let tail = FileTail(url: url, offset: 4, callbackQueue: callbacks, lineEnding: .lf, stamped: { got.add($0, $1) })
        tail.start()
        defer { tail.stop() }
        settle(tail, callbacks)
        try appendBytes(url, Array("ab\r\ncd\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        let a = try #require(got.all.first)
        #expect(a.0 == .appended("ab\ncd\n"))
        #expect(a.1.lineEnding == nil)
        #expect(a.1.lineBreaks?.others == [LineBreaks.entry(2, .crlf)], "the CRLF, at its offset in the appended text")
        // An append of the dominant kind only: none.
        try appendBytes(url, Array("ef\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        #expect(got.all.last?.1.lineBreaks == nil)

        // Rotated to a CRLF file with one LF: its own breaks.
        let next = dir.appendingPathComponent("next.log")
        try Data("x\r\ny\r\nz\n".utf8).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        tail.poll()
        settle(tail, callbacks)
        let r = try #require(got.all.last)
        #expect(r.0 == .reset("x\ny\nz\n"))
        #expect(r.1.lineEnding == .crlf)
        #expect(r.1.lineBreaks?.others == [LineBreaks.entry(5, .lf)])
        // Appends now count against CRLF: an LF one is odd, a CRLF isn't.
        try appendBytes(url, Array("p\nq\r\n".utf8))
        tail.poll()
        settle(tail, callbacks)
        #expect(got.all.last?.0 == .appended("p\nq\n"))
        #expect(got.all.last?.1.lineBreaks?.others == [LineBreaks.entry(1, .lf)])
    }
}
