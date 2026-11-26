import AppKit
import CedricCore

/// CEDRIC_CHECK=tags: a temp folder of notes opened in the sidebar; View ›
/// Show Tags (the menu item, nothing read before it), the tree and its
/// counts (inline, nested, front matter; not code, fences, headings, URLs
/// or numbers), the tree made off the main thread, a click on a tag → its
/// notes with their lines → a click opens the right tab at the line, a
/// note renamed and one deleted on disk (the counts follow), and a
/// large document opened while the pane shows: no scan, no index build
/// and no tree made for it, and no pane in its tab. Then the folder
/// replaced while a tag is listed, both folders having a `daily.md` with
/// it: the old tree and its notes go at once and an old hit opens nothing.
extension DevChecks {
    static func tagsCheck(_ app: AppDelegate) {
        let root = dir.appendingPathComponent("tg", isDirectory: true)
        _ = write("tg/Alpha.md", "# Alpha\n\nWork on #project/owlink today.\n\nAlso #todo and #idea.\n")
        _ = write("tg/Beta.md", "---\ntitle: Beta\ntags:\n  - todo\n  - project/tankard\n---\n\n# Beta #draft\n")
        _ = write("tg/sub/Gamma.md", "---\ntags: [todo, café]\n---\nSee https://x.org/page#frag and [a](#anchor).\n\nIssue #123.\n")
        _ = write("tg/code.md", "```\n#todo\n```\n`#idea` only in code\n")
        _ = write("tg/notes.txt", "plain #todo note\n")
        let big = write("tg/big.md", String(repeating: "b", count: 30_000) + " #huge\n")
        let draft = app.open(write("tg/draft.md", "draft\n"))!
        sized(draft)
        var notes: WikiNotes? { FolderSidebar.shared?.wikiNotes }
        var side: TagsSidebar? { draft.wiki.tags }
        func tab(_ name: String) -> EditorWindowController? { app.tabs.first { $0.doc.fileURL?.lastPathComponent == name } }
        func wait(_ what: String, _ ok: @escaping () -> Bool) -> Step { waitFor(what, 8, ok) }
        func row(_ path: String) -> String? { side?.shownRows.first { $0.hasPrefix(path + " ") } }
        var builds = 0
        func pause(_ seconds: Double) -> Step {
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { next() } }
        }
        var before: (scans: Int, names: Int, index: Int, trees: Int) = (0, 0, 0, 0)
        var staleHit: TagTree.Hit?
        var staleNotes: WikiNotes?

        run([
            sync { app.openFolder(root) },
            wait("the folder sidebar shows") { FolderSidebar.shared?.isShown == true },
            sync {
                focus(draft)
                expect(notes == nil, "nothing is read for tags before the pane shows")
                if let i = menuItem(action: #selector(AppDelegate.toggleTagsMenu(_:))) {
                    expect(app.validateMenuItem(i) && i.title == "Show Tags", "View › Show Tags is on", i.title)
                    app.toggleTagsMenu(i)
                } else {
                    expect(false, "View › Show Tags exists")
                }
                expect(draft.tagsVisible, "the Tags pane shows")
                expect(side?.message == "Reading the folder’s notes…", "it says it is reading first", side?.message ?? "-")
            },
            wait("the tag tree lands") { (side?.tree?.roots.count ?? 0) > 0 },
            sync {
                let rows = side?.shownRows ?? []
                // todo: Alpha, Beta, Gamma, notes.txt; project: Alpha, Beta; then 1-note tags by name.
                expect(rows == ["todo 4", "project 2", "café 1", "draft 1", "huge 1", "idea 1"],
                       "every tag with its note count, most first, then by name; not code, fences, headings, URLs or numbers", "\(rows)")
                expect(side?.partial == false, "not partial")
                if let s = side {
                    expect(s.frame.width > 100 && draft.editorContainer.scrollView.frame.minX >= s.frame.maxX,
                           "the pane sits left of the text", "\(s.frame) \(draft.editorContainer.scrollView.frame)")
                }
                if let i = menuItem(action: #selector(AppDelegate.toggleTagsMenu(_:))) {
                    expect(app.validateMenuItem(i) && i.title == "Hide Tags", "the menu item says Hide Tags", i.title)
                }
                // A refresh makes the tree on the query queue: nothing is applied in the call.
                builds = side?.builds ?? -1
                draft.refreshTags()
                expect(side?.builds == builds, "a tags refresh doesn't build the tree on the main thread", "\(side?.builds ?? -1) vs \(builds)")
            },
            wait("the refreshed tree lands") { (side?.builds ?? -1) > builds },
            sync {
                side?.selectTag("project/tankard")
                let rows = side?.shownRows ?? []
                expect(rows.contains("project/owlink 1") && rows.contains("project/tankard 1"), "nested tags show under their parent", "\(rows)")
                let hits = side?.hits ?? []
                expect(hits.map(\.source) == ["Beta.md"] && hits.first?.line == 4 && hits.first?.snippet == "- project/tankard",
                       "a front-matter tag lists its note at its line", "\(hits)")
                side?.selectTag("todo")
                let todo = side?.hits ?? []
                expect(todo.map(\.source) == ["Alpha.md", "Beta.md", "notes.txt", "sub/Gamma.md"], "#todo lists its four notes", "\(todo.map(\.source))")
                expect(todo.first?.line == 4 && todo.first?.snippet == "Also #todo and #idea.", "with the line's snippet",
                       "\(todo.first.map { "\($0)" } ?? "-")")
                expect(side?.header.stringValue == "#todo: 4 notes", "the list says which tag", side?.header.stringValue ?? "-")
            },
            sync {
                // The counts sit at the right of the pane, inside it (not cut off).
                if let s = side, let c = s.outline.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TagCell {
                    let r = c.convert(c.count.frame, to: s)
                    expect(c.count.stringValue == "4" && r.minX > 100 && r.maxX <= s.tagScroll.frame.maxX,
                           "the count is shown inside the pane", "\(r) in \(s.tagScroll.frame)")
                } else {
                    expect(false, "the first tag row has a cell")
                }
            },
            snapshot("tags-pane.png", window: draft.window),
            sync { side?.activate(0) },
            wait("a note click opens Alpha.md at the tag's line") {
                guard let a = tab("Alpha.md") else { return false }
                return a.lineIndex.line(containing: a.textView.selectedRange().location) == 4
            },
            sync {
                expect(app.currentTab === tab("Alpha.md") || tab("Alpha.md")?.window?.isKeyWindow == true, "the note's tab is the one in front")
                try? FileManager.default.moveItem(at: root.appendingPathComponent("notes.txt"), to: root.appendingPathComponent("renamed.txt"))
            },
            wait("a rename on disk updates the notes") { side?.hits.map(\.source).contains("renamed.txt") == true },
            sync {
                expect(side?.hits.map(\.source) == ["Alpha.md", "Beta.md", "renamed.txt", "sub/Gamma.md"], "renamed.txt replaces notes.txt",
                       "\(side?.hits.map(\.source) ?? [])")
                expect(row("todo") == "todo 4", "the count stays", row("todo") ?? "-")
                try? FileManager.default.removeItem(at: root.appendingPathComponent("sub/Gamma.md"))
            },
            wait("a delete on disk updates the counts") { row("todo") == "todo 3" },
            sync {
                expect(row("café") == nil, "a tag only the deleted note had goes", "\(side?.shownRows ?? [])")
                expect(side?.hits.map(\.source) == ["Alpha.md", "Beta.md", "renamed.txt"], "and its note leaves the list",
                       "\(side?.hits.map(\.source) ?? [])")
                print("check: tags: \(side?.tree?.tagCount ?? -1) tags, \(notes?.tagScansDone ?? -1) tag scans, \(notes?.notesBuilt ?? -1) name builds")
                focus(draft)
            },
            // Settle: no scan or tree in flight before the large open.
            pause(3),
            sync {
                before = (notes?.scansDone ?? -1, notes?.notesBuilt ?? -1, FolderSidebar.shared?.quickOpen?.builds ?? -1, side?.builds ?? -1)
                _ = app.open(big)
            },
            wait("the long-line note opens in large mode") { tab("big.md")?.largeReason != nil },
            pause(1.5),
            sync {
                guard let b = tab("big.md") else { return }
                let after = (notes?.scansDone ?? -1, notes?.notesBuilt ?? -1, FolderSidebar.shared?.quickOpen?.builds ?? -1, side?.builds ?? -1)
                expect(after == before, "opening a large document reads no notes, builds no index and makes no tree",
                       "\(before) → \(after)")
                expect(!b.tagsVisible && b.wiki.tags == nil, "and its tab has no Tags pane")
                // Folder replacement with a tag selected: both folders have a daily.md with it.
                _ = write("tga/daily.md", "first folder #shared\n")
                _ = write("tgb/daily.md", "second folder\n\n#shared\n")
                app.openFolder(dir.appendingPathComponent("tga", isDirectory: true))
                focus(draft)
            },
            wait("the first folder's tree lands") { side?.tree?.node("shared") != nil && notes?.root.lastPathComponent == "tga" },
            sync {
                side?.selectTag("shared")
                expect(side?.hits.map(\.source) == ["daily.md"], "the first folder's daily.md is listed", "\(side?.hits ?? [])")
                staleHit = side?.hits.first
                staleNotes = notes
                app.openFolder(dir.appendingPathComponent("tgb", isDirectory: true))
                focus(draft)
                expect(side?.tree == nil && side?.hits.isEmpty == true && side?.selectedTag == nil,
                       "replacing the folder clears the old tree, its tag and its notes at once",
                       "\(side?.tree?.tagCount ?? -1) tags, \(side?.hits ?? []), \(side?.selectedTag ?? "-")")
                side?.activate(0)
                if let h = staleHit { side?.onOpen?(h, staleNotes) }
            },
            pause(1),
            sync {
                expect(tab("daily.md") == nil, "an old folder's hit opens nothing in the new folder",
                       app.tabs.compactMap { $0.doc.fileURL?.path }.joined(separator: ", "))
                staleNotes = nil
            },
            wait("the second folder's tree lands") { side?.tree?.node("shared") != nil && notes?.root.lastPathComponent == "tgb" },
            sync {
                side?.selectTag("shared")
                expect(side?.hits.first?.line == 2, "the new folder's own hit is listed", "\(side?.hits ?? [])")
                side?.activate(0)
            },
            wait("its click opens the new folder's daily.md") {
                tab("daily.md")?.doc.fileURL?.deletingLastPathComponent().lastPathComponent == "tgb"
            },
            sync {
                draft.hideTags()
                expect(!draft.tagsVisible && notes?.wantsTags == false, "hiding the last Tags pane stops reading tags")
                finish()
            },
        ])
    }
}
