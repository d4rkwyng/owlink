import AppKit
import CedricCore

/// CEDRIC_CHECK=wikilinks: a temp folder of notes opened in the sidebar;
/// `[[` typed with real key events (the list, filtering, ↑/↓, Return,
/// Tab, ⎋, nothing in a code span or fence), ⌘-click on links (the right
/// tab, a heading, a missing note created, none outside the folder
/// through a symlinked parent), Backlinks (the list, its
/// snippets, a click to the line), a note renamed on disk (names and
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
        let outside = dir.appendingPathComponent("wl-outside", isDirectory: true)

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
                expect(popup?.shownNames.first == "Beta", "typing filters by prefix", "\(popup?.shownNames ?? [])")
            },
            snapshot("wikilinks-popup.png", window: draft.window),
            sync {
                type("\n")
                expect(draft.text == "See [[Beta]]", "Return inserts the name and closes the ]]", draft.text)
                expect(popup?.isShown != true, "and the list goes")
                expect(draft.textView.selectedRange().location == 12, "the caret is after the ]]")
                type(" [[gma")
                expect(popup?.shownNames.first == "Gamma", "fuzzy: gma finds Gamma", "\(popup?.shownNames ?? [])")
                type("\t")
                expect(draft.text == "See [[Beta]] [[Gamma]]", "Tab inserts too", draft.text)
                type(" [[zz")
                expect(popup?.isShown == true && popup?.shownNames.isEmpty == true, "no match: the list says so")
                press("\u{1b}", 53)
                expect(popup?.isShown != true, "⎋ dismisses the list")
                expect(draft.text == "See [[Beta]] [[Gamma]] [[zz", "and leaves the text", draft.text)
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
                let names = popup?.shownNames ?? []
                expect(names.contains("Bravo") && !names.contains("Beta"), "and the suggestions", "\(names)")
                press("\u{1b}", 53)
                print("check: wiki notes: \(notes?.notes?.count ?? -1) names, \(notes?.notesBuilt ?? -1) name builds, \(notes?.scansDone ?? -1) backlink scans")
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
