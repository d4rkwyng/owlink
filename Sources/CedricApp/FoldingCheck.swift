import AppKit
import CedricCore

/// CEDRIC_CHECK=folding (Scripts/tools-check.sh): code folding driven by
/// real events: mouse clicks on the gutter's triangles and on the "⋯"
/// pill, the Text › Folding shortcuts (⌥⌘←/→, ⌥⇧⌘←/→) and arrow keys
/// through the window. Checks that hidden lines aren't laid out (TextKit's
/// fragments skip them, so the gutter's numbers jump), that the text
/// storage never changes, that typing next to a fold keeps it and typing
/// in it opens it, that Find, Go to Line, bookmarks and multiple carets
/// open what they land in, that copy takes the whole text, undo, Fold All
/// and Fold to Level, the session's folds, Markdown, Python, plain text
/// and large mode. Snapshots in dark and light.
@MainActor
extension DevChecks {
    static let foldingSource = """
    import Foundation

    struct Alpha {
        func one() -> Int {
            let s = "{ needle"
            return 1
        }

        func two() {
            if true {
                print("x")
            }
        }
    }
    /*
     comment block
     */
    let tail = 2
    print("y")

    """

    /// The lines TextKit lays out, top to bottom (small documents).
    static func laidOutLines(_ tab: EditorWindowController) -> [Int] {
        let tv = tab.textView
        guard let tlm = tv.textLayoutManager else { return [] }
        var out: [Int] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            out.append(tab.lineIndex.line(containing: tv.offset(of: f.rangeInElement.location)))
            return true
        }
        return out
    }

    /// The middle of line `line`'s fold triangle, in gutter coordinates.
    static func foldPoint(_ tab: EditorWindowController, line: Int) -> NSPoint {
        let tv = tab.textView
        let p = tv.convert(caretPoint(tv, tab.lineIndex.starts[line]), to: nil)
        let g = tab.gutter.convert(p, from: nil)
        let col = tab.gutter.foldColumnRange
        return NSPoint(x: (col.lowerBound + col.upperBound) / 2, y: g.y)
    }

    /// Pixels in line `line`'s fold column that aren't the gutter's background.
    static func foldInk(_ tab: EditorWindowController, line: Int) -> Int {
        let g = tab.gutter
        g.needsDisplay = true
        g.displayIfNeeded()
        let c = foldPoint(tab, line: line)
        let box = NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
        guard let rep = DevHooks.render(g, box) else { return 0 }
        let bg = TypingCheck.luminance(NSColor(hex: tab.palette.gutterBackground))
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let col = rep.colorAt(x: x, y: y), TypingCheck.contrast(TypingCheck.luminance(col), bg) > 1.3 { n += 1 }
            }
        }
        return n
    }

    static func foldingCheck(_ app: AppDelegate) {
        let src = foldingSource
        let tab = app.open(write("folding.swift", src))!
        sized(tab)
        let tv = tab.textView
        let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        func start(_ l: Int) -> Int { tab.lineIndex.starts[l] }
        func end(_ l: Int) -> Int { NSMaxRange(tab.lineIndex.contentRange(ofLine: l)) }
        var folds: [NSRange] { tab.folding?.state.folds ?? [] }
        func caretAt(_ offset: Int) { tv.setSelectedRange(NSRange(location: offset, length: 0)) }
        func clickFold(_ line: Int) { click(tab.gutter, at: foldPoint(tab, line: line)) }
        var savedPasteboard: String?
        var foldAllCount = 0
        var dirtyBefore = false
        var copy: EditorWindowController?
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                for (sel, name, key, mods) in [(#selector(AppDelegate.foldMenu(_:)), "Fold", left, NSEvent.ModifierFlags([.option, .command])),
                                               (#selector(AppDelegate.unfoldMenu(_:)), "Unfold", right, [.option, .command]),
                                               (#selector(AppDelegate.foldAllMenu(_:)), "Fold All", left, [.option, .shift, .command]),
                                               (#selector(AppDelegate.unfoldAllMenu(_:)), "Unfold All", right, [.option, .shift, .command])] {
                    let i = menuItem(action: sel)
                    expect(i?.keyEquivalent == key && i?.keyEquivalentModifierMask == mods, "Text › Folding › \(name) has its shortcut")
                }
                expect(menuItem(action: #selector(AppDelegate.foldMenu(_:))).map { app.validateMenuItem($0) } == true, "Fold is enabled in a Swift tab")
                expect(menuItem(action: #selector(AppDelegate.unfoldAllMenu(_:))).map { app.validateMenuItem($0) } == false,
                       "Unfold All is off with nothing folded")
                expect(tab.folding == nil, "nothing made for folding before the first fold")
                expect(tab.gutter.foldColumn > 0, "the gutter has a fold column for Swift")
                // The pointer over the gutter (its tracking area's event): triangles show.
                if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    tab.gutter.mouseEntered(with: e)
                }
                expect(foldInk(tab, line: 3) > 8, "hovering: a triangle on line 4 (func one)", "\(foldInk(tab, line: 3))")
                expect(foldInk(tab, line: 4) == 0, "…and none on line 5", "\(foldInk(tab, line: 4))")
            },
            sync {
                // A click on the triangle folds lines 5–6.
                clickFold(3)
                expect(folds == [NSRange(location: start(4), length: start(6) - start(4))], "a click on the triangle folds func one", "\(folds)")
                let lines = laidOutLines(tab)
                expect(!lines.contains(4) && !lines.contains(5) && lines.contains(3) && lines.contains(6),
                       "hidden lines aren't laid out (the numbers jump 4 → 7)", "\(lines)")
                expect(tv.string == src && !tab.doc.isDirty, "the text storage is unchanged and the tab clean")
                tv.needsDisplay = true
                tv.displayIfNeeded()
                expect(tv.foldPills.count == 1, "a pill after the header line", "\(tv.foldPills.count)")
                expect(tab.folding?.label(for: folds[0], tab.lineIndex) == "⋯ 2 lines", "it reads ⋯ 2 lines")
                expect(menuItem(action: #selector(AppDelegate.unfoldAllMenu(_:))).map { app.validateMenuItem($0) } == true, "Unfold All is on now")
            },
            snapshot("folding-dark.png"),
            sync {
                // Arrow keys step over the hidden lines.
                caretAt(end(3))
                arrow(NSRightArrowFunctionKey, 124)
                expect(tv.selectedRange().location == start(6), "→ at the header's end skips to the line after the fold", "\(tv.selectedRange())")
                arrow(NSLeftArrowFunctionKey, 123)
                expect(tv.selectedRange().location == end(3), "← comes back to the header's end", "\(tv.selectedRange())")
                caretAt(start(3) + 4)
                arrow(NSDownArrowFunctionKey, 125)
                expect(tab.lineIndex.line(containing: tv.selectedRange().location) == 6, "↓ from the header goes to line 7", "\(tv.selectedRange())")
                arrow(NSUpArrowFunctionKey, 126)
                expect(tab.lineIndex.line(containing: tv.selectedRange().location) == 3, "↑ goes back to the header")
                caretAt(end(3))
                arrow(NSRightArrowFunctionKey, 124, [.option])
                expect(!tab.folding!.state.isHidden(tv.selectedRange().location), "⌥→ never lands in hidden text", "\(tv.selectedRange())")
                expect(folds.count == 1, "moving around keeps the fold")
            },
            sync {
                // The triangle again: unfolds.
                clickFold(3)
                expect(folds.isEmpty && laidOutLines(tab).contains(4), "a second click unfolds", "\(folds)")
                expect(tab.textView.contentStorage?.delegate == nil, "with nothing folded, TextKit has no folding delegate")
                // ⌥⌘← with the caret inside func two's if: folds the if.
                caretAt(start(10) + 4)
                key(left, [.option, .command])
                expect(folds == [NSRange(location: start(10), length: start(11) - start(10))], "⌥⌘← folds the innermost region around the caret",
                       "\(folds)")
                expect(tab.lineIndex.line(containing: tv.selectedRange().location) == 9, "the caret goes to the header line")
                key(left, [.option, .command])
                expect(folds.count == 2 && folds.contains { $0.location == start(9) }, "⌥⌘← again folds func two around it", "\(folds)")
                key(right, [.option, .command])
                expect(folds.count == 1, "⌥⌘→ unfolds the caret line's fold (the inner one stays)", "\(folds)")
                tv.needsDisplay = true
                tv.displayIfNeeded()
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // A click on the pill unfolds.
                guard let pill = tv.foldPills.first else { expect(false, "a pill to click"); return }
                click(tv, at: NSPoint(x: pill.rect.midX, y: pill.rect.midY))
                expect(folds.isEmpty, "a click on the ⋯ pill unfolds", "\(folds)")
            },
            sync {
                // Typing at the header's end keeps the fold; Return there opens it; undo is the usual.
                clickFold(3)
                caretAt(end(3))
                type("z")
            },
            sync {
                expect(folds.count == 1 && tv.string.contains("Int {z\n"), "typing at the header's end keeps the fold", "\(folds)")
                returnKey()
            },
            sync {
                expect(folds.isEmpty, "Return at the header's end opens it")
                key("z", [.command])
            },
            sync {
                // (AppKit may group the typed z with the Return.)
                let once = tv.string
                expect(once.contains("Int {z\n        let") || once == src, "⌘Z takes back the Return", once)
                if once != src { key("z", [.command]) }
            },
            sync {
                expect(tv.string == src, "⌘Z again: the original text", tv.string)
                // An edit inside a folded range (as Replace or the owl's Apply would make): opens it.
                clickFold(3)
                tv.insertText("Q", replacementRange: NSRange(location: start(5) + 8, length: 0))
            },
            sync {
                expect(folds.isEmpty && laidOutLines(tab).contains(5), "an edit inside the fold opens it", "\(folds)")
                expect(tv.string.contains("        Qreturn 1"), "…and is where it was made")
                key("z", [.command])
            },
            sync {
                expect(tv.string == src, "⌘Z restores the text", tv.string)
                // Find opens the fold its match is in.
                clickFold(3)
                caretAt(0)
                key("f", [.command])
                type("needle")
            },
            sync {
                let match = (src as NSString).range(of: "needle")
                expect(tv.selectedRange() == match, "Find selects the match in the fold", "\(tv.selectedRange())")
                expect(folds.isEmpty, "…and opens the fold", "\(folds)")
                tab.hideFindBar()
                // Go to Line into a fold opens it.
                clickFold(8)
                tab.goToLine(11)
                expect(folds.isEmpty && tab.lineIndex.line(containing: tv.selectedRange().location) == 10, "Go to Line into a fold opens it",
                       "\(folds) \(tv.selectedRange())")
                // Next Bookmark (F2) onto a hidden line opens it.
                clickFold(8)
                tab.editing.bookmarks = Bookmarks([10])
                caretAt(0)
                key(String(UnicodeScalar(UInt16(NSF2FunctionKey))!))
                expect(folds.isEmpty && tab.lineIndex.line(containing: tv.selectedRange().location) == 10, "F2 to a bookmark in a fold opens it",
                       "\(folds) \(tv.selectedRange())")
                tab.editing.bookmarks = Bookmarks()
                // Select All Occurrences with one in a fold: opens it.
                clickFold(8)
                caretAt(start(18) + 2)
                key("g", [.control, .command])
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                expect((tv.multiCarets?.count ?? 0) == 2, "⌃⌘G: a caret at each print", "\(tv.multiCarets?.count ?? 0)")
                expect(folds.isEmpty, "a caret in a fold opens it", "\(folds)")
                escape()
                // Copy of a folded range: the whole text.
                savedPasteboard = NSPasteboard.general.string(forType: .string)
                clickFold(3)
                tv.setSelectedRange(NSRange(location: start(3), length: start(7) - start(3)))
                key("c", [.command])
                let want = (src as NSString).substring(with: NSRange(location: start(3), length: start(7) - start(3)))
                expect(NSPasteboard.general.string(forType: .string) == want, "copy across a fold copies the hidden lines too")
                expect(folds.count == 1, "a selection over a whole fold leaves it folded", "\(folds)")
                caretAt(0)
            },
            sync {
                // Fold All, Unfold All, Fold to Level.
                dirtyBefore = tab.doc.isDirty
                key(left, [.option, .shift, .command])
                let all = tab.foldScanner()?.allRegions() ?? []
                foldAllCount = folds.count
                expect(all.count == 5 && foldAllCount == 5, "⌥⇧⌘← folds every region (struct, two funcs, if, comment)", "\(all.count) \(foldAllCount)")
                let lines = laidOutLines(tab)
                expect(lines.filter { $0 < 19 } == [0, 1, 2, 13, 14, 17, 18], "only the outer lines are laid out", "\(lines)")
                expect(tv.string == src && tab.doc.isDirty == dirtyBefore, "Fold All leaves the text and the tab's saved state alone")
                print("check: note: Fold All took \(String(format: "%.2f", tab.lastFoldAllMs)) ms")
            },
            snapshot("folding-all-dark.png"),
            sync {
                key(right, [.option, .shift, .command])
                expect(folds.isEmpty && laidOutLines(tab).count >= 19, "⌥⇧⌘→ unfolds everything", "\(folds)")
                guard let level2 = menuItem(action: #selector(AppDelegate.foldToLevelMenu(_:)))?.menu?.items.first(where: { ($0.representedObject as? Int) == 2 })
                else { expect(false, "Fold to Level 2 item"); return }
                expect(app.validateMenuItem(level2), "Fold to Level 2 is enabled")
                NSApp.sendAction(#selector(AppDelegate.foldToLevelMenu(_:)), to: nil, from: level2)
                let lines = laidOutLines(tab)
                expect(folds.count == 3 && lines.contains(3) && lines.contains(8) && !lines.contains(4) && !lines.contains(9),
                       "Fold to Level 2 folds the funcs (and the if inside one), not the struct", "\(folds) \(lines)")
            },
            sync {
                // The session keeps the folds by header line, and they come back.
                let headers = tab.sessionFolds ?? []
                expect(headers == [3, 8, 9], "the session saves the folds' header lines", "\(headers)")
                let st = SessionTab(path: "/x", folds: headers)
                let back = try? JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(st))
                expect(back?.folds == headers, "…which round-trip through session.json")
                let old = try? JSONDecoder().decode(SessionTab.self, from: Data(#"{"id":"\#(UUID().uuidString)","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}"#.utf8))
                expect(old != nil && old?.folds == nil, "an older session without folds still reads")
                copy = app.open(write("folding-copy.swift", src))
                sized(copy)
                copy?.restoreFolds(headers)
            },
            sync {
                expect(copy?.sessionFolds == [3, 8, 9], "restored folds fold the same regions", "\(copy?.sessionFolds ?? [])")
                copy?.window?.close()
                focus(tab)
                tab.unfoldAll()
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            sync {
                // Markdown headings, Python indentation.
                let md = app.open(write("folding.md", "# Title\nintro\n## One\ntext\n```\n# code\n```\n## Two\nmore\n"))!
                sized(md)
                focus(md)
                key(left, [.option, .shift, .command])
                let lines = laidOutLines(md)
                expect(md.folding?.state.folds.count == 3 && lines.filter { $0 < 9 } == [0], "Markdown: Fold All folds by heading; a # in a fence isn't one",
                       "\(md.folding?.state.folds ?? []) \(lines)")
                key(right, [.option, .shift, .command])
                let py = app.open(write("folding.py", "def f(x):\n    if x:\n        return 1\n    return 2\n\nprint(f(1))\n"))!
                sized(py)
                focus(py)
                click(py.gutter, at: foldPoint(py, line: 0))
                expect(py.folding?.state.folds.count == 1 && laidOutLines(py).filter { $0 < 6 } == [0, 4, 5], "Python: the def folds by indentation",
                       "\(laidOutLines(py))")
                py.doc.markSaved()
                // Plain text: no fold column, the menu is off.
                let plain = app.open(write("folding.txt", "a {\n  b\n}\n"))!
                sized(plain)
                focus(plain)
                expect(plain.gutter.foldColumn == 0, "plain text: no fold column")
                expect(menuItem(action: #selector(AppDelegate.foldMenu(_:))).map { app.validateMenuItem($0) } == false, "plain text: Fold is off")
                // Large mode: folding is off.
                let big = app.open(write("folding-large.js", "const s = '" + String(repeating: "x", count: LargeDocument.lineThreshold + 10) + "'\nfunction f() {\n  return 1\n}\n"))!
                sized(big)
                focus(big)
                expect(big.isLargeDocument && !big.foldingAvailable && big.gutter.foldColumn == 0, "large mode: no folding, no fold column")
                expect(menuItem(action: #selector(AppDelegate.foldAllMenu(_:))).map { app.validateMenuItem($0) } == false, "large mode: Fold All is off")
            },
            sync {
                // Light theme snapshot.
                focus(tab)
                TypingCheck.apply(TypingCheck.themes.first { $0.name == "light" }!)
                clickFold(3)
                clickFold(14)
                expect(folds.count == 2, "light: two folds", "\(folds)")
                tv.needsDisplay = true
                tab.gutter.needsDisplay = true
            },
            snapshot("folding-light.png"),
            sync {
                tab.unfoldAll()
                expect(tv.string == src, "after everything, the text is the original")
                if let s = savedPasteboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
                tab.doc.markSaved()
            },
        ]
        steps += steps4
        run(steps)
    }
}
