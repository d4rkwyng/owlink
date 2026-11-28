import AppKit
import CedricCore

/// CEDRIC_CHECK=folder (Scripts/tools-check.sh): the folder sidebar
/// (plan-0.2.0.md §6). Builds a small tree in the temp folder, opens it
/// the way a folder dropped on the Dock icon arrives, and drives the tree
/// with real mouse and key events: a click on a disclosure triangle, →
/// on a selected folder, clicks on files (a tab opens; a second click
/// doesn't open another), Return on a file. Then changes the tree on disk
/// (create, delete, rename) and waits for FSEvents to show it; checks the
/// git-ignored rows dimmed, and re-dimmed when the .gitignore is edited
/// on disk; the symlink loop guard, the layout with the preview and Find in Files
/// docked too, re-docking on a tab switch, ⌃⌘1 hiding (stream stopped)
/// and showing again (re-listed), the session state, snapshots in light
/// and dark, Close Folder, and File › Open Enclosing Folder / Reveal in
/// Finder (off when untitled; the file's folder, the file selected).
@MainActor
extension DevChecks {
    static func folderCheck(_ app: AppDelegate) {
        let proj = dir.appendingPathComponent("proj", isDirectory: true)
        _ = write("proj/src/a.swift", "let a = 1\n")
        _ = write("proj/src/b.swift", "let b = 2\n")
        _ = write("proj/docs/readme.md", "# Readme\n\nfolder sidebar\n")
        for n in ["zeta.txt", "alpha.txt", "file10.txt", "file2.txt", ".hidden", ".DS_Store", ".git/HEAD"] { _ = write("proj/\(n)", "\(n)\n") }
        // Git-ignored entries are listed, dimmed.
        _ = write("proj/.gitignore", "*.log\nbuild/\n")
        _ = write("proj/debug.log", "log\n")
        _ = write("proj/build/out.o", "o\n")
        try? FileManager.default.createSymbolicLink(atPath: proj.appendingPathComponent("src/up").path, withDestinationPath: "..")
        // Outside any git repository: its own folder in the temp folder (checked below).
        let plain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-nogit-\(getpid())", isDirectory: true)
        let outside = app.open(write("outside.txt", "not in the folder\n"))!
        sized(outside)
        let fm = FileManager.default
        var sidebar: FolderSidebar { FolderSidebar.shared! }
        func names(_ parent: FolderNode?) -> [String] {
            let o = sidebar.outline
            return (0..<o.numberOfChildren(ofItem: parent)).compactMap { (o.child($0, ofItem: parent) as? FolderNode)?.name }
        }
        func node(_ rel: String) -> FolderNode? { FolderSidebar.shared?.root.descendant(rel) }
        func row(_ rel: String) -> Int { node(rel).map { sidebar.outline.row(forItem: $0) } ?? -1 }
        func tab(named n: String) -> EditorWindowController? { app.tabs.first { $0.doc.fileURL?.lastPathComponent == n } }
        func toggleItem() -> NSMenuItem? { menuItem(action: #selector(AppDelegate.toggleFolderSidebarMenu(_:))) }
        func checkSplit(_ split: NSSplitView, content: NSView, folder: FolderSidebar?, width: CGFloat, _ name: String) {
            // Do not call layoutIfNeeded here: that can hide a missing
            // adjustSubviews() after the sidebar is removed.
            let panes = split.arrangedSubviews
            let expected = folder.map { [$0, content] } ?? [content]
            let order = panes.count == expected.count && zip(panes, expected).allSatisfy { pair in pair.0 === pair.1 }
            let left = folder.map { $0.frame.maxX + split.dividerThickness } ?? 0
            let folderWidth = folder.map { abs($0.frame.minX) <= 2 && abs($0.frame.width - width) <= 2 } ?? true
            expect(order && folderWidth && abs(content.frame.minX - left) <= 2 &&
                   abs(content.frame.maxX - split.bounds.width) <= 2 &&
                   abs(content.frame.width - (split.bounds.width - left)) <= 2,
                   name, "split=\(split.bounds) panes=\(panes.map(\.frame)) saved width=\(width)")
        }
        func checkEditor(_ tab: EditorWindowController, folder: FolderSidebar?, width: CGFloat, _ name: String) {
            checkSplit(tab.split, content: tab.editorArea, folder: folder, width: width, name)
            let scroll = tab.scrollView.convert(tab.scrollView.bounds, to: tab.split)
            let gutter = tab.gutter.convert(tab.gutter.bounds, to: tab.split)
            let left = folder.map { $0.frame.maxX + tab.split.dividerThickness } ?? 0
            expect(abs(gutter.minX - left) <= 2 && abs(scroll.maxX - tab.editorArea.frame.maxX) <= 2 &&
                   abs(scroll.minX - (left + gutter.width)) <= 2,
                   "\(name): gutter and scroll fill the editor",
                   "gutter=\(gutter) scroll=\(scroll) editor=\(tab.editorArea.frame) left=\(left)")
        }
        /// The row's drawn name colour (nil if the row has no view).
        func nameColor(_ rel: String) -> NSColor? {
            let r = row(rel)
            guard r >= 0 else { return nil }
            return (sidebar.outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTableCellView)?.textField?.textColor
        }
        /// A real left click on the row's text, or (inactive app: a synthetic
        /// click isn't taken by a table in a window that can't become key)
        /// the selection and click action it would make.
        func clickRow(_ r: Int, _ what: String) {
            let o = sidebar.outline
            let rect = o.frameOfCell(atColumn: 0, row: r)
            click(o, at: NSPoint(x: rect.minX + 30, y: rect.midY))
            if o.selectedRow != r {
                print("check: note: synthetic click on \(what) not taken by the inactive outline; selecting it and opening as the click would")
                o.selectRowIndexes([r], byExtendingSelection: false)
                sidebar.activateSelection()
            }
        }
        func keyTo(_ view: NSView, _ code: UInt16, _ chars: String) {
            guard let w = view.window,
                  let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                              isARepeat: false, keyCode: code) else { return }
            w.makeFirstResponder(view)
            w.sendEvent(down)
        }
        func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }
        /// ⇧⌘F. In the macOS 15 VM (app active) the synthetic key event
        /// doesn't reach the menu item with the sidebar docked, though a real
        /// ⇧⌘F does there: then the menu item's action, as the key would.
        func findInFilesKey() {
            key("f", [.command, .shift])
            if app.findInFiles?.isShown != true {
                print("check: note: synthetic ⇧⌘F not taken; sending Find in Files…'s action")
                app.findInFilesMenu(nil)
            }
        }
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        var tabsBefore = 0
        var redockMs = 0.0
        var savedWrap = true
        var savedReadableWidth: Bool?
        var listingsBeforeRefresh = 0

        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(outside)
                print("check: note: app active=\(NSApp.isActive) key window=\(NSApp.keyWindow != nil)")
                expect(FolderSidebar.shared == nil && FolderWatcher.running == 0, "nothing built and no stream before a folder is opened")
                guard let open = menuItem(action: #selector(AppDelegate.openFolderMenu(_:))), let show = toggleItem() else {
                    expect(false, "the menu items exist"); return
                }
                expect(open.keyEquivalent == "o" && open.keyEquivalentModifierMask == [.command, .shift] && app.validateMenuItem(open),
                       "File › Open Folder… is ⇧⌘O and enabled", MenuShortcuts.name(open))
                expect(show.keyEquivalent == "1" && show.keyEquivalentModifierMask == [.control, .command] && !app.validateMenuItem(show),
                       "View › Show Folder Sidebar is ⌃⌘1, disabled until a folder is open", MenuShortcuts.name(show))
                // A folder dropped on the Dock icon (or `owlink dir`) arrives here.
                app.application(NSApp, open: [proj])
                expect(app.tabs.count == 1, "a folder doesn't open as a tab", "\(app.tabs.count)")
                expect(FolderSidebar.shared?.isShown == true, "the folder opens in the sidebar")
            },
            until("the folder is listed") { FolderSidebar.shared?.root.isLoaded == true },
            sync {
                let s = sidebar
                outside.window?.layoutIfNeeded()
                let subs = outside.split.arrangedSubviews
                expect(subs.first === s && subs.count == 2 && subs[1] === outside.editorArea, "docked at the left of the tab's split", "\(subs.map { Swift.type(of: $0) })")
                expect(abs(s.frame.width - FolderSidebar.defaultWidth) <= 2, "default width", "\(s.frame.width)")
                expect(names(nil) == ["build", "docs", "src", "alpha.txt", "debug.log", "file2.txt", "file10.txt", "zeta.txt"],
                       "folders first, then Finder order; no .git, .DS_Store or hidden files", "\(names(nil))")
                expect(node("build")?.entry.isIgnored == true && node("debug.log")?.entry.isIgnored == true,
                       "git-ignored entries are marked (.gitignore: *.log, build/)")
                expect(["docs", "src", "alpha.txt", "file2.txt"].allSatisfy { node($0)?.entry.isIgnored == false }, "the rest aren't")
                expect(nameColor("debug.log") == .tertiaryLabelColor && nameColor("build") == .tertiaryLabelColor, "ignored rows are dimmed",
                       "\(String(describing: nameColor("debug.log")))")
                expect(nameColor("alpha.txt") == .labelColor, "other rows aren't", "\(String(describing: nameColor("alpha.txt")))")
                expect(node("src")?.isLoaded == false, "subfolders aren't listed until expanded")
                expect(FolderWatcher.running == 1 && s.isWatching, "one FSEvents stream while shown", "\(FolderWatcher.running)")
                expect(toggleItem().map { app.validateMenuItem($0) && $0.title == "Hide Folder Sidebar" && $0.state == .off } == true,
                       "View › Hide Folder Sidebar enabled (Show/Hide, no checkmark)", toggleItem()?.title ?? "-")
                guard let actions = s.subviews.first(where: { $0.identifier?.rawValue == "folder-actions" }) as? NSPopUpButton,
                      let menu = actions.menu else {
                    expect(false, "the folder-actions pull-down"); return
                }
                expect(actions.accessibilityLabel() == String(localized: "Folder Actions") &&
                       actions.toolTip == String(localized: "Folder Actions"), "folder-actions has a VoiceOver label and tooltip")
                let expectedMenu = ["", "New File…", "New Folder…", "|", "Rename", "Move to Trash…", "|",
                                    "Reveal in Finder", "Open in Terminal Here", "Open Enclosing Folder", "Copy Path", "Find in Folder…", "|",
                                    "Refresh", "Collapse All", "|", "Show Hidden Files", "|", "Open Folder…", "|", "Close Folder"]
                @MainActor func checkMenu(_ name: String) {
                    s.updateHeaderMenu()
                    let titles = menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
                    expect(titles == expectedMenu, name, "\(titles)")
                }
                func enabled(_ title: String) -> Bool? { menu.items.first { $0.title == title }?.isEnabled }
                s.outline.deselectAll(nil)
                checkMenu("header menu titles and separators")
                expect(enabled("New File…") == true && enabled("New Folder…") == true && enabled("Rename") == false &&
                       enabled("Move to Trash…") == false && enabled("Reveal in Finder") == true &&
                       enabled("Open Enclosing Folder") == false && enabled("Copy Path") == true &&
                       enabled("Find in Folder…") == true && enabled("Refresh") == true &&
                       enabled("Collapse All") == false && enabled("Open Folder…") == true &&
                       enabled("Close Folder") == true && menu.items.first { $0.title == "Show Hidden Files" }?.state == .off,
                       "header menu enablement with no selected row")
                s.outline.selectRowIndexes([row("alpha.txt")], byExtendingSelection: false)
                s.updateHeaderMenu()
                expect(enabled("Rename") == true && enabled("Move to Trash…") == true && enabled("Open Enclosing Folder") == false,
                       "a root file enables Rename and Trash, not Open Enclosing Folder")
                s.outline.selectRowIndexes([row("docs")], byExtendingSelection: false)
                s.updateHeaderMenu()
                expect(enabled("Rename") == true && enabled("Move to Trash…") == true && enabled("Open Enclosing Folder") == false,
                       "a selected folder enables Rename and Trash, not Open Enclosing Folder")
                s.outline.deselectAll(nil)
                listingsBeforeRefresh = s.listings
                s.refresh(nil)
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            until("header Refresh re-lists loaded folders") { sidebar.listings > listingsBeforeRefresh },
            snapshot("folder-root.png"),
            { next in
                // Expand src: a click on its disclosure triangle.
                let o = sidebar.outline
                let r = row("src")
                let tri = o.frameOfOutlineCell(atRow: r)
                expect(r >= 0 && tri.width > 0, "src has a disclosure triangle", "row \(r) \(tri)")
                click(o, at: NSPoint(x: tri.midX, y: tri.midY))
                if let n = node("src"), !o.isItemExpanded(n) {
                    print("check: note: synthetic click on the disclosure triangle not taken; expanding as it would")
                    o.expandItem(n)
                }
                next()
            },
            until("src is listed after expanding") { node("src")?.isLoaded == true },
            sync {
                expect(sidebar.outline.isItemExpanded(node("src")), "a click on the triangle expands src")
                expect(names(node("src")) == ["up", "a.swift", "b.swift"], "src's files (and the link to its parent, as a folder)", "\(names(node("src")))")
                // Expand docs with the keyboard: select it, →.
                let o = sidebar.outline
                o.selectRowIndexes([row("docs")], byExtendingSelection: false)
                keyTo(o, 124, right)
            },
            until("docs is listed after →") { node("docs")?.isLoaded == true },
            sync {
                expect(sidebar.outline.isItemExpanded(node("docs")), "→ on a selected folder expands it")
                expect(names(node("docs")) == ["readme.md"], "docs' file", "\(names(node("docs")))")
                sidebar.outline.selectRowIndexes([row("docs/readme.md")], byExtendingSelection: false)
                sidebar.updateHeaderMenu()
                let enclosing = sidebar.subviews.first(where: { $0.identifier?.rawValue == "folder-actions" })
                    .flatMap { ($0 as? NSPopUpButton)?.menu?.items.first { $0.title == "Open Enclosing Folder" } }
                expect(enclosing?.isEnabled == true, "a file below the root enables Open Enclosing Folder")
                sidebar.outline.deselectAll(nil)
                tabsBefore = app.tabs.count
                clickRow(row("src/a.swift"), "a.swift")
            },
            until("clicking a file opens it") { tab(named: "a.swift") != nil },
            sync {
                guard let a = tab(named: "a.swift") else { finish(); return }
                expect(app.tabs.count == tabsBefore + 1, "one new tab", "\(app.tabs.count)")
                expect(sidebar.superview === a.split && a.split.arrangedSubviews.first === sidebar, "the sidebar moves to the new tab")
                expect(sidebar.outline.selectedRow == row("src/a.swift"), "the file's row is selected")
                tabsBefore = app.tabs.count
                clickRow(row("src/a.swift"), "a.swift again")
            },
            sync {
                expect(app.tabs.count == tabsBefore, "clicking the same file again opens no second tab", "\(app.tabs.count)")
                // Return on a selected file opens it.
                let o = sidebar.outline
                o.selectRowIndexes([row("src/b.swift")], byExtendingSelection: false)
                keyTo(o, 36, "\r")
            },
            until("Return on a file opens it") { tab(named: "b.swift") != nil },
            sync {
                // Outside changes: create, delete, rename.
                try? "new\n".write(to: proj.appendingPathComponent("src/new.swift"), atomically: false, encoding: .utf8)
                try? fm.removeItem(at: proj.appendingPathComponent("zeta.txt"))
                try? fm.moveItem(at: proj.appendingPathComponent("alpha.txt"), to: proj.appendingPathComponent("omega.txt"))
            },
            until("FSEvents: a created file shows", timeout: 5) { node("src/new.swift") != nil && row("src/new.swift") >= 0 },
            until("FSEvents: a deleted file goes", timeout: 5) { node("zeta.txt") == nil },
            until("FSEvents: a renamed file shows its new name", timeout: 5) { node("omega.txt") != nil && node("alpha.txt") == nil },
            sync {
                expect(names(nil) == ["build", "docs", "src", "debug.log", "file2.txt", "file10.txt", "omega.txt"], "root rows after the changes", "\(names(nil))")
                expect(names(node("src")) == ["up", "a.swift", "b.swift", "new.swift"], "src rows after the changes", "\(names(node("src")))")
                expect(sidebar.outline.isItemExpanded(node("src")) && sidebar.outline.isItemExpanded(node("docs")), "expansion kept through the updates")
                // The .gitignore edited on disk: rows re-dimmed in place, in loaded subfolders too.
                try? "*.log\nbuild/\nfile2.txt\nb.swift\n".write(to: proj.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            until("FSEvents: an edited .gitignore dims what it now ignores", timeout: 5) {
                node("file2.txt")?.entry.isIgnored == true && node("src/b.swift")?.entry.isIgnored == true
            },
            sync {
                expect(nameColor("file2.txt") == .tertiaryLabelColor && nameColor("src/b.swift") == .tertiaryLabelColor,
                       "the newly ignored rows are redrawn dimmed", "\(String(describing: nameColor("file2.txt")))")
                expect(node("debug.log")?.entry.isIgnored == true && node("src/a.swift")?.entry.isIgnored == false, "the rest unchanged")
                expect(sidebar.outline.isItemExpanded(node("src")), "expansion kept")
                // The link back to src's parent: never listed into.
                sidebar.outline.expandItem(node("src/up"))
            },
            until("the loop link is handled") { node("src/up")?.isLoaded == true },
            sync {
                let up = node("src/up")
                expect(up?.children?.isEmpty == true && up?.loadError != nil, "a link to a folder above it isn't expanded into (loop guard)",
                       "\(up?.children?.count ?? -1) \(up?.loadError ?? "-")")
                // Preview and Find in Files with the sidebar: Folder | editor | preview | Find in Files.
                clickRow(row("docs/readme.md"), "readme.md")
            },
            until("readme.md opens") { tab(named: "readme.md") != nil },
            sync {
                let t = tab(named: "readme.md")!
                t.window?.setContentSize(NSSize(width: 1500, height: 720))
                focus(t)
                key("p", [.command, .option])
                findInFilesKey()
            },
            until("the preview shows") { tab(named: "readme.md")?.previewVisible == true },
            sync {
                let t = tab(named: "readme.md")!
                t.window?.layoutIfNeeded()
                let subs = t.split.arrangedSubviews
                let order = subs.map { $0 === sidebar ? "folder" : $0 === t.editorArea ? "editor" : $0 === t.previewPane ? "preview" : $0 === app.findInFiles ? "find" : "?" }
                // Where the panel is, if not here (the 0.2.0 VM run saw it missing from this split).
                let fif = app.findInFiles
                let fifTab = app.tabs.first { fif?.superview === $0.split }?.doc.displayName ?? "none"
                expect(order == ["folder", "editor", "preview", "find"], "folder | editor | preview | find in files",
                       "\(order); find in files shown=\(fif?.isShown ?? false) in tab \(fifTab), key=\(NSApp.keyWindow?.title ?? "-")")
                let widths = subs.map { Int($0.frame.width) }
                expect(widths.allSatisfy { $0 >= 150 }, "no pane collapsed", "\(widths)")
                expect(t.previewVisible, "previewVisible with the folder sidebar docked")
                let s = sidebar
                let savedWidth = s.width
                s.hide()
                let remaining = t.split.arrangedSubviews
                expect(remaining.count == 3 && remaining[0] === t.editorArea && remaining[1] === t.previewPane &&
                       remaining[2] === app.findInFiles && abs(remaining[0].frame.minX) <= 2 &&
                       abs(remaining[2].frame.maxX - t.split.bounds.width) <= 2 &&
                       zip(remaining, remaining.dropFirst()).allSatisfy {
                           abs($0.0.frame.maxX + t.split.dividerThickness - $0.1.frame.minX) <= 2
                       }, "hiding with preview and Find in Files leaves no gap", "\(remaining.map(\.frame))")
                s.show(in: t)
                let restored = t.split.arrangedSubviews
                expect(restored.count == 4 && restored[0] === s && restored[1] === t.editorArea &&
                       restored[2] === t.previewPane && restored[3] === app.findInFiles &&
                       abs(s.frame.minX) <= 2 && abs(s.frame.width - savedWidth) <= 2 &&
                       abs(restored[3].frame.maxX - t.split.bounds.width) <= 2 &&
                       zip(restored, restored.dropFirst()).allSatisfy {
                           abs($0.0.frame.maxX + t.split.dividerThickness - $0.1.frame.minX) <= 2
                       },
                       "showing with other panes restores the sidebar without a gap")
            },
            snapshot("folder-with-preview.png"),
        ]
        steps += steps3
        let steps4: [Step] = [
            sync {
                let t = tab(named: "readme.md")!
                app.hideFindInFiles()
                t.togglePreview()
                expect(!t.previewVisible && t.split.arrangedSubviews.count == 2, "preview and Find in Files closed: folder | editor",
                       "\(t.split.arrangedSubviews.count)")
                // Tab switch: the sidebar re-docks in the tab that becomes key.
                let a = tab(named: "a.swift")!
                let start = Date()
                a.window?.makeKeyAndOrderFront(nil)
                if sidebar.superview !== a.split { app.tabBecameKey(a) }  // inactive app: no key change
                redockMs = Date().timeIntervalSince(start) * 1000
                print("check: note: tab switch with re-dock took \(String(format: "%.1f", redockMs)) ms")
                expect(sidebar.superview === a.split, "re-docked in the selected tab")
                expect(t.split.arrangedSubviews.count == 1 && t.split.arrangedSubviews.first === t.editorArea, "…and gone from the other tab's split")
                expect(t.split.holdingPriorityForSubview(at: 0) == .defaultLow, "the other tab's editor keeps the default holding priority",
                       "\(t.split.holdingPriorityForSubview(at: 0).rawValue)")
                checkEditor(t, folder: nil, width: 0, "re-docking gives the old tab its room back")
            },
            sync {
                // At the 0.2.0 VM's window size (900 wide): Find in Files docks
                // right of the editor and its × gives its room back to the
                // editor, never to the sidebar (which kept ~490 px and left
                // the editor 0 wide when Find in Files opened again).
                let a = tab(named: "a.swift")!
                focus(a)
                a.window?.setContentSize(NSSize(width: 900, height: 670))
                a.window?.layoutIfNeeded()
                expect(abs(sidebar.frame.width - FolderSidebar.defaultWidth) <= 2, "900 wide: the sidebar keeps its width", "\(sidebar.frame.width)")
                findInFilesKey()
                a.window?.layoutIfNeeded()
                let subs = a.split.arrangedSubviews
                let widths = subs.map { Int($0.frame.width) }
                expect(subs.count == 3 && subs.first === sidebar && subs[1] === a.editorArea && subs[2] === app.findInFiles,
                       "900 wide: folder | editor | find in files", "\(widths)")
                expect(abs(sidebar.frame.width - FolderSidebar.defaultWidth) <= 2 && a.editorArea.frame.width >= 250,
                       "900 wide: Find in Files takes its room from the editor, which stays usable", "\(widths)")
            },
            sync {
                // The panel's ×, a real click: its mouse events are not a divider drag.
                let a = tab(named: "a.swift")!
                guard let p = app.findInFiles,
                      let close = allSubviews(p).first(where: { ($0 as? NSButton)?.action == #selector(FindInFilesPanel.closePanel) }) as? NSButton else {
                    expect(false, "Find in Files has its × button"); return
                }
                click(close, at: NSPoint(x: close.bounds.midX, y: close.bounds.midY))
                if p.isShown {
                    print("check: note: synthetic click on Find in Files' × not taken; pressing it")
                    close.performClick(nil)
                }
                a.window?.layoutIfNeeded()
                let subs = a.split.arrangedSubviews
                expect(!p.isShown && subs.count == 2, "× closes Find in Files", "\(subs.count)")
                expect(abs(sidebar.frame.width - FolderSidebar.defaultWidth) <= 2, "…the sidebar keeps its width", "\(sidebar.frame.width)")
                expect(abs(sidebar.width - FolderSidebar.defaultWidth) <= 2 && app.folderSessionState?.width.map { abs($0 - Double(FolderSidebar.defaultWidth)) <= 2 } == true,
                       "…and that width is what the session saves", "\(sidebar.width) \(app.folderSessionState?.width ?? -1)")
                expect(abs(a.editorArea.frame.maxX - a.split.bounds.width) <= 1 && a.editorArea.frame.width >= a.split.bounds.width - FolderSidebar.defaultWidth - 4,
                       "…the editor gets the room back", "\(Int(a.editorArea.frame.width)) of \(Int(a.split.bounds.width))")
            },
            sync {
                // Opened again: the editor isn't squeezed to nothing.
                let a = tab(named: "a.swift")!
                focus(a)
                findInFilesKey()
                a.window?.layoutIfNeeded()
                let widths = a.split.arrangedSubviews.map { Int($0.frame.width) }
                expect(a.split.arrangedSubviews.count == 3 && abs(sidebar.frame.width - FolderSidebar.defaultWidth) <= 2 && a.editorArea.frame.width >= 250,
                       "Find in Files opened again: the sidebar and the editor keep their room", "\(widths)")
                app.hideFindInFiles()
                a.window?.layoutIfNeeded()
                expect(abs(sidebar.frame.width - FolderSidebar.defaultWidth) <= 2 && a.split.arrangedSubviews.count == 2,
                       "closed again (Find in Files' close path): the sidebar keeps its width", "\(sidebar.frame.width)")
                a.window?.setContentSize(NSSize(width: 1200, height: 720))
            },
        ]
        steps += steps4
        let steps5: [Step] = [
            snapshot("folder-sidebar-open.png"),
            sync {
                // ⌃⌘1: hidden, the stream stopped.
                let a = tab(named: "a.swift")!
                focus(a)
                savedWrap = a.wrapsLines
                savedReadableWidth = a.editing.readableWidth
                a.forceWrapForPerf(true)
                key("1", [.control, .command])
                expect(sidebar.isShown == false && sidebar.superview == nil, "⌃⌘1 hides the sidebar")
                checkEditor(a, folder: nil, width: 0, "hiding gives the editor its room back")
                expect(FolderWatcher.running == 0 && !sidebar.isWatching, "hidden: no FSEvents stream", "\(FolderWatcher.running)")
                expect(toggleItem().map { app.validateMenuItem($0) && $0.title == "Show Folder Sidebar" && $0.state == .off } == true,
                       "View › Show Folder Sidebar still enabled", toggleItem()?.title ?? "-")
                try? "later\n".write(to: proj.appendingPathComponent("docs/later.md"), atomically: false, encoding: .utf8)
            },
            snapshot("folder-sidebar-hidden.png"),
            sync {
                let a = tab(named: "a.swift")!
                // Readable Width after the hide snapshot, while the sidebar
                // is still hidden, so the inset is computed for the full width.
                a.setReadableWidth(true)
                if let column = a.textView.readableColumnWidth {
                    let inset = ReadableWidth.inset(viewWidth: Double(a.textView.bounds.width), column: Double(column))
                    expect(abs(a.textView.textContainerInset.width - CGFloat(inset)) <= 1,
                           "hiding updates the readable-width inset")
                } else { expect(false, "readable width is active") }
                a.editing.readableWidth = savedReadableWidth
                a.applyReadableWidth()
                a.forceWrapForPerf(savedWrap)
                key("1", [.control, .command])
                expect(sidebar.isShown && sidebar.superview === a.split, "⌃⌘1 shows it again in the tab")
                checkEditor(a, folder: sidebar, width: sidebar.width, "showing restores the sidebar width and shrinks the editor")
                expect(FolderWatcher.running == 1, "showing starts the stream again", "\(FolderWatcher.running)")
            },
            until("shown again: what changed while hidden is listed") { node("docs/later.md") != nil },
            sync {
                let st = app.folderSessionState
                expect(st?.path == proj.standardizedFileURL.path && st?.visible == true, "session: folder and visibility", "\(String(describing: st))")
                expect(st?.expanded == ["docs", "src"], "session: expanded folders, parents first", "\(st?.expanded ?? [])")
                expect(st?.width.map { abs($0 - Double(FolderSidebar.defaultWidth)) <= 2 } == true, "session: width", "\(st?.width ?? -1)")
                Settings.shared.themeOverride = .light
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                tab(named: "a.swift")?.window?.setContentSize(NSSize(width: 1200, height: 720))
            },
            snapshot("folder-light.png"),
            sync {
                Settings.shared.themeOverride = .dark
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
            },
            snapshot("folder-dark.png"),
            sync {
                // Close Folder (the × in the header): gone, no stream, menu item off.
                let s = sidebar
                s.updateHeaderMenu()
                let collapse = s.subviews.first(where: { $0.identifier?.rawValue == "folder-actions" })
                    .flatMap { ($0 as? NSPopUpButton)?.menu?.items.first { $0.title == "Collapse All" } }
                expect(collapse?.isEnabled == true, "Collapse All is enabled when folders are expanded")
                s.collapseAll(nil)
                expect(!(s.outline.isItemExpanded(node("src")) || s.outline.isItemExpanded(node("docs"))),
                       "Collapse All collapses expanded folder rows")
                guard let close = s.subviews.first(where: { $0.identifier?.rawValue == "folder-close" }) as? NSButton else {
                    expect(false, "the close button"); return
                }
                expect(close.accessibilityLabel() == String(localized: "Close Folder"), "the close button has a VoiceOver label")
                expect(s.outline.accessibilityLabel() == String(localized: "Folder"), "the folder outline has a VoiceOver label")
                click(close, at: NSPoint(x: close.bounds.midX, y: close.bounds.midY))
                if FolderSidebar.shared != nil {
                    print("check: note: synthetic click on × not taken; sending its action")
                    close.performClick(nil)
                }
                expect(FolderSidebar.shared == nil && s.superview == nil && FolderWatcher.running == 0, "Close Folder removes the sidebar and its stream")
                checkEditor(tab(named: "a.swift")!, folder: nil, width: 0, "header close gives the editor its room back")
                expect(toggleItem().map { app.validateMenuItem($0) } == false, "Show Folder Sidebar disabled again")
                expect(app.folderSessionState == nil, "session: no folder")
            },
        ]
        steps += steps5
        let steps6: [Step] = [
            sync {
                let a = tab(named: "a.swift")!
                focus(a)
                app.openFolder(proj)
                checkEditor(a, folder: sidebar, width: FolderSidebar.defaultWidth, "opening a folder after header close restores the layout")
                app.closeFolder()
                checkEditor(a, folder: nil, width: 0, "Close Folder gives the editor its room back")
                app.openFolder(proj)
                checkEditor(a, folder: sidebar, width: FolderSidebar.defaultWidth, "opening a folder after Close Folder restores the layout")
                app.closeFolder()
                app.openFolder(proj, state: SessionFolder(path: proj.path, width: 310))
                let s = sidebar
                checkEditor(a, folder: s, width: 310, "a saved non-default sidebar width is restored")
                s.hide()
                checkEditor(a, folder: nil, width: 0, "hiding a wider sidebar gives the editor its room back")
                s.show(in: a)
                checkEditor(a, folder: s, width: 310, "showing again keeps the saved non-default width")
                app.closeFolder()
            },
            // A folder with NO .git in it or anywhere above it (the 0.2.0 VM
            // hang: GitIgnore's walk up never ended outside a repository).
            // Its own .gitignore still applies.
            sync {
                let fm = FileManager.default
                try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
                for (n, t) in [("keep.txt", "needle\n"), ("skip.log", "needle\n"), ("sub/inner.txt", "needle\n"), (".gitignore", "*.log\n")] {
                    let u = plain.appendingPathComponent(n)
                    try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? t.write(to: u, atomically: false, encoding: .utf8)
                }
                var p = plain.resolvingSymlinksInPath().path
                var gitAbove: String?
                while true {
                    if fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) { gitAbove = p; break }
                    let up = (p as NSString).deletingLastPathComponent
                    if p == "/" || up.isEmpty || up.count >= p.count { break }
                    p = up
                }
                expect(gitAbove == nil, "no-git fixture: no .git in it or above it", gitAbove ?? "")
                focus(outside)
                app.openFolder(plain)
            },
            until("no-git folder: listed", timeout: 10) { FolderSidebar.shared?.root.isLoaded == true },
            sync {
                expect(names(nil) == ["sub", "keep.txt", "skip.log"], "no-git folder: listed", "\(names(nil))")
                expect(node("skip.log")?.entry.isIgnored == true && node("keep.txt")?.entry.isIgnored == false,
                       "no-git folder: its .gitignore still marks skip.log")
                // Find in Files, Respect .gitignore on: defaults to the sidebar's folder.
                focus(outside)
                findInFilesKey()
                guard let p = app.findInFiles else { expect(false, "no-git folder: Find in Files opens"); return }
                expect(p.folderField.stringValue == FolderSidebar.shared?.rootURL.path, "Find in Files defaults to the open sidebar folder",
                       "\(p.folderField.stringValue) vs \(FolderSidebar.shared?.rootURL.path ?? "-")")
                p.gitIgnoreBox.state = .on
                p.queryField.stringValue = "needle"
            },
            { next in
                let p = app.findInFiles!
                var done = false
                p.onFinished = { p.onFinished = nil; done = true; next() }
                p.startSearch()
                // A search that never ends is the bug: fail, don't hang.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if !done { p.onFinished = nil; p.cancel(); expect(false, "no-git folder: the search ends", "timed out"); next() }
                }
            },
        ]
        steps += steps6
        let steps7: [Step] = [
            sync {
                guard let p = app.findInFiles else { return }
                let files = Set(p.results.map(\.relativePath)).sorted()
                expect(p.lastSummary?.cancelled == false && files == ["keep.txt", "sub/inner.txt"],
                       "no-git folder: Find in Files (Respect .gitignore) finds keep.txt and sub/inner.txt, not skip.log", "\(files)")
                app.hideFindInFiles()
                app.closeFolder()
                try? FileManager.default.removeItem(at: plain)
            },
            // File › Open Enclosing Folder (⌥⇧⌘O) and Reveal in Finder: off
            // for an untitled tab; on a file, its folder opens in the sidebar
            // with the file selected, and Finder is asked to show it.
            sync {
                guard let enc = menuItem(action: #selector(AppDelegate.openEnclosingFolderMenu(_:))),
                      let fin = menuItem(action: #selector(AppDelegate.revealFileInFinderMenu(_:))) else {
                    expect(false, "File › Open Enclosing Folder and Reveal in Finder exist"); return
                }
                expect(enc.keyEquivalent == "o" && enc.keyEquivalentModifierMask == [.command, .shift, .option],
                       "File › Open Enclosing Folder is ⌥⇧⌘O", MenuShortcuts.name(enc))
                expect(MenuShortcuts.list().filter { $0.0 == "⌥⇧⌘O" }.count == 1, "⌥⇧⌘O is used once")
                app.newTab(nil)
                if let untitled = app.tabs.last, untitled.doc.fileURL == nil {
                    focus(untitled)
                    expect(!app.validateMenuItem(enc) && !app.validateMenuItem(fin), "both off for an untitled tab")
                    untitled.window?.performClose(nil)
                } else {
                    expect(false, "an untitled tab opens")
                }
                guard let a = app.open(proj.appendingPathComponent("src/a.swift")) else { expect(false, "src/a.swift opens"); return }
                focus(a)
                expect(app.validateMenuItem(enc) && app.validateMenuItem(fin), "both on with a file open")
                PreviewLinkLog.revealed = []
                NSApp.sendAction(fin.action!, to: nil, from: fin)
                expect(PreviewLinkLog.revealed.map(\.standardizedFileURL) == [a.doc.fileURL?.standardizedFileURL].compactMap { $0 },
                       "Reveal in Finder selects the tab's file in Finder", "\(PreviewLinkLog.revealed)")
                NSApp.sendAction(enc.action!, to: nil, from: enc)
            },
            until("the enclosing folder is listed") {
                FolderSidebar.shared?.rootURL.lastPathComponent == "src" && FolderSidebar.shared?.root.isLoaded == true
            },
            sync {
                let s = sidebar
                expect(s.isShown && s.rootURL.resolvingSymlinksInPath().path == proj.appendingPathComponent("src").resolvingSymlinksInPath().path,
                       "Open Enclosing Folder opens the file's folder in the sidebar", s.rootURL.path)
                let sel = s.outline.selectedRow >= 0 ? (s.outline.item(atRow: s.outline.selectedRow) as? FolderNode)?.name : nil
                expect(sel == "a.swift", "with the file selected", sel ?? "none")
                let image = NSImage(size: NSSize(width: 2, height: 2))
                image.lockFocus()
                NSColor.red.setFill()
                NSRect(x: 0, y: 0, width: 2, height: 2).fill()
                image.unlockFocus()
                if let data = image.tiffRepresentation {
                    try? data.write(to: proj.appendingPathComponent("src/sidebar-test.tiff"))
                }
                s.load(s.root)
            },
            until("viewer file is listed") { node("sidebar-test.tiff") != nil },
        ]
        steps += steps7
        let steps8: [Step] = [
            sync {
                guard let n = node("sidebar-test.tiff") else { expect(false, "viewer row exists"); return }
                app.openFromFolder(n)
                guard let viewer = app.viewerTab(for: n.url) else { expect(false, "viewer opens"); return }
                expect(sidebar.window === viewer.window, "folder sidebar follows a file opened in a viewer")
                viewer.window?.layoutIfNeeded()
                let viewerSplit = viewer.sidebarHost?.split
                expect(viewerSplit?.arrangedSubviews.count == 2 && sidebar.frame.width > 100 &&
                       (viewerSplit?.arrangedSubviews.last?.frame.width ?? 0) > 100,
                       "viewer and sidebar both have room")
                if let split = viewerSplit, let content = split.arrangedSubviews.last {
                    let s = sidebar
                    let savedWidth = s.width
                    s.hide()
                    checkSplit(split, content: content, folder: nil, width: 0, "hiding gives the viewer its room back")
                    s.show(in: viewer)
                    checkSplit(split, content: content, folder: s, width: savedWidth, "showing restores the viewer sidebar layout")
                    s.close()
                    checkSplit(split, content: content, folder: nil, width: 0, "closing gives the viewer its room back")
                    s.show(in: viewer)
                    checkSplit(split, content: content, folder: s, width: savedWidth, "reopening restores the viewer sidebar layout")
                } else { expect(false, "viewer split and content exist") }
                let item = NSMenuItem()
                item.representedObject = n
                sidebar.renameItem(item)
                guard let cell = sidebar.outline.view(atColumn: 0, row: sidebar.outline.row(forItem: n), makeIfNecessary: true) as? NSTableCellView,
                      let field = cell.textField else { expect(false, "rename field exists"); return }
                expect(field.isEditable, "rename edits the outline row")
                let selected = field.currentEditor()?.selectedRange
                expect(selected == FolderActions.renameSelection(name: "sidebar-test.tiff", isDirectory: false)
                       && selected?.length == ("sidebar-test" as NSString).length,
                       "rename selects the base name, not the extension", "\(String(describing: selected))")
                field.stringValue = "renamed.tiff"
                sidebar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
                expect(viewer.fileURL.lastPathComponent == "renamed.tiff" && viewer.window?.title == "renamed.tiff",
                       "an open viewer follows an inline rename")
                let separate = app.makeTab(EditorDocument(untitledName: "Separate"), text: "", newWindow: true)
                app.tabBecameKey(separate)
                let renamedNode = FolderNode(url: viewer.fileURL, entry: FolderEntry(name: viewer.fileURL.lastPathComponent, isDirectory: false))
                app.openFromFolder(renamedNode)
                expect(sidebar.window === viewer.window, "opening a tree file in another window carries the sidebar")
                if let unrelated = app.open(write("unrelated.txt", "elsewhere")) {
                    app.tabBecameKey(unrelated)
                    expect(sidebar.window === unrelated.window, "the app-wide sidebar follows an unrelated opened text tab")
                } else { expect(false, "unrelated text opens") }
                do {
                    try sidebar.createItem(named: "created.pdf", in: sidebar.root, directory: false)
                    let created = sidebar.rootURL.appendingPathComponent("created.pdf")
                    expect(app.tabs.contains { $0.doc.fileURL == created } && sidebar.window === app.tabs.last?.window,
                           "creating a file opens it with the sidebar")
                    try sidebar.createItem(named: "created-folder", in: sidebar.root, directory: true)
                    let parent = try FolderActions.create(in: sidebar.rootURL, name: "explorer", directory: true)
                    let file = try FolderActions.create(in: parent, name: "note.txt", directory: false)
                    let emptyPDF = try FolderActions.create(in: parent, name: "empty.pdf", directory: false)
                    let newNode = FolderNode(url: emptyPDF, entry: FolderEntry(name: "empty.pdf", isDirectory: false))
                    app.openFromFolder(newNode, asText: true)
                    expect(app.tabs.contains { $0.doc.fileURL == emptyPDF }, "a new file opens as text even with a viewer extension")
                    let newTab = app.tabs.first { $0.doc.fileURL == emptyPDF }
                    expect(app.open(emptyPDF) === newTab, "opening that file again selects the existing text tab")
                    try "unsaved text".write(to: file, atomically: true, encoding: .utf8)
                    let image = parent.appendingPathComponent("picture.tiff")
                    try Data(contentsOf: viewer.fileURL).write(to: image)
                    guard let textTab = app.open(file), let imageTab = app.openImage(image) else {
                        expect(false, "explorer fixture tabs open"); return
                    }
                    textTab.doc.markDirtyFromSession()
                    let renamed = try FolderActions.rename(parent, name: "explorer-renamed")
                    app.folderItemRenamed(parent, to: renamed, directory: true)
                    expect(textTab.doc.fileURL?.path == renamed.appendingPathComponent("note.txt").path &&
                           imageTab.fileURL.path == renamed.appendingPathComponent("picture.tiff").path,
                           "open text and viewer tabs follow a folder rename")
                    expect(textTab.text == "unsaved text" && textTab.doc.isDirty &&
                           textTab.window?.title == "note.txt •" && imageTab.window?.representedURL == imageTab.fileURL,
                           "folder rename preserves unsaved text and updates window metadata")
                    _ = try FolderActions.rename(renamed, name: "explorer-moved-away")
                    app.folderItemTrashed(renamed, directory: true)
                    expect(textTab.doc.missingOnDisk && textTab.doc.isDirty && textTab.text == "unsaved text" &&
                           textTab.diskBar?.label.stringValue.contains("was deleted or moved") == true,
                           "moving away a folder keeps text unsaved and shows the missing-file bar")
                    let notice = imageTab.sidebarHost?.arrangedSubviews.compactMap { $0 as? NoticeBar }.first
                    expect(notice?.isHidden == false && notice?.label.stringValue.contains("was deleted or moved") == true,
                           "moving away a folder shows a viewer notice")
                } catch { expect(false, "explorer file operations", error.localizedDescription) }
            },
        ]
        steps += steps8
        let steps9: [Step] = [
            until("new folder is revealed") {
                guard let n = node("created-folder") else { return false }
                return sidebar.outline.row(forItem: n) == sidebar.outline.selectedRow
            },
            sync {
                let hiddenBefore = sidebar.showHidden
                do {
                    try sidebar.createItem(named: ".created-hidden", in: sidebar.root, directory: false)
                    expect(sidebar.showHidden == hiddenBefore, "creating a hidden file does not turn on Show Hidden Files")
                } catch { expect(false, "creating a hidden file", error.localizedDescription) }
            },
            until("the new hidden file is still shown in the tree") { node(".created-hidden") != nil },
            sync { app.closeFolder() },
        ]
        steps += steps9
        steps += folderSwitchSteps(app)
        run(steps)
    }

    /// 0.6.1 bug 1: a file opened from outside the app (Finder / Open With
    /// / the Dock icon as `application(_:open:)`, Open Recent, a drop, the
    /// cedric script) while the sidebar shows another folder switches the
    /// sidebar to the file's folder, the file selected, the sidebar docked
    /// in the file's own tab (text, image, PDF, a big file read in the
    /// background). Opens from inside the app (a sidebar click, Quick Open,
    /// a preview or wiki link, a restored tab) and a hidden or closed
    /// sidebar leave the folder alone; so do a refused file and a file
    /// reached through a link into the loaded folder.
    static func folderSwitchSteps(_ app: AppDelegate) -> [Step] {
        let fm = FileManager.default
        func folder(_ name: String) -> URL { dir.appendingPathComponent("switch/\(name)", isDirectory: true) }
        let a = folder("A"), b = folder("B"), img = folder("Img"), pdf = folder("PDF"), recent = folder("Recent"),
            cli = folder("CLI"), drop = folder("Drop"), big = folder("Big"), other = folder("Other")
        _ = write("switch/A/a1.md", "# A\n")
        _ = write("switch/A/sub/a2.md", "# A2\n")
        let welcome = write("switch/B/Welcome.md", "# Welcome\n")
        _ = write("switch/B/zz-other.md", "other\n")
        let recentFile = write("switch/Recent/recent.md", "recent\n")
        let cliFile = write("switch/CLI/cli.md", "cli\n")
        let dropFile = write("switch/Drop/drop.md", "drop\n")
        let bigText = write("switch/Big/big.log", "")
        let bigLine = "a line of a big log, read in the background\n"
        try? Data(String(repeating: bigLine, count: AppDelegate.backgroundOpenBytes / bigLine.utf8.count + 1000).utf8).write(to: bigText)
        let small = write("switch/Big/small.txt", "small\n")
        let outsideFiles = ["click.md", "quick.md", "link.md", "wiki.md", "restored.md"].map { write("switch/Other/\($0)", "\($0)\n") }
        let hiddenFile = write("switch/Hidden/hidden.md", "hidden\n")
        let closedFile = write("switch/Hidden/closed.md", "closed\n")
        let image = img.appendingPathComponent("pic.tiff")
        let pdfFile = pdf.appendingPathComponent("doc.pdf")
        let fifo = other.appendingPathComponent("pipe")
        // A link outside the loaded folder into it.
        let linkIntoBig = dir.appendingPathComponent("switch/big-link")
        var sidebar: FolderSidebar? { FolderSidebar.shared }
        func root() -> String { sidebar?.rootURL.path ?? "nil" }
        func selected() -> String { sidebar?.selectedNode?.url.lastPathComponent ?? "nil" }
        func textTab(_ u: URL) -> EditorWindowController? { app.tabs.first { $0.doc.fileURL?.standardizedFileURL == u.standardizedFileURL } }
        func docked(_ w: NSWindow?) -> Bool { w != nil && sidebar?.window === w && sidebar?.isShown == true }
        func switchedTo(_ f: URL, file: URL, _ what: String) -> (@escaping () -> Void) -> Void {
            until("\(what): the sidebar shows \(f.lastPathComponent) with \(file.lastPathComponent) selected", timeout: 4) {
                root() == f.path && selected() == file.lastPathComponent
            }
        }
        func dockedInText(_ file: URL, _ what: String) -> (@escaping () -> Void) -> Void {
            sync { expect(docked(textTab(file)?.window), "\(what): the sidebar is docked in the file's tab",
                          "root=\(root()) sidebar window=\(sidebar?.window?.title ?? "nil")") }
        }
        func unchanged(_ was: String, _ what: String) {
            expect(root() == was, "\(what) leaves the folder alone", "root=\(root()) was \(was)")
        }
        return [
            sync {
                let pdfMade = makePDF(pdfFile, pages: 1)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                try? fm.createDirectory(at: img, withIntermediateDirectories: true)
                try? rep?.tiffRepresentation?.write(to: image)
                expect(pdfMade && fm.fileExists(atPath: image.path) && mkfifo(fifo.path, 0o600) == 0
                       && (try? fm.createSymbolicLink(atPath: linkIntoBig.path, withDestinationPath: big.path)) != nil,
                       "switch fixtures made")
                app.openFolder(a)
            },
            until("folder A is listed", timeout: 4) { root() == a.path && sidebar?.root.isLoaded == true && sidebar?.isShown == true },
            // Finder double-click / Open With / a file dropped on the Dock icon.
            sync { app.application(NSApp, open: [welcome]) },
            switchedTo(b, file: welcome, "Finder open"),
            dockedInText(welcome, "Finder open"),
            snapshot("061-sidebar-switch-welcome.png"),
            // An image: a viewer tab.
            sync { app.application(NSApp, open: [image]) },
            switchedTo(img, file: image, "image open"),
            sync { expect(docked(app.viewerTab(for: image)?.window), "image open: the sidebar is docked in the image tab", "root=\(root())") },
            // A PDF dropped on a window.
            sync { FileDrop.open([pdfFile]) },
            switchedTo(pdf, file: pdfFile, "PDF drop"),
            sync { expect(docked(app.viewerTab(for: pdfFile)?.window), "PDF drop: the sidebar is docked in the PDF tab", "root=\(root())") },
            // File › Open Recent.
            sync {
                let item = NSMenuItem()
                item.representedObject = recentFile
                app.openRecentItem(item)
            },
            switchedTo(recent, file: recentFile, "Open Recent"),
            dockedInText(recentFile, "Open Recent"),
            // The cedric script (cedric://open?path=…, with its token).
            sync { openURL(app, "cedric://open?path=" + (cliFile.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) },
            switchedTo(cli, file: cliFile, "cedric script"),
            dockedInText(cliFile, "cedric script"),
            // A file already open, opened again from outside: brought to front, folder switched.
            sync { app.application(NSApp, open: [welcome]) },
            switchedTo(b, file: welcome, "re-opening an open file"),
            dockedInText(welcome, "re-opening an open file"),
            // Several files at once: the last one's folder.
            sync { app.application(NSApp, open: [recentFile, dropFile]) },
            switchedTo(drop, file: dropFile, "two files at once"),
            dockedInText(dropFile, "two files at once"),
            // A text file of 16 MB or more: read in the background, switched once its tab is there.
            sync { app.application(NSApp, open: [bigText]) },
            until("big file: its tab arrives", timeout: 20) { textTab(bigText) != nil },
            switchedTo(big, file: bigText, "big file"),
            dockedInText(bigText, "big file"),
            sync {
                let was = root()
                // Through a link outside the folder into it: inside, no switch.
                app.application(NSApp, open: [linkIntoBig.appendingPathComponent("small.txt")])
                unchanged(was, "a file reached through a link into the folder")
                expect(textTab(small) != nil || app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "small.txt" }, "the linked file opened")
                // Refused (a FIFO): no switch.
                app.application(NSApp, open: [fifo])
                unchanged(was, "a refused file")
                // Opens from inside the app.
                let (click, quick, link, wiki, restored) = (outsideFiles[0], outsideFiles[1], outsideFiles[2], outsideFiles[3], outsideFiles[4])
                app.openFromFolder(FolderNode(url: click, entry: FolderEntry(name: click.lastPathComponent, isDirectory: false)))
                unchanged(was, "a sidebar click")
                CommandPalette.openFile(quick)
                unchanged(was, "Quick Open")
                guard let host = textTab(bigText) else { expect(false, "big file tab for the link opens"); return }
                host.previewLink(.openInCedric(link))
                unchanged(was, "a preview link")
                host.openWikiNote(wiki, heading: nil)
                unchanged(was, "a wiki link")
                app.restoreTab(SessionTab(path: restored.path), into: nil)
                unchanged(was, "a restored tab")
                expect([click, quick, link, wiki, restored].allSatisfy { textTab($0) != nil }, "the inside-the-app opens made their tabs")
                // Hidden: the folder stays, still hidden.
                sidebar?.hide()
                app.application(NSApp, open: [hiddenFile])
                expect(root() == was && sidebar?.isShown == false, "a hidden sidebar is not switched or shown", "root=\(root())")
                // No folder open: none is opened.
                app.closeFolder()
                app.application(NSApp, open: [closedFile])
                expect(FolderSidebar.shared == nil && FolderSidebar.pendingFolder == nil, "no folder open: none is opened")
            },
        ]
    }
}

/// Scripts/render-check.sh (RenderDump.check): the folder sidebar shown,
/// whole window rendered both ways (CALayer tree and cacheDisplay) in a
/// light and a dark theme. The rows must have ink, and the editor beside
/// it must still show its typed text and its own background (an opaque
/// panel that doesn't clip can paint over its neighbours).
@MainActor
enum FolderRenderCheck {
    static func run(_ app: AppDelegate, out: String, report: (Bool, String, String) -> Void) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-render-folder-\(getpid())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        for n in ["src/main.swift", "README.md", "notes.txt"] {
            let u = root.appendingPathComponent(n)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(n.utf8).write(to: u)
        }
        for c in TypingCheck.themes where c.name == "light" || c.name == "dark" {
            TypingCheck.apply(c)
            app.newTab(nil)
            guard let tab = app.tabs.last, let window = tab.window else { report(false, "folder/\(c.name)", "no tab"); continue }
            window.setContentSize(NSSize(width: 900, height: 670))
            window.makeKeyAndOrderFront(nil)
            app.openFolder(root)
            let deadline = Date().addingTimeInterval(3)
            while FolderSidebar.shared?.root.isLoaded != true, Date() < deadline { TypingCheck.settle(0.05) }
            guard let s = FolderSidebar.shared, s.superview === tab.split else { report(false, "folder/\(c.name)/docked", "not docked"); continue }
            window.makeFirstResponder(tab.textView)
            TypingCheck.type(window, "Beside the folder")
            TypingCheck.settle(0.3)
            window.displayIfNeeded()
            CATransaction.flush()
            let rootView = window.contentView!.superview ?? window.contentView!
            let p = tab.palette
            let bg = NSColor(hex: p.background)
            let typed = (tab.text as NSString).range(of: "Beside the folder")
            let textRects = TypingCheck.glyphRects(tab.textView, typed).map { tab.textView.convert($0, to: rootView) }
            let rows = (0..<min(3, s.outline.numberOfRows)).map { s.outline.convert(s.outline.rect(ofRow: $0), to: rootView) }
            let tvVis = tab.textView.convert(tab.textView.visibleRect, to: rootView)
            let empty = NSRect(x: tvVis.minX + 200, y: tvVis.minY + 150, width: 100, height: 100)
            var sideBG = NSColor.windowBackgroundColor
            s.effectiveAppearance.performAsCurrentDrawingAppearance { sideBG = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? sideBG }
            for (how, rep) in [("layer", RenderDump.renderLayer(rootView)), ("cache", DevHooks.render(rootView, rootView.bounds))] {
                guard let rep else { report(false, "folder/\(c.name)/\(how)", "no image"); continue }
                RenderDump.save(rep, "\(out)/folder-\(c.name)-\(how).png")
                let r = RenderDump.inkCount(rep, rows, root: rootView, bg: sideBG)
                report(rows.count == 3 && r >= 30, "folder/\(c.name)/\(how)/rows", "rows=\(rows.count) ink=\(r)")
                let t = RenderDump.inkCount(rep, textRects, root: rootView, bg: bg)
                report(t >= 30, "folder/\(c.name)/\(how)/typed-text-beside", "ink=\(t)")
                let stray = RenderDump.inkCount(rep, [empty], root: rootView, bg: bg, threshold: 1.25)
                report(stray == 0, "folder/\(c.name)/\(how)/editor-background", "pixels unlike the theme background=\(stray)")
            }
            app.closeFolder()
            tab.doc.markSaved()
            window.close()
            TypingCheck.settle(0.05)
        }
    }
}
