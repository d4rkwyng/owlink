import Foundation
import Testing
@testable import CedricCore

/// Astra batch 9b: the preview's containment decisions compare paths by
/// their UTF-8 bytes, a `/` byte at the boundary, not as Swift text. A
/// slash followed by a combining mark is one Swift character, so a text
/// prefix test missed a first-level folder or file whose name starts with
/// one; and a canonically equivalent but byte-distinct root spelling
/// passed a text prefix test.
@Suite struct PreviewContainmentTests {
    func isText(_ u: URL) -> Bool { ["md", "txt"].contains(u.pathExtension) }
    func page(_ file: URL) throws -> URL { try #require(PreviewFolder.pageURL(forFile: file)) }

    /// Resource reads (`file(for:in:)`): a first-level and a nested
    /// combining-mark name is inside; the folder itself and a sibling
    /// named the folder plus a mark are not.
    @Test func combiningMarkNamesAreInsideTheFolder() throws {
        let t = try makeTree(["doc/\u{301}a.png", "doc/\u{301}d/b.png", "doc/c/\u{301}e/f.png", "doc\u{301}/s.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        for rel in ["\u{301}a.png", "\u{301}d/b.png", "c/\u{301}e/f.png"] {
            let f = doc.appendingPathComponent(rel)
            #expect(PreviewFolder.file(for: try page(f), in: doc) == f.standardizedFileURL, "\(rel) is inside")
        }
        #expect(PreviewFolder.file(for: try page(t.appendingPathComponent("doc\u{301}/s.png")), in: doc) == nil,
                "the folder's name plus a mark is a sibling, outside")
        #expect(PreviewFolder.file(for: try page(doc), in: doc) == nil, "the folder itself is not a file inside it")
    }

    /// A root named with Ω (U+03A9) does not admit the files of one named
    /// with the Ohm sign (U+2126): Swift text calls the two equal, but
    /// their bytes differ, Foundation keeps both spellings (the HFS
    /// decomposition leaves U+2126 alone) and a volume may keep them apart.
    @Test func aCanonicallyEquivalentRootIsNotTheSameRoot() throws {
        let base = "/cedric-no-such-folder-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: base + "/\u{3A9}")
        let sibling = URL(fileURLWithPath: base + "/\u{2126}/x.png")
        #expect(Array(folder.path.utf8) != Array(sibling.deletingLastPathComponent().path.utf8), "two spellings")
        #expect(PreviewFolder.file(for: try page(sibling), in: folder) == nil)
        #expect(PreviewFolder.file(for: try page(URL(fileURLWithPath: base + "/\u{3A9}/x.png")), in: folder) != nil)
    }

    /// Link clicks and `previewDocument`: a Markdown file in a
    /// combining-mark folder, first-level and nested, opens in the
    /// preview; one in the folder-plus-mark sibling is only revealed.
    @Test func linkClicksInCombiningMarkFolders() throws {
        let t = try makeTree(["doc/\u{301}a.md", "doc/\u{301}d/b.md", "doc/c/\u{301}e/f.md", "doc\u{301}/s.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let doc = t.appendingPathComponent("doc")
        for rel in ["\u{301}a.md", "\u{301}d/b.md", "c/\u{301}e/f.md"] {
            let f = doc.appendingPathComponent(rel).standardizedFileURL
            #expect(PreviewLinkAction.action(for: try page(f), folder: doc, isText: isText) == .openInCedric(f), "\(rel)")
            #expect(PreviewLinkAction.previewAction(for: try page(f), folder: doc, command: false, isText: isText) == .openInPreview(f))
            #expect(PreviewLinkAction.previewDocument(at: f, root: doc, isText: isText).map { String(decoding: $0.data, as: UTF8.self) }
                    == "doc/" + rel, "\(rel) is read")
        }
        let s = t.appendingPathComponent("doc\u{301}/s.md").standardizedFileURL
        #expect(PreviewLinkAction.action(for: try page(s), folder: doc, isText: isText) == .revealInFinder(s))
        var read = false
        #expect(PreviewLinkAction.previewDocument(at: s, root: doc, isText: isText) { _ in read = true; return nil } == nil)
        #expect(!read, "the sibling's file is not read")
    }

    /// The enclosing-root gate: a document in a combining-mark folder
    /// under the opened folder (or the opened folder itself) gets the
    /// opened folder's files; a document in the opened folder's
    /// name-plus-mark sibling does not.
    @Test func theOpenedFolderEnclosesCombiningMarkFolders() throws {
        let t = try makeTree(["root/img.png", "root/\u{301}d/doc.md", "root/c/\u{301}e/doc.md", "root\u{301}/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let root = t.appendingPathComponent("root"), img = root.appendingPathComponent("img.png")
        for rel in ["root/\u{301}d", "root/c/\u{301}e", "root"] {
            let folder = t.appendingPathComponent(rel)
            let hit = PreviewFolder.approved(for: try page(img), in: folder, openedRoot: root, scriptOn: true, siteRoots: false)
            #expect(hit?.root == root, "\(rel)")
            #expect(hit?.file == img.standardizedFileURL, "\(rel)")
        }
        let sibling = t.appendingPathComponent("root\u{301}")
        #expect(PreviewFolder.approved(for: try page(img), in: sibling, openedRoot: root, scriptOn: true, siteRoots: false) == nil,
                "the opened folder's name plus a mark doesn't enclose it")
    }

    /// With JavaScript on, a name starting with a dot byte is hidden even
    /// when a combining mark follows the dot (`hasPrefix(".")` missed it),
    /// on the path asked for and on the path its links lead to; a
    /// combining-mark name that isn't hidden is still served.
    @Test func aDotFollowedByAMarkIsHiddenWithScriptOn() throws {
        let t = try makeTree(["doc/.\u{301}x.png", "doc/.\u{301}d/y.png", "doc/c/.\u{301}e/z.png", "doc/\u{301}ok/w.png", "doc/ok.png"])
        defer { try? FileManager.default.removeItem(at: t) }
        let fm = FileManager.default
        let doc = t.appendingPathComponent("doc")
        func served(_ rel: String) throws -> URL? {
            PreviewFolder.file(for: try page(doc.appendingPathComponent(rel)), in: doc, scriptOn: true)
        }
        for rel in [".\u{301}x.png", ".\u{301}d/y.png", "c/.\u{301}e/z.png"] {
            #expect(try served(rel) == nil, "\(rel) is hidden")
            #expect(PreviewFolder.file(for: try page(doc.appendingPathComponent(rel)), in: doc, scriptOn: false) != nil, "\(rel) with script off")
        }
        #expect(try served("\u{301}ok/w.png") != nil, "a mark-leading folder isn't hidden")
        #expect(try served("ok.png") != nil)
        // Asked for by a plain name, leading to a hidden one: refused.
        try fm.createSymbolicLink(at: doc.appendingPathComponent("pics"), withDestinationURL: doc.appendingPathComponent(".\u{301}d"))
        try fm.createSymbolicLink(at: doc.appendingPathComponent("v.png"), withDestinationURL: doc.appendingPathComponent(".\u{301}x.png"))
        #expect(try served("pics/y.png") == nil, "the resolved folder is hidden")
        #expect(try served("v.png") == nil, "the resolved file is hidden")
    }
}
