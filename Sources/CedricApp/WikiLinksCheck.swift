import AppKit
import CedricCore

/// CEDRIC_CHECK=wikilinks: a temp folder of notes opened in the sidebar;
/// `[[` typed with real key events (the list, filtering, ↑/↓, Return,
/// Tab, ⎋, nothing in a code span or fence), ⌘-click on links (the right
/// tab, a heading, a missing note created, none outside the folder
/// through a symlinked parent, none opened when the folder was replaced
/// at its path before confirming), Backlinks (the list, its
/// snippets, a click to the line; the list and the backlinks computed
/// off the main thread), a note renamed on disk (names and
/// backlinks follow), held queries (a click on an old row or a key while
/// a list ranks, typing after a held Return, superseded queries skipped),
/// the folder closed or replaced while a list ranks (the list goes, the
/// backlinks follow), and no list in large mode.
extension DevChecks {
    static func wikiLinksCheck(_ app: AppDelegate) {
        let root = dir.appendingPathComponent("wl", isDirectory: true)
        let alpha = write("wl/Alpha.md", "# Alpha\n\nSee [[Beta]] and [[Gamma#Part]].\n\nAlso [[Missing]].\n")
        _ = write("wl/Beta.md", "# Beta\n\nBack to [[Alpha]].\n")
        _ = write("wl/sub/Gamma.md", "# Gamma\n\nIntro.\n\n## Part\n\nPart body, see [[Alpha|the first]].\n")
        _ = write("wl/notes.txt", "plain [[alpha]] note\n")
        _ = write("wl/code.md", "```\n[[Alpha]]\n```\n`[[Alpha]]`\n")
        _ = write("wl/image.png", "not a note\n")
        let draft = app.open(write("wl/draft.md", ""))!
        let big = write("wl/big.md", String(repeating: "b", count: 30_000) + "\n")
        sized(draft)
        var notes: WikiNotes? { FolderSidebar.shared?.wikiNotes }
        var popup: WikiCompletion? { draft.wiki.completion }
        func tab(_ name: String) -> EditorWindowController? { app.tabs.first { $0.doc.fileURL?.lastPathComponent == name } }
        func type(_ s: String, in t: EditorWindowController = draft) {
            guard let w = t.window else { return }
            for ch in s {
                switch ch {
                case "\n": TypingCheck.key(w, "\r", keyCode: 36)
                case "\t": TypingCheck.key(w, "\t", keyCode: 48)
                default: TypingCheck.key(w, String(ch), keyCode: keyCodes[Character(ch.lowercased())] ?? 0)
                }
            }
        }
        func press(_ chars: String, _ code: UInt16, in t: EditorWindowController = draft) {
            if let w = t.window { TypingCheck.key(w, chars, keyCode: code) }
        }
        func setText(_ t: EditorWindowController, _ s: String) {
            let tv = t.textView
            tv.insertText(s, replacementRange: NSRange(location: 0, length: (tv.string as NSString).length))
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        /// A ⌘-click on the middle of the first `needle` in the tab's text.
        func commandClick(_ t: EditorWindowController, _ needle: String) {
            let tv = t.textView
            let r = (tv.string as NSString).range(of: needle)
            guard r.location != NSNotFound, let w = tv.window else { expect(false, "⌘-click target \(needle)"); return }
            let screen = tv.firstRect(forCharacterRange: NSRange(location: r.location + r.length / 2, length: 1), actualRange: nil)
            let p = w.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
            let ti = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [.command], timestamp: ti,
                                                windowNumber: w.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return }
            tv.mouseDown(with: down)
        }
        func wait(_ what: String, _ ok: @escaping () -> Bool) -> Step { waitFor(what, 8, ok) }
        var alphaTab: EditorWindowController? { tab("Alpha.md") }
        var side: BacklinksSidebar? { alphaTab?.wiki.backlinks }
        var created: [String] = []
        var failures: [Error] = []
        var slashBefore: [String] = []
        var offersBefore = 0
        var builds = 0
        var skipped = 0
        var oldNotes: WikiNotes?
        let outside = dir.appendingPathComponent("wl-outside", isDirectory: true)
        /// The note offered from a link in a note at `rel`'s folder: offered
        /// once by that path (compared as bytes). Where the kernel enforces
        /// beneath, made there inside the open folder, not at its top, and
        /// opened. On the fallback (macOS 14, or `walk` forced) a note in a
        /// subfolder is refused as unsupported (FolderActions.createFile):
        /// nothing is made beside the note or at the folder's top, and
        /// nothing opens.
        func besideChecks(_ rel: String, _ what: String, walk: Bool = !Beneath.kernelEnforced) {
            let fm = FileManager.default
            let file = (rel as NSString).lastPathComponent
            let want = root.appendingPathComponent(rel)
            expect(created.count == offersBefore + 1 && created.last.map { Array($0.utf8) } == Array(rel.utf8),
                   "\(what): the offer names the note beside it", "\(created.dropFirst(offersBefore))")
            expect(!fm.fileExists(atPath: root.appendingPathComponent(file).path), "\(what): not at the folder's top")
            if walk {
                let codes = failures.map { (($0 as NSError).domain, ($0 as NSError).code) }
                expect(codes.count == 1 && codes.first.map { $0 == NSCocoaErrorDomain && $1 == NSFeatureUnsupportedError } == true,
                       "\(what), fallback: the create is refused as unsupported", "\(failures)")
                expect(!fm.fileExists(atPath: want.path), "\(what), fallback: nothing is made beside the note")
                expect(tab(file) == nil, "\(what), fallback: nothing opens")
                return
            }
            expect(failures.isEmpty, "\(what): the create isn't refused", "\(failures)")
            expect(fm.fileExists(atPath: want.path), "\(what): the note is made in that folder")
            let opened = tab(file)?.doc.fileURL.map { FolderSidebar.realPath($0.path) }
            expect(opened.map { Array($0.utf8) } == Array(FolderSidebar.realPath(want.path).utf8),
                   "\(what): the new note opens from inside the open folder", opened ?? "-")
        }
        let movedRoot = dir.appendingPathComponent("wl-moved", isDirectory: true)

        run([
            sync {
                focus(draft)
                type("[[")
                expect(popup?.isShown != true, "no folder open: no list after [[")
                setText(draft, "")
                app.openFolder(root)
            },
            wait("the folder sidebar shows") { FolderSidebar.shared?.isShown == true },
            sync {
                focus(draft)
                expect(notes == nil, "nothing is indexed for wiki links before [[ is typed")
                type("See [[")
                expect(popup?.isShown == true, "[[ shows the notes list")
            },
            wait("the note names are indexed") { notes?.isReady == true && (popup?.shownNames.count ?? 0) > 0 },
            sync {
                let names = popup?.shownNames ?? []
                expect(Set(names) == ["Alpha", "Beta", "Gamma", "notes", "code", "draft", "big"],
                       "the list holds the folder's notes (.md and .txt, not image.png)", "\(names)")
                expect(popup?.selectedRow == 0, "the first row is selected")
                press(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125)
                expect(popup?.selectedRow == 1, "↓ moves down the list", "\(popup?.selectedRow ?? -1)")
                press(String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), 126)
                expect(popup?.selectedRow == 0, "↑ moves back up")
                expect(draft.text == "See [[", "the arrows didn't move the caret or edit", draft.text)
                type("be")
                // Ranked on the query queue, not in the keystroke.
                expect(popup?.ranking == true, "the names are ranked off the main thread")
            },
            wait("the list for be lands") { popup?.ranking == false },
            sync {
                expect(popup?.shownNames.first == "Beta", "typing filters by prefix", "\(popup?.shownNames ?? [])")
            },
            snapshot("wikilinks-popup.png", window: draft.window),
            sync {
                type("\n")
                expect(draft.text == "See [[Beta]]", "Return inserts the name and closes the ]]", draft.text)
                expect(popup?.isShown != true, "and the list goes")
                expect(draft.textView.selectedRange().location == 12, "the caret is after the ]]")
                type(" [[gma")
            },
            wait("the list for gma lands") { popup?.ranking == false && popup?.isShown == true },
            sync {
                expect(popup?.shownNames.first == "Gamma", "fuzzy: gma finds Gamma", "\(popup?.shownNames ?? [])")
                type("\t")
                expect(draft.text == "See [[Beta]] [[Gamma]]", "Tab inserts too", draft.text)
                type(" [[zz")
            },
            wait("the list for zz lands") { popup?.ranking == false && popup?.isShown == true },
            sync {
                expect(popup?.isShown == true && popup?.shownNames.isEmpty == true, "no match: the list says so")
                press("\u{1b}", 53)
                expect(popup?.isShown != true, "⎋ dismisses the list")
                expect(draft.text == "See [[Beta]] [[Gamma]] [[zz", "and leaves the text", draft.text)
                // Return straight after typing, before the list lands: it takes the match for what was typed.
                setText(draft, "")
                type("[[alp\n")
            },
            wait("Return while ranking is answered") { popup?.isActive != true },
            sync {
                expect(draft.text == "[[Alpha]]", "Return before the list lands inserts the match for what was typed", draft.text)
                // Held queries (a slow folder): input while a list ranks belongs to that list.
                WikiNotes.queryDelay = 0.4
                setText(draft, "")
                type("[[")
            },
            wait("the full list lands") { popup?.ranking == false && popup?.isShown == true && (popup?.shownNames.count ?? 0) > 2 },
            sync {
                type("b")
                expect(popup?.ranking == true, "a held query is ranking")
                popup?.activate(0)
                expect(draft.text == "[[b", "a click on a row of the old list while ranking inserts nothing", draft.text)
                expect(popup?.isActive == true, "and the list stays for what was typed")
                press(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125)
                expect(draft.text == "[[b" && draft.textView.selectedRange().location == 3, "↓ while ranking doesn't move the caret", draft.text)
            },
            wait("the list for b lands") { popup?.ranking == false && popup?.isShown == true },
            sync {
                let names = popup?.shownNames ?? []
                expect(names.count >= 2 && names.prefix(2).allSatisfy { $0.lowercased().hasPrefix("b") }, "the list is for b", "\(names)")
                expect(popup?.selectedRow == 1, "↓ held while ranking moves on the new list", "\(popup?.selectedRow ?? -1)")
                press("\u{1b}", 53)
                setText(draft, "")
                type("[[alp\n")
                type("x")
                expect(draft.text == "[[alpx", "typing after a held Return", draft.text)
            },
            wait("the list for alpx lands") { popup?.ranking == false },
            sync {
                expect(draft.text == "[[alpx", "a Return held for older text isn't replayed after more typing", draft.text.debugDescription)
                press("\u{1b}", 53)
                skipped = popup?.skippedRankings ?? 0
                setText(draft, "")
                type("[[bet")
            },
            wait("the list for bet lands") { popup?.ranking == false && popup?.isShown == true },
            sync {
                let n = (popup?.skippedRankings ?? 0) - skipped
                expect(n >= 2, "queries superseded while queued are skipped before ranking", "\(n) skipped")
                expect(popup?.shownNames.first == "Beta", "and the latest one is ranked", "\(popup?.shownNames ?? [])")
                press("\u{1b}", 53)
                WikiNotes.queryDelay = 0
                setText(draft, "See [[Beta]] [[Gamma]] [[zz")
                type(" `[[")
                expect(popup?.isShown != true, "no list inside a code span")
                setText(draft, "```\n")
                type("[[")
                expect(popup?.isShown != true, "no list inside a fence")
                setText(draft, "Draft [[Beta]] and [[Missing note]]\n")
                commandClick(draft, "[[Beta]]")
            },
            wait("⌘-click on [[Beta]] opens Beta.md") { tab("Beta.md") != nil },
            sync {
                expect(draft.text == "Draft [[Beta]] and [[Missing note]]\n" && draft.textView.multiCarets == nil,
                       "the ⌘-click added no caret")
                let a = app.open(alpha)!
                sized(a)
                focus(a)
                commandClick(a, "[[Gamma#Part]]")
            },
            wait("⌘-click on [[Gamma#Part]] opens sub/Gamma.md") { tab("Gamma.md") != nil },
            sync {
                if let g = tab("Gamma.md") {
                    let line = g.lineIndex.line(containing: g.textView.selectedRange().location)
                    expect(line == 4, "at its ## Part heading", "line \(line)")
                }
                WikiTabState.confirmCreate = { created.append($0); return true }
                focus(draft)
                commandClick(draft, "[[Missing note]]")
            },
            wait("⌘-click on a missing note offers it and creates it") { tab("Missing note.md") != nil },
            sync {
                expect(created == ["Missing note.md"], "the offer names the new note", "\(created)")
                expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Missing note.md").path), "the note is on disk")
                // A link whose folder is a symbolic link out of the open folder: confirming creates nothing there.
                try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("away"), withDestinationURL: outside)
                WikiTabState.createFailed = { failures.append($0) }
                setText(draft, "Draft [[away/Escape]]\n")
                commandClick(draft, "[[away/Escape]]")
            },
            wait("⌘-click on a note behind a symlinked folder is answered") { created.count == 2 && !failures.isEmpty || tab("Escape.md") != nil },
            sync {
                expect(created.last == "away/Escape.md", "the offer names the note inside the folder", "\(created)")
                expect(((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? ["?"]).isEmpty,
                       "confirming leaves the outside folder untouched", "\((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? [])")
                expect(!failures.isEmpty && tab("Escape.md") == nil, "the create is refused and nothing opens", "\(failures)")
                // A slash followed by a combining mark: one Swift character, but the
                // kernel splits the name there. It names no single note, so nothing is made.
                failures = []
                offersBefore = created.count
                slashBefore = FileManager.default.subpaths(atPath: root.path)?.sorted() ?? ["?"]
                setText(draft, "Draft [[sub/\u{301}Slash]]\n")
                commandClick(draft, "[[sub/\u{301}Slash]]")
            },
            wait("⌘-click on a link with a slash before a combining mark is answered") {
                !failures.isEmpty || tab("\u{301}Slash.md") != nil
            },
            sync {
                let fm = FileManager.default
                expect(!failures.isEmpty && tab("\u{301}Slash.md") == nil,
                       "a slash before a combining mark: the create is refused and nothing opens", "\(failures)")
                expect(failures.first.map { ($0 as NSError).code } == NSFileWriteInvalidFileNameError, "refused as a bad name",
                       "\(failures)")
                expect(created.count == offersBefore, "refused before the offer is shown", "\(created.dropFirst(offersBefore))")
                let after = fm.subpaths(atPath: root.path)?.sorted() ?? ["?"]
                expect(after == slashBefore, "nothing made on disk", "\(Set(after).symmetricDifference(slashBefore))")
                // A note in a folder whose name starts with a combining mark, first
                // under the root: a missing link is offered and made beside it, not
                // at the folder's top (Astra batch 7b). Written here, after the list
                // of the folder's notes was checked above.
                failures = []
                offersBefore = created.count
                let here = app.open(write("wl/\u{301}m/Here.md", "Here [[Beside one]]\n"))!
                sized(here)
                focus(here)
                commandClick(here, "[[Beside one]]")
            },
            wait("⌘-click on a missing note beside a note in a combining-mark folder is answered") {
                !failures.isEmpty || tab("Beside one.md") != nil
            },
            sync {
                besideChecks("\u{301}m/Beside one.md", "a first-level combining-mark folder")
                // The same one level down.
                failures = []
                offersBefore = created.count
                let there = app.open(write("wl/sub/\u{301}n/There.md", "There [[Beside two]]\n"))!
                sized(there)
                focus(there)
                commandClick(there, "[[Beside two]]")
            },
            wait("⌘-click on a missing note beside a note in a nested combining-mark folder is answered") {
                !failures.isEmpty || tab("Beside two.md") != nil
            },
            sync {
                besideChecks("sub/\u{301}n/Beside two.md", "a nested combining-mark folder")
                // The first-level case again with the fallback forced (macOS 14's
                // component walk), so its refusal is checked on any kernel.
                failures = []
                offersBefore = created.count
                WikiTabState.forceWalk = true
                guard let here = tab("Here.md") else { expect(false, "Here tab"); return }
                setText(here, "Here [[Beside three]]\n")
                focus(here)
                commandClick(here, "[[Beside three]]")
            },
            wait("⌘-click on a missing note beside a note in a combining-mark folder, fallback forced, is answered") {
                !failures.isEmpty || tab("Beside three.md") != nil
            },
            sync {
                WikiTabState.forceWalk = false
                besideChecks("\u{301}m/Beside three.md", "a first-level combining-mark folder", walk: true)
                // The open folder replaced at its path between opening it and confirming:
                // the note goes in the folder that was opened, and nothing opens.
                failures = []
                focus(draft)
                WikiTabState.confirmCreate = { shown in
                    created.append(shown)
                    try? FileManager.default.moveItem(at: root, to: movedRoot)
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    return true
                }
                setText(draft, "Draft [[Swapped]]\n")
                commandClick(draft, "[[Swapped]]")
            },
            wait("⌘-click on a missing note after the folder was replaced is answered") { !failures.isEmpty || tab("Swapped.md") != nil },
            sync {
                let fm = FileManager.default
                expect(!failures.isEmpty && tab("Swapped.md") == nil, "a replaced open folder: the create is reported and nothing opens", "\(failures)")
                expect(!fm.fileExists(atPath: root.appendingPathComponent("Swapped.md").path), "nothing is made in the folder now at its path")
                expect(fm.fileExists(atPath: movedRoot.appendingPathComponent("Swapped.md").path), "the note is in the folder that was opened")
                // Put the folder back (the replacement is moved aside, never deleted).
                try? fm.moveItem(at: root, to: dir.appendingPathComponent("wl-replaced", isDirectory: true))
                try? fm.moveItem(at: movedRoot, to: root)
                expect(fm.fileExists(atPath: root.appendingPathComponent("Alpha.md").path), "the folder is back")
                WikiTabState.confirmCreate = { created.append($0); return true }
                WikiTabState.createFailed = nil
                guard let a = alphaTab else { expect(false, "Alpha tab"); return }
                focus(a)
                if let i = menuItem(action: #selector(AppDelegate.toggleBacklinksMenu(_:))) {
                    expect(app.validateMenuItem(i) && i.title == "Show Backlinks", "View › Show Backlinks is on for a note", i.title)
                }
                a.toggleBacklinks()
                expect(a.backlinksVisible, "the backlinks pane shows")
            },
            wait("the backlinks list lands") { (side?.links.count ?? 0) >= 3 },
            sync {
                let l = side?.links ?? []
                expect(l.map(\.source) == ["Beta.md", "notes.txt", "sub/Gamma.md"],
                       "Backlinks: the notes linking here, not code or fences", "\(l.map(\.source))")
                expect(l.first?.snippet == "Back to [[Alpha]]." && l.first?.line == 2, "with the line's snippet", "\(l.first.map { "\($0)" } ?? "-")")
                expect(side?.partial == false, "not partial")
                if let a = alphaTab, let s = side {
                    expect(s.frame.minX >= 0 && s.frame.width > 100 && a.editorContainer.scrollView.frame.minX >= s.frame.maxX,
                           "the pane sits left of the text", "\(s.frame) \(a.editorContainer.scrollView.frame)")
                }
            },
            sync {
                // A refresh walks the references on the query queue: nothing is applied in the call.
                builds = side?.builds ?? -1
                alphaTab?.refreshBacklinks()
                expect(side?.builds == builds, "a backlinks refresh doesn't traverse on the main thread", "\(side?.builds ?? -1) vs \(builds)")
            },
            wait("the refreshed backlinks land") { (side?.builds ?? -1) > builds },
            sync {
                expect(side?.links.map(\.source) == ["Beta.md", "notes.txt", "sub/Gamma.md"], "the refreshed list is the same",
                       "\(side?.links.map(\.source) ?? [])")
            },
            snapshot("wikilinks-backlinks.png", window: alphaTab?.window),
            sync { side?.activate(0) },
            wait("a backlink click opens its note at the line") {
                guard let b = tab("Beta.md") else { return false }
                return b.lineIndex.line(containing: b.textView.selectedRange().location) == 2
            },
            sync {
                try? FileManager.default.moveItem(at: root.appendingPathComponent("Beta.md"), to: root.appendingPathComponent("Bravo.md"))
            },
            wait("a rename on disk updates the backlinks") { side?.links.map(\.source).contains("Bravo.md") == true },
            sync {
                expect(side?.links.map(\.source) == ["Bravo.md", "notes.txt", "sub/Gamma.md"], "Bravo replaces Beta", "\(side?.links.map(\.source) ?? [])")
                focus(draft)
                setText(draft, "")
                type("[[b")
            },
            wait("the list for b lands") { popup?.ranking == false && popup?.isShown == true },
            sync {
                let names = popup?.shownNames ?? []
                expect(names.contains("Bravo") && !names.contains("Beta"), "and the suggestions", "\(names)")
                press("\u{1b}", 53)
                print("check: wiki notes: \(notes?.notes?.count ?? -1) names, \(notes?.notesBuilt ?? -1) name builds, \(notes?.scansDone ?? -1) backlink scans")
                // The folder closed while a list ranks and a backlinks walk is out.
                WikiNotes.queryDelay = 0.4
                focus(draft)
                setText(draft, "")
                type("[[b")
                alphaTab?.refreshBacklinks()
                expect(popup?.ranking == true, "a list is ranking when the folder closes")
                let applied = side?.builds ?? -1
                app.closeFolder()
                expect(side?.builds == applied + 1, "closing the folder refreshes the backlinks pane once", "\(applied) → \(side?.builds ?? -1)")
                expect(popup?.isActive != true && draft.textView.commandInterceptor == nil, "closing the folder drops the list and its key handling")
                expect(side?.links.isEmpty == true && side?.message.hasPrefix("Open a folder") == true,
                       "and the backlinks pane says no folder is open", side?.message ?? "-")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { next() } },
            sync {
                expect(popup?.isShown != true && side?.links.isEmpty == true, "results asked before the close aren't applied after it")
                app.openFolder(root)
            },
            wait("the folder opens again and the backlinks follow it") { FolderSidebar.shared?.isShown == true && (side?.links.count ?? 0) >= 3 },
            sync {
                // Replaced while a list ranks: the old folder's names never show.
                focus(draft)
                setText(draft, "")
                type("[[b")
                expect(popup?.ranking == true, "a list is ranking when the folder is replaced")
                oldNotes = FolderSidebar.shared?.wikiNotes
                let applied = side?.builds ?? -1
                app.openFolder(root)
                expect(side?.builds == applied + 1, "replacing the folder refreshes the backlinks pane once", "\(applied) → \(side?.builds ?? -1)")
                expect(popup?.isActive != true && draft.textView.commandInterceptor == nil, "replacing the folder drops the list too")
                expect(FolderSidebar.shared?.wikiNotes !== oldNotes, "the backlinks pane asks the new folder")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { next() } },
            wait("the backlinks follow the new folder") { (side?.links.count ?? 0) >= 3 && FolderSidebar.shared?.wikiNotes === notes && (notes?.scansDone ?? 0) > 0 },
            sync {
                expect(popup?.isShown != true, "the old folder's list never shows")
                expect(side?.links.map(\.source) == ["Bravo.md", "notes.txt", "sub/Gamma.md"], "the new folder's backlinks", "\(side?.links.map(\.source) ?? [])")
                WikiNotes.queryDelay = 0
                oldNotes = nil
                _ = app.open(big)
            },
            wait("the long-line note opens in large mode") { tab("big.md")?.largeReason != nil },
            sync {
                guard let b = tab("big.md") else { return }
                focus(b)
                b.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("[[", in: b)
                expect(b.wiki.completion?.isShown != true, "large mode: no list after [[")
                expect(!b.wikiEligible, "and wiki links are off there")
                WikiTabState.confirmCreate = nil
                finish()
            },
        ])
    }
}
