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
}

private final class CancelFlag: @unchecked Sendable {
    var value = false
}
