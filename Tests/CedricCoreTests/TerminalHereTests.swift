import Foundation
import Testing
@testable import CedricCore

@Suite struct TerminalHereTests {
    @Test func aDocumentOpensAtItsFolder() {
        let doc = URL(fileURLWithPath: "/tmp/it's a \"dir\"/notes/a b.md")
        #expect(TerminalHere.folder(forDocument: doc)?.path == "/tmp/it's a \"dir\"/notes")
        #expect(TerminalHere.folder(forDocument: doc)?.hasDirectoryPath == true)
    }

    @Test func untitledHasNoFolder() {
        #expect(TerminalHere.folder(forDocument: nil) == nil)
        #expect(TerminalHere.folder(forDocument: URL(string: "https://example.com/a.md")) == nil)
    }

    @Test func aSidebarFolderIsItselfAndAFileItsFolder() {
        let folder = URL(fileURLWithPath: "/tmp/proj/sub folder/")
        #expect(TerminalHere.folder(forItem: folder, isDirectory: true)?.path == "/tmp/proj/sub folder")
        #expect(TerminalHere.folder(forItem: URL(fileURLWithPath: "/tmp/proj/sub folder/x.txt"), isDirectory: false)?.path == "/tmp/proj/sub folder")
        #expect(TerminalHere.folder(forItem: URL(string: "https://example.com/")!, isDirectory: true) == nil)
    }
}
