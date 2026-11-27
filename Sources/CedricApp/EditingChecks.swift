import AppKit
import CedricCore

/// In-process checks of the editing extras (EditingFeatures.swift), run by
/// Scripts/tools-check.sh like the other DevChecks: real key events
/// through the menus' key equivalents and the text view, then the text,
/// the state and the drawn pixels are checked.
///
///   CEDRIC_CHECK=highlight|lineops|bookmarks|closedtab|closefail|quitfail|quitsyncfail|backupfail|reopenfail|closedmemory|closedraw|jsonwhole|colours|autoedit|counts|editedtitle
@MainActor
extension DevChecks {
    static func editingCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "highlight": highlight(app)
        case "lineops": lineOps(app)
        case "bookmarks": bookmarks(app)
        case "closedtab": closedTab(app)
        case "closefail": closeAfterFailedSave(app)
        case "quitfail": quitAfterFailedSave(app)
        case "quitsyncfail": quitAfterFailedFlush(app)
        case "backupfail": backupFailureNotice(app)
        case "reopenfail": reopenUnreadableClosedTab(app)
        case "closedmemory": closedTextOnlyInMemory(app)
        case "sessionlatency": sessionLatency(app)
        case "closedraw": closedTabsStillDrawn(app)
        case "jsonwhole": formatWholeJSONCheck(app)
        case "colours": colourConsistency(app)
        case "autoedit": autoEdit(app)
        case "counts": counts(app)
        case "diskconflict": diskConflict(app)
        case "help": helpCheck(app)
        case "closenotice": closeNoticeCheck(app)
        case "menus": menusCheck(app)
        case "editedtitle": editedTitle(app)
        default: return gapCheck(name, app)
        }
        return true
    }

    /// The colour drawn at the top-left corner of `range`'s first segment
    /// (inside the highlight, clear of the glyph).
    static func cornerColor(_ tab: EditorWindowController, _ range: NSRange) -> NSColor? {
        let tv = tab.textView
        guard let rect = TypingCheck.glyphRects(tv, range).first else { return nil }
        let probe = NSRect(x: rect.minX, y: rect.minY, width: 4, height: 3)
        tv.displayIfNeeded()
        guard let rep = DevHooks.render(tv, probe) else { return nil }
        return rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
    }

    static func distance(_ a: NSColor?, _ hex: UInt32) -> Double {
        guard let a = a?.usingColorSpace(.sRGB), let b = NSColor(hex: hex).usingColorSpace(.sRGB) else { return 0 }
        return abs(Double(a.redComponent - b.redComponent)) + abs(Double(a.greenComponent - b.greenComponent))
            + abs(Double(a.blueComponent - b.blueComponent))
    }

    static func focus(_ tab: EditorWindowController) {
        tab.window?.makeKeyAndOrderFront(nil)
        tab.window?.makeFirstResponder(tab.textView)
    }

    // MARK: Highlight all, Mark All

    static func highlight(_ app: AppDelegate) {
        let src = "let alpha = 1\nlet beta = alpha + alphabet\nprint(alpha, beta)\nlet other = 2\n"
        let tab = app.open(write("occ.swift", src))!
        sized(tab)
        let ns = { tab.text as NSString }
        func at(_ s: String, _ n: Int = 0) -> NSRange {
            var r = NSRange(location: 0, length: 0), from = 0
            for _ in 0...n {
                r = ns().range(of: s, options: [], range: NSRange(location: from, length: ns().length - from))
                from = NSMaxRange(r)
            }
            return r
        }
        run([
            sync {
                focus(tab)
                // Caret inside "alpha" on line 1 (a click there: the selection change path).
                tab.textView.setSelectedRange(NSRange(location: at("alpha").location + 2, length: 0))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                let occ = tab.textView.occurrenceRanges
                expect(occ.count == 3, "the word under the caret: 3 whole-word occurrences (not \"alphabet\")", "\(occ)")
                let p = tab.palette
                let other = cornerColor(tab, at("alpha", 1))
                let plain = cornerColor(tab, at("other"))
                expect(distance(other, p.background) > 0.08, "an occurrence on another line is tinted",
                       "\(String(describing: other)) vs bg \(String(p.background, radix: 16))")
                expect(distance(plain, p.background) < 0.03, "a word that isn't an occurrence isn't tinted", "\(String(describing: plain))")
            },
            snapshot("highlight-occurrences.png"),
            sync {
                // Typing: the new word under the caret is highlighted after the pause.
                tab.textView.setSelectedRange(NSRange(location: ns().length, length: 0))
                type("beta")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                expect(tab.text.hasSuffix("\nbeta"), "typed with key events", tab.text)
                expect(tab.textView.occurrenceRanges.count == 3, "the typed word's occurrences are highlighted",
                       "\(tab.textView.occurrenceRanges)")
                // Mark All on "alpha" with ⌃⌘M.
                tab.textView.setSelectedRange(at("alpha"))
                key("m", [.control, .command])
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() } },
            sync {
                expect(tab.textView.markRanges.count == 3, "⌃⌘M marks every \"alpha\"", "\(tab.textView.markRanges)")
                expect(tab.statusBar.position.stringValue.contains("3 marked"), "the status bar counts the marks",
                       tab.statusBar.position.stringValue)
                tab.textView.setSelectedRange(NSRange(location: ns().length, length: 0))
                type(" alpha")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                expect(tab.textView.markRanges.count == 4, "a typed occurrence is marked too", "\(tab.textView.markRanges)")
                expect(tab.statusBar.position.stringValue.contains("4 marked"), "and counted", tab.statusBar.position.stringValue)
                let c = cornerColor(tab, at("alpha", 1))
                expect(distance(c, tab.palette.findMatch) < 0.25, "a mark is drawn in the theme's match colour",
                       "\(String(describing: c)) vs \(String(tab.palette.findMatch, radix: 16))")
            },
            snapshot("mark-all.png"),
            sync {
                key("m", [.control, .command, .shift])
                expect(tab.textView.markRanges.isEmpty && !tab.hasMarks, "⌃⇧⌘M clears the marks")
                expect(!tab.statusBar.position.stringValue.contains("marked"), "and the count", tab.statusBar.position.stringValue)
                // Turned off in the View menu: nothing is highlighted. (The
                // user's own setting is put back as it was.)
                let saved = UserDefaults.standard.object(forKey: "highlightOccurrences")
                defer { UserDefaults.standard.set(saved, forKey: "highlightOccurrences") }
                Settings.shared.highlightOccurrences = false
                tab.textView.setSelectedRange(NSRange(location: at("alpha").location + 1, length: 0))
                tab.refreshHighlights()
                expect(tab.textView.occurrenceRanges.isEmpty, "View › Highlight Occurrences off: no tint")
            },
        ])
    }

    // MARK: Line operations

    static let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
    static let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)

    static func lineOps(_ app: AppDelegate) {
        let src = "func f() {\n    let a = 1\n    let b = 2\n}\n"
        let tab = app.open(write("lines.swift", src))!
        let json = app.open(write("data.json", "{\"a\": 1}\n"))!
        sized(tab)
        let pb = NSPasteboard.general
        let savedClipboard = pb.string(forType: .string)
        func caret(_ off: Int) { tab.textView.setSelectedRange(NSRange(location: off, length: 0)) }
        let lineA = 11 + 4 // inside "let a"
        run([
            sync {
                focus(tab)
                caret(lineA)
                key("d", [.command, .shift])
                expect(tab.text == "func f() {\n    let a = 1\n    let a = 1\n    let b = 2\n}\n", "⇧⌘D duplicates the line", tab.text)
                expect(tab.textView.selectedRange().location == lineA + 14, "the caret moves to the copy", "\(tab.textView.selectedRange())")
                expect(tab.textView.undoManager?.undoActionName == "Duplicate Line", "undo is named", tab.textView.undoManager?.undoActionName ?? "-")
            },
            sync {
                key("z", [.command])
                expect(tab.text == src, "one ⌘Z undoes it", tab.text)
                caret(lineA)
                key(down, [.control, .command])
                expect(tab.text == "func f() {\n    let b = 2\n    let a = 1\n}\n", "⌃⌘↓ moves the line down", tab.text)
            },
            sync {
                key(up, [.control, .command])
                expect(tab.text == src, "⌃⌘↑ moves it back up", tab.text)
                expect(tab.textView.selectedRange().location == lineA, "the caret stays on the moved line", "\(tab.textView.selectedRange())")
                caret(0)
                key(up, [.control, .command])
                expect(tab.text == src, "⌃⌘↑ on the first line changes nothing", tab.text)
            },
            sync {
                caret(lineA)
                key("k", [.command, .shift])
                expect(tab.text == "func f() {\n    let b = 2\n}\n", "⇧⌘K deletes the line", tab.text)
            },
            sync {
                key("z", [.command])
                caret(lineA)
                key("/", [.command])
                expect(tab.text == "func f() {\n    // let a = 1\n    let b = 2\n}\n", "⌘/ comments the line out", tab.text)
                expect(tab.textView.selectedRange().location == lineA + 3, "the caret moves with its text", "\(tab.textView.selectedRange())")
            },
            sync {
                // Two lines selected: mixed → both commented, then both back.
                tab.textView.setSelectedRange(NSRange(location: 11, length: 30))
                key("/", [.command])
                expect(tab.text == "func f() {\n    // // let a = 1\n    // let b = 2\n}\n", "⌘/ on mixed lines comments all", tab.text)
            },
            sync {
                key("/", [.command])
                expect(tab.text == "func f() {\n    // let a = 1\n    let b = 2\n}\n", "⌘/ again uncomments all", tab.text)
            },
            sync { key("z", [.command]) },
            sync { key("z", [.command]) },
            sync {
                key("z", [.command])
                expect(tab.text == src, "each ⌘Z undoes one step, back to the original", tab.text)
            },
            snapshot("line-ops.png"),
            sync {
                // ⌘X with no selection cuts the line.
                caret(lineA)
                key("x", [.command])
                expect(tab.text == "func f() {\n    let b = 2\n}\n", "⌘X with nothing selected cuts the line", tab.text)
                expect(pb.string(forType: .string) == "    let a = 1\n", "the line is on the clipboard", pb.string(forType: .string) ?? "-")
                key("v", [.command])
                expect(tab.text == src, "and ⌘V pastes it back as a line (at the caret's line start)", tab.text)
                // With a selection, ⌘X cuts only the selection.
                tab.textView.setSelectedRange(NSRange(location: 15, length: 3))
                key("x", [.command])
                expect(tab.text == "func f() {\n     a = 1\n    let b = 2\n}\n", "⌘X with a selection cuts the selection", tab.text)
                if let savedClipboard { pb.clearContents(); pb.setString(savedClipboard, forType: .string) }
            },
            sync {
                focus(json)
                json.textView.setSelectedRange(NSRange(location: 1, length: 0))
                key("/", [.command])
                expect(json.text == "{\"a\": 1}\n", "⌘/ does nothing in JSON (no comments)", json.text)
            },
        ])
    }

    // MARK: Bookmarks

    static let f2Key = String(UnicodeScalar(UInt16(NSF2FunctionKey))!)

    static func bookmarks(_ app: AppDelegate) {
        let lines = (1...12).map { $0 == 4 || $0 == 9 ? "todo \($0)" : "line \($0)" }
        let tab = app.open(write("marks.txt", lines.joined(separator: "\n") + "\n"))!
        sized(tab)
        func caretTo(line: Int) { tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[line] + 1, length: 0)) }
        var marks: [Int] { tab.editing.bookmarks.lines }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                caretTo(line: 1)
                key(f2Key, [.command])
                caretTo(line: 5)
                key(f2Key, [.command])
                expect(marks == [1, 5], "⌘F2 bookmarks the caret's line", "\(marks)")
                tab.gutter.display()
            },
            sync {
                // The marker is drawn in the gutter, in the theme's caret colour.
                let g = tab.gutter
                let y = TypingCheck.glyphRects(tab.textView, NSRange(location: tab.lineIndex.starts[1], length: 1)).first.map {
                    g.convert(NSPoint(x: 0, y: $0.midY), from: tab.textView).y } ?? -1
                let rep = DevHooks.render(g, NSRect(x: 0, y: max(0, y - 2), width: 10, height: 4))
                let c = rep?.colorAt(x: 8, y: 4)
                expect(distance(c, tab.palette.caret) < 0.3, "a bookmark marker is drawn in the gutter",
                       "\(String(describing: c)) at y=\(y)")
                let none = DevHooks.render(g, NSRect(x: 0, y: max(0, y + 3 * 16 - 2), width: 10, height: 4))?.colorAt(x: 8, y: 4)
                expect(distance(none, tab.palette.gutterBackground) < 0.05, "no marker on a line without one", "\(String(describing: none))")
            },
            snapshot("bookmarks.png"),
            sync {
                caretTo(line: 0)
                key(f2Key)
                expect(tab.caretLine == 1, "F2 goes to the next bookmark", "line \(tab.caretLine)")
                key(f2Key)
                expect(tab.caretLine == 5, "F2 again: the one after", "line \(tab.caretLine)")
                key(f2Key)
                expect(tab.caretLine == 1, "F2 wraps to the first", "line \(tab.caretLine)")
                key(f2Key, [.shift])
                expect(tab.caretLine == 5, "⇧F2 goes back (wrapping)", "line \(tab.caretLine)")
            },
            sync {
                // A line typed above: the bookmarks stay on their text.
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                key("\r")
                expect(marks == [2, 6], "a new line above moves the bookmarks down with their lines", "\(marks)")
                expect(tab.text.components(separatedBy: "\n")[2] == "line 2", "still on \"line 2\"")
                key("z", [.command])
            },
            sync {
                expect(marks == [1, 5] || marks == [2, 6], "undo keeps them on lines", "\(marks)")
                // Delete a bookmarked line: its bookmark goes.
                tab.editing.bookmarks = Bookmarks([1, 5])
                caretTo(line: 1)
                key("k", [.command, .shift])
                expect(marks == [4], "deleting a bookmarked line drops its bookmark, the one below moves up", "\(marks)")
                // Move a bookmarked line: the bookmark goes with it.
                caretTo(line: 4)
                key(down, [.control, .command])
                expect(marks == [5], "⌃⌘↓ takes the bookmark along", "\(marks)")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // Bookmark All Matches on the word under the caret ("todo").
                key(f2Key, [.command, .shift])
                expect(marks.isEmpty, "⇧⌘F2 clears the bookmarks", "\(marks)")
                let todo = (tab.text as NSString).range(of: "todo")
                tab.textView.setSelectedRange(NSRange(location: todo.location + 1, length: 0))
                key(f2Key, [.command, .option])
                let want = tab.text.components(separatedBy: "\n").enumerated().filter { $0.element.hasPrefix("todo") }.map(\.offset)
                expect(marks == want && want.count == 2, "⌥⌘F2 bookmarks every line with the word", "\(marks) want \(want)")
                // With the find bar open: its search (a regex here).
                tab.showFindBar(replace: false)
                // UX review #6: previous/next are chevron symbols with VoiceOver names.
                let fb = tab.findBar
                expect(fb.prevButton.image != nil && fb.nextButton.image != nil && fb.prevButton.title.isEmpty,
                       "the find bar's previous/next are chevron symbols")
                expect(fb.prevButton.accessibilityLabel() == "Find Previous" && fb.nextButton.accessibilityLabel() == "Find Next",
                       "named Find Previous / Find Next for VoiceOver")
                tab.findBar.regexBox.state = .on
                tab.findBar.findField.stringValue = "line 1[01]"
                key(f2Key, [.command, .option])
                expect(marks.count == 4, "⌥⌘F2 with the find bar: every line matching its search too", "\(marks)")
                tab.hideFindBar()
            },
            sync {
                // A click on a line number toggles that line's bookmark.
                key(f2Key, [.command, .shift])
                let g = tab.gutter
                let r = TypingCheck.glyphRects(tab.textView, NSRange(location: tab.lineIndex.starts[2], length: 1)).first ?? .zero
                let p = g.convert(NSPoint(x: 0, y: r.midY), from: tab.textView)
                click(g, at: NSPoint(x: g.bounds.width - 10, y: p.y))
                expect(marks == [2], "a click in the gutter toggles a bookmark", "\(marks)")
                click(g, at: NSPoint(x: g.bounds.width - 10, y: p.y))
                expect(marks.isEmpty, "and a second click removes it", "\(marks)")
            },
        ]
        steps += steps2
        steps += bookmarksThroughBigEdits(app)
        run(steps)
    }

    /// Edits made in one go keep the bookmarks on lines whose text
    /// survives (they used to collapse onto the edit's first line).
    static func bookmarksThroughBigEdits(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        var tab: EditorWindowController!
        var marks: [Int] { tab.editing.bookmarks.lines }
        let text = "let foo = 0\nlet a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = foo\nlet f = 6\n"
        return [
            sync {
                tab = app.open(write("marks.swift", text))!
                sized(tab)
                focus(tab)
                tab.editing.bookmarks = Bookmarks([1, 2, 3, 4])
                tab.showFindBar(replace: true)
                tab.findBar.findField.stringValue = "foo"
                tab.findBar.replaceField.stringValue = "bar"
                tab.findBar.onReplaceAll?()
                expect(tab.text == text.replacingOccurrences(of: "foo", with: "bar"), "Replace All with matches on lines 0 and 5", tab.text)
                expect(marks == [1, 2, 3, 4], "keeps the bookmarks on lines 1–4", "\(marks)")
                tab.hideFindBar()
            },
            sync {
                focus(tab)
                tab.editing.bookmarks = Bookmarks([2, 4])
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[1], length: tab.lineIndex.starts[5] - 1 - tab.lineIndex.starts[1]))
                key("/", [.command])
                expect(tab.text.components(separatedBy: "\n")[1].hasPrefix("// "), "⌘/ comments lines 1–4", tab.text)
                expect(marks == [2, 4], "Comment Selection keeps bookmarks 2 and 4", "\(marks)")
            },
            sync {
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                tab.editing.bookmarks = Bookmarks([1, 6])
                tab.applyTextTool(.uppercase)
                expect(tab.text.hasPrefix("LET BAR"), "Text Tools › Uppercase on the whole text", tab.text)
                expect(marks == [1, 6], "keeps the bookmarks", "\(marks)")
            },
            // Undo and redo of line commands bring the bookmarks back too.
            sync {
                focus(tab)
                tab.editing.bookmarks = Bookmarks([2])
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[2] + 1, length: 0))
                key(down, [.control, .command])
                expect(marks == [3], "⌃⌘↓ takes the bookmark to line 3", "\(marks)")
            },
            sync {
                key("z", [.command])
                expect(marks == [2], "undo Move Line puts the bookmark back on line 2", "\(marks)")
            },
            sync {
                key("z", [.command, .shift])
                expect(marks == [3], "redo moves it again", "\(marks)")
            },
            sync {
                tab.editing.bookmarks = Bookmarks([3, 5])
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[3] + 1, length: 0))
                key("k", [.command, .shift])
                expect(marks == [4], "Delete Line drops its bookmark", "\(marks)")
            },
            sync {
                key("z", [.command])
                expect(marks == [3, 5], "undo Delete Line brings it back", "\(marks)")
            },
            sync {
                key("z", [.command, .shift])
                expect(marks == [4], "redo drops it again", "\(marks)")
            },
        ]
    }

    // MARK: Hot close, Reopen Closed Tab

    static func closedTab(_ app: AppDelegate) {
        let file = app.open(write("kept.txt", "on disk\n"))!
        sized(file)
        var untitled: EditorWindowController!
        run([
            sync {
                // Exactly one ⇧⌘T in the menus (AppKit's own tab items included).
                var hits: [String] = []
                func walk(_ m: NSMenu) {
                    m.update()
                    for i in m.items {
                        if i.keyEquivalent.lowercased() == "t",
                           i.keyEquivalentModifierMask.union(i.keyEquivalent != i.keyEquivalent.lowercased() ? .shift : []) == [.command, .shift] {
                            hits.append(i.title)
                        }
                        if let s = i.submenu { walk(s) }
                    }
                }
                if let m = NSApp.mainMenu { walk(m) }
                expect(hits == ["Reopen Closed Tab"], "⇧⌘T is only Reopen Closed Tab", "\(hits)")
                app.newTab(nil)
                untitled = app.tabs.last
                focus(untitled)
                type("hot close")
                expect(untitled.doc.isDirty && untitled.text == "hot close", "typed into an untitled tab", untitled.text)
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === untitled }, "⌘W closes the unsaved tab")
                expect(NSApp.modalWindow == nil && NSApp.windows.allSatisfy { $0.attachedSheet == nil }, "without asking")
                expect(app.closedTabs.count == 1 && app.closedTabs.last?.hasBuffer == true, "it is remembered with its text",
                       "\(app.closedTabs.count)")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" and edited")
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === file }, "⌘W closes the edited file tab too")
                expect(app.closedTabs.count == 2, "both are remembered", "\(app.closedTabs.count)")
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.last
                expect(back?.doc.fileURL?.lastPathComponent == "kept.txt", "⇧⌘T reopens the newest closed tab", back?.doc.displayName ?? "-")
                expect(back?.text == "on disk and edited\n" && back?.doc.isDirty == true, "with its unsaved edit, still unsaved",
                       back?.text ?? "-")
                expect((try? String(contentsOf: back!.doc.fileURL!, encoding: .utf8)) == "on disk\n", "the file itself is untouched")
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.last
                expect(back?.doc.fileURL == nil && back?.text == "hot close" && back?.doc.isDirty == true,
                       "⇧⌘T again: the untitled tab and its text", back?.text ?? "-")
                expect(app.closedTabs.isEmpty, "nothing left to reopen")
                expect(key("t", [.command, .shift]) == false || app.tabs.count == 2, "⇧⌘T with nothing closed does nothing")
            },
            snapshot("reopened-tab.png"),
        ])
    }

    /// Quit while every session write fails (SessionStore.checkFailWrites,
    /// as on a full disk): the app stays open, the user is asked (here
    /// answered by `checkQuitSaveChoice`), and Try Again once the disk
    /// works writes the latest text and lets the quit go on. Needs
    /// session saving on (run like closefail).
    static func quitAfterFailedSave(_ app: AppDelegate) {
        let file = app.open(write("quit-fail.txt", "on disk\n"))!
        sized(file)
        func buffer() -> String? { app.store.readBuffer(file.doc.id) }
        var asked: [String] = []
        run([
            sync {
                expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" one")
                app.saveSession(sync: true)
                expect(buffer() == "on disk one\n", "a save writes the buffer", buffer() ?? "-")
                type(" two")
                app.store.checkFailWrites = true
                AppDelegate.checkQuitSaveChoice = { asked.append($0); return .keepOpen }
                let reply = app.applicationShouldTerminate(NSApp)
                expect(reply == .terminateCancel, "a quit whose session save fails is cancelled")
                expect(asked.count == 1, "the user is asked once", "\(asked)")
                expect(!app.terminating, "the app isn't quitting")
                expect(app.tabs.contains { $0 === file } && file.doc.isDirty, "the tab is still open, unsaved")
                expect(buffer() == "on disk one\n", "nothing newer reached the disk", buffer() ?? "-")
                // Try Again, with the disk working again: the quit goes on.
                asked = []
                AppDelegate.checkQuitSaveChoice = { why in
                    asked.append(why)
                    app.store.checkFailWrites = false
                    return .retry
                }
                let again = app.applicationShouldTerminate(NSApp)
                expect(asked.count == 1, "asked once more", "\(asked)")
                expect(again == .terminateNow, "after a save that worked, the quit goes on")
                expect(buffer() == "on disk one two\n", "the latest text is in its buffer", buffer() ?? "-")
                expect(app.store.load()?.allTabs.contains { $0.id == file.doc.id && $0.hasBuffer } == true, "and the session names it")
                AppDelegate.checkQuitSaveChoice = nil
            },
        ])
    }

    /// ⇧⌘T on a closed tab whose buffer is there but can't be read: the
    /// tab isn't reopened (not from its file without the text either),
    /// the entry stays on the closed list and the buffer is held (kept,
    /// never pruned). Readable again, ⇧⌘T brings the text back. Needs
    /// session saving on (run like closefail).
    static func reopenUnreadableClosedTab(_ app: AppDelegate) {
        let file = app.open(write("reopen-fail.txt", "on disk\n"))!
        sized(file)
        let id = file.doc.id
        let path = app.store.bufferURL(id).path
        let fm = FileManager.default
        run([
            sync {
                expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" edited")
                key("w", [.command])
            },
            sync {
                expect(app.closedTabs.last?.id == id && app.closedTabs.last?.hasBuffer == true, "⌘W keeps the edit for ⇧⌘T")
                expect(app.store.readBuffer(id) == "on disk edited\n", "in its buffer", app.store.readBuffer(id) ?? "-")
                try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
                key("t", [.command, .shift])
            },
            sync {
                expect(!app.tabs.contains { $0.doc.id == id || $0.doc.fileURL?.lastPathComponent == "reopen-fail.txt" },
                       "an unreadable buffer: the tab isn't reopened", app.tabs.map(\.doc.displayName).joined(separator: ","))
                expect(app.closedTabs.last?.id == id && app.closedTabs.last?.hasBuffer == true, "the entry stays on the closed list")
                expect(app.store.heldBuffers.contains(id), "its buffer is held")
                app.saveSession(sync: true)
                expect(fm.fileExists(atPath: path), "and survives a save and its prune")
                expect(app.store.load()?.heldBuffers?.contains(id) == true, "the session names it as held")
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.first { $0.doc.id == id }
                expect(back?.text == "on disk edited\n" && back?.doc.isDirty == true, "readable again: ⇧⌘T brings the edit back, unsaved",
                       back?.text ?? "-")
                expect(!app.closedTabs.contains { $0.id == id }, "and it leaves the closed list")
                expect(!app.store.heldBuffers.contains(id), "no longer held")
                // Closed again; then ⇧⌘T while the store can't be written:
                // the reopen isn't journaled, and the tab says so.
                if let back { focus(back) }
                key("w", [.command])
            },
            sync {
                expect(app.closedTabs.last?.id == id, "closed again")
                app.store.checkFailWrites = true
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.first { $0.doc.id == id }
                let bar = back?.noticeBar
                expect(back?.text == "on disk edited\n", "the store can't be written: ⇧⌘T still reopens the text", back?.text ?? "-")
                expect(bar?.isHidden == false && bar?.label.stringValue.contains("couldn’t record that") == true,
                       "and the tab says the reopen wasn't recorded", bar?.label.stringValue ?? "-")
                expect(bar?.button("Save As…")?.isEnabled == true, "with Save As")
                app.store.checkFailWrites = false
                app.saveSession(sync: true)
                // Closed once more; then its buffer's place holds a folder,
                // not a file: the commit can't count it as on disk, but it
                // must not block every later commit either.
                if let back { focus(back) }
                key("w", [.command])
            },
            sync {
                expect(app.closedTabs.last?.id == id && app.closedTabs.last?.hasBuffer == true, "closed with its buffer")
                try? fm.removeItem(atPath: path)
                try? fm.createDirectory(atPath: path, withIntermediateDirectories: false)
                let first = app.saveSession(sync: true)
                expect(first != nil, "a commit that needs it on disk is refused once", first ?? "-")
                let second = app.saveSession(sync: true)
                expect(second == nil, "then it is held and the next commit goes through", second ?? "-")
                expect(app.store.load()?.heldBuffers?.contains(id) == true, "the session names it as held")
                expect(app.closedTabs.last?.id == id && app.closedTabs.last?.hasBuffer == true, "it stays on the closed list")
                var isDir: ObjCBool = false
                expect(fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue, "and its place is left as it is")
                try? fm.removeItem(atPath: path)
                // An older closed tab, then a newer one whose buffer stays
                // unreadable: ⇧⌘T must get past the newer one.
                if let older = app.open(write("reopen-older.txt", "older\n")) {
                    sized(older)
                    focus(older)
                    older.textView.setSelectedRange(NSRange(location: 5, length: 0))
                    type(" edited")
                    key("w", [.command])
                }
            },
            sync {
                if let newer = app.open(write("reopen-newer.txt", "newer\n")) {
                    sized(newer)
                    focus(newer)
                    newer.textView.setSelectedRange(NSRange(location: 5, length: 0))
                    type(" edited")
                    key("w", [.command])
                }
            },
            sync {
                guard let newer = app.closedTabs.last, newer.path?.hasSuffix("reopen-newer.txt") == true,
                      let older = app.closedTabs.dropLast().last, older.path?.hasSuffix("reopen-older.txt") == true else {
                    expect(false, "two closed tabs, newer last", app.closedTabs.compactMap(\.path).joined(separator: ","))
                    return
                }
                expect(app.store.readBuffer(newer.id) == "newer edited\n", "the newer one's edit is in its buffer")
                try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: app.store.bufferURL(newer.id).path)
                key("t", [.command, .shift])
                expect(!app.tabs.contains { $0.doc.id == newer.id }, "⇧⌘T: the unreadable newest isn't reopened")
                expect(app.store.heldBuffers.contains(newer.id), "and is held")
                key("t", [.command, .shift])
                let back = app.tabs.first { $0.doc.id == older.id }
                expect(back?.text == "older edited\n" && back?.doc.isDirty == true, "⇧⌘T again: the tab closed before it comes back",
                       back?.text ?? "-")
                expect(app.closedTabs.last?.id == newer.id && app.closedTabs.last?.hasBuffer == true,
                       "the unreadable one stays on the closed list")
                app.saveSession(sync: true)
                expect(app.store.load()?.heldBuffers?.contains(newer.id) == true, "held in the session")
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: app.store.bufferURL(newer.id).path)
                expect(app.store.readBuffer(newer.id) == "newer edited\n", "its bytes are kept",
                       app.store.readBuffer(newer.id) ?? "-")
                // Once every other entry has been tried, ⇧⌘T tries it again (readable now).
                for _ in 0..<app.closedTabs.count where !app.tabs.contains(where: { $0.doc.id == newer.id }) {
                    key("t", [.command, .shift])
                }
                let again = app.tabs.first { $0.doc.id == newer.id }
                expect(again?.text == "newer edited\n", "readable again: ⇧⌘T brings it back", again?.text ?? "-")
            },
        ])
    }

    /// A closed tab whose text couldn't be written when it closed (kept in
    /// memory, `closedTexts`): a timed save writes it once the disk works
    /// again, not only quit. Reopened while still only in memory, the tab
    /// isn't counted as written (it was, before: quit then skipped it and
    /// let the app go with the text nowhere on disk). Needs session saving
    /// on (run like closefail).
    static func closedTextOnlyInMemory(_ app: AppDelegate) {
        let first = app.open(write("memory-one.txt", "on disk\n"))!
        let second = app.open(write("memory-two.txt", "on disk\n"))!
        sized(first)
        let one = first.doc.id, two = second.doc.id
        func buffer(_ id: UUID) -> String? { app.store.readBuffer(id) }
        func waitForSaves() { app.sessionQueue.sync {}; RunLoop.main.run(until: Date().addingTimeInterval(0.2)); app.sessionQueue.sync {} }
        run([
            sync {
                expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
                focus(first)
                first.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" one")
                focus(second)
                second.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" two")
                app.store.checkFailWrites = true
                first.window?.close()
                second.window?.close()
            },
            sync {
                expect(app.closedTexts[one] == "on disk one\n" && app.closedTexts[two] == "on disk two\n",
                       "the closes couldn't write: both texts kept in memory")
                expect(buffer(one) == nil && buffer(two) == nil, "nothing on disk")
                app.store.checkFailWrites = false
                app.saveSession(sync: false)
                waitForSaves()
            },
            sync {
                expect(buffer(one) == "on disk one\n" && buffer(two) == "on disk two\n", "a timed save writes them once it can",
                       "\(buffer(one) ?? "-") / \(buffer(two) ?? "-")")
                expect(app.closedTexts.isEmpty, "and lets the memory copies go")
                expect(app.store.load()?.closedTabs?.filter(\.hasBuffer).count == 2, "the session names both")
                // Again, closed and reopened while the disk still fails.
                key("t", [.command, .shift])
            },
            sync {
                guard let back = app.tabs.first(where: { $0.doc.id == two }) else { expect(false, "⇧⌘T reopens the second tab"); return }
                focus(back)
                type(" more")
                app.store.checkFailWrites = true
                back.window?.close()
            },
            sync {
                expect(app.closedTexts[two] == "on disk two more\n", "closed again with the write failing: in memory",
                       app.closedTexts[two] ?? "-")
                key("t", [.command, .shift])
            },
            sync {
                guard let back = app.tabs.first(where: { $0.doc.id == two }) else { expect(false, "⇧⌘T reopens it"); return }
                expect(back.text == "on disk two more\n" && back.doc.isDirty, "reopened from memory with its text", back.text)
                expect(back.doc.sessionChangeCount != back.doc.changeCount, "and not counted as written: it isn't on disk")
                expect(buffer(two) == "on disk two\n", "the disk still has the older text", buffer(two) ?? "-")
                app.store.checkFailWrites = false
                // An older copy's write finishing after a newer one is kept:
                // the first tab, closed with its write failing (in memory)...
                key("t", [.command, .shift])
            },
            sync {
                guard let back = app.tabs.first(where: { $0.doc.id == one }) else { expect(false, "⇧⌘T reopens the first tab"); return }
                focus(back)
                type(" A")
                app.store.checkFailWrites = true
                back.window?.close()
            },
            sync {
                expect(app.closedTexts[one] == "on disk one A\n", "the first tab closed with its write failing: in memory",
                       app.closedTexts[one] ?? "-")
                // ...a timed save writes that copy; its completion waits
                // for the main thread, which meanwhile reopens the tab,
                // edits it and closes it again with the write failing.
                app.store.checkFailWrites = false
                app.saveSession(sync: false)
                app.sessionQueue.sync {}
                expect(buffer(one) == "on disk one A\n", "the timed save wrote the older copy", buffer(one) ?? "-")
                app.reopenClosedTab(nil)
                guard let back = app.tabs.first(where: { $0.doc.id == one }) else { expect(false, "reopened again"); return }
                focus(back)
                type(" B")
                app.store.checkFailWrites = true
                back.window?.close()
                expect(app.closedTexts[one] == "on disk one A B\n", "closed again, failing: the newer text in memory",
                       app.closedTexts[one] ?? "-")
            },
            sync {
                // The older save's completion has run by now.
                expect(app.closedTexts[one] == "on disk one A B\n", "an older save's completion doesn't clear newer text",
                       app.closedTexts[one] ?? "-")
                app.store.checkFailWrites = false
            },
            sync {
                var asked: [String] = []
                AppDelegate.checkQuitSaveChoice = { asked.append($0); return .keepOpen }
                let reply = app.applicationShouldTerminate(NSApp)
                expect(reply == .terminateNow && asked.isEmpty, "quit saves without a failure", "\(asked)")
                expect(buffer(two) == "on disk two more\n", "and quit wrote the reopened text", buffer(two) ?? "-")
                expect(buffer(one) == "on disk one A B\n", "and the newer closed text, not the older copy", buffer(one) ?? "-")
                AppDelegate.checkQuitSaveChoice = nil
            },
        ])
    }

    /// How long the main thread waits on the session store for ⌘W (the
    /// buffer write and the commit), ⇧⌘T (the reopen's journal and the
    /// commit) and quit (queued timed saves drained, then the final
    /// commit), with a 200 KB file edited. Prints "session-timing:" lines
    /// (median and max over the runs, ms). Measures only; needs session
    /// saving on (run like closefail). Not part of tools-check.
    static func sessionLatency(_ app: AppDelegate) {
        let line = "a line of a document of some size, to make each buffer write real work\n"
        let body = String(repeating: line, count: 200_000 / line.utf8.count)
        let file = app.open(write("latency.txt", body))!
        sized(file)
        let id = file.doc.id
        var closes: [Double] = [], reopens: [Double] = []
        func ms(_ f: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
        func report(_ name: String, _ v: [Double]) {
            let s = v.sorted()
            print(String(format: "session-timing: %@ median=%.1f ms max=%.1f ms n=%d", name, s[s.count / 2], s.last ?? 0, s.count))
        }
        var steps: [(@escaping () -> Void) -> Void] = [sync {
            expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
        }]
        for _ in 0..<9 {
            steps.append(sync {
                guard let t = app.tabs.first(where: { $0.doc.id == id }) else { expect(false, "the tab is open"); return }
                focus(t)
                t.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("x")
                app.sessionQueue.sync {}
                closes.append(ms { key("w", [.command]) })
            })
            steps.append(sync { reopens.append(ms { key("t", [.command, .shift]) }) })
        }
        steps.append(sync {
            expect(closes.count == 9 && reopens.count == 9, "nine closes and reopens")
            expect(app.store.readBuffer(id)?.hasPrefix(String(repeating: "x", count: 9)) == true, "each close wrote the edit")
            report("close (⌘W, edited 200 KB file)", closes)
            report("reopen (⇧⌘T)", reopens)
            // Timed saves queued behind each other: one commit, not four.
            func generation() -> Int? {
                let url = app.store.directory.appendingPathComponent("session.json")
                return ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any])?["generation"] as? Int
            }
            guard let t = app.tabs.first(where: { $0.doc.id == id }) else { return }
            focus(t)
            t.textView.setSelectedRange(NSRange(location: 0, length: 0))
            let before = generation()
            let gate = DispatchSemaphore(value: 0)
            app.sessionQueue.async { gate.wait() }
            for _ in 0..<4 { type("c"); app.saveSession(sync: false) }
            gate.signal()
            app.sessionQueue.sync {}
            let after = generation()
            expect(before != nil && after == before.map { $0 + 1 }, "four queued timed saves: one commit", "\(before ?? -1) → \(after ?? -1)")
            expect(app.store.readBuffer(id)?.hasPrefix("cccc") == true, "with the latest text", String(app.store.readBuffer(id)?.prefix(12) ?? "-"))
            // Quit with timed saves queued behind each other (typing).
            focus(t)
            t.textView.setSelectedRange(NSRange(location: 0, length: 0))
            for _ in 0..<4 { type("q"); app.saveSession(sync: false) }
            var reply: NSApplication.TerminateReply?
            let quit = ms { reply = app.applicationShouldTerminate(NSApp) }
            expect(reply == .terminateNow, "quit saves")
            expect(app.store.readBuffer(id)?.hasPrefix("qqqq") == true, "with the last text")
            print(String(format: "session-timing: quit (4 timed saves queued) %.1f ms", quit))
        })
        run(steps)
    }

    /// Quit while the disk takes the session's writes but won't confirm
    /// them (each flush fails: SessionStore.checkFailSync): the save fails,
    /// so the app stays open and asks, as for a write that fails. Needs
    /// session saving on (run like closefail).
    static func quitAfterFailedFlush(_ app: AppDelegate) {
        let file = app.open(write("quit-sync-fail.txt", "on disk\n"))!
        sized(file)
        func buffer() -> String? { app.store.readBuffer(file.doc.id) }
        var asked: [String] = []
        run([
            sync {
                expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" one")
                app.saveSession(sync: true)
                expect(buffer() == "on disk one\n", "a save writes the buffer", buffer() ?? "-")
                type(" two")
                app.store.checkFailSync = true
                AppDelegate.checkQuitSaveChoice = { asked.append($0); return .keepOpen }
                expect(app.applicationShouldTerminate(NSApp) == .terminateCancel, "a quit whose flush fails is cancelled")
                expect(asked.count == 1, "the user is asked", "\(asked)")
                expect(app.tabs.contains { $0 === file } && file.doc.isDirty, "the tab is still open, unsaved")
                expect(file.doc.sessionChangeCount != file.doc.changeCount, "its text isn't counted as written")
                expect(buffer() == "on disk one\n", "the older buffer stays", buffer() ?? "-")
                asked = []
                AppDelegate.checkQuitSaveChoice = { why in
                    asked.append(why)
                    app.store.checkFailSync = false
                    return .retry
                }
                expect(app.applicationShouldTerminate(NSApp) == .terminateNow, "flushes confirmed: the quit goes on")
                expect(buffer() == "on disk one two\n", "with the latest text on disk", buffer() ?? "-")
                AppDelegate.checkQuitSaveChoice = nil
            },
        ])
    }

    /// Timed session saves failing (SessionStore.checkFailWrites, as on a
    /// full disk): the first failure is tried again quietly; once the
    /// retry fails too, every text tab shows a notice that unsaved work
    /// isn't being backed up, with Save As, and it stays until a save
    /// writes everything. Needs session saving on and a short retry
    /// (CEDRIC_SESSION_RETRY_DELAY=2: longer than the steps
    /// between the first failure and its check; tools-check runs it so).
    static func backupFailureNotice(_ app: AppDelegate) {
        let file = app.open(write("backup-fail.txt", "on disk\n"))!
        sized(file)
        app.newTab(nil)
        let untitled = app.tabs.last!
        // A tab already showing another notice (a recovered tab's, say).
        app.newTab(nil)
        let other = app.tabs.last!
        let otherNotice = "A notice this tab already shows."
        let savedAs = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("backup-fail-saved-\(getpid()).txt")
        // In either bar, on screen: not hidden itself, nor in a hidden view, laid out with some height.
        func visible(_ bar: NoticeBar?) -> Bool {
            guard let bar, !bar.isHiddenOrHasHiddenAncestor, bar.window != nil else { return false }
            bar.window?.layoutIfNeeded()
            return bar.frame.height > 0
        }
        func says(_ t: EditorWindowController) -> Bool {
            [t.backupBar, t.noticeBar].contains { visible($0) && $0?.label.stringValue.contains("isn’t being backed up") == true }
        }
        func saysOnly(_ t: EditorWindowController) -> NoticeBar? {
            [t.backupBar, t.noticeBar].compactMap { $0 }.first { visible($0) && $0.label.stringValue.contains("isn’t being backed up") }
        }
        run([
            sync {
                expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
                expect(AppDelegate.sessionRetryDelay <= 3, "a short retry for this check", "\(AppDelegate.sessionRetryDelay)")
                focus(other)
                type("kept by Save As")
                other.showNotice(otherNotice, buttons: [])
                focus(untitled)
                type("typed while the disk is full")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" edited")
            },
            // The typing's own saves first, so the failures below are the
            // only saves (no timer armed by an edit).
            waitFor("the typing is saved", 5) {
                app.store.readBuffer(file.doc.id) == "on disk edited\n" && app.store.readBuffer(untitled.doc.id) != nil
            },
            sync {
                app.store.checkFailWrites = true
                app.saveSession(sync: false)
            },
            waitFor("the first save fails") { app.sessionSaveFailures >= 1 },
            sync {
                expect(!app.backupNoticeShown && !says(file), "one failed save: no notice yet (it is tried again)", "failures \(app.sessionSaveFailures)")
            },
            waitFor("the retry fails too", 8) { app.sessionSaveFailures >= 2 },
            sync {
                expect(app.backupNoticeShown, "then unsaved work isn't being backed up")
                expect(says(file) && says(untitled), "every text tab says so", file.noticeBar?.label.stringValue ?? "-")
                expect(saysOnly(file)?.button("Save As…") != nil, "with Save As")
                expect(saysOnly(file)?.button("Dismiss") != nil, "and Dismiss (it is not modal)")
                focus(other)
                expect(other.window?.isVisible == true && says(other), "a tab already showing another notice says so too, on screen",
                       "backup bar: \(other.backupBar.map { "\($0.isHiddenOrHasHiddenAncestor ? "hidden" : "shown") \($0.frame.height)" } ?? "none")")
                expect(visible(other.noticeBar) && other.noticeBar?.label.stringValue == otherNotice, "and still shows its own notice",
                       other.noticeBar?.label.stringValue ?? "-")
                // Its Save As works from there (the check chooses the place).
                let button = saysOnly(other)?.button("Save As…")
                expect(button?.isEnabled == true, "that tab's Save As is there and enabled")
                EditorWindowController.checkSaveAsURL = savedAs
                button?.performClick(nil)
                expect(EditorWindowController.checkSaveAsURL == nil, "Save As… ran")
                expect((try? String(contentsOf: savedAs, encoding: .utf8)) == "kept by Save As", "and wrote the tab's text",
                       (try? String(contentsOf: savedAs, encoding: .utf8)) ?? "-")
                EditorWindowController.checkSaveAsURL = nil
                try? FileManager.default.removeItem(at: savedAs)
            },
            waitFor("more retries fail", 8) { app.sessionSaveFailures >= 3 },
            sync {
                expect(says(file) && says(untitled), "it stays while saves fail")
                app.store.checkFailWrites = false
            },
            waitFor("a save that works clears it", 8) { !app.backupNoticeShown },
            sync {
                expect(app.store.readBuffer(file.doc.id) == "on disk edited\n", "a save that works writes the text",
                       app.store.readBuffer(file.doc.id) ?? "-")
                expect(app.store.load()?.allTabs.contains { $0.id == untitled.doc.id && $0.hasBuffer } == true, "and the session names both tabs")
                expect(!says(file) && !says(untitled) && !says(other), "and the notice goes from every tab")
                expect(visible(other.noticeBar) && other.noticeBar?.label.stringValue == otherNotice, "the other notice stays")
            },
        ])
    }

    /// A timed session save whose buffer write fails, then a hot close:
    /// the close must still write the text (it used to trust the failed
    /// save and keep the older buffer). Needs session saving on (run
    /// without CEDRIC_NO_SESSION_SAVE, in a throwaway CEDRIC_SESSION_DIR).
    static func closeAfterFailedSave(_ app: AppDelegate) {
        let file = app.open(write("failed-save.txt", "on disk\n"))!
        sized(file)
        let dir = app.store.directory.path
        let fm = FileManager.default
        func buffer() -> String? { app.store.readBuffer(file.doc.id) }
        run([
            sync {
                expect(DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1", "session saving is on for this check")
                focus(file)
                file.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type(" one")
            },
            sync {
                app.saveSession(sync: true)
                expect(buffer() == "on disk one\n", "a timed save writes the buffer", buffer() ?? "-")
                type(" two")
            },
            sync {
                // The buffer can't be written now (as on a full disk or a
                // folder made read-only).
                try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
                app.saveSession(sync: true)
                expect(buffer() == "on disk one\n", "the save's buffer write failed", buffer() ?? "-")
                expect(file.doc.sessionChangeCount != file.doc.changeCount, "and the tab isn't counted as written")
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === file }, "⌘W closes the tab")
                expect(app.closedTabs.last?.hasBuffer == true, "it is remembered with its text")
                expect(buffer() == "on disk one two\n", "the close wrote the latest text, not the older buffer", buffer() ?? "-")
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
            },
        ])
    }

    /// A closed tab's views drawn after its controller is gone (AppKit can
    /// keep a closed window and draw it): this aborted the app (an
    /// unowned self in the gutter's closures). Hot-closes a dirty tab, a
    /// clean one and a reopened one, keeps their windows and views alive
    /// as AppKit might, and draws them over several run-loop turns.
    static func closedTabsStillDrawn(_ app: AppDelegate) {
        let dirty = app.open(write("draw-dirty.txt", "one\ntwo\nthree\n"))!
        let clean = app.open(write("draw-clean.swift", "let a = 1\n// two\nlet b = [a]\n"))!
        sized(dirty)
        var kept: [(NSWindow?, NSView, NSView)] = []
        var gone: [() -> EditorWindowController?] = []
        func keep(_ t: EditorWindowController) {
            kept.append((t.window, t.gutter, t.textView))
            weak var w = t
            gone.append { w }
        }
        func drawAll() {
            for (w, g, tv) in kept {
                w?.display()
                g.needsDisplay = true
                g.display()
                tv.needsDisplay = true
                tv.display()
                if let rep = g.bitmapImageRepForCachingDisplay(in: g.bounds.isEmpty ? NSRect(x: 0, y: 0, width: 40, height: 40) : g.bounds) {
                    g.cacheDisplay(in: g.bounds, to: rep)
                }
            }
        }
        run([
            sync {
                focus(dirty)
                dirty.editing.bookmarks = Bookmarks([1])
                dirty.textView.setSelectedRange(NSRange(location: 3, length: 0))
                type(" edited")
                keep(dirty)
                key("w", [.command])
            },
            sync {
                expect(!app.tabs.contains { $0 === dirty }, "the dirty tab hot-closed")
                drawAll()
                focus(clean)
                keep(clean)
                key("w", [.command])
            },
            sync { drawAll() },
            sync {
                key("t", [.command, .shift])
            },
            sync {
                let back = app.tabs.last
                expect(back?.doc.fileURL?.lastPathComponent == "draw-clean.swift", "⇧⌘T reopened a tab", back?.doc.displayName ?? "-")
                if let back { focus(back); keep(back) }
                key("w", [.command])
            },
            sync { drawAll() },
            sync { drawAll() },
            sync {
                let freed = gone.filter { $0() == nil }.count
                print("check: note \(freed) of \(gone.count) closed controllers freed while their views were drawn")
                drawAll()
                // A tab built after launch (as the deferred restore does), closed at once.
                let late = app.open(write("draw-late.txt", "late\n"))!
                keep(late)
                late.window?.performClose(nil)
                drawAll()
            },
            sync {
                drawAll()
                expect(true, "closed tabs' windows, gutters and text views drew after close without crashing")
            },
        ], gap: 0.4)
    }

    /// The owl's Fix it on a long one-line JSON file (only its start in
    /// the owl's window) formats the whole file, as one undo step; a file
    /// that isn't valid JSON as a whole is left alone and the owl says so.
    static func formatWholeJSONCheck(_ app: AppDelegate) {
        let item = "{\"id\": 12345, \"name\": \"something\", \"tags\": [\"a\", \"b\"]}"
        let full = "[" + Array(repeating: item, count: 300).joined(separator: ",") + "]\n"
        let tab = app.open(write("long.json", full))!
        let broken = app.open(write("broken.json", String(full.dropLast(3)) + "\n"))!
        sized(tab)
        var said: String?
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                let w = tab.owlContextWindow()
                expect(!w.isWholeDocument, "the owl sees only the start of the file", "\((w.context.text as NSString).length)")
                let hint = RulesHintProvider().check(w.context, facts: tab.owlFacts(wholeDocument: w.isWholeDocument))
                    .first { $0.id == RulesHintProvider.jsonID }
                expect(hint != nil && hint?.replacement == nil, "he offers to format it (the whole file, on Fix it)")
                tab.formatWholeJSON { said = $0 }
            },
            sync {
                let expectPretty = try? RulesHintProvider.formatWholeJSON(full).get()
                expect(tab.text == expectPretty, "Fix it formatted the whole file", "\(tab.text.prefix(60))…\(tab.text.suffix(30))")
                expect(tab.text.hasSuffix("  }\n]\n"), "to the very end")
                tab.textView.undoManager?.undo()
            },
            sync {
                expect(tab.text == full, "one undo puts the one-line file back")
                broken.formatWholeJSON { said = $0 }
            },
            sync {
                expect(broken.text == String(full.dropLast(3)) + "\n", "a file that isn't valid JSON as a whole is left alone")
                expect(said != nil, "and the reason is given", said ?? "-")
            },
        ]
        steps += steps1
        steps += staleJSONHintSteps(app)
        run(steps, gap: 0.6)
    }

    /// "Looks like JSON. Format it?" shown again from Recent hints after
    /// the text changed (0.5.4 QA #12): still one-line JSON, the question
    /// with a Fix it that formats the text as it is now; not JSON any
    /// more, a past hint that asks nothing (OK, Don't show again).
    static func staleJSONHintSteps(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        let first = #"{"a":1,"b":[1,2]}"#, second = #"{"a":2,"b":[3,4],"c":"x"}"#
        var tab: EditorWindowController!
        var shown: OwlCoordinator.Shown?
        func titles() -> [String] { tab.owl?.bubble?.buttons.map(\.title) ?? [] }
        func replace(_ text: String) {
            tab.textView.setSelectedRange(NSRange(location: 0, length: (tab.text as NSString).length))
            tab.textView.insertText(text, replacementRange: tab.textView.selectedRange())
        }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                guard let t = app.open(write("stale.json", first)) else { expect(false, "stale JSON: opened stale.json"); return }
                tab = t
                sized(t)
                t.setOwlVisible(true)
                let w = t.owlContextWindow()
                let hub = OwlHub.shared
                guard let hint = RulesHintProvider().check(w.context, facts: t.owlFacts(wholeDocument: w.isWholeDocument))
                        .first(where: { $0.id == RulesHintProvider.jsonID }) else { expect(false, "stale JSON: the rules offer to format it"); return }
                hub.coordinator.markShown(hint, documentID: t.doc.id, context: w.context)
                shown = hub.coordinator.recent.first { $0.hint.id == RulesHintProvider.jsonID && $0.documentID == t.doc.id }
                expect(shown != nil && t.owl != nil, "stale JSON: the hint is under Recent hints")
                focus(t)
                replace(second)
            },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                expect(tab.text == second, "stale JSON: the text changed, still one-line JSON", tab.text)
                owl.showAgain(shown, document: tab.text as NSString, own: true)
                expect(owl.pendingRechecks == 1 && owl.bubble == nil, "stale JSON: checked again off the main thread, not in the click",
                       "pending \(owl.pendingRechecks) bubble \(owl.bubble != nil)")
            },
            waitFor("stale JSON: the check comes back") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let owl = tab?.owl else { return }
                expect(owl.presentedHint?.hint.title == "Looks like JSON. Format it?", "stale JSON: still JSON, it asks",
                       owl.presentedHint?.hint.title ?? "-")
                expect(titles().first == String(localized: "Fix it"), "stale JSON: …with a Fix it that works", "\(titles())")
                owl.bubble?.buttons.first { $0.title == String(localized: "Fix it") }?.performClick(nil)
            },
            sync {
                guard let tab else { return }
                expect(tab.text == JSONFormatter.prettyIfMinified(second), "stale JSON: Fix it formatted the text as it is now", tab.text)
                replace("not JSON any more\n")
            },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                owl.showAgain(shown, document: tab.text as NSString, own: true)
            },
            waitFor("stale JSON: the check comes back (not JSON)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl else { return }
                let title = owl.presentedHint?.hint.title ?? "-"
                expect(title == "Looked like JSON (the text has changed since).", "stale JSON: not JSON now, a past hint", title)
                expect(!title.contains("?"), "stale JSON: …that asks nothing", title)
                expect(titles() == [String(localized: "OK"), String(localized: "Don’t show again")], "stale JSON: …OK and Don’t show again",
                       "\(titles())")
                expect(owl.presentedHint?.documentRange == nil, "stale JSON: …and no range")
                owl.bubble?.buttons.first { $0.title == String(localized: "OK") }?.performClick(nil)
                expect(owl.bubble == nil, "stale JSON: OK closes it")
                // Codex round 2: the JSON kept as the start of a longer,
                // invalid text still matched its range and offered to format it.
                replace(first + " and more")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                owl.showAgain(shown, document: tab.text as NSString, own: true)
            },
            waitFor("stale JSON: the check comes back (JSON then more)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                expect(owl.presentedHint?.hint.title == RulesHintProvider.staleJSONTitle, "stale JSON: JSON then more text, a past hint",
                       owl.presentedHint?.hint.title ?? "-")
                expect(!titles().contains(String(localized: "Fix it")), "stale JSON: …no Fix it for the start of it", "\(titles())")
                owl.hideBubble()
                // Still one-line JSON when asked, edited while it is checked: not offered for text that has gone.
                replace(second)
                owl.showAgain(shown, document: tab.text as NSString, own: true)
                replace(second + " x")
            },
            waitFor("stale JSON: the check comes back (edited meanwhile)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl else { return }
                expect(owl.presentedHint?.hint.title == RulesHintProvider.staleJSONTitle, "stale JSON: edited while checked, a past hint",
                       owl.presentedHint?.hint.title ?? "-")
                expect(owl.presentedHint?.hint.replacement == nil, "stale JSON: …with nothing to apply")
                owl.hideBubble()
                // Sol round 3: the long one-line file's hint (no range),
                // past the length checked again, had its shape checked over
                // the whole file in the click. Off the main thread now too.
                let longLine = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?", source: "rules")
                OwlHub.shared.coordinator.markShown(longLine, documentID: tab.doc.id)
                guard let rangeless = OwlHub.shared.coordinator.recent.first(where: {
                    $0.hint.id == RulesHintProvider.jsonID && $0.documentID == tab.doc.id }) else {
                    expect(false, "stale JSON: the long file's hint is under Recent hints"); return
                }
                expect(rangeless.hint.range == nil, "stale JSON: the long file's hint has no range")
                replace("[" + Array(repeating: "1", count: 40_000).joined(separator: ",") + "]")
                expect((tab.text as NSString).length > RulesHintProvider.replayJSONLimit, "stale JSON: the long file is past the recheck length")
                owl.showAgain(rangeless, document: tab.text as NSString, own: true)
                expect(owl.pendingRechecks == 1 && owl.bubble == nil, "stale JSON: the long file's hint is checked off the main thread, not in the click",
                       "pending \(owl.pendingRechecks) bubble \(owl.bubble != nil)")
            },
            waitFor("stale JSON: the long file's check comes back") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                expect(owl.presentedHint?.hint.title == "Looks like JSON. Format it?", "stale JSON: the long file still JSON-shaped, it asks",
                       owl.presentedHint?.hint.title ?? "-")
                owl.hideBubble()
                // 0.5.4 QA review 3: the check coming back compared the
                // whole text with its copy on the main thread. Now the
                // tab's text revision: any change while it is checked,
                // even one that ends at the same text, makes it a past hint.
                replace(second)
                owl.showAgain(shown, document: tab.text as NSString, own: true)
                replace(second + " x")
                replace(second)
                expect(tab.text == second, "stale JSON: edited and back to the same text")
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            waitFor("stale JSON: the check comes back (edited and back)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                expect(owl.presentedHint?.hint.title == RulesHintProvider.staleJSONTitle,
                       "stale JSON: edited while checked, even back to the same text, a past hint", owl.presentedHint?.hint.title ?? "-")
                owl.hideBubble()
                // Text added the way Follow File adds it (the storage, no
                // user edit, the tab stays clean) while it is checked.
                owl.showAgain(shown, document: tab.text as NSString, own: true)
                let storage = tab.textView.textStorage!
                storage.beginEditing()
                storage.append(NSAttributedString(string: "\n", attributes: tab.baseAttributes()))
                storage.endEditing()
            },
            waitFor("stale JSON: the check comes back (appended)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                expect(owl.presentedHint?.hint.title == RulesHintProvider.staleJSONTitle, "stale JSON: appended to while checked, a past hint",
                       owl.presentedHint?.hint.title ?? "-")
                owl.hideBubble()
                // The whole buffer replaced (a reload, a Follow reset) by the same text.
                replace(second)
                owl.showAgain(shown, document: tab.text as NSString, own: true)
                tab.setText(second)
                expect(tab.text == second, "stale JSON: the buffer replaced by the same text")
            },
            waitFor("stale JSON: the check comes back (replaced)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl, let shown else { return }
                expect(owl.presentedHint?.hint.title == RulesHintProvider.staleJSONTitle, "stale JSON: buffer replaced while checked, a past hint",
                       owl.presentedHint?.hint.title ?? "-")
                owl.hideBubble()
                // Untouched while checked: still asks.
                owl.showAgain(shown, document: tab.text as NSString, own: true)
            },
            waitFor("stale JSON: the check comes back (untouched)") { tab?.owl?.pendingRechecks == 0 && tab?.owl?.bubble != nil },
            sync {
                guard let tab, let owl = tab.owl else { return }
                expect(owl.presentedHint?.hint.title == "Looks like JSON. Format it?", "stale JSON: untouched while checked, it asks",
                       owl.presentedHint?.hint.title ?? "-")
                owl.hideBubble()
                tab.setOwlVisible(false)
                tab.doc.markSaved()
                tab.window?.performClose(nil)
            },
        ]
        steps += steps3
        return steps
    }

    // MARK: Colouring stays right after edits

    /// Lines near the viewport whose colours differ from a fresh, full
    /// re-highlight of the current text (first few, for the report).
    static func colourMismatches(_ tab: EditorWindowController) -> [String] {
        guard let storage = tab.textView.textStorage, let vr = tab.textView.visibleCharacterRange else { return ["no view"] }
        let text = storage.string as NSString
        let index = tab.lineIndex
        let pal = tab.palette
        let fresh = HighlightEngine(language: tab.doc.language)
        // The visible lines and some way past them (the colorizer's own
        // margin edge can move a line with TextKit's height estimates).
        let first = max(0, index.line(containing: vr.location) - SyntaxColorizer.margin / 2)
        let last = min(index.lineCount, index.line(containing: NSMaxRange(vr)) + SyntaxColorizer.margin / 2 + 1)
        let tokens = fresh.tokens(forLines: 0..<last, in: text, index: index).filter { index.line(containing: $0.start) >= first }
        let lo = index.starts[first], hi = last < index.lineCount ? index.starts[last] : index.length
        var want = [UInt32](repeating: pal.foreground, count: hi - lo)
        for t in tokens where t.start >= lo {
            for k in t.start..<min(t.start + t.length, hi) { want[k - lo] = pal.color(for: t.kind) }
        }
        var bad: [String] = []
        var k = lo
        while k < hi, bad.count < 5 {
            var eff = NSRange()
            let c = storage.attribute(.foregroundColor, at: k, effectiveRange: &eff) as? NSColor
            let end = min(NSMaxRange(eff), hi)
            for j in k..<end where text.character(at: j) > 32 {
                if c == nil || distance(c, want[j - lo]) > 0.02 {
                    let line = index.line(containing: j)
                    bad.append("line \(line + 1) col \(j - index.starts[line] + 1) '\(text.substring(with: NSRange(location: j, length: 1)))' coloured=\(tab.colorizer.isColored(line)) region \(first + 1)-\(last) got \(c?.description ?? "-")")
                    break
                }
            }
            k = max(end, k + 1)
        }
        return bad
    }

    /// A multi-KB JSON and a Swift file: random edits (typing, multi-line
    /// replacements with and without a change in line count, pastes,
    /// Replace All, Comment Selection), scrolling far down and back, and a
    /// language switch; after each, the colours near the viewport must
    /// equal a fresh full re-highlight.
    static func colourConsistency(_ app: AppDelegate) {
        let rows = (0..<400).map { "  {\"id\": \($0), \"name\": \"item \($0)\", \"ok\": \($0 % 2 == 0), \"tags\": [\"a\", \"b\"], \"n\": null}" }
        let json = app.open(write("colours.json", "[\n" + rows.joined(separator: ",\n") + "\n]\n"))!
        let swiftSrc = (0..<300).map { "let v\($0) = \"s\($0)\" // note \($0)\n/* block \($0) */ func f\($0)() -> Int { \($0) }" }.joined(separator: "\n") + "\n"
        let swift = app.open(write("colours.swift", swiftSrc))!
        sized(json)
        var seed: UInt64 = 0x5eed
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, n))) }
        func settle(_ tab: EditorWindowController) {
            TypingCheck.settle(0.05)
            tab.colorizer.colorViewport()
            TypingCheck.settle(0.05)
        }
        func verify(_ tab: EditorWindowController, _ what: String) {
            settle(tab)
            let bad = colourMismatches(tab)
            expect(bad.isEmpty, "colours match a fresh highlight: \(what)", bad.joined(separator: ", "))
        }
        func randomEdits(_ tab: EditorWindowController, _ name: String) {
            for round in 0..<12 {
                let ns = tab.text as NSString
                let index = tab.lineIndex
                let vr = tab.textView.visibleCharacterRange ?? NSRange(location: 0, length: 0)
                let firstVis = index.line(containing: vr.location)
                let line = min(index.lineCount - 1, firstVis + next(30))
                let start = index.starts[line]
                let r: NSRange, rep: String
                switch round % 6 {
                case 0: // typing a quote mid-line (changes what follows on the line)
                    r = NSRange(location: start + min(index.lineLength(line), 3), length: 0); rep = "\""
                case 1: // several lines replaced by as many (same line count)
                    let e = index.starts[min(index.lineCount - 1, line + 3)]
                    r = NSRange(location: start, length: e - start)
                    rep = ns.substring(with: r).replacingOccurrences(of: "1", with: "\"x\"")
                case 2: // a paste of several lines
                    r = NSRange(location: start, length: 0); rep = ns.substring(with: NSRange(location: index.starts[0], length: index.starts[min(index.lineCount - 1, 4)]))
                case 3: // lines deleted
                    let e = index.starts[min(index.lineCount - 1, line + 2)]
                    r = NSRange(location: start, length: e - start); rep = ""
                case 4: // a block comment opened (Swift) / a string broken (JSON)
                    r = NSRange(location: start, length: 0); rep = tab.doc.language == .swift ? "/* " : "\"open "
                default: // and closed again
                    r = NSRange(location: start, length: 0); rep = tab.doc.language == .swift ? " */" : "\" "
                }
                tab.replaceAsOneStep(r, with: rep, actionName: "Edit")
                verify(tab, "\(name) edit \(round)")
            }
        }
        run([
            sync { focus(json); verify(json, "json opened") },
            sync { randomEdits(json, "json") },
            sync {
                json.goToLine(json.lineIndex.lineCount - 5)
                verify(json, "json scrolled to the end")
                json.goToLine(json.lineIndex.lineCount / 2)
                verify(json, "json scrolled to the middle")
                randomEdits(json, "json middle")
            },
            sync {
                // Replace All across the document, then undo.
                json.showFindBar(replace: true)
                json.findBar.findField.stringValue = "name"
                json.findBar.replaceField.stringValue = "label"
                json.findBar.onReplaceAll?()
                json.hideFindBar()
                verify(json, "json after Replace All")
                json.textView.undoManager?.undo()
                verify(json, "json after undo")
            },
            sync { focus(swift); sized(swift); verify(swift, "swift opened") },
            sync { randomEdits(swift, "swift") },
            sync {
                swift.textView.setSelectedRange(NSRange(location: swift.lineIndex.starts[2], length: swift.lineIndex.starts[8] - swift.lineIndex.starts[2]))
                swift.perform(.toggleComment)
                verify(swift, "swift after Comment Selection")
                swift.goToLine(swift.lineIndex.lineCount - 3)
                verify(swift, "swift scrolled to the end")
                swift.setLanguage(.javascript)
                verify(swift, "after switching to JavaScript")
                swift.setLanguage(.swift)
                verify(swift, "and back to Swift")
            },
        ], gap: 0.3)
    }

    // MARK: Auto-indent, pairing, bracket match

    static func autoEdit(_ app: AppDelegate) {
        let tab = app.open(write("auto.swift", ""))!
        let prose = app.open(write("prose.txt", ""))!
        sized(tab)
        var t: String { tab.text }
        var caret: Int { tab.textView.selectedRange().location }
        run([
            sync {
                focus(tab)
                expect(tab.doc.language == .swift, "a Swift file", tab.doc.language.rawValue)
                type("if x {")
                expect(t == "if x {}" && caret == 6, "typing { adds } after the caret", "\(t.debugDescription) caret \(caret)")
            },
            sync {
                expect(tab.textView.bracketRanges == [NSRange(location: 5, length: 1), NSRange(location: 6, length: 1)],
                       "the bracket pair at the caret is matched", "\(tab.textView.bracketRanges)")
                key("\r")
                expect(t == "if x {\n    \n}" && caret == 11, "Return between { } indents and puts } on its own line",
                       "\(t.debugDescription) caret \(caret)")
            },
            snapshot("auto-indent.png"),
            sync {
                type("f(a)")
                expect(t == "if x {\n    f(a)\n}" && caret == 15, "( pairs, typing ) steps over it", "\(t.debugDescription) caret \(caret)")
                type(" \"hi\"")
                expect(t == "if x {\n    f(a) \"hi\"\n}", "quotes pair and step over", t.debugDescription)
                type("[")
                expect(t == "if x {\n    f(a) \"hi\"[]\n}", "[ pairs", t.debugDescription)
                key("\u{7f}")
                expect(t == "if x {\n    f(a) \"hi\"\n}", "Backspace in [|] deletes both", t.debugDescription)
            },
            sync {
                key("\r")
                expect(t == "if x {\n    f(a) \"hi\"\n    \n}", "Return keeps the line's indent", t.debugDescription)
                tab.textView.setSelectedRange((t as NSString).range(of: "hi"))
                type("(")
                expect(t.contains("\"(hi)\""), "( with a selection wraps it", t.debugDescription)
                expect(tab.textView.selectedRange() == NSRange(location: ((t as NSString).range(of: "hi")).location, length: 2),
                       "and keeps it selected", "\(tab.textView.selectedRange())")
            },
            sync {
                // Undo takes the typing back step by step, without leaving a stray closer.
                let before = t
                type("(")
                key("z", [.command])
                expect(t == before, "⌘Z undoes a pair in one step", t.debugDescription)
            },
            sync {
                // Prose: no pairing, Return keeps the indent.
                focus(prose)
                type("  (don't")
                key("\r")
                type("x")
                expect(prose.text == "  (don't\n  x", "plain text: no pairing; Return keeps the indent", prose.text.debugDescription)
            },
            sync {
                // A quote right before a quote that was already there types a
                // quote (it opens the next string); it doesn't step over it.
                focus(tab)
                tab.setText("print(\"world\")\n")
                tab.textView.setSelectedRange(NSRange(location: 6, length: 0))
                type("\"")
                expect(t == "print(\"\"world\")\n" && caret == 7, "a quote before an existing quote is typed, not stepped over",
                       "\(t.debugDescription) caret \(caret)")
                // In Swift ' never quotes a string: no pair.
                tab.setText("")
                type("// it's")
                expect(t == "// it's", "no ' pairing in Swift", t.debugDescription)
            },
            sync {
                // ⌘X with no selection while an input method is composing: nothing is cut.
                tab.setText("keep this line\nand this\n")
                tab.textView.setSelectedRange(NSRange(location: 2, length: 0))
                tab.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let before = t
                tab.cutLine()
                expect(t == before && tab.textView.hasMarkedText(), "⌘X doesn't cut the line under marked text", t.debugDescription)
                tab.textView.unmarkText()
                tab.doc.markSaved()
            },
        ])
    }

    // MARK: Status bar counts

    static func counts(_ app: AppDelegate) {
        let tab = app.open(write("count.txt", "one two\nthree four\nfive\n"))!
        let mid = app.open(write("mid.txt", String(repeating: "lorem ipsum\n", count: 6_000)))!   // 72 K: counted after a pause
        let big = app.open(write("big.txt", String(repeating: "lorem ipsum dolor\n", count: 70_000)))! // 1.26 M: lines only
        sized(tab)
        var label: String { tab.statusBar.counts.stringValue }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                expect(label == "5 words · 3 lines · 24 characters", "the document's counts", label)
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                type("six")
                expect(label == "6 words · 4 lines · 27 characters", "updated as you type", label)
                tab.textView.setSelectedRange((tab.text as NSString).range(of: "two\nthree"))
                expect(label == "Selected: 2 words · 2 lines · 9 characters", "a selection's counts", label)
                tab.textView.setSelectedRange(NSRange(location: 0, length: 3))
                expect(label == "Selected: 1 word · 1 line · 3 characters", "singular", label)
            },
            snapshot("counts.png"),
            sync {
                focus(mid)
                mid.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("x")
            },
            waitFor("a 72 K document is counted after a pause, in time", 5) {
                mid.statusBar.counts.stringValue == "12,000 words · 6,000 lines · 72,001 characters"
            },
            sync {
                let l = mid.statusBar.counts.stringValue
                expect(l == "12,000 words · 6,000 lines · 72,001 characters", "a 72 K document is counted after a pause", l)
            },
            sync {
                // The count itself runs off the main thread: the main thread only copies the text.
                let half = String(repeating: "lorem ipsum dolor sit amet\n", count: 36_000)   // ~970 K
                mid.setText(half)
                mid.textView.setSelectedRange(NSRange(location: 0, length: 0))
                mid.editing.documentCounts = nil
                let t0 = Date()
                mid.updateCounts()
                let ms = Date().timeIntervalSince(t0) * 1000
                expect(ms < 15, "counting ~1 M characters doesn't hold up the main thread", String(format: "%.1f ms", ms))
            },
            waitFor("~1 M characters counted, in time", 10) {
                mid.statusBar.counts.stringValue == "180,000 words · 36,000 lines · 972,000 characters"
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                let l = mid.statusBar.counts.stringValue
                expect(l == "180,000 words · 36,000 lines · 972,000 characters", "and the counts arrive", l)
                focus(big)
                big.textView.setSelectedRange(NSRange(location: 0, length: 0))
                let t0 = Date()
                type("x")
                let ms = Date().timeIntervalSince(t0) * 1000
                let l2 = big.statusBar.counts.stringValue
                expect(l2 == "70,000 lines", "over 1 M characters: lines only, no scan", l2)
                expect(ms < 50, "typing there stays fast", String(format: "%.1f ms", ms))
                big.textView.setSelectedRange(NSRange(location: 0, length: 20 * 18))
                let l3 = big.statusBar.counts.stringValue
                expect(l3 == "Selected: 60 words · 20 lines · 360 characters", "a small selection in a big document is counted", l3)
                // 0.5.4: lines-only and cached counts never read the text.
                // Past the cap, the document's lines-only state is cached.
                big.textView.setSelectedRange(NSRange(location: 0, length: 0))
                // (Review: the text read itself is counted, so the old eager
                // bridge would fail these.) A small selection reads it: the
                // counter is live.
                var reads = big.editing.countsTextReads
                big.textView.setSelectedRange(NSRange(location: 0, length: 18))
                expect(big.editing.countsTextReads == reads + 1, "a small selection's count reads the text",
                       "\(big.editing.countsTextReads - reads) reads")
                big.textView.setSelectedRange(NSRange(location: 0, length: 0))
                big.editing.documentCounts = nil
                reads = big.editing.countsTextReads
                big.updateCounts()
                var cachedLinesOnly = false
                if case .some(.none) = big.editing.documentCounts { cachedLinesOnly = true }
                expect(cachedLinesOnly && big.statusBar.counts.stringValue == "70,000 lines", "over the cap: lines only, cached as such",
                       big.statusBar.counts.stringValue)
                expect(big.editing.countsTextReads == reads, "over the cap, not cached: the text isn't read",
                       "\(big.editing.countsTextReads - reads) reads")
                big.updateCounts()
                big.textView.setSelectedRange(NSRange(location: 5, length: 0))
                expect(big.editing.countsTextReads == reads && big.statusBar.counts.stringValue == "70,000 lines",
                       "over the cap, cached: the text isn't read", "\(big.editing.countsTextReads - reads) reads")
                // A selection over the cap: the lines it touches, from the index
                // ("x" was typed at the start: line 1 is 19 units long).
                big.textView.setSelectedRange(NSRange(location: 0, length: 19 + 59_999 * 18))
                expect(big.statusBar.counts.stringValue == "Selected: 60,000 lines", "a selection over the cap: its lines",
                       big.statusBar.counts.stringValue)
                big.textView.setSelectedRange(NSRange(location: 0, length: 19 + 59_999 * 18 - 1))
                expect(big.statusBar.counts.stringValue == "Selected: 60,000 lines", "…ending before a newline: the same lines",
                       big.statusBar.counts.stringValue)
                big.textView.setSelectedRange(NSRange(location: 1, length: 19 + 59_999 * 18 + 1))
                expect(big.statusBar.counts.stringValue == "Selected: 60,001 lines", "…one unit into the next line: one more",
                       big.statusBar.counts.stringValue)
                expect(big.editing.countsTextReads == reads, "selections over the cap: the text isn't read",
                       "\(big.editing.countsTextReads - reads) reads")
                // Exactly the cap: counted (after a pause, off the main thread).
                big.textView.setSelectedRange(NSRange(location: 1, length: TextStats.maxCounted))
                // The cached document counts come back at once with no selection.
                mid.textView.setSelectedRange(NSRange(location: 0, length: 27))
                let midReads = mid.editing.countsTextReads
                mid.textView.setSelectedRange(NSRange(location: 0, length: 0))
                mid.updateCounts()
                expect(mid.statusBar.counts.stringValue == "180,000 words · 36,000 lines · 972,000 characters", "cached counts, at once",
                       mid.statusBar.counts.stringValue)
                expect(mid.editing.countsTextReads == midReads, "cached counts: the text isn't read",
                       "\(mid.editing.countsTextReads - midReads) reads")
            },
            // The cap-sized count runs off the main thread: wait for it (bounded).
            waitFor("a selection of exactly the cap is counted, in time", 10) {
                big.statusBar.counts.stringValue == "Selected: 166,667 words · 55,556 lines · 1,000,000 characters"
            },
            sync {
                // 1,000,000 units of "lorem ipsum dolor\n" (18 each): 55,555
                // lines and "lorem ipsu", 166,667 words over 55,556 lines.
                let l4 = big.statusBar.counts.stringValue
                expect(l4 == "Selected: 166,667 words · 55,556 lines · 1,000,000 characters", "a selection of exactly the cap is counted", l4)
                for t in [tab, mid, big] { t.doc.markSaved() }
            },
        ]
        steps += steps2
        run(steps)
    }
}
