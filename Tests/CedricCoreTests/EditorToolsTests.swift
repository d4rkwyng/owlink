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

    @Test func xmlPretty() throws {
        let out = try t(.xmlPrettyPrint, "<root b=\"2\" a=\"1\"><item>x</item><empty/><!-- c --></root>")
        #expect(out.contains("<root b=\"2\" a=\"1\">"))
        #expect(out.contains("\n    <item>x</item>"))
        #expect(out.contains("<empty/>") || out.contains("<empty></empty>"))
        #expect(!out.hasPrefix("<?xml"))
        #expect(throws: TextToolError.self) { try t(.xmlPrettyPrint, "<a><b></a>") }
    }

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

    /// A followed UTF-16 log replaced by one cut mid-character (odd size,
    /// the writer still busy): the reset shows the whole characters and
    /// keeps the half for the next append. TextCodec refuses odd UTF-16
    /// (it dropped the last byte), so the reset holds it back itself.
    @Test func aUTF16ResetCutMidCharacterKeepsTheHalf() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("u16.log")
        let start = Data([0xFF, 0xFE]) + "start\n".data(using: .utf16LittleEndian)!
        try start.write(to: url)
        let events = Events()
        let tail = FileTail(url: url, encoding: .utf16LE, offset: UInt64(start.count), callbackQueue: DispatchQueue(label: "t")) { events.add($0) }
        tail.start()
        defer { tail.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Replaced (a new file renamed over it): BOM, "ab", half of "c".
        let next = dir.appendingPathComponent("next.log")
        try Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00, 0x63]).write(to: next)
        #expect(rename(next.path, url.path) == 0)
        await waitFor(events, count: 1)
        #expect(events.all.first == .reset("ab"))
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data([0x00, 0x64, 0x00]))
        try fh.close()
        await waitFor(events, count: 2)
        #expect(Self.shown(events.all) == "abcd")
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
}
