import XCTest
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
}
