import XCTest
import SwiftUI
import UIKit
import CedricCore

/// Wiki links, Backlinks and Tags on iOS (Mac 0.6.0), from the shared
/// NoteIndex / BacklinkScan / TagTree over the folder Owlink can read.
@MainActor
final class NoteLinksTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func vault() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        dirs.append(d)
        try Data("# Alpha\nSee [[Beta]] for more. #project\n".utf8).write(to: d.appendingPathComponent("Alpha.md"))
        try Data("# Beta\n\n## Part\nNothing links out. #project/ios #idea\n".utf8).write(to: d.appendingPathComponent("Beta.md"))
        try Data("Also [[Beta#Part|the part]].\n".utf8).write(to: d.appendingPathComponent("sub/Gamma.txt"))
        try Data("[[Beta]] hidden\n".utf8).write(to: d.appendingPathComponent(".hidden/Secret.md"))
        return d
    }

    private func editor(_ url: URL) throws -> EditorViewController {
        let text = try String(contentsOf: url, encoding: .utf8)
        let doc = TextDocument(fileURL: url)
        doc.text = text
        doc.language = .forFile(named: url.lastPathComponent, content: text)
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    func testBacklinksAndTagsFromTheFolder() async throws {
        let d = try vault()
        let model = NoteLinksModel(document: d.appendingPathComponent("Beta.md"), root: d, headings: [])
        model.load()
        await model.task?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.backlinks.map(\.source), ["Alpha.md", "sub/Gamma.txt"], "not the hidden folder's note")
        XCTAssertEqual(model.backlinks.first?.line, 1)
        let tags = try XCTUnwrap(model.tags)
        XCTAssertEqual(Set(NoteLinksView.flatten(tags.roots).map(\.path)), ["project", "project/ios", "idea"])
        XCTAssertEqual(Set(tags.notes(for: "project").map(\.source)), ["Alpha.md", "Beta.md"])
        XCTAssertEqual(model.url(of: "Alpha.md")?.lastPathComponent, "Alpha.md")
    }

    func testNoFolderAndNotInFolder() async throws {
        let d = try vault()
        let none = NoteLinksModel(document: d.appendingPathComponent("Beta.md"), root: nil, headings: [])
        none.load()
        XCTAssertEqual(none.state, .noFolder)
        let other = NoteLinksModel(document: URL(fileURLWithPath: "/tmp/elsewhere/x.md"), root: d, headings: [])
        other.load()
        XCTAssertEqual(other.state, .notInFolder)
        XCTAssertNil(NoteLinksModel.root(for: d.appendingPathComponent("Beta.md"), granted: nil, readable: false))
        XCTAssertEqual(NoteLinksModel.root(for: d.appendingPathComponent("Beta.md"), granted: nil, readable: true)?.standardizedFileURL,
                       d.standardizedFileURL)
    }

    func testEditorFindsTheWikiLinkUnderTheCaret() throws {
        let d = try vault()
        let e = try editor(d.appendingPathComponent("Alpha.md"))
        let at = (e.textView.text as NSString).range(of: "Beta]]").location + 1
        let link = try XCTUnwrap(e.wikiLink(at: at))
        XCTAssertEqual(link.target, "Beta")
        XCTAssertEqual(e.wikiTarget(link)?.lastPathComponent, "Beta.md")
        let action = try XCTUnwrap(e.wikiLinkMenuAction(for: NSRange(location: at, length: 0)))
        XCTAssertEqual(action.title, "Open “Beta”")
        XCTAssertNil(e.wikiLink(at: 2), "not in a link")
        XCTAssertNil(e.wikiLinkMenuAction(for: NSRange(location: 2, length: 0)))
    }

    func testOutlineAndMenu() throws {
        let d = try vault()
        let e = try editor(d.appendingPathComponent("Beta.md"))
        XCTAssertTrue(e.noteLinksApply)
        let model = e.makeNoteLinksModel()
        XCTAssertEqual(model.headings.map(\.title), ["Beta", "Part"])
        let code = try editor(d.appendingPathComponent("Alpha.md"))
        code.setLanguage(.swift)
        XCTAssertFalse(code.noteLinksApply)
    }
    /// A note file or a folder that is a symbolic link out of the folder:
    /// not listed, not read, not opened, from the sheet or the editor.
    func testOutsideSymlinksAreNotReadOrOpened() async throws {
        let d = try vault()
        let o = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: o.appendingPathComponent("dir"), withIntermediateDirectories: true)
        dirs.append(o)
        try Data("[[Beta]] secret #secret\n".utf8).write(to: o.appendingPathComponent("Evil.md"))
        try Data("[[Beta]] deep #deep\n".utf8).write(to: o.appendingPathComponent("dir/Deep.md"))
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("Evil.md"), withDestinationURL: o.appendingPathComponent("Evil.md"))
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("out"), withDestinationURL: o.appendingPathComponent("dir"))
        try Data("Go to [[Evil]] or [[out/Deep]].\n".utf8).write(to: d.appendingPathComponent("Links.md"))

        XCTAssertNil(NoteLinksModel.relativePath(of: d.appendingPathComponent("Evil.md"), under: d))
        XCTAssertNil(NoteLinksModel.relativePath(of: d.appendingPathComponent("out/Deep.md"), under: d))
        XCTAssertNil(NoteLinksModel.openableNote(d.appendingPathComponent("Evil.md"), under: d))
        XCTAssertNil(NoteLinksModel.openableNote(d.appendingPathComponent("out/Deep.md"), under: d))
        XCTAssertNotNil(NoteLinksModel.openableNote(d.appendingPathComponent("Alpha.md"), under: d))

        let model = NoteLinksModel(document: d.appendingPathComponent("Beta.md"), root: d, headings: [])
        model.load()
        await model.task?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.backlinks.map(\.source), ["Alpha.md", "sub/Gamma.txt"])
        let tags = Set(NoteLinksView.flatten(try XCTUnwrap(model.tags).roots).map(\.path))
        XCTAssertFalse(tags.contains("secret") || tags.contains("deep"), "\(tags)")

        // The editor's Open “Note” keeps to the same folder.
        let e = try editor(d.appendingPathComponent("Links.md"))
        for name in ["Evil]]", "out/Deep]]"] {
            let at = (e.textView.text as NSString).range(of: name).location + 1
            let link = try XCTUnwrap(e.wikiLink(at: at))
            XCTAssertNil(e.wikiTarget(link), link.target)
        }
    }

    /// A listed note replaced by a symbolic link before it is read (or
    /// opened) is skipped: the read goes through the folder's descriptor.
    func testListedNoteReplacedBySymlinkIsSkipped() throws {
        let d = try vault()
        let listed = NoteLinksModel.notes(under: d).paths
        XCTAssertTrue(listed.contains("Alpha.md"))
        let o = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("[[Beta]] stolen #stolen\n".utf8).write(to: o)
        defer { try? FileManager.default.removeItem(at: o) }
        try FileManager.default.removeItem(at: d.appendingPathComponent("Alpha.md"))
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("Alpha.md"), withDestinationURL: o)
        let result = try XCTUnwrap(NoteLinksModel.read(root: d, note: "Beta.md", listed: listed))
        XCTAssertEqual(result.backlinks.map(\.source), ["sub/Gamma.txt"])
        XCTAssertTrue(result.partial)
        XCTAssertFalse(NoteLinksView.flatten(result.tags.roots).map(\.path).contains("stolen"))
        XCTAssertNil(NoteLinksModel.openableNote(d.appendingPathComponent("Alpha.md"), under: d), "checked again before it opens")
    }

    /// The read stops when asked (the sheet went, the root changed), and
    /// the editor's model finds its folder only when it is read.
    func testReadIsCancellableAndStartsOnLoad() async throws {
        let d = try vault()
        XCTAssertNil(NoteLinksModel.read(root: d, note: "Beta.md", cancelled: { true }))
        let e = try editor(d.appendingPathComponent("Beta.md"))
        let model = e.makeNoteLinksModel()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.root, "no folder probe before Backlinks or Tags is shown")
        model.load()
        model.cancel()
        XCTAssertEqual(model.state, .idle)
        model.load()
        await model.task?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.root?.resolvingSymlinksInPath(), d.resolvingSymlinksInPath())
        XCTAssertEqual(model.backlinks.map(\.source), ["Alpha.md", "sub/Gamma.txt"])
    }

    /// The sheet's callbacks don't hold its hosting controller: once let
    /// go (dismissed), the controller and its model go.
    func testSheetIsReleasedWhenDismissed() throws {
        let d = try vault()
        let e = try editor(d.appendingPathComponent("Beta.md"))
        weak var host: UIHostingController<NoteLinksView>?
        weak var model: NoteLinksModel?
        autoreleasepool {
            let controller = e.makeNoteLinksController(.backlinks)
            controller.loadViewIfNeeded()
            host = controller
            model = controller.rootView.model
            XCTAssertNotNil(model)
        }
        for _ in 0..<20 where host != nil || model != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(host)
        XCTAssertNil(model)
    }

    private func outsideFolder(_ files: [String: String]) throws -> URL {
        let o = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        dirs.append(o)
        for (name, text) in files { try Data(text.utf8).write(to: o.appendingPathComponent(name)) }
        return o
    }

    /// Open “Note” checks the note, then this document closes (which can
    /// save or ask first) before the note opens. A note swapped for a link
    /// to another file in between is not what opens: the document the
    /// browser makes for it (`TextDocument.linkedNote`) is read only if it
    /// is still the file that was checked (Sol round 2, must-fix 2). The
    /// close itself isn't driven here: with no host app, a test window's
    /// dismissal never finishes.
    func testNoteSwappedAfterItsCheckIsNotOpened() throws {
        let d = try vault()
        let o = try outsideFolder(["Stolen.md": "# Stolen\n"])
        let note = try checkedAlpha(d)
        let alpha = d.appendingPathComponent("Alpha.md")
        try FileManager.default.removeItem(at: alpha)
        try FileManager.default.createSymbolicLink(at: alpha, withDestinationURL: o.appendingPathComponent("Stolen.md"))
        let result = try open(TextDocument.linkedNote(at: note.url, expecting: note.id))
        XCTAssertFalse(result.ok, "opened: \(result.text)")
        XCTAssertFalse(result.text.contains("Stolen"))
        // Another file renamed into its place: refused too.
        try FileManager.default.removeItem(at: alpha)
        try Data("# Other\n".utf8).write(to: alpha)
        let other = try open(TextDocument.linkedNote(at: note.url, expecting: note.id))
        XCTAssertFalse(other.ok, "opened: \(other.text)")
    }

    /// The same, with the note left alone: it opens (the test's control).
    func testCheckedNoteOpens() throws {
        let d = try vault()
        let note = try checkedAlpha(d)
        let result = try open(TextDocument.linkedNote(at: note.url, expecting: note.id))
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.text.hasPrefix("# Alpha"), result.text)
    }

    /// Alpha.md as Open “Note” checks it from Links.md's editor.
    private func checkedAlpha(_ d: URL) throws -> NoteLinksModel.CheckedNote {
        try Data("Go to [[Alpha]].\n".utf8).write(to: d.appendingPathComponent("Links.md"))
        let e = try editor(d.appendingPathComponent("Links.md"))
        let found = (e.textView.text as NSString).range(of: "Alpha]]").location
        XCTAssertNotEqual(found, NSNotFound)
        let link = try XCTUnwrap(e.wikiLink(at: found == NSNotFound ? 0 : found + 1))
        XCTAssertNotNil(e.wikiLinkMenuAction(for: NSRange(location: found + 1, length: 0)))
        return try XCTUnwrap(e.wikiNote(link))
    }

    private func open(_ doc: TextDocument) throws -> (ok: Bool, text: String) {
        var ok: Bool?
        doc.open { ok = $0 }
        for _ in 0..<200 where ok == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let result = (ok: try XCTUnwrap(ok, "the open finished"), text: doc.text)
        if result.ok {
            var closed = false
            doc.close { _ in closed = true }
            for _ in 0..<100 where !closed { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        return result
    }

    /// The root itself replaced by a symbolic link to another folder after
    /// it was read: the next read, and a note's check, refuse it instead of
    /// reading the folder the link leads to (Sol round 2, must-fix 3).
    func testRootReplacedByALinkIsNotRead() async throws {
        let d = try vault()
        let model = NoteLinksModel(document: d.appendingPathComponent("Beta.md"), root: d, headings: [])
        model.load()
        await model.task?.value
        XCTAssertEqual(model.backlinks.map(\.source), ["Alpha.md", "sub/Gamma.txt"])
        let o = try outsideFolder(["Beta.md": "# Beta\n", "Thief.md": "[[Beta]] taken #stolen\n"])
        let moved = d.deletingLastPathComponent().appendingPathComponent(d.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: d, to: moved)
        dirs.append(moved)
        try FileManager.default.createSymbolicLink(at: d, withDestinationURL: o)
        model.load()
        await model.task?.value
        XCTAssertFalse(model.backlinks.map(\.source).contains("Thief.md"), "\(model.backlinks.map(\.source))")
        XCTAssertFalse(NoteLinksView.flatten(model.tags?.roots ?? []).map(\.path).contains("stolen"))
        let direct = NoteLinksModel.read(root: d, note: "Beta.md", listed: ["Beta.md", "Thief.md"])
        XCTAssertEqual(direct?.backlinks.map(\.source) ?? [], [])
        XCTAssertNil(NoteLinksModel.openableNote(d.appendingPathComponent("Thief.md"), under: d))
    }

    /// The root swapped for another real folder (renamed into its place)
    /// after it was read: the model's next read refuses it.
    func testRootSwappedForAnotherFolderIsNotRead() async throws {
        let d = try vault()
        let model = NoteLinksModel(document: d.appendingPathComponent("Beta.md"), root: d, headings: [])
        model.load()
        await model.task?.value
        XCTAssertEqual(model.backlinks.map(\.source), ["Alpha.md", "sub/Gamma.txt"])
        let o = try outsideFolder(["Beta.md": "# Beta\n", "Thief.md": "[[Beta]] taken #stolen\n"])
        let moved = d.deletingLastPathComponent().appendingPathComponent(d.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: d, to: moved)
        dirs.append(moved)
        try FileManager.default.moveItem(at: o, to: d)
        model.load()
        await model.task?.value
        XCTAssertFalse(model.backlinks.map(\.source).contains("Thief.md"), "\(model.backlinks.map(\.source))")
        XCTAssertTrue(model.partial)
    }

    /// Compact notes holding many links and tags: the read holds no more
    /// than the limits while it collects, not everything first (Sol round
    /// 2, must-fix 4).
    func testReadKeepsWithinTheLimitsWhileCollecting() throws {
        let d = try vault()
        var listed = ["Beta.md"]
        var n = 0
        for k in 0..<25 {
            var text = ""
            for _ in 0..<1_000 { text += "[[Beta]] #t\(n)\n"; n += 1 }
            let name = String(format: "many-%02d.md", k)
            try Data(text.utf8).write(to: d.appendingPathComponent(name))
            listed.append(name)
        }
        let stats = NoteLinksModel.ScanStats()
        let result = try XCTUnwrap(NoteLinksModel.read(root: d, note: "Beta.md", listed: listed, stats: stats))
        XCTAssertEqual(result.backlinks.count, NoteLinksModel.maxBacklinks)
        XCTAssertEqual(result.backlinks.first?.source, "many-00.md")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.tags.roots.count, NoteLinksModel.maxTagRefs)
        XCTAssertLessThanOrEqual(stats.retained, NoteLinksModel.maxBacklinks + NoteLinksModel.maxTagRefs,
                                 "held \(stats.retained) links and tags at once")
    }

    /// A cancel that comes in the middle of the read (while a note is being
    /// read) stops it there: that note's links and tags aren't parsed, and
    /// nothing after it is read.
    func testCancelInTheMiddleStopsTheWork() throws {
        let d = try vault()
        var listed: [String] = []
        for k in 0..<10 {
            var text = ""
            for i in 0..<200 { text += "[[Beta]] #k\(k)x\(i)\n" }
            let name = "note-\(k).md"
            try Data(text.utf8).write(to: d.appendingPathComponent(name))
            listed.append(name)
        }
        let flag = CancelFlag()
        var reads = 0, readsAfter = 0
        let stats = NoteLinksModel.ScanStats()
        let result = NoteLinksModel.read(root: d, note: "Beta.md", listed: listed, cancelled: { flag.value }, stats: stats,
                                         readNote: { rel, dir, max in
            if flag.value { readsAfter += 1 }
            reads += 1
            // Cancelled while the fourth note is read.
            if reads == 4 { flag.value = true }
            return BacklinkScan.readBeneath(rel, root: dir, maxBytes: max)
        })
        XCTAssertNil(result)
        XCTAssertEqual(readsAfter, 0)
        // Three notes, 200 links and 200 tags each, before the cancel.
        XCTAssertEqual(stats.parsed, 3 * 400, "parsed \(stats.parsed - 3 * 400) after the cancel")
    }
    // MARK: Round 4

    /// A registry of folder grants of its own (its bookmarks in a suite removed afterwards).
    private func testGrants() throws -> PreviewFolderGrants {
        let suite = "cedric-tests-grants-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PreviewFolderGrants(defaults: defaults)
    }

    /// Moves `folder` away and puts `replacement` (a real folder, or a
    /// symbolic link to it) in its place.
    private func swap(_ folder: URL, for replacement: URL, byLink: Bool) throws {
        let moved = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder, to: moved)
        dirs.append(moved)
        if byLink {
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: folder)
        }
    }

    /// Links.md's editor, and Alpha.md as its Open “Note” checks it.
    private func linksEditor(_ d: URL) throws -> (EditorViewController, NoteLinksModel.CheckedNote) {
        let url = d.appendingPathComponent("Links.md")
        try Data("Go to [[Alpha]].\n".utf8).write(to: url)
        // Opened, as the browser opens it, so that closing it finishes.
        let doc = TextDocument(fileURL: url)
        var opened: Bool?
        doc.open { opened = $0 }
        for _ in 0..<200 where opened == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(opened, true)
        let e = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: e)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        let found = (e.textView.text as NSString).range(of: "Alpha]]").location
        let link = try XCTUnwrap(e.wikiLink(at: found + 1))
        return (e, try XCTUnwrap(e.wikiNote(link)))
    }

    /// Open “Note” the whole way: the editor closes, then hands the note
    /// and the file it was checked to be to the browser (a real
    /// `DocumentBrowserViewController`), which opens it. What the open
    /// decided is what is returned.
    private func openThroughTheBrowser(_ e: EditorViewController, _ note: NoteLinksModel.CheckedNote) throws -> DocumentOpening.Outcome {
        let browser = DocumentBrowserViewController()
        e.linkedNoteOpenerForTests = browser
        e.dismissEditorForTests = { $0() }
        var outcome: DocumentOpening.Outcome?
        DocumentOpening.outcomeForTests = { url, o in
            XCTAssertEqual(url, note.url)
            outcome = o
        }
        defer { DocumentOpening.outcomeForTests = nil }
        e.openLinked(note.url, expecting: note.id)
        let deadline = Date().addingTimeInterval(10)
        while outcome == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let result = try XCTUnwrap(outcome, "the browser was asked to open the note")
        if case .opened(let doc) = result {
            var closed = false
            doc.close { _ in closed = true }
            for _ in 0..<100 where !closed { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        withExtendedLifetime(browser) {}
        return result
    }

    private static let binaryBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D, 0x00, 0x01, 0x02, 0x03] + Array(repeating: 0, count: 64))

    /// Sol round 3, must-fix 1: the note swapped, after Open “Note”
    /// checked it, for a link to a binary file outside the folder, or for
    /// another file: the open is refused as such, and the browser never
    /// reads the path again (it would follow the link) to ask whether
    /// to open a binary file.
    func testHandoffRefusesASwappedNoteWithoutReadingItAgain() throws {
        let d = try vault()
        let o = try outsideFolder([:])
        try Self.binaryBytes.write(to: o.appendingPathComponent("Blob.md"))
        let alpha = d.appendingPathComponent("Alpha.md")
        do {
            let (e, note) = try linksEditor(d)
            try FileManager.default.removeItem(at: alpha)
            try FileManager.default.createSymbolicLink(at: alpha, withDestinationURL: o.appendingPathComponent("Blob.md"))
            let outcome = try openThroughTheBrowser(e, note)
            guard case .refused = outcome else { return XCTFail("a link to a binary file outside: \(outcome)") }
        }
        try FileManager.default.removeItem(at: alpha)
        try Data("# Alpha\n".utf8).write(to: alpha)
        do {
            let (e, note) = try linksEditor(d)
            try FileManager.default.removeItem(at: alpha)
            try Data("# Other\n".utf8).write(to: alpha)
            let outcome = try openThroughTheBrowser(e, note)
            guard case .refused = outcome else { return XCTFail("another file in its place: \(outcome)") }
        }
    }

    /// The control: a binary note left alone is offered as binary, from
    /// the bytes the checked read took, and opens once allowed.
    func testHandoffOffersAnUnchangedBinaryNote() throws {
        let d = try vault()
        try Self.binaryBytes.write(to: d.appendingPathComponent("Alpha.md"))
        let (e, note) = try linksEditor(d)
        let outcome = try openThroughTheBrowser(e, note)
        guard case .binary = outcome else { return XCTFail("\(outcome)") }
        var allowed: DocumentOpening.Outcome?
        DocumentOpening.open(note.url, binaryOK: true, expecting: note.id) { allowed = $0 }
        for _ in 0..<200 where allowed == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard case .opened(let doc) = allowed else { return XCTFail("\(String(describing: allowed))") }
        var closed = false
        doc.close { _ in closed = true }
        for _ in 0..<100 where !closed { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Sol round 3, must-fix 3: the granted folder swapped for another
    /// (renamed into its place, or a link) after it was granted and before
    /// Backlinks or Tags first reads it: that folder is not read.
    func testFirstScanRefusesAGrantSwappedBeforeIt() async throws {
        for byLink in [false, true] {
            let d = try vault()
            let grants = try testGrants()
            XCTAssertTrue(grants.add(d))
            let e = try editor(d.appendingPathComponent("Beta.md"))
            e.folderGrants = grants
            let o = try outsideFolder(["Beta.md": "# Beta\n", "Thief.md": "[[Beta]] taken #stolen\n"])
            try swap(d, for: o, byLink: byLink)
            let model = e.makeNoteLinksModel()
            model.load()
            await model.task?.value
            XCTAssertFalse(model.backlinks.map(\.source).contains("Thief.md"), "byLink \(byLink): \(model.backlinks.map(\.source))")
            XCTAssertFalse(NoteLinksView.flatten(model.tags?.roots ?? []).map(\.path).contains("stolen"), "byLink \(byLink)")
            if let root = model.root {
                XCTAssertNil(NoteLinksModel.checkedNote(root.appendingPathComponent("Thief.md"), under: root, rootID: model.rootID,
                                                        anchor: model.anchor), "byLink \(byLink)")
            }
        }
    }

    /// The control: the same, not swapped, reads the granted folder.
    func testFirstScanReadsTheGrant() async throws {
        let d = try vault()
        let grants = try testGrants()
        XCTAssertTrue(grants.add(d))
        let e = try editor(d.appendingPathComponent("Beta.md"))
        e.folderGrants = grants
        let model = e.makeNoteLinksModel()
        model.load()
        await model.task?.value
        XCTAssertEqual(model.backlinks.map(\.source), ["Alpha.md", "sub/Gamma.txt"])
    }

    /// Sol round 3, must-fix 3: the vault is a folder inside the grant
    /// (`.obsidian` there), and the grant above it is swapped for another
    /// folder holding the same names: Open “Note” refuses the note.
    func testOpenNoteRefusesAGrantSwappedAboveTheVault() throws {
        for byLink in [false, true] {
            let g = try outsideFolder([:])
            let v = g.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: v.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
            try Data("# Alpha\n".utf8).write(to: v.appendingPathComponent("Alpha.md"))
            let grants = try testGrants()
            XCTAssertTrue(grants.add(g))
            try Data("Go to [[Alpha]].\n".utf8).write(to: v.appendingPathComponent("Links.md"))
            let e = try editor(v.appendingPathComponent("Links.md"))
            e.folderGrants = grants
            XCTAssertEqual(e.noteLinksRoot()?.lastPathComponent, "vault")
            let found = (e.textView.text as NSString).range(of: "Alpha]]").location
            let link = try XCTUnwrap(e.wikiLink(at: found + 1))
            XCTAssertNotNil(e.wikiNote(link), "the control, before the swap")
            let r = try outsideFolder([:])
            let rv = r.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: rv.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
            try Data("# Stolen\n".utf8).write(to: rv.appendingPathComponent("Alpha.md"))
            try Data("Go to [[Alpha]].\n".utf8).write(to: rv.appendingPathComponent("Links.md"))
            try swap(g, for: r, byLink: byLink)
            XCTAssertNil(e.wikiNote(link), "byLink \(byLink): the note in the folder swapped in")
        }
    }

    /// Sol round 3, must-fix 4: one line holding 300,000 links to the note,
    /// one holding 300,000 different tags, and front matter listing
    /// 300,000 tags: the parsers make no more than the limits (plus the
    /// one that finds them full), not the whole line first.
    func testDenseLinesStayWithinTheLimits() throws {
        let d = try vault()
        try Data(String(repeating: "[[Beta]] ", count: 300_000).utf8).write(to: d.appendingPathComponent("dense-links.md"))
        try Data((0..<300_000).map { "#t\($0)" }.joined(separator: " ").utf8).write(to: d.appendingPathComponent("dense-tags.md"))
        try Data(("---\ntags: [" + (0..<300_000).map { "f\($0)" }.joined(separator: ", ") + "]\n---\n").utf8)
            .write(to: d.appendingPathComponent("dense-front.md"))
        let slack = 10 // Beta.md's own tags, and one past each limit
        for (file, cap) in [("dense-links.md", NoteLinksModel.maxBacklinks), ("dense-tags.md", NoteLinksModel.maxTagRefs),
                            ("dense-front.md", NoteLinksModel.maxTagRefs)] {
            let counter = ParseCounter()
            let result = ParseCounter.$current.withValue(counter) {
                NoteLinksModel.read(root: d, note: "Beta.md", listed: ["Beta.md", file])
            }
            XCTAssertTrue(result?.truncated == true, file)
            XCTAssertLessThanOrEqual(counter.produced, cap + slack, "\(file): the parser made \(counter.produced)")
        }
    }

    /// A cancel that comes in the middle of one long line stops the parse
    /// there: nothing more is parsed once it said stop.
    func testCancelInTheMiddleOfALineStops() throws {
        let d = try vault()
        try Data(String(repeating: "[[Nowhere]] ", count: 300_000).utf8).write(to: d.appendingPathComponent("dense-links.md"))
        try Data((0..<300_000).map { "#t\($0)" }.joined(separator: " ").utf8).write(to: d.appendingPathComponent("dense-tags.md"))
        for file in ["dense-links.md", "dense-tags.md"] {
            let counter = ParseCounter()
            var atCancel: Int?
            let result = ParseCounter.$current.withValue(counter) {
                NoteLinksModel.read(root: d, note: "Beta.md", listed: [file], cancelled: {
                    if atCancel == nil, counter.produced >= 1_000 { atCancel = counter.produced }
                    return atCancel != nil
                })
            }
            XCTAssertNil(result, file)
            let at = try XCTUnwrap(atCancel, "\(file): the cancel was asked mid-line")
            XCTAssertLessThanOrEqual(at, 1_000 + 200, "\(file): asked only after \(at)")
            XCTAssertEqual(counter.produced, at, "\(file): parsed \(counter.produced - at) after the cancel")
        }
    }

    /// The tag tree: bounded (nested tags expand into the tags above them),
    /// and a cancel while it is built (while tags expand, or while nodes
    /// are made) stops it.
    func testTagTreeIsBoundedAndStopsWhenCancelled() throws {
        let d = try vault()
        try Data((0..<20_000).map { "#a\($0)/b/c/d/e" }.joined(separator: "\n").utf8).write(to: d.appendingPathComponent("deep.md"))
        let result = try XCTUnwrap(NoteLinksModel.read(root: d, note: "Beta.md", listed: ["deep.md"]))
        XCTAssertLessThanOrEqual(result.tags.tagCount, NoteLinksModel.maxTagEntries, "tree of \(result.tags.tagCount)")
        XCTAssertTrue(result.truncated)
        // The cap counts (tag, note) entries kept, not distinct tags: many
        // notes sharing a few tags are cut at the cap too (Sol round 4).
        var shared: [String: [Tags.Ref]] = [:]
        for n in 0..<2_000 { shared["n\(n).md"] = (0..<50).map { Tags.Ref(name: "x\($0)", line: $0, snippet: "") } }
        let capped = TagTree(files: shared, maxEntries: NoteLinksModel.maxTagEntries)
        let retained = NoteLinksView.flatten(capped.roots).reduce(0) { $0 + capped.notes(for: $1.path).count }
        XCTAssertTrue(capped.truncated)
        XCTAssertLessThanOrEqual(retained, NoteLinksModel.maxTagEntries, "\(retained) notes kept under \(capped.tagCount) tags")
        XCTAssertGreaterThan(retained, 0)
        // 20,000 tags four deep: expanding (80,000 entries) is work 0..<80,000,
        // the parent map 80,000..<160,000, the nodes 160,000..<240,000, then
        // the 20,000 top-level siblings are sorted (some 280,000 comparisons).
        // One tag in 20,000 notes: its notes are sorted from 20,000 on.
        let refs = (0..<20_000).map { Tags.Ref(name: "a\($0)/b/c/d", line: $0, snippet: "") }
        var wide: [String: [Tags.Ref]] = [:]
        for n in 0..<20_000 { wide["n\(n).md"] = [Tags.Ref(name: "same", line: 1, snippet: "")] }
        for (files, threshold, phase) in [(["n.md": refs], 1_000, "expanding"), (["n.md": refs], 80_000 + 500, "the parent map"),
                                          (["n.md": refs], 160_000 + 500, "building nodes"),
                                          (["n.md": refs], 240_000 + 1_000, "sorting siblings"),
                                          (wide, 20_000 + 1_000, "sorting a tag's notes")] {
            let whole = ParseCounter()
            _ = ParseCounter.$current.withValue(whole) { TagTree(files: files) }
            XCTAssertGreaterThan(whole.treeWork, threshold + 10_000, "\(phase): the threshold is inside the work")
            let counter = ParseCounter()
            var atCancel: Int?
            _ = ParseCounter.$current.withValue(counter) {
                TagTree(files: files, cancelled: {
                    if atCancel == nil, counter.treeWork >= threshold { atCancel = counter.treeWork }
                    return atCancel != nil
                })
            }
            let at = try XCTUnwrap(atCancel, "\(phase): the cancel was asked")
            XCTAssertLessThanOrEqual(at - threshold, 256, "\(phase): asked only at \(at)")
            XCTAssertLessThanOrEqual(counter.treeWork - at, 0, "\(phase): \(counter.treeWork - at) after the cancel")
        }
    }

}

private final class CancelFlag: @unchecked Sendable {
    var value = false
}
