import AppKit
import CedricCore

/// CEDRIC_CHECK=writing, then CEDRIC_CHECK=writingrestore
/// (Scripts/writing-check.sh, also in tools-check.sh): View › Writing Mode
/// and the stats popover, driven with real key and mouse events.
///
/// - Writing Mode is off by default (no hook, no inset), its items are in
///   the menu and the palette.
/// - Typewriter Scrolling: 40 lines typed with Return; once past the
///   middle the caret's line stays at the middle (within one line), with
///   at most one scroll per keystroke. With Reduce Motion a click moves
///   the line to the middle at once (no animation).
/// - Focus: the paragraphs around the caret's carry the dimming rendering
///   attribute and the caret's doesn't; Focus on Sentence; typed text is
///   bright; off, no attribute is left.
/// - Typing timed with Writing Mode off and on (alternating rounds).
/// - A click on the word count opens the stats popover with the numbers
///   (document and selection); a word goal typed there with its ring; the
///   file on disk is untouched. The app then quits (the session is saved)
///   and `writingrestore`, a second launch on that session, finds the goal
///   and the tab's Writing Mode again.
///
/// CEDRIC_WRITING_DIR: where the files go (they must outlive the first launch).
@MainActor
extension DevChecks {
    static var writingDir: URL {
        DevEnvironment.values["CEDRIC_WRITING_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dir
    }

    static let essayStart = "# Essay\n\nThe opening paragraph sets the scene.\n\n"

    static func writingCheck(_ app: AppDelegate) {
        // Never the real defaults: the session is saved in this run.
        Settings.shared.focusUnitOverride = .paragraph
        try? FileManager.default.createDirectory(at: writingDir, withIntermediateDirectories: true)
        let essayURL = writingDir.appendingPathComponent("essay.md")
        try? essayStart.write(to: essayURL, atomically: true, encoding: .utf8)
        let focusText = "First paragraph, one line.\nIts second line.\n\nSecond paragraph. Dr. Smith said 3.5 is fine! Is it?\n\nThird paragraph here.\n"
        let statsText = "One two three.\n\nFour five 日本\n"
        let essay = app.open(essayURL)!
        let focusTab = app.open(write("focus.md", focusText))!
        let stats = app.open(write("stats.md", statsText))!
        for t in [essay, focusTab, stats] { sized(t) }
        func menu(_ s: Selector) -> NSMenuItem? { ContextBarView.menuItem(NSStringFromSelector(s)) }
        func send(_ s: Selector, unit: FocusUnit? = nil) {
            if let unit {
                let items = menu(s)?.menu?.items.filter { $0.action == s } ?? []
                guard let i = items.first(where: { $0.representedObject as? String == unit.rawValue }) else { expect(false, "Focus on \(unit)"); return }
                NSApp.sendAction(s, to: nil, from: i)
                return
            }
            guard let i = menu(s) else { expect(false, "menu item \(s)"); return }
            NSApp.sendAction(i.action!, to: nil, from: i)
        }
        let typewriter = #selector(AppDelegate.toggleTypewriterMenu(_:)), focusSel = #selector(AppDelegate.toggleFocusMenu(_:))
        let unitSel = #selector(AppDelegate.pickFocusUnitMenu(_:))
        func caretOffset(_ tab: EditorWindowController) -> CGFloat? {
            guard let mid = tab.caretLineMidY(tab.textView) else { return nil }
            let b = tab.scrollView.contentView.bounds
            return mid - b.midY
        }
        let lineHeight: CGFloat = {
            let f = essay.textView.font ?? Settings.shared.font
            return ceil(f.ascender - f.descender + f.leading)
        }()
        let focusNS = focusText as NSString
        let p1 = focusNS.range(of: "First paragraph, one line.\nIts second line.")
        let p2 = focusNS.range(of: "Second paragraph. Dr. Smith said 3.5 is fine! Is it?")
        let p3 = focusNS.range(of: "Third paragraph here.")
        let smith = focusNS.range(of: "Dr. Smith said 3.5 is fine!")
        func dims() -> [NSRange] { focusTab.focusDimmedRanges(in: focusTab.textView) }
        func covered(_ r: NSRange) -> Bool { dims().contains { NSIntersectionRange($0, r) == r } }
        func touched(_ r: NSRange) -> Bool { dims().contains { NSIntersectionRange($0, r).length > 0 } }

        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(essay)
                expect(essay.editing.writing.isOff && focusTab.editing.writing.isOff, "Writing Mode is off by default")
                expect(essay.textView.onScrollRangeToVisible == nil && essay.scrollView.contentInsets.bottom == 0, "off: no scroll hook, no inset")
                expect(essay.focusDimmedRanges(in: essay.textView).isEmpty, "off: no dimming attribute")
                for s in [typewriter, focusSel] {
                    let i = menu(s)
                    expect(i != nil && i?.parent?.title == "Writing Mode" && i?.state == .off, "View › Writing Mode › \(i?.title ?? "-") is there, off")
                }
                let rows = CommandPalette.collect(for: essay.window)
                for t in ["Typewriter Scrolling", "Focus", "Focus on Paragraph", "Focus on Sentence"] {
                    let r = rows.first { $0.candidate.title == t }
                    expect(r?.candidate.path == "View › Writing Mode" && r?.candidate.enabled == true, "the palette has View › Writing Mode › \(t)",
                           r?.candidate.path ?? "-")
                }
                send(typewriter)
                expect(essay.editing.writing.typewriter && !focusTab.editing.writing.typewriter, "Typewriter Scrolling is on for this tab only")
                let inset = essay.scrollView.contentInsets.bottom
                let half = essay.scrollView.contentView.bounds.height / 2
                expect(inset > half - lineHeight && inset <= half, "a bottom inset of about half the view", "\(inset) for \(half * 2)")
                if let i = menu(typewriter) { _ = CommandPalette.validate(i, in: essay.window); expect(i.state == .on, "the item is checked") }
            },
            sync {
                // 40 typed lines: past the middle, the caret line stays there.
                guard let w = essay.window else { return }
                essay.textView.setSelectedRange(NSRange(location: (essay.text as NSString).length, length: 0))
                var worst: CGFloat = 0, maxScrolls = 0, pastMiddle = 0
                let view = essay.scrollView.contentView.bounds.height
                for n in 1...40 {
                    for ch in "Line \(n) of the draft" {
                        let before = essay.editing.typewriterScrolls
                        TypingCheck.key(w, String(ch))
                        maxScrolls = max(maxScrolls, essay.editing.typewriterScrolls - before)
                    }
                    let before = essay.editing.typewriterScrolls
                    TypingCheck.key(w, "\r", keyCode: 36)
                    maxScrolls = max(maxScrolls, essay.editing.typewriterScrolls - before)
                    w.displayIfNeeded()
                    guard let mid = essay.caretLineMidY(essay.textView) else { continue }
                    if mid > view / 2 + lineHeight, let off = caretOffset(essay) {
                        pastMiddle += 1
                        worst = max(worst, abs(off))
                    }
                }
                print(String(format: "check: typewriter: %d lines past the middle, worst offset %.1f pt (line %.0f pt), most scrolls per key %d",
                             pastMiddle, worst, lineHeight, maxScrolls))
                expect(pastMiddle >= 10, "the typing went past the middle of the view", "\(pastMiddle)")
                expect(worst <= lineHeight, "the caret line stays at the middle while typing", String(format: "%.1f pt off", worst))
                expect(maxScrolls <= 1, "at most one scroll per keystroke", "\(maxScrolls)")
                expect(essay.text.hasSuffix("Line 40 of the draft\n"), "the lines were typed", String(essay.text.suffix(40)))
                // One long paragraph: each wrap moves the caret a row down, and the text up.
                var wrapWorst: CGFloat = 0
                let sentence = String(repeating: "Prose wraps onto the next row as it grows. ", count: 14)
                for (i, ch) in sentence.enumerated() {
                    TypingCheck.key(w, String(ch))
                    if i % 8 == 7 { w.displayIfNeeded(); if let off = caretOffset(essay) { wrapWorst = max(wrapWorst, abs(off)) } }
                }
                TypingCheck.key(w, "\r", keyCode: 36)
                print(String(format: "check: typewriter: a wrapping paragraph, worst offset %.1f pt", wrapWorst))
                expect(wrapWorst <= lineHeight, "a wrapping paragraph stays at the middle too", String(format: "%.1f pt off", wrapWorst))
            },
            snapshot("writing-typewriter.png"),
            sync {
                // Reduce Motion: a click on a line near the top moves it to the middle at once.
                WritingMode.reduceMotionOverride = true
                let tv = essay.textView
                let b = essay.scrollView.contentView.bounds
                click(tv, at: NSPoint(x: 60, y: b.minY + lineHeight * 3))
                let off = caretOffset(essay) ?? 999
                expect(abs(off) <= lineHeight, "Reduce Motion: a click centres the clicked line without animating",
                       String(format: "%.1f pt off right after the click", off))
                WritingMode.reduceMotionOverride = nil
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // View › Split Editor: typing in the second pane keeps its caret line centred.
                focus(essay)
                essay.toggleSplit()
                guard let second = essay.splitEditor?.second, let w = essay.window else { expect(false, "the essay splits"); return }
                essay.window?.layoutIfNeeded()
                w.makeFirstResponder(second.textView)
                expect(essay.activePane === second, "the second pane is the active one")
                expect(second.textView.onScrollRangeToVisible != nil && second.scrollView.contentInsets.bottom > 0,
                       "the second pane has typewriter scrolling too", "inset \(second.scrollView.contentInsets.bottom)")
                second.textView.setSelectedRange(NSRange(location: (essay.text as NSString).length, length: 0))
                var worst: CGFloat = 0, counted = 0
                for n in 1...14 {
                    for ch in "Split line \(n)" { TypingCheck.key(w, String(ch)) }
                    TypingCheck.key(w, "\r", keyCode: 36)
                    w.displayIfNeeded()
                    guard let mid = essay.caretLineMidY(second.textView) else { continue }
                    let b = second.scrollView.contentView.bounds
                    if mid > b.height / 2 + lineHeight { counted += 1; worst = max(worst, abs(mid - b.midY)) }
                }
                print(String(format: "check: typewriter in the second pane: %d lines, worst offset %.1f pt", counted, worst))
                expect(counted >= 10 && worst <= lineHeight, "the second pane's caret line stays at the middle",
                       String(format: "%d lines, %.1f pt off", counted, worst))
                essay.toggleSplit()
                expect(essay.splitEditor == nil, "unsplit again")
            },
            sync {
                // Large-document mode pauses Writing Mode (as it does the colouring), with a note; the switches stay on.
                let long = String(repeating: "x", count: LargeDocument.lineThreshold + 500)
                let big = app.open(write("bigline.md", "Para one.\n\n" + long + "\n\nPara three.\n"))!
                sized(big)
                focus(big)
                big.setWriting(WritingModeState(typewriter: true, focus: true))
                expect(big.isLargeDocument && big.writingPaused, "a very long line: large-document mode")
                expect(big.editing.writing == WritingModeState(typewriter: true, focus: true), "the switches stay on")
                expect(big.textView.onScrollRangeToVisible == nil && big.scrollView.contentInsets.bottom == 0, "typewriter scrolling is paused")
                expect(big.focusDimmedRanges(in: big.textView).isEmpty, "Focus is paused")
                let note = big.largeBar.label.stringValue
                expect(!big.largeBar.isHidden && note == "Very long lines: colouring, spell check, the owl and Writing Mode are paused for speed.",
                       "the large-document bar says Writing Mode is paused", note)
                if let i = menu(typewriter) { _ = CommandPalette.validate(i, in: big.window); expect(i.state == .on, "the menu item stays checked") }
                // Small again (the text replaced, as a reload does): it resumes.
                big.setText("Para one.\n\nPara two is short now.\n\nPara three.\n")
                big.textView.setSelectedRange(NSRange(location: 14, length: 0))
                expect(!big.isLargeDocument && big.largeBar.isHidden, "the document is small again")
                expect(big.textView.onScrollRangeToVisible != nil && big.scrollView.contentInsets.bottom > 0, "typewriter scrolling resumes")
            },
            sync {
                let tab = app.tabs.first { $0.doc.fileURL?.lastPathComponent == "bigline.md" }
                expect(tab.map { !$0.focusDimmedRanges(in: $0.textView).isEmpty } == true, "Focus resumes")
                // A long line typed in pauses it at once, and "Turn On Anyway" resumes it.
                guard let tab else { return }
                tab.textView.setSelectedRange(NSRange(location: 14, length: 0))
                tab.textView.insertText(String(repeating: "y", count: LargeDocument.lineThreshold + 10), replacementRange: tab.textView.selectedRange())
            },
            sync {
                guard let tab = app.tabs.first(where: { $0.doc.fileURL?.lastPathComponent == "bigline.md" }) else { return }
                expect(tab.writingPaused && tab.textView.onScrollRangeToVisible == nil && tab.focusDimmedRanges(in: tab.textView).isEmpty,
                       "a long line typed in pauses Writing Mode")
                tab.turnOnExtras()
                expect(!tab.writingPaused && tab.textView.onScrollRangeToVisible != nil, "Turn On Anyway resumes it")
                tab.setWriting(WritingModeState())
                essay.window.map { _ in focus(essay) }
            },
            sync {
                // Focus on Paragraph, in another tab.
                focus(focusTab)
                focusTab.textView.setSelectedRange(NSRange(location: p2.location + 5, length: 0))
                send(focusSel)
                expect(focusTab.editing.writing.focus && !essay.editing.writing.focus, "Focus is on for this tab only")
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                expect(covered(p1) && covered(p3), "Focus dims the other paragraphs", "\(dims())")
                expect(!touched(p2), "and not the caret's paragraph", "\(dims())")
            },
            snapshot("writing-focus-paragraph.png"),
            sync {
                send(unitSel, unit: .sentence)
                expect(Settings.shared.focusUnit == .sentence, "Focus on Sentence")
                focusTab.textView.setSelectedRange(NSRange(location: smith.location + 6, length: 0))
            },
            sync {
                let rest = NSRange(location: p2.location, length: smith.location - p2.location)
                expect(!touched(smith), "Focus on Sentence keeps the caret's sentence bright", "\(dims())")
                expect(covered(NSRange(location: rest.location, length: rest.length - 1)) && covered(p1), "and dims the rest of its paragraph too", "\(dims())")
                guard let w = focusTab.window else { return }
                focusTab.textView.setSelectedRange(NSRange(location: NSMaxRange(smith) - 1, length: 0))
                TypingCheck.type(w, " truly")
            },
            sync {
                let typed = (focusTab.text as NSString).range(of: "fine truly!")
                expect(typed.location != NSNotFound && !touched(typed), "typed text in the focus is bright", "\(dims())")
                // The dimming after the focus moved with its text.
                let third = (focusTab.text as NSString).range(of: "Third paragraph here.")
                expect(covered(third) && covered(p1), "the dimmed text before and after the focus stays dimmed", "\(dims()) vs \(third)")
            },
            snapshot("writing-focus-sentence.png"),
            sync {
                send(unitSel, unit: .paragraph)
                send(focusSel)
                expect(!focusTab.editing.writing.focus && dims().isEmpty, "Focus off: no attribute left", "\(dims())")
            },
            sync {
                // Typing speed in the essay: Writing Mode off and on (typewriter and Focus).
                focus(essay)
                writingTypingRounds(essay) { on in
                    essay.setWriting(WritingModeState(typewriter: on, focus: on))
                }
                essay.setWriting(WritingModeState(typewriter: true, focus: false))
            },
            sync {
                // The stats popover.
                focus(stats)
                stats.window?.layoutIfNeeded()
                let label = stats.statusBar.counts
                click(label, at: NSPoint(x: 4, y: label.bounds.midY))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                guard let p = stats.editing.statsPopover else { expect(false, "a click on the word count opens the stats popover"); return }
                expect(p.popover.isShown, "a click on the word count opens the stats popover")
                let want = TextStats.count(statsText as NSString, range: NSRange(location: 0, length: (statsText as NSString).length))!
                expect(want == TextCounts(words: 7, lines: 3, characters: 29), "the stats text counts 7 words, 3 lines, 29 characters", "\(want)")
                expect(p.values["words"] == "7" && p.values["characters"] == "29" && p.values["lines"] == "3", "the popover shows them",
                       "\(p.values)")
                expect(p.values["reading"] == "1 min", "and a reading time", p.values["reading"] ?? "-")
                expect(p.values["sel.words"] == nil, "no selection column without a selection")
                expect(p.values["goal"] == nil && p.ring.progress == 0, "no goal yet")
                selectText("two three.\n\nFour", in: stats)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                let p = stats.editing.statsPopover
                expect(p?.values["sel.words"] == "3" && p?.values["sel.lines"] == "3" && p?.values["sel.characters"] == "16",
                       "with a selection: its counts beside the document's", "\(p?.values ?? [:])")
                p?.popover.close()
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                // UX review #5: View › Show Statistics opens the same popover from the keyboard.
                focus(stats)
                guard let i = ContextBarView.menuItem(NSStringFromSelector(#selector(AppDelegate.showStatisticsMenu(_:)))) else {
                    expect(false, "View › Show Statistics exists"); return
                }
                expect(CommandPalette.validate(i, in: stats.window), "View › Show Statistics is enabled in a text tab")
                expect(CommandPalette.collect(for: stats.window).contains { $0.candidate.title == "Show Statistics" }, "the palette has Show Statistics")
                NSApp.sendAction(i.action!, to: nil, from: i)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                expect(stats.editing.statsPopover?.popover.isShown == true, "View › Show Statistics opens the stats popover")
                stats.editing.statsPopover?.popover.close()
                // The status bar's pop-ups are named for VoiceOver, with tooltips.
                let sb = stats.statusBar
                expect(sb.languageButton.accessibilityLabel() == "Language" && sb.encodingButton.accessibilityLabel() == "Text Encoding"
                       && sb.lineEndingButton.accessibilityLabel() == "Line Endings", "the status bar pop-ups have VoiceOver labels")
                expect([sb.languageButton, sb.encodingButton, sb.lineEndingButton].allSatisfy { !($0.toolTip ?? "").isEmpty }, "and tooltips")
                expect(sb.counts.accessibilityRole() == .button, "the word count is a button for VoiceOver")
                if NSApp.isFullKeyboardAccessEnabled {
                    expect(sb.counts.canBecomeKeyView, "with Full Keyboard Access the word count takes focus")
                } else {
                    print("check: note: Full Keyboard Access off; word-count focus not exercised")
                }
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            sync {
                // A word goal for the essay: typed into the popover's field.
                focus(essay)
                essay.window?.layoutIfNeeded()
                click(essay.statusBar.counts, at: NSPoint(x: 4, y: essay.statusBar.counts.bounds.midY))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                guard let p = essay.editing.statsPopover, let pw = p.goalField.window else { expect(false, "the essay's popover"); return }
                pw.makeFirstResponder(p.goalField)
                for ch in "500" { TypingCheck.key(pw, String(ch)) }
                TypingCheck.key(pw, "\r", keyCode: 36)
                if essay.editing.wordGoal == nil { p.commitGoal() }   // a Return that the inactive popover dropped
                expect(essay.editing.wordGoal == 500, "a goal typed in the popover is set", "\(essay.editing.wordGoal.map(String.init) ?? "nil")")
                p.refresh()
                let words = TextStats.count(essay.text as NSString, range: NSRange(location: 0, length: (essay.text as NSString).length))!.words
                expect(abs(p.ring.progress - WordGoal.progress(words: words, goal: 500)) < 0.0001 && p.ring.progress > 0,
                       "the ring shows the share of the goal", "\(p.ring.progress) for \(words) words")
                expect(p.values["goal"] == "500", "the popover shows the goal")
                expect(FileWordGoals.goal(for: essay.doc.fileURL!.path, in: app.fileWordGoals) == 500, "the goal is the file's, in the session")
                let disk = try? String(contentsOf: essayURL, encoding: .utf8)
                expect(disk == essayStart, "the file on disk is untouched (the goal is never written into it)", disk ?? "-")
            },
            { next in snapshot("writing-stats-popover.png", window: essay.editing.statsPopover?.goalField.window)(next) },
            sync { essay.editing.statsPopover?.popover.close() },
        ]
        steps += steps4
        run(steps, quit: true)
    }

    /// The second launch: the session from `writingCheck` restored.
    static func writingRestoreCheck(_ app: AppDelegate) {
        Settings.shared.focusUnitOverride = .paragraph
        let path = writingDir.appendingPathComponent("essay.md").path
        run([
            sync {
                guard let essay = app.tabs.first(where: { $0.doc.fileURL?.path == path }) else {
                    expect(false, "the essay tab is restored", app.tabs.map { $0.doc.fileURL?.path ?? "-" }.joined(separator: ", "))
                    return
                }
                expect(essay.editing.wordGoal == 500, "the word goal is back after a quit and relaunch",
                       "\(essay.editing.wordGoal.map(String.init) ?? "nil")")
                expect(essay.editing.writing == WritingModeState(typewriter: true, focus: false), "and so is the tab's Writing Mode",
                       "\(essay.editing.writing)")
                expect(essay.textView.onScrollRangeToVisible != nil && essay.scrollView.contentInsets.bottom > 0, "typewriter scrolling is wired again")
                let disk = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                expect(disk == essayStart, "the file still holds no goal", disk ?? "-")
                // A tab of the same file opened fresh (closed, then opened) finds the goal by path.
                expect(FileWordGoals.goal(for: path, in: app.fileWordGoals) == 500, "the session keeps the file's goal by path")
                focus(essay)
                essay.toggleStatsPopover()
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                let tab = app.tabs.first { $0.doc.fileURL?.path == path }
                expect(tab?.editing.statsPopover?.values["goal"] == "500", "the popover shows the restored goal")
            },
        ])
    }

    /// Keystrokes with Writing Mode off and on in alternating rounds (each
    /// key handled and the window drawn, timed). On may not be slower than
    /// off by more than 10 % (and 0.5 ms).
    static func writingTypingRounds(_ tab: EditorWindowController, set: (Bool) -> Void) {
        guard let w = tab.window else { return }
        focus(tab)
        var off: [Double] = [], on: [Double] = []
        let line = "The quick brown fox jumps over the lazy dog. "
        for round in 0..<8 {
            let wantOn = round % 2 == 1
            set(wantOn)
            tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
            TypingCheck.settle(0.1)
            for ch in line {
                let t = CACurrentMediaTime()
                TypingCheck.key(w, String(ch))
                w.displayIfNeeded()
                let ms = (CACurrentMediaTime() - t) * 1000
                if wantOn { on.append(ms) } else { off.append(ms) }
            }
            TypingCheck.key(w, "\r", keyCode: 36)
        }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        let o = median(off), n = median(on)
        print(String(format: "check: writing typing ms: off median %.3f, on median %.3f (n=%d each)", o, n, off.count))
        expect(n <= o * 1.1 + 0.5, "typing with Writing Mode on is within 10 % (0.5 ms) of off", String(format: "%.3f vs %.3f", n, o))
    }
}
