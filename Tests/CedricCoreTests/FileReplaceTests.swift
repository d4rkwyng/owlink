import Foundation
import Testing
@testable import CedricCore

@Suite struct FileReplaceTests {
    func dir() throws -> URL {
        let d = tempDir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.resolvingSymlinksInPath()
    }

    func put(_ root: URL, _ rel: String, _ data: Data) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    func candidates(_ root: URL, _ urls: [URL]) -> [FileReplace.Candidate] {
        urls.map { .init(url: $0, relativePath: String($0.path.dropFirst(root.path.count + 1)), searchStamp: DiskStamp.of($0)) }
    }

    /// Plans and writes every edit; returns the report.
    func replaceAll(_ q: ReplaceQuery, root: URL, _ urls: [URL], store: ReplaceUndoStore) throws -> (ReplacePlan, ReplaceReport) {
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, urls))
        return (plan, FileReplace.apply(plan.files, query: q, root: root, store: store))
    }

    @Test func encodingsRoundTripByteExact() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let cases: [(String, Data, Data)] = [
            ("utf8.txt", Data("café owl\nowl\n".utf8), Data("café OWL\nOWL\n".utf8)),
            ("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("owl ünï\n".utf8), Data([0xEF, 0xBB, 0xBF]) + Data("OWL ünï\n".utf8)),
            ("u16le.txt", Data([0xFF, 0xFE]) + "owl é\r\n".data(using: .utf16LittleEndian)!,
             Data([0xFF, 0xFE]) + "OWL é\r\n".data(using: .utf16LittleEndian)!),
            ("u16be.txt", Data([0xFE, 0xFF]) + "x owl\n".data(using: .utf16BigEndian)!,
             Data([0xFE, 0xFF]) + "x OWL\n".data(using: .utf16BigEndian)!),
            ("latin1.txt", "naïve owl\n".data(using: .isoLatin1)!, "naïve OWL\n".data(using: .isoLatin1)!),
            ("crlf.txt", Data("a owl\r\nb\r\nowl c\r\n".utf8), Data("a OWL\r\nb\r\nOWL c\r\n".utf8)),
            ("cr.txt", Data("owl\rx\r".utf8), Data("OWL\rx\r".utf8)),
        ]
        let urls = try cases.map { try put(root, $0.0, $0.1) }
        let (plan, report) = try replaceAll(ReplaceQuery(query: "owl", template: "OWL", caseSensitive: true), root: root, urls, store: store)
        #expect(plan.skipped.isEmpty, "\(plan.skipped)")
        #expect(report.written.count == cases.count)
        for (u, c) in zip(urls, cases) {
            #expect(try Data(contentsOf: u) == c.2, "\(c.0)")
        }
    }

    @Test func mixedEndingsAndBinaryAndLargeSkipped() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mixed = try put(root, "mixed.txt", Data("owl\r\nowl\n".utf8))
        let bin = try put(root, "b.bin", Data("owl".utf8) + Data([0, 1, 0]))
        let big = try put(root, "big.txt", Data("owl ".utf8) + Data(repeating: 0x61, count: 2048))
        let q = ReplaceQuery(query: "owl", template: "x")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [mixed, bin, big]), maxFileSize: 1024)
        #expect(plan.files.isEmpty)
        #expect(plan.skippedCount(.mixedLineEndings) == 1)
        #expect(plan.skippedCount(.binary) == 1)
        #expect(plan.skippedCount(.tooLarge) == 1)
    }

    @Test func regexTemplatesCaseAndZeroLength() throws {
        let q = ReplaceQuery(query: #"(\w+)@(\w+)"#, template: "$2 at $1", regex: true)
        let re = try FindEngine.regex(q.query, q.findOptions)
        let text = "mail bob@home\nand Amy@Work\n"
        let e = FileReplace.edits(in: text, regex: re, query: q)
        #expect(FileReplace.applying(e, to: text) == "mail home at bob\nand Work at Amy\n")
        #expect(e.map(\.line) == [1, 2])
        #expect(e[1].lineText == "and Amy@Work" && e[1].lineRange == NSRange(location: 4, length: 8))
        // The find bar's Replace All gives the same text.
        #expect(try FindEngine.replaceAll(in: text, pattern: q.query, with: q.template, options: q.findOptions).0 == FileReplace.applying(e, to: text))
        // Case-insensitive literal; "$1" stays literal outside regex mode.
        let lit = ReplaceQuery(query: "OWL", template: "$1")
        let le = FileReplace.edits(in: "owl Owl", regex: try FindEngine.regex(lit.query, lit.findOptions), query: lit)
        #expect(FileReplace.applying(le, to: "owl Owl") == "$1 $1")
        // Zero-length matches are ignored.
        let z = ReplaceQuery(query: "x*", template: "-", regex: true)
        let ze = FileReplace.edits(in: "abxxc", regex: try FindEngine.regex(z.query, z.findOptions), query: z)
        #expect(ze.count == 1 && FileReplace.applying(ze, to: "abxxc") == "ab-c")
        // Line anchors per line, as the find bar.
        let a = ReplaceQuery(query: "^", template: "> ", regex: true)
        #expect(FileReplace.edits(in: "a\nb", regex: try FindEngine.regex(a.query, a.findOptions), query: a).isEmpty)
        let b = ReplaceQuery(query: "^(.)", template: "> $1", regex: true)
        #expect(FileReplace.applying(FileReplace.edits(in: "a\nb", regex: try FindEngine.regex(b.query, b.findOptions), query: b), to: "a\nb") == "> a\n> b")
    }

    @Test func spanIsOneBufferChange() throws {
        let q = ReplaceQuery(query: "o", template: "00")
        let text = "xo yo zo!"
        let e = FileReplace.edits(in: text, regex: try FindEngine.regex(q.query, q.findOptions), query: q)
        let (span, new) = try #require(FileReplace.span(Array(e.dropFirst()), in: text))
        #expect(span == NSRange(location: 4, length: 4))
        #expect(new == "00 z00")
    }

    @Test func stampMismatchSkipped() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let a = try put(root, "a.txt", Data("owl\n".utf8))
        let b = try put(root, "b.txt", Data("owl\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "cat")
        // Changed between search and preview.
        var cs = candidates(root, [a, b])
        cs[0].searchStamp = DiskStamp(modified: Date(timeIntervalSince1970: 1), size: 4)
        let plan = try FileReplace.plan(q, root: root, candidates: cs)
        #expect(plan.skippedCount(.changedSinceSearch) == 1 && plan.files.count == 1)
        // Changed between preview and write, same size and (forced) same date: the hash catches it.
        let date = try FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as! Date
        try Data("OWL\n".utf8).write(to: b)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        let report = FileReplace.apply(plan.files, query: q, root: root, store: store)
        #expect(report.written.isEmpty)
        #expect(report.skipped.map(\.reason) == [.changedSincePreview])
        #expect(try Data(contentsOf: b) == Data("OWL\n".utf8))
        #expect(report.operation == nil)
    }

    @Test func permissionsAndXattrsKept() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "run.sh", Data("echo owl\n".utf8))
        chmod(f.path, 0o750)
        setxattr(f.path, "org.owlink.test", "v", 1, 0, 0)
        _ = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, [f], store: store)
        var st = stat()
        stat(f.path, &st)
        #expect(st.st_mode & 0o7777 == 0o750)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(getxattr(f.path, "org.owlink.test", &buf, 4, 0, 0) == 1)
        #expect(try String(contentsOf: f, encoding: .utf8) == "echo hoot\n")
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [".undo", "run.sh"])
    }

    @Test func undoRestoresBytesAndSkipsLaterEdits() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let origA = Data([0xEF, 0xBB, 0xBF]) + Data("owl\r\nowl\r\n".utf8)
        let origB = Data("one owl\n".utf8)
        let a = try put(root, "a.txt", origA)
        let b = try put(root, "b.txt", origB)
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "bird"), root: root, [a, b], store: store)
        let id = try #require(report.operation)
        #expect(report.replacements == 3)
        // The backup folder is private.
        var st = stat()
        stat(root.appendingPathComponent(".undo/\(id.uuidString)").path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        // b is edited again after the replace: undo leaves it alone.
        try Data("one bird!\n".utf8).write(to: b)
        let u = store.undo(id)
        #expect(u.restored.map(\.lastPathComponent) == ["a.txt"])
        #expect(u.skipped.map(\.reason) == [.changedSinceReplace])
        #expect(try Data(contentsOf: a) == origA)
        #expect(try Data(contentsOf: b) == Data("one bird!\n".utf8))
        #expect(store.manifest(id)?.undone == true)
        // A second undo does nothing.
        #expect(store.undo(id).restored.isEmpty)
    }

    @Test func manifestPruning() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent("undo"))
        let q = ReplaceQuery(query: "a", template: "b")
        let now = Date()
        var ids: [UUID] = []
        // One 8 days old, then six recent ones.
        ids.append(try store.begin(query: q, now: now.addingTimeInterval(-8 * 24 * 3600)).id)
        for k in 0..<6 { ids.append(try store.begin(query: q, now: now.addingTimeInterval(Double(k))).id) }
        store.prune(now: now.addingTimeInterval(10))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path))
        #expect(left == Set(ids.suffix(5).map(\.uuidString)))
    }

    @Test func symlinksAndOutsideRootRefused() throws {
        let root = try dir()
        let outside = try dir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let target = try put(outside, "t.txt", Data("owl\n".utf8))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let hard = try put(root, "h.txt", Data("owl\n".utf8))
        try FileManager.default.linkItem(at: hard, to: root.appendingPathComponent("h2.txt"))
        let q = ReplaceQuery(query: "owl", template: "x")
        let plan = try FileReplace.plan(q, root: root, candidates: [
            .init(url: link, relativePath: "link.txt", searchStamp: nil),
            .init(url: target, relativePath: "t.txt", searchStamp: nil),
            .init(url: hard, relativePath: "h.txt", searchStamp: nil),
        ])
        #expect(plan.files.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.symbolicLink, .outsideFolder, .hardLinked])
        #expect(try Data(contentsOf: target) == Data("owl\n".utf8))
    }

    @Test func openBuffersPlannedFromTheirText() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "open.txt", Data("owl on disk\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "cat")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]),
                                        buffers: [f.standardizedFileURL.path: OpenBuffer(text: "owl owl unsaved", fileID: DiskStamp.of(f)?.identity)])
        #expect(plan.files.count == 1 && plan.files[0].disk == nil && plan.files[0].edits.count == 2)
        // apply never writes a buffer-planned file.
        let r = FileReplace.apply(plan.files, query: q, root: root, store: store)
        #expect(r.written.isEmpty)
        #expect(try Data(contentsOf: f) == Data("owl on disk\n".utf8))
    }

    /// Another file put at `url`'s spelling, as a sync client or a restore
    /// does: written next to it, then renamed over it (a new inode).
    func replaceAtSamePath(_ url: URL, _ data: Data) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sync-\(UUID().uuidString)")
        try data.write(to: tmp)
        #expect(rename(tmp.path, url.path) == 0)
    }

    /// Sol 21v-3 (class i), planning: a tab's text is planned only when the
    /// file the tab recorded (read or saved) is the file at the path now.
    /// A file replaced at the same spelling since, or a buffer with no
    /// recorded identity, is refused as out of date: neither the tab's
    /// text nor the disk's is planned, and nothing is written.
    @Test func staleTabBufferNotPlanned() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try put(root, "s.txt", Data("owl old\n".utf8))
        let recorded = try #require(DiskStamp.of(f)?.identity)
        let q = ReplaceQuery(query: "owl", template: "cat")
        // Same path, same file: planned from the tab.
        let fresh = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]),
                                         buffers: [f.standardizedFileURL.path: OpenBuffer(text: "owl tab\n", fileID: recorded)])
        #expect(fresh.files.count == 1 && fresh.files[0].disk == nil && fresh.files[0].fileID == recorded)
        try replaceAtSamePath(f, Data("owl synced\n".utf8))
        let now = try #require(DiskStamp.of(f)?.identity)
        try #require(now != recorded, "the rename put another inode at the path")
        for id in [recorded, nil] as [DiskStamp.FileID?] {
            let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]),
                                            buffers: [f.standardizedFileURL.path: OpenBuffer(text: "owl tab\n", fileID: id)])
            #expect(plan.files.isEmpty && plan.skipped.map(\.reason) == [.tabOutOfDate])
        }
        #expect(try Data(contentsOf: f) == Data("owl synced\n".utf8))
        // A disk plan records the file it read.
        let disk = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]))
        #expect(disk.files.count == 1 && disk.files[0].fileID == now && disk.files[0].disk?.stamp.identity == now)
    }

    /// Sol 21v-3 (class i), apply: the tab decision uses the identity the
    /// tab recorded and the one the plan recorded, against the file at
    /// the path now, never the path alone. A tab still holding the old
    /// file's text after the file was replaced at the same spelling is
    /// out of date; a tab that read the new file is current but the plan
    /// was for the old one (changed since the preview); a file gone since
    /// is out of date too. Only all three agreeing, with the exact
    /// planned text, lets the edits in.
    @Test func tabDecisionByRecordedIdentity() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try put(root, "t.txt", Data("owl\n".utf8))
        let old = try #require(DiskStamp.of(f)?.identity)
        let q = ReplaceQuery(query: "owl", template: "cat")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]),
                                        buffers: [f.standardizedFileURL.path: OpenBuffer(text: "owl tab\n", fileID: old)])
        let file = try #require(plan.files.first)
        #expect(FileReplace.tabRefusal(file, tabText: "owl tab\n", tabFileID: old, fileIDNow: old) == nil)
        try replaceAtSamePath(f, Data("owl synced\n".utf8))
        let new = try #require(DiskStamp.of(f)?.identity)
        try #require(new != old)
        #expect(FileReplace.tabRefusal(file, tabText: "owl tab\n", tabFileID: old, fileIDNow: new) == .tabOutOfDate)
        #expect(FileReplace.tabRefusal(file, tabText: "owl tab\n", tabFileID: new, fileIDNow: new) == .changedSincePreview)
        #expect(FileReplace.tabRefusal(file, tabText: "owl tab\n", tabFileID: nil, fileIDNow: new) == .tabOutOfDate)
        #expect(FileReplace.tabRefusal(file, tabText: "owl tab\n", tabFileID: old, fileIDNow: nil) == .tabOutOfDate)
        #expect(try Data(contentsOf: f) == Data("owl synced\n".utf8))
    }

    /// Sol 21v-3 (class i): a preview replacing "b" in "\u{E9}ab", then the
    /// tab's text changed to the canonically equal "e\u{301}ab" (one UTF-16
    /// unit longer). Swift's == calls them equal, but the planned range
    /// would now cover "a": the tab is refused, never edited there.
    @Test func tabTextComparedByExactUTF16() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try put(root, "e.txt", Data("x\n".utf8))
        let q = ReplaceQuery(query: "b", template: "X", caseSensitive: true)
        let planned = "\u{E9}ab", changed = "e\u{301}ab"
        let id = DiskStamp.of(f)?.identity
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]), buffers: [f.standardizedFileURL.path: OpenBuffer(text: planned, fileID: id)])
        try #require(plan.files.count == 1 && plan.files[0].edits.count == 1)
        let file = plan.files[0]
        #expect(file.edits[0].range == NSRange(location: 2, length: 1))
        // Why == is not enough: equal to Swift, and the planned range lands on "a".
        #expect(changed == planned && (changed as NSString).length == 4)
        #expect(FileReplace.span(file.edits, in: changed).map { (changed as NSString).replacingCharacters(in: $0.0, with: $0.1) } == "e\u{301}Xb")
        #expect(!FileReplace.sameSource(changed, planned))
        #expect(FileReplace.tabRefusal(file, tabText: changed, tabFileID: id, fileIDNow: id) == .changedSincePreview)
        // The exact text it was planned against is taken.
        #expect(FileReplace.sameSource(planned, "\u{E9}ab"))
        #expect(FileReplace.tabRefusal(file, tabText: planned, tabFileID: id, fileIDNow: id) == nil)
    }

    @Test func unencodableReplacementSkipped() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try put(root, "l.txt", "caf\u{E9} owl\n".data(using: .isoLatin1)!)
        let plan = try FileReplace.plan(ReplaceQuery(query: "owl", template: "🦉"), root: root, candidates: candidates(root, [f]))
        #expect(plan.files.isEmpty && plan.skippedCount(.cannotEncode) == 1)
    }

    @Test func partialSelectionWritesOnlyCheckedEdits() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "p.txt", Data("owl1 owl2 owl3\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "cat")
        var plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [f]))
        plan.files[0].edits.remove(at: 1)
        let r = FileReplace.apply(plan.files, query: q, root: root, store: store)
        #expect(r.replacements == 2)
        #expect(try String(contentsOf: f, encoding: .utf8) == "cat1 owl2 cat3\n")
    }

    @Test func applyReportsProgressPerFileAndStage() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let urls = try (0..<3).map { try put(root, "f\($0).txt", Data("owl \($0)\n".utf8)) }
        let q = ReplaceQuery(query: "owl", template: "hoot")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, urls))
        // The third file changes after the preview: checked, never backed up or written.
        try Data("owl changed\n".utf8).write(to: urls[2])
        var seen: [ReplaceProgress] = []
        let r = FileReplace.apply(plan.files, query: q, root: root, store: store) { seen.append($0) }
        #expect(r.written.count == 2 && r.skipped.map(\.reason) == [.changedSincePreview])
        #expect(seen == [
            ReplaceProgress(stage: .checking, done: 1, total: 3), ReplaceProgress(stage: .checking, done: 2, total: 3),
            ReplaceProgress(stage: .checking, done: 3, total: 3),
            ReplaceProgress(stage: .backingUp, done: 1, total: 2), ReplaceProgress(stage: .backingUp, done: 2, total: 2),
            ReplaceProgress(stage: .writing, done: 1, total: 2), ReplaceProgress(stage: .writing, done: 2, total: 2),
        ])
    }

    @Test func applyOffTheMainThreadKeepsEveryByte() async throws {
        // What the app does: plan, then write on a background queue.
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let orig: [String: Data] = [
            "bom.txt": Data([0xEF, 0xBB, 0xBF]) + Data("owl\r\nowl\r\n".utf8),
            "latin.txt": "café owl\n".data(using: .isoLatin1)!,
            "u16.txt": "owl\n".data(using: .utf16)!,
        ]
        var urls: [URL] = []
        for (k, v) in orig.sorted(by: { $0.key < $1.key }) { urls.append(try put(root, k, v)) }
        chmod(urls[1].path, 0o604)
        let q = ReplaceQuery(query: "owl", template: "hibou")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, urls))
        let files = plan.files
        let (report, onMain) = await withCheckedContinuation { (c: CheckedContinuation<(ReplaceReport, Bool), Never>) in
            DispatchQueue(label: "test.replace.write").async {
                c.resume(returning: (FileReplace.apply(files, query: q, root: root, store: store), Thread.isMainThread))
            }
        }
        #expect(!onMain && report.written.count == 3 && report.replacements == 4)
        #expect(try Data(contentsOf: urls[0]) == Data([0xEF, 0xBB, 0xBF]) + Data("hibou\r\nhibou\r\n".utf8))
        #expect(try Data(contentsOf: urls[1]) == "café hibou\n".data(using: .isoLatin1))
        #expect(try Data(contentsOf: urls[2]) == "hibou\n".data(using: .utf16))
        var st = stat()
        stat(urls[1].path, &st)
        #expect(st.st_mode & 0o7777 == 0o604)
        let u = store.undo(try #require(report.operation))
        #expect(u.restored.count == 3)
        for (k, v) in orig { #expect(try Data(contentsOf: root.appendingPathComponent(k)) == v, "\(k)") }
    }

    // MARK: 0.2.0 release review (HK-47). The skip reasons are compared by
    // raw value so these tests also build against the code before the fix.

    func mtime(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
    func setOld(_ u: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: u.path) // 2020-01-01
    }

    @Test func replaceAndUndoGiveANewModificationDate() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "old.txt", Data("owl\n".utf8))
        try setOld(f)
        let start = Date().addingTimeInterval(-60)
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, [f], store: store)
        #expect(report.written.count == 1)
        #expect((mtime(f) ?? .distantPast) > start, "replace kept the old date: \(String(describing: mtime(f)))")
        // Undo, with the file dated 2020 again: the restored file is dated now too.
        try setOld(f)
        let u = store.undo(try #require(report.operation))
        #expect(u.restored.count == 1)
        #expect(try Data(contentsOf: f) == Data("owl\n".utf8))
        #expect((mtime(f) ?? .distantPast) > start, "undo kept the old date: \(String(describing: mtime(f)))")
    }

    @Test func readOnlyFileSkipped() throws {
        let root = try dir()
        defer { chmod(root.appendingPathComponent("ro.txt").path, 0o644); try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let ro = try put(root, "ro.txt", Data("owl\n".utf8))
        let rw = try put(root, "rw.txt", Data("owl\n".utf8))
        let q = ReplaceQuery(query: "owl", template: "hoot")
        // Read-only at preview: skipped there.
        chmod(ro.path, 0o444)
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [ro, rw]))
        #expect(plan.skipped.map(\.reason.rawValue) == ["readOnly"])
        #expect(plan.skipped.first?.reason.summary == "read-only")
        // Made read-only after the preview: skipped at the write.
        chmod(ro.path, 0o644)
        let plan2 = try FileReplace.plan(q, root: root, candidates: candidates(root, [ro]))
        chmod(ro.path, 0o444)
        let r = FileReplace.apply(plan2.files, query: q, root: root, store: store)
        #expect(r.written.isEmpty && r.skipped.map(\.reason.rawValue) == ["readOnly"])
        #expect(try Data(contentsOf: ro) == Data("owl\n".utf8))
        var st = stat()
        stat(ro.path, &st)
        #expect(st.st_mode & 0o7777 == 0o444)
    }

    /// Release review 0.2.1 M2: made read-only after the apply's checks
    /// (here, while the originals are backed up), just before the write.
    /// renameat alone would replace it; the last check skips it instead.
    @Test func fileMadeReadOnlyBetweenPlanAndWriteIsSkipped() throws {
        let root = try dir()
        let ro = try put(root, "ro.txt", Data("owl\n".utf8))
        defer { chmod(ro.path, 0o644); try? FileManager.default.removeItem(at: root) }
        let rw = try put(root, "rw.txt", Data("owl\n".utf8))
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let q = ReplaceQuery(query: "owl", template: "hoot")
        let plan = try FileReplace.plan(q, root: root, candidates: candidates(root, [ro, rw]))
        #expect(plan.skipped.isEmpty)
        var checked = false
        let r = FileReplace.apply(plan.files, query: q, root: root, store: store) { p in
            if p.stage == .backingUp, !checked { checked = true; chmod(ro.path, 0o444) }
        }
        #expect(checked)
        #expect(r.written.map(\.lastPathComponent) == ["rw.txt"])
        #expect(r.skipped.map(\.relativePath) == ["ro.txt"] && r.skipped.map(\.reason.rawValue) == ["readOnly"])
        #expect(try Data(contentsOf: ro) == Data("owl\n".utf8), "a read-only file was replaced")
        var st = stat()
        stat(ro.path, &st)
        #expect(st.st_mode & 0o7777 == 0o444)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(FileReplace.tempMarker) }
        #expect(left.isEmpty, "temp file left: \(left)")
        // Undo writes through the same path: it says read-only the same way.
        let w = try put(root, "w.txt", Data("x\n".utf8))
        chmod(w.path, 0o444)
        defer { chmod(w.path, 0o644) }
        let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(dirfd) }
        #expect(throws: TreeWrite.ReadOnly.self) { try TreeWrite.replace(Data("y\n".utf8), name: "w.txt", in: dirfd, mode: 0o644) }
        #expect(try Data(contentsOf: w) == Data("x\n".utf8))
    }

    /// Astra batch 6 must-fix 1: the name is checked as the bytes the
    /// kernel gets. A NUL would cut "a\0b" short to "a"; a slash before a
    /// combining mark is one Swift character, so a text search for "/"
    /// misses it, but fstatat/openat/renameat would follow it into "sub".
    /// Both are refused as a bad name and every file keeps its bytes.
    @Test func replaceRefusesANameThatIsNotOneNameByItsBytes() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try put(root, "a", Data("a original\n".utf8))
        let nested = try put(root, "sub/\u{301}x", Data("nested original\n".utf8))
        let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(dirfd >= 0)
        defer { close(dirfd) }
        for name in ["a\0b", "a\0", "sub/\u{301}x", "sub/x", "/\u{301}", "", ".", ".."] {
            #expect(throws: CocoaError(.fileWriteInvalidFileName), "\(name.debugDescription)") {
                try TreeWrite.replace(Data("new\n".utf8), name: name, in: dirfd, mode: 0o644)
            }
        }
        #expect(try Data(contentsOf: a) == Data("a original\n".utf8), "a name with a NUL wrote over the file before it")
        #expect(try Data(contentsOf: nested) == Data("nested original\n".utf8), "a slash before a combining mark wrote into the subfolder")
        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["a", "sub"])
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("sub").path) == ["\u{301}x"])
    }

    @Test func undoOverAReadOnlyFileIsReportedAndCanBeRetried() throws {
        let root = try dir()
        defer { chmod(root.appendingPathComponent("a.txt").path, 0o644); try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let a = try put(root, "a.txt", Data("owl a\n".utf8))
        let b = try put(root, "b.txt", Data("owl b\n".utf8))
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, [a, b], store: store)
        let id = try #require(report.operation)
        chmod(a.path, 0o444)
        let u = store.undo(id)
        #expect(u.restored.map(\.lastPathComponent) == ["b.txt"])
        #expect(u.skipped.map(\.reason.rawValue) == ["readOnly"])
        #expect(try Data(contentsOf: a) == Data("hoot a\n".utf8), "a read-only file was overwritten by undo")
        #expect(store.manifest(id)?.undone == false, "undo marked done with a file left to restore")
        // Writable again: a second undo puts it back.
        chmod(a.path, 0o644)
        let again = store.undo(id)
        #expect(again.restored.map(\.lastPathComponent) == ["a.txt"] && again.skipped.isEmpty)
        #expect(try Data(contentsOf: a) == Data("owl a\n".utf8))
        #expect(store.manifest(id)?.undone == true)
    }

    @Test func undoWithAnUnreadableBackupKeepsTheOperationOpenAndSaysWhy() throws {
        let root = try dir()
        let undoDir = root.appendingPathComponent(".undo")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: undoDir)
        let a = try put(root, "a.txt", Data("owl a\n".utf8))
        let b = try put(root, "b.txt", Data("owl b\n".utf8))
        let c = try put(root, "c.txt", Data("owl c\n".utf8))
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, [a, b, c], store: store)
        let id = try #require(report.operation)
        let m = try #require(store.manifest(id))
        let opDir = undoDir.appendingPathComponent(id.uuidString)
        func backup(_ u: URL) throws -> URL {
            opDir.appendingPathComponent(try #require(m.entries.first { $0.path == u.standardizedFileURL.path }).backup)
        }
        // a's copy can't be read, b's is gone, c's is intact.
        let aBackup = try backup(a), bBackup = try backup(b)
        let bBytes = try Data(contentsOf: bBackup)
        chmod(aBackup.path, 0o000)
        defer { chmod(aBackup.path, 0o600) }
        try FileManager.default.removeItem(at: bBackup)
        let u = store.undo(id)
        #expect(u.restored.map(\.lastPathComponent) == ["c.txt"])
        #expect(u.remaining, "files left unrestored must keep the operation undoable")
        #expect(store.manifest(id)?.undone == false, "undo marked done while backups couldn't be read")
        let why = Dictionary(uniqueKeysWithValues: u.skipped.map { ($0.relativePath, $0) })
        #expect(why["a.txt"]?.reason == .backupUnreadable && why["a.txt"]?.why == "backup copy unreadable: permission denied")
        #expect(why["b.txt"]?.reason == .backupUnreadable && why["b.txt"]?.why == "backup copy unreadable: missing")
        #expect(try Data(contentsOf: a) == Data("hoot a\n".utf8) && Data(contentsOf: b) == Data("hoot b\n".utf8))
        // The copies readable again: Undo again puts the rest back and closes the operation.
        chmod(aBackup.path, 0o600)
        try bBytes.write(to: bBackup)
        let again = store.undo(id)
        #expect(Set(again.restored.map(\.lastPathComponent)) == ["a.txt", "b.txt"] && again.skipped.isEmpty && !again.remaining)
        #expect(try Data(contentsOf: a) == Data("owl a\n".utf8) && Data(contentsOf: b) == Data("owl b\n".utf8))
        #expect(store.manifest(id)?.undone == true)
    }

    @Test func undoWithADamagedBackupLeavesTheFileAndCanBeRetried() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let a = try put(root, "a.txt", Data("owl a\n".utf8))
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, [a], store: store)
        let id = try #require(report.operation)
        let e = try #require(store.manifest(id)?.entries.first)
        let copy = root.appendingPathComponent(".undo").appendingPathComponent(id.uuidString).appendingPathComponent(e.backup)
        let good = try Data(contentsOf: copy)
        try Data("garbage\n".utf8).write(to: copy)
        let u = store.undo(id)
        #expect(u.restored.isEmpty && u.remaining)
        #expect(u.skipped.first?.why == "backup copy unreadable: doesn’t match the original")
        #expect(try Data(contentsOf: a) == Data("hoot a\n".utf8), "a damaged copy must never be written over the file")
        try good.write(to: copy)
        #expect(store.undo(id).restored.map(\.lastPathComponent) == ["a.txt"])
        #expect(try Data(contentsOf: a) == Data("owl a\n".utf8))
    }

    @Test func utf8WithAStrayByteIsEncodingUncertain() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        // UTF-8 "café foo" plus one stray Windows-1252 byte: guessed as 8-bit.
        let stray = Data("café foo".utf8) + Data([0x92, 0x0A])
        let f = try put(root, "stray.txt", stray)
        // A real Latin-1 file with an ASCII replacement still works.
        let latin = try put(root, "latin.txt", "naïve foo\n".data(using: .isoLatin1)!)
        // Non-ASCII replacement: skipped, even for the UTF-8 case's ASCII-only twin.
        let ascii8 = try put(root, "ascii8.txt", Data("plain foo".utf8) + Data([0x92, 0x0A]))
        let q = ReplaceQuery(query: "foo", template: "naïve")
        let (plan, report) = try replaceAll(q, root: root, [f, ascii8], store: store)
        #expect(plan.files.isEmpty && report.written.isEmpty)
        #expect(plan.skipped.map(\.reason.rawValue) == ["encodingUncertain", "encodingUncertain"])
        #expect(plan.skipped.first?.reason.summary == "encoding uncertain")
        #expect(try Data(contentsOf: f) == stray)
        // ASCII replacement, but the bytes hold UTF-8 sequences (é): still uncertain.
        let qa = ReplaceQuery(query: "foo", template: "bar")
        let p2 = try FileReplace.plan(qa, root: root, candidates: candidates(root, [f, latin]))
        #expect(p2.skipped.map(\.reason.rawValue) == ["encodingUncertain"])
        #expect(p2.files.map(\.relativePath) == ["latin.txt"])
    }

    @Test func undoAfterACrashMidReplaceRestoresWhatWasWritten() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let orig = (0..<3).map { Data("owl \($0)\n".utf8) }
        let urls = try (0..<3).map { try put(root, "f\($0).txt", orig[$0]) }
        let (_, report) = try replaceAll(ReplaceQuery(query: "owl", template: "hoot"), root: root, urls, store: store)
        let id = try #require(report.operation)
        // The manifest as a crash before its final save leaves it: no file marked written.
        var m = try #require(store.manifest(id))
        for k in m.entries.indices { m.entries[k].written = false; m.entries[k].writtenModified = nil }
        try ReplaceUndoStore.Operation(dir: store.root.appendingPathComponent(id.uuidString), manifest: m).save()
        let u = store.undo(id)
        #expect(u.restored.count == 3, "undo restored \(u.restored.count) of 3 written files")
        for (k, url) in urls.enumerated() { #expect(try Data(contentsOf: url) == orig[k]) }
    }

    @Test func gitIsNeverWrittenEvenWithExcludeEmpty() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent("undo-store"))
        let head = Data("ref: refs/heads/owl\n".utf8)
        let inGit = try ["HEAD", "config", "packed-refs", "hooks/pre-commit"].map { try put(root, ".git/\($0)", head) }
        let gitFile = try put(root, "sub/.git", Data("gitdir: ../.git/modules/owl\n".utf8))
        let normal = try put(root, "a.txt", Data("owl\n".utf8))
        // The search, with the Exclude field cleared, finds them.
        var found: [URL] = []
        _ = try FileSearch(FileSearchOptions(root: root, query: "owl", exclude: [])).run { found.append($0.url) }
        #expect(Set(found.map(\.lastPathComponent)).isSuperset(of: ["HEAD", ".git", "a.txt"]))
        let all = inGit + [gitFile, normal]
        let (plan, report) = try replaceAll(ReplaceQuery(query: "owl", template: "cat"), root: root, all, store: store)
        #expect(report.written.map(\.lastPathComponent) == ["a.txt"])
        #expect(plan.skipped.count == 5 && plan.skipped.allSatisfy { $0.reason.rawValue == "insideGit" }, "\(plan.skipped.map(\.reason))")
        for u in inGit { #expect(try Data(contentsOf: u) == head, "\(u.path)") }
        #expect(try Data(contentsOf: gitFile) == Data("gitdir: ../.git/modules/owl\n".utf8))
        // apply refuses them too, should a plan carry one.
        var forged = try FileReplace.plan(ReplaceQuery(query: "owl", template: "cat"), root: root,
                                          candidates: candidates(root, [try put(root, "b.txt", Data("owl\n".utf8))]))
        forged.files[0].url = inGit[0]
        let r2 = FileReplace.apply(forged.files, query: forged.query, root: root, store: store)
        #expect(r2.written.isEmpty)
        #expect(try Data(contentsOf: inGit[0]) == head)
    }

    @Test func retentionKeepsExactlyFive() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent("undo"))
        let q = ReplaceQuery(query: "a", template: "b")
        let now = Date()
        var ids: [UUID] = []
        for k in 0..<7 { ids.append(try store.begin(query: q, now: now.addingTimeInterval(Double(k))).id) }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path))
        #expect(left == Set(ids.suffix(5).map(\.uuidString)), "kept \(left.count)")
    }

    @Test func oldCopiesArePrunedAtLaunchWithoutANewReplace() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent("undo"))
        let q = ReplaceQuery(query: "a", template: "b")
        let now = Date()
        // The recent one first: no replace after the old one prunes it.
        let recent = try store.begin(query: q, now: now.addingTimeInterval(-3600)).id
        let old = try store.begin(query: q, now: now.addingTimeInterval(-8 * 24 * 3600)).id
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path)) == [recent.uuidString, old.uuidString])
        store.pruneAtLaunch(now: now)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path))
        #expect(left == [recent.uuidString] && !left.contains(old.uuidString))
    }

    @Test func leftoverTempFilesSweptOnTheNextRun() throws {
        let root = try dir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReplaceUndoStore(root: root.appendingPathComponent(".undo"))
        let f = try put(root, "a.txt", Data("owl\n".utf8))
        let stale = try put(root, ".a.txt.owlink-Ab12Cd", Data("half".utf8))
        let fresh = try put(root, ".a.txt.owlink-Zz99Yy", Data("busy".utf8))
        let other = try put(root, ".notes.owlink-Ab12Cd", Data("not ours".utf8))
        try setOld(stale)
        try setOld(other)
        _ = try replaceAll(ReplaceQuery(query: "owl", template: "cat"), root: root, [f], store: store)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(!names.contains(stale.lastPathComponent), "the stale temp file is left")
        #expect(names.contains(fresh.lastPathComponent) && names.contains(other.lastPathComponent))
    }
}
