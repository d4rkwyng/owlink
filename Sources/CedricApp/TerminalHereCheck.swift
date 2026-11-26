import AppKit
import CedricCore

/// CEDRIC_CHECK=terminalhere (Scripts/tools-check.sh): File › Open in
/// Terminal Here and the folder sidebar's Open in Terminal Here, with the
/// opener recording the folder (Terminal is never launched in checks).
/// Off for an untitled tab; a document's folder, in a path with spaces
/// and quotes; in the sidebar, a folder row's folder (row menu and header
/// menu), a file row's own folder, and the root with no row selected.
@MainActor
extension DevChecks {
    static func terminalHereCheck(_ app: AppDelegate) {
        let rootName = "it's a \"quoted\" dir"
        let root = dir.appendingPathComponent(rootName, isDirectory: true)
        let docURL = write("\(rootName)/notes/a b.md", "# Terminal here\n")
        _ = write("\(rootName)/sub folder/x.txt", "x\n")
        _ = write("\(rootName)/top.txt", "top\n")
        app.newTab(nil)
        let untitled = app.tabs.last!
        let doc = app.open(docURL)!
        sized(doc)
        TerminalOpener.opened = []
        func real(_ u: URL?) -> String { u?.standardizedFileURL.resolvingSymlinksInPath().path ?? "-" }
        func item() -> NSMenuItem? { menuItem(action: #selector(AppDelegate.openInTerminalMenu(_:))) }
        var sidebar: FolderSidebar? { FolderSidebar.shared }
        func select(_ rel: String) {
            guard let s = sidebar, let n = s.root.descendant(rel) else { expect(false, "the sidebar lists \(rel)"); return }
            s.outline.selectRowIndexes([s.outline.row(forItem: n)], byExtendingSelection: false)
        }
        func perform(_ menu: NSMenu?, _ what: String) {
            guard let menu, let i = menu.items.firstIndex(where: { $0.title == "Open in Terminal Here" }) else {
                expect(false, "\(what) has Open in Terminal Here"); return
            }
            expect(menu.items[i].isEnabled, "\(what): Open in Terminal Here is enabled")
            menu.performActionForItem(at: i)
        }
        run([
            sync {
                expect(TerminalOpener.dryRun, "checks record the folder instead of launching Terminal")
                guard let i = item() else { expect(false, "File › Open in Terminal Here exists"); return }
                expect(i.title == "Open in Terminal Here" && i.menu?.supermenu?.items.contains { $0.submenu === i.menu && $0.title == "File" } == true,
                       "it is in the File menu")
                focus(untitled)
                expect(untitled.doc.fileURL == nil && !app.validateMenuItem(i), "off for an untitled tab")
                app.openInTerminalMenu(nil)
                expect(TerminalOpener.opened.isEmpty, "an untitled tab opens nothing", "\(TerminalOpener.opened)")
                focus(doc)
                expect(app.validateMenuItem(i), "on for a saved document")
                NSApp.sendAction(i.action!, to: nil, from: i)
                let want = root.appendingPathComponent("notes", isDirectory: true)
                let got = TerminalOpener.opened.first
                expect(TerminalOpener.opened.count == 1 && real(got) == real(want), "the document's folder is passed", "\(TerminalOpener.opened)")
                expect(got?.isFileURL == true && got?.hasDirectoryPath == true && got?.path.hasSuffix("/\(rootName)/notes") == true,
                       "a folder file URL, spaces and quotes as they are (nothing escaped)", got?.path ?? "-")
                TerminalOpener.opened = []
                app.openFolder(root)
            },
            until("the folder is listed") { sidebar?.root.isLoaded == true && sidebar?.root.descendant("sub folder") != nil },
            sync {
                guard let s = sidebar else { return }
                // Row menu on a folder.
                select("sub folder")
                guard let rowMenu = s.outline.menu else { expect(false, "the sidebar rows have a menu"); return }
                s.menuNeedsUpdate(rowMenu)
                perform(rowMenu, "a folder row's menu")
                expect(real(TerminalOpener.opened.last) == real(root.appendingPathComponent("sub folder")), "a folder row: that folder",
                       "\(TerminalOpener.opened)")
                // Row menu on a file: its own folder.
                select("top.txt")
                s.menuNeedsUpdate(rowMenu)
                perform(rowMenu, "a file row's menu")
                expect(real(TerminalOpener.opened.last) == real(root), "a file row: its folder", "\(TerminalOpener.opened)")
                // Header menu, a folder selected, then nothing selected (the root).
                guard let actions = s.subviews.first(where: { $0.identifier?.rawValue == "folder-actions" }) as? NSPopUpButton else {
                    expect(false, "the folder-actions pull-down"); return
                }
                select("notes")
                s.updateHeaderMenu()
                perform(actions.menu, "the header menu")
                expect(real(TerminalOpener.opened.last) == real(root.appendingPathComponent("notes")), "header menu: the selected folder",
                       "\(TerminalOpener.opened)")
                s.outline.deselectAll(nil)
                s.updateHeaderMenu()
                perform(actions.menu, "the header menu with nothing selected")
                expect(real(TerminalOpener.opened.last) == real(root), "header menu, no row: the folder's root", "\(TerminalOpener.opened)")
                expect(TerminalOpener.opened.count == 4 && TerminalOpener.opened.allSatisfy(\.hasDirectoryPath), "one folder per command",
                       "\(TerminalOpener.opened)")
                app.closeFolder()
            },
        ])
    }
}
