import AppKit
import CedricCore

/// CEDRIC_CHECK=split (Scripts/tools-check.sh): View › Split Editor driven
/// by real key and mouse events. ⌃⌘\ splits and unsplits; typing in the
/// second pane shows in the first (the storage and the drawn glyphs); ⌘Z
/// from either pane; Find, Go to Line and multiple carets in the second
/// pane leave the first alone; a fold made in one pane hides the lines in
/// both; the orientation switch; the preview and Find in Files dock
/// around the split; the session round trip and restore; colouring of the
/// first pane's viewport after typing in the second; large mode; unsplit
/// removes the second layout manager and frees the pane. Snapshots in dark
/// and light.
@MainActor
extension DevChecks {
    static let splitSource: String = {
        var s = DevChecks.foldingSource
        for i in 0..<120 { s += "let filler\(i) = \"value \(i)\" // needle\(i % 3 == 0 ? "" : "x")\n" }
        return s
    }()

    /// The lines `tv` lays out, top to bottom (small documents).
    static func laidOutLines(_ tab: EditorWindowController, _ tv: EditorTextView) -> [Int] {
        guard let tlm = tv.textLayoutManager else { return [] }
        var out: [Int] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            out.append(tab.lineIndex.line(containing: tv.offset(of: f.rangeInElement.location)))
            return true
        }
        return out
    }

    /// The middle of `line`'s fold triangle in `pane`'s gutter.
    static func foldPoint(_ tab: EditorWindowController, _ pane: EditorPane, line: Int) -> NSPoint {
        let tv = pane.textView
        let p = tv.convert(caretPoint(tv, tab.lineIndex.starts[line]), to: nil)
        let g = pane.gutter.convert(p, from: nil)
        let col = pane.gutter.foldColumnRange
        return NSPoint(x: (col.lowerBound + col.upperBound) / 2, y: g.y)
    }

    /// `range`'s glyphs are drawn in `tv` (pixels against the backgrounds).
    static func expectDrawn(in tv: EditorTextView, _ tab: EditorWindowController, _ range: NSRange, _ name: String) {
        let p = tab.palette
        let rects = TypingCheck.glyphRects(tv, range)
        tv.needsDisplay = true
        let ink = TypingCheck.ink(tv, rects, backgrounds: [p.background, p.currentLine, p.selection])
        expect(!rects.isEmpty && TypingCheck.visible(ink, minPixels: 6), name, "rects=\(rects.count) " + TypingCheck.describe(ink))
    }

    static func splitCheck(_ app: AppDelegate) {
        let src = splitSource
        let tab = app.open(write("split.swift", src))!
        sized(tab)
        let first = tab.primaryTextView
        let cs = first.contentStorage!
        let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        func start(_ l: Int) -> Int { tab.lineIndex.starts[l] }
        var second: EditorTextView { tab.splitEditor!.second.textView }
        var secondPane: EditorPane { tab.splitEditor!.second }
        weak var oldSecond: EditorTextView?
        weak var oldSecondLM: NSTextLayoutManager?
        weak var oldSplit: SplitEditor?
        var savedPasteboard: String?
        var restored: EditorWindowController?
        var saved: SplitEditorState?
        var md: EditorWindowController?
        var big: EditorWindowController?
        var firstSelBefore = NSRange(location: 0, length: 0)
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                let i = menuItem(action: #selector(AppDelegate.toggleSplitEditorMenu(_:)))
                expect(i?.keyEquivalent == "\\" && i?.keyEquivalentModifierMask == [.control, .command], "View › Split Editor is ⌃⌘\\")
                expect(i.map { app.validateMenuItem($0) } == true && i?.state == .off, "…enabled, unchecked")
                expect(menuItem(action: #selector(AppDelegate.switchSplitOrientationMenu(_:))).map { app.validateMenuItem($0) } == false,
                       "Switch Orientation is off unsplit")
                expect(menuItem(action: #selector(AppDelegate.moveFocusToOtherPaneMenu(_:))).map { app.validateMenuItem($0) } == false,
                       "Move Focus to Other Pane is off unsplit")
                expect(tab.splitEditor == nil && cs.textLayoutManagers.count == 1, "nothing made for a split before the first one")
                expect(tab.editorArea === tab.editorContainer && tab.textView === first, "unsplit: the editor area is the primary pane")
                first.setSelectedRange(NSRange(location: start(3), length: 0))
                firstSelBefore = first.selectedRange()
                key("\\", [.control, .command])
            },
            sync {
                guard let s = tab.splitEditor else { expect(false, "⌃⌘\\ splits the editor"); return }
                expect(true, "⌃⌘\\ splits the editor")
                expect(cs.textLayoutManagers.count == 2 && second.contentStorage === cs, "the second pane's layout manager is on the same content storage",
                       "\(cs.textLayoutManagers.count)")
                expect(!s.sideBySide && abs(s.ratio - 0.5) < 0.05, "top and bottom by default, halves", "\(s.ratio)")
                expect(tab.window?.firstResponder === second && tab.textView === second, "the new pane has the focus and is the active pane")
                expect(cs.primaryTextLayoutManager === second.textLayoutManager, "…and the content storage's primary layout manager")
                expect(tab.split.arrangedSubviews.contains(s.view) && tab.editorArea === s.view, "the split view is the editor area in the tab's split")
                let f1 = tab.primaryPane.container.frame, f2 = secondPane.container.frame
                expect(f1.height > 150 && f2.height > 150 && abs(f1.width - f2.width) < 1, "two panes, one above the other", "\(f1) \(f2)")
                expect(secondPane.gutter.frame.width > 20 && secondPane.gutter.foldColumn > 0, "the second pane has its gutter with a fold column")
                expect(second.selectedRange() == firstSelBefore, "the second pane starts at the first one's selection")
                expect(menuItem(action: #selector(AppDelegate.toggleSplitEditorMenu(_:))).map { app.validateMenuItem($0) && $0.state == .on } == true,
                       "Split Editor is checked")
                // The mouse wheel scrolls the new pane down the whole text.
                for _ in 0..<12 {
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -250, wheel2: 0, wheel3: 0),
                       let e = NSEvent(cgEvent: cg) { secondPane.scrollView.scrollWheel(with: e) }
                }
            },
            sync {
                let top2 = tab.topLine(in: secondPane)
                expect(top2 > 100 && tab.topLine(in: tab.primaryPane) < 5, "the wheel scrolls pane 2 to the end, pane 1 stays", "top2=\(top2)")
                print("check: note: laying out the new pane took \(String(format: "%.1f", tab.lastSplitLayoutMs)) ms")
                tab.scrollToLine(0, in: secondPane)
                // Type in pane 2 (real keys to the first responder).
                second.setSelectedRange(NSRange(location: start(2), length: 0))
                type("zq")
            },
            sync {
                let typed = NSRange(location: start(2), length: 2)
                expect(first.string.hasPrefix("import Foundation\n\nzqstruct Alpha"), "typed in pane 2: the text storage has it",
                       String(first.string.prefix(40)))
                expectDrawn(in: first, tab, typed, "…and pane 1 draws it")
                expectDrawn(in: second, tab, typed, "…as does pane 2")
                expect(first.selectedRange().location != start(2) + 2, "pane 1's caret didn't follow pane 2's typing")
                expect(tab.doc.isDirty, "the tab is unsaved")
                tab.primaryPane.gutter.needsDisplay = true
                // ⌘Z from pane 1: a real click there first.
                click(first, at: caretPoint(first, start(0) + 3))
            },
            sync {
                expect(tab.window?.firstResponder === first && tab.textView === first, "a click in pane 1 makes it the active pane")
                expect(cs.primaryTextLayoutManager === first.textLayoutManager, "…and the primary layout manager")
                key("z", [.command])
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                expect(first.string == src, "⌘Z in pane 1 undoes pane 2's typing", String(first.string.prefix(40)))
                // Type in pane 1, undo from pane 2 (Move Focus to Other Pane).
                first.setSelectedRange(NSRange(location: start(1), length: 0))
                type("w")
            },
            sync {
                expect(first.string.hasPrefix("import Foundation\nw\n"), "typing in pane 1")
                guard let mf = menuItem(action: #selector(AppDelegate.moveFocusToOtherPaneMenu(_:))) else { expect(false, "Move Focus item"); return }
                expect(app.validateMenuItem(mf), "Move Focus to Other Pane is on when split")
                NSApp.sendAction(#selector(AppDelegate.moveFocusToOtherPaneMenu(_:)), to: nil, from: mf)
                expect(tab.window?.firstResponder === second && tab.textView === second, "Move Focus to Other Pane focuses pane 2")
                key("z", [.command])
            },
            sync {
                expect(second.string == src, "⌘Z in pane 2 undoes pane 1's typing")
                key("z", [.command, .shift])
            },
            sync {
                expect(first.string.hasPrefix("import Foundation\nw\n"), "⇧⌘Z in pane 2 redoes it")
                key("z", [.command])
            },
            sync {
                expect(first.string == src, "…and ⌘Z again")
                // Find in pane 2: selects there, pane 1 keeps its selection.
                firstSelBefore = NSRange(location: start(1), length: 0)
                first.setSelectedRange(firstSelBefore)
                second.setSelectedRange(NSRange(location: start(20), length: 0))
                key("f", [.command])
                type("needlex")
            },
            sync {
                let ns = src as NSString
                let want = ns.range(of: "needlex", options: [], range: NSRange(location: start(20), length: ns.length - start(20)))
                expect(second.selectedRange() == want, "Find in pane 2 selects the match there", "\(second.selectedRange()) \(want)")
                expect(first.selectedRange() == firstSelBefore, "…pane 1's selection doesn't move", "\(first.selectedRange())")
                expect(tab.textView === second, "the find bar keeps pane 2 as the active pane")
                key("g", [.command])
            },
            sync {
                expect(second.selectedRange().location > start(21) && first.selectedRange() == firstSelBefore, "⌘G finds the next one in pane 2",
                       "\(second.selectedRange())")
                tab.hideFindBar()
                expect(tab.window?.firstResponder === second, "closing the find bar puts the focus back in pane 2")
                // Go to Line in pane 2.
                tab.goToLine(100)
                expect(tab.lineIndex.line(containing: second.selectedRange().location) == 99 && first.selectedRange() == firstSelBefore,
                       "Go to Line moves pane 2 only")
                let top2 = tab.topLine(in: secondPane), top1 = tab.topLine(in: tab.primaryPane)
                expect(top2 > 60 && top1 < 10, "…and scrolls pane 2, not pane 1", "\(top1) \(top2)")
                // Pane 1 scrolled far away, pane 2 at the top typing: pane 1's viewport is coloured.
                tab.scrollToLine(0, in: secondPane)
                tab.scrollToLine(110, in: tab.primaryPane)
                second.setSelectedRange(NSRange(location: start(1), length: 0))
                type("x")
            },
            sync {
                tab.colorizer.colorViewport()
                let l1 = tab.topLine(in: tab.primaryPane)
                expect(l1 > 90 && tab.colorizer.isColored(l1 + 2) && tab.colorizer.isColored(1), "both panes' viewports are coloured after typing in pane 2",
                       "top1=\(l1)")
                key("z", [.command])
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                expect(first.string == src, "undo the x")
                // Fold from pane 2's gutter (a real click): both panes hide the lines.
                tab.scrollToLine(0, in: tab.primaryPane)
                tab.scrollToLine(0, in: secondPane)
                if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    secondPane.gutter.mouseEntered(with: e)
                }
                click(secondPane.gutter, at: foldPoint(tab, secondPane, line: 3))
            },
            sync {
                let l1 = laidOutLines(tab, first), l2 = laidOutLines(tab, second)
                expect(tab.folding?.state.folds.count == 1, "a click on pane 2's triangle folds", "\(tab.folding?.state.folds ?? [])")
                expect(!l1.contains(4) && !l1.contains(5) && l1.contains(6), "pane 1 hides the folded lines", "\(l1.prefix(10))")
                expect(!l2.contains(4) && !l2.contains(5) && l2.contains(6), "pane 2 hides them too", "\(l2.prefix(10))")
                expect(first.folding === tab.folding && second.folding === tab.folding, "both views draw the fold's pill")
                // Unfold from pane 1 (⌥⌘→ with the caret on the header line).
                click(first, at: caretPoint(first, start(3) + 2))
            },
            sync {
                key(right, [.option, .command])
                let l1 = laidOutLines(tab, first), l2 = laidOutLines(tab, second)
                expect(tab.folding?.state.folds.isEmpty != false && l1.contains(4) && l2.contains(4), "⌥⌘→ in pane 1 unfolds in both", "\(l2.prefix(8))")
                key(left, [.option, .shift, .command])
                expect((tab.folding?.state.folds.count ?? 0) >= 4 && !laidOutLines(tab, second).contains(4), "⌥⇧⌘← (Fold All) shows in pane 2 too")
                key(right, [.option, .shift, .command])
            },
            sync {
                // Multiple carets in pane 2.
                click(second, at: caretPoint(second, start(21)))
            },
            sync {
                expect(tab.textView === second, "a click focuses pane 2")
                second.setSelectedRange(NSRange(location: start(21), length: 0))
                key(down, [.control, .shift])
                key(down, [.control, .shift])
                expect(second.multiCarets?.count == 3 && first.multiCarets == nil, "⌃⇧↓ twice: three carets in pane 2, none in pane 1",
                       "\(second.multiCarets?.count ?? 0)")
                expect(tab.statusBar.position.stringValue.contains("3"), "the status bar counts pane 2's carets", tab.statusBar.position.stringValue)
                type("M")
            },
            sync {
                let ns = first.string as NSString
                let ok = (21...23).allSatisfy { ns.character(at: tab.lineIndex.starts[$0]) == 77 }
                expect(ok, "typing at three carets in pane 2 edits three lines")
                tab.scrollToLine(15, in: tab.primaryPane)
                expectDrawn(in: first, tab, NSRange(location: tab.lineIndex.starts[22], length: 1), "…pane 1 draws the edits")
                escape()
                expect(second.multiCarets == nil, "⎋ leaves one caret")
                key("z", [.command])
            },
            sync {
                expect(first.string == src, "one ⌘Z undoes the multi-caret edit")
                escape()
                // Bookmarks follow the focused pane's caret.
                second.setSelectedRange(NSRange(location: start(30), length: 0))
                tab.toggleBookmark()
                expect(tab.editing.bookmarks.lines == [30], "a bookmark on pane 2's caret line", "\(tab.editing.bookmarks.lines)")
                tab.editing.bookmarks = Bookmarks()
                tab.setGuttersNeedDisplay()
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            snapshot("split-dark.png"),
            sync {
                // Side by side and back.
                guard let o = menuItem(action: #selector(AppDelegate.switchSplitOrientationMenu(_:))) else { expect(false, "orientation item"); return }
                expect(app.validateMenuItem(o) && o.title == "Split Side by Side", "Split Side by Side is offered", o.title)
                NSApp.sendAction(#selector(AppDelegate.switchSplitOrientationMenu(_:)), to: nil, from: o)
                let f1 = tab.primaryPane.container.frame, f2 = secondPane.container.frame
                expect(tab.splitEditor?.sideBySide == true && f1.width > 200 && f2.width > 200 && abs(f1.height - f2.height) < 1,
                       "side by side: two panes next to each other", "\(f1) \(f2)")
                expect(app.validateMenuItem(o) && o.title == "Split Top and Bottom", "…and the item offers top and bottom", o.title)
            },
            snapshot("split-side-dark.png"),
            sync {
                // The context menu has the split items.
                guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: second.convert(caretPoint(second, start(1)), to: nil), modifierFlags: [],
                                                 timestamp: 0, windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: 1), let m = second.menu(for: e) else { expect(false, "a context menu"); return }
                let titles = m.items.map(\.title)
                expect(titles.contains("Close Split") && titles.contains("Split Top and Bottom"), "the context menu has Close Split and the orientation",
                       "\(titles.suffix(4))")
                if let o = m.items.first(where: { $0.title == "Split Top and Bottom" }), let a = o.action { NSApp.sendAction(a, to: o.target, from: o) }
                expect(tab.splitEditor?.sideBySide == false, "…and switches back to top and bottom")
                // Session: the split, the ratio, pane 2's top line and focus.
                tab.scrollToLine(80, in: secondPane)
                secondPane.anchorLine = 80
                saved = tab.sessionSplit
                expect(saved?.sideBySide == false && (saved?.topLine ?? 0) >= 79 && (saved?.topLine ?? 0) <= 81 && saved?.secondFocused == true,
                       "the session keeps the split, pane 2's top line and its focus", "\(String(describing: saved))")
                let st = SessionTab(path: "/x", split: saved)
                let back = try? JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(st))
                expect(back?.split == saved, "…which round-trips through session.json")
                let old = try? JSONDecoder().decode(SessionTab.self, from: Data(#"{"id":"\#(UUID().uuidString)","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}"#.utf8))
                expect(old != nil && old?.split == nil, "an older session without a split still reads")
                restored = app.open(write("split-copy.swift", src))
                sized(restored)
                if let saved { restored?.restoreSplit(saved) }
            },
            sync {},
            sync {
                guard let r = restored, let s = r.splitEditor else { expect(false, "the restored tab is split"); return }
                let top = r.topLine(in: s.second)
                expect(!s.sideBySide && abs(s.ratio - (saved?.ratio ?? 0.5)) < 0.05 && abs(top - (saved?.topLine ?? 0)) <= 1,
                       "restored: split top and bottom, same ratio, pane 2 at its line", "ratio=\(s.ratio) top=\(top)")
                expect(r.textView === s.second.textView, "…with pane 2 active")
                r.window?.close()
                restored = nil
                focus(tab)
            },
            sync {
                // Preview and Find in Files dock around the split (a Markdown tab).
                let m = app.open(write("split.md", "# Title\n\n" + (0..<60).map { "Line \($0) of text.\n" }.joined()))!
                md = m
                sized(m)
                focus(m)
                key("\\", [.control, .command])
                key("p", [.command, .option])
                let subs = m.split.arrangedSubviews
                expect(m.isSplit && subs.count == 2 && subs[0] === m.editorArea && subs[1] === m.previewPane,
                       "the preview docks right of the split editor", "\(subs.map { Swift.type(of: $0) })")
                expect(m.editorArea.frame.width > 300 && (m.previewPane?.frame.width ?? 0) > 300, "…both get room",
                       "\(m.editorArea.frame) \(m.previewPane?.frame ?? .zero)")
                NSApp.sendAction(#selector(AppDelegate.findInFilesMenu(_:)), to: nil, from: nil)
                let subs2 = m.split.arrangedSubviews
                expect(subs2.count == 3 && subs2[0] === m.editorArea && subs2[2] === app.findInFiles, "Find in Files docks at the right too",
                       "\(subs2.map { Swift.type(of: $0) })")
            },
        ]
        steps += steps4
        let steps5: [Step] = [
            snapshot("split-preview-dark.png"),
            sync {
                guard let m = md else { return }
                app.hideFindInFiles()
                m.split.layoutSubtreeIfNeeded()
                let previewWidth = m.previewPane?.frame.width ?? 0
                m.window?.makeFirstResponder(m.splitEditor?.second.textView)
                key("\\", [.control, .command])
                let subs = m.split.arrangedSubviews
                expect(!m.isSplit && subs.count == 2 && subs[0] === m.editorContainer && subs[1] === m.previewPane,
                       "unsplit: the primary pane is back left of the preview", "\(subs.map { Swift.type(of: $0) })")
                expect(abs((m.previewPane?.frame.width ?? 0) - previewWidth) < 2, "…which keeps its width",
                       "\(previewWidth) → \(m.previewPane?.frame.width ?? 0)")
                expect(m.window?.firstResponder === m.primaryTextView, "…and the focus goes to the remaining pane")
                m.togglePreview()
                m.window?.close()
                md = nil
                focus(tab)
            },
            sync {
                // Unsplit tears it all down.
                oldSecond = tab.splitEditor?.second.textView
                oldSecondLM = oldSecond?.textLayoutManager
                oldSplit = tab.splitEditor
                tab.window?.makeFirstResponder(oldSecond)
                key("\\", [.control, .command])
                expect(tab.splitEditor == nil && cs.textLayoutManagers.count == 1 && cs.textLayoutManagers.first === first.textLayoutManager,
                       "⌃⌘\\ again unsplits: one layout manager on the content storage", "\(cs.textLayoutManagers.count)")
                expect(cs.primaryTextLayoutManager === first.textLayoutManager, "…the primary pane's is the primary layout manager")
                expect(tab.editorArea === tab.editorContainer && tab.split.arrangedSubviews.first === tab.editorContainer,
                       "…the primary pane is the editor area again")
                expect(tab.window?.firstResponder === first && tab.textView === first, "…and has the focus")
                expect(oldSecond?.superview == nil || oldSecond?.window == nil, "the second pane is out of the window")
                expect(tab.sessionSplit == nil, "the session has no split")
            },
            sync { if DevEnvironment.values["CEDRIC_SPLIT_DEBUG_UNDO"] == "1" { tab.window?.undoManager?.removeAllActions() } },
            sync {
                // Released on a later turn (autorelease pools drained).
                expect(oldSplit == nil, "the split editor is freed")
                expect(oldSecondLM == nil, "the second layout manager is freed")
                expect(oldSecond == nil, "the second text view is freed")
                // Resplit: works again.
                key("\\", [.control, .command])
                second.setSelectedRange(NSRange(location: start(2), length: 0))
                type("k")
            },
            sync {
                expect(tab.isSplit && cs.textLayoutManagers.count == 2 && first.string.contains("\nkstruct Alpha"), "split again: typing in the new pane 2 works")
                key("z", [.command])
                key("\\", [.control, .command])
                expect(!tab.isSplit && first.string == src && cs.textLayoutManagers.count == 1, "undo and unsplit again")
                // ⌘Z after unsplit undoes an edit made in the gone pane.
                key("\\", [.control, .command])
                second.setSelectedRange(NSRange(location: start(2), length: 0))
                type("j")
            },
            sync {
                key("\\", [.control, .command])
                expect(!tab.isSplit && first.string.contains("\njstruct Alpha"), "typed in pane 2, then unsplit")
                key("z", [.command])
            },
        ]
        steps += steps5
        let steps6: [Step] = [
            sync {
                expect(first.string == src, "⌘Z in pane 1 undoes the gone pane's edit")
            },
            sync {
                // Large mode, split.
                let b = app.open(write("split-large.js", "const s = '" + String(repeating: "x", count: LargeDocument.lineThreshold + 10) + "'\nfunction f() {\n  return 1\n}\n"))!
                big = b
                sized(b)
                focus(b)
                key("\\", [.control, .command])
                guard let s = b.splitEditor else { expect(false, "large mode: splits"); return }
                expect(b.isLargeDocument && b.primaryTextView.contentStorage?.textLayoutManagers.count == 2, "large mode splits, chunked storage shared")
                s.second.textView.setSelectedRange(NSRange(location: (b.text as NSString).length, length: 0))
                type("q")
            },
            sync {
                guard let b = big else { return }
                expect(b.primaryTextView.string.hasSuffix("}\nq"), "large mode: typing in pane 2")
                key("z", [.command])
                key("\\", [.control, .command])
                expect(!b.isSplit && b.primaryTextView.contentStorage?.textLayoutManagers.count == 1, "large mode: unsplit")
                b.doc.markSaved()
                b.window?.close()
                big = nil
                focus(tab)
                // Light theme, split, with a fold and a selection.
                TypingCheck.apply(TypingCheck.themes.first { $0.name == "light" }!)
                key("\\", [.control, .command])
                savedPasteboard = nil
                second.setSelectedRange(NSRange(location: start(14), length: 30))
                tab.toggleFold(line: 8)
                tab.setGuttersNeedDisplay()
            },
            snapshot("split-light.png"),
            sync {
                expect(tab.splitEditor?.view.color != nil && tab.palette.isDark == false, "light theme applied to the split")
                tab.unfoldAll()
                key("\\", [.control, .command])
                expect(!tab.isSplit && first.string == src, "after everything: unsplit, the original text")
                if let s = savedPasteboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
                tab.doc.markSaved()
            },
        ]
        steps += steps6
        run(steps)
    }
}
