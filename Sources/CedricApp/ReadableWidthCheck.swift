import AppKit
import CedricCore

/// CEDRIC_CHECK=readable (Scripts/writing-check.sh): View › Readable Width.
/// Off by default in a Markdown tab and a Swift tab. Turned on, the column
/// is centred (inset + column + inset is the view's width, the column is
/// the setting's characters wide) and the gutter sits just left of the
/// text; the gutter's line under a wrapped paragraph's first line is that
/// line; typing leaves the inset alone; a narrower window re-centres it;
/// Typewriter Scrolling keeps the caret line at the middle and Focus dims,
/// in the column; the menu item turns it off and on; an explicit choice
/// stays when the Writing default changes; Settings › Readable width
/// changes the column; without Wrap Lines it is off.
@MainActor
extension DevChecks {
    static func readableWidthCheck(_ app: AppDelegate) {
        let para = "This sentence is long enough to wrap a few times in a seventy-two character column of text. "
        var md = "# Readable\n\n"
        for i in 1...60 { md += "Paragraph \(i). " + String(repeating: para, count: 3) + "\n\n" }
        let mdTab = app.open(write("readable.md", md))!
        let swiftTab = app.open(write("readable.swift", "let x = 1 // " + String(repeating: "code ", count: 80) + "\n"))!
        sized(mdTab)
        sized(swiftTab)
        let defaults = UserDefaults.standard
        let savedColumns = defaults.object(forKey: "readableColumns"), savedWrap = defaults.object(forKey: "wrapLines")
        let savedDefault = defaults.object(forKey: "readableWidthDefault")
        func inset(_ t: EditorWindowController) -> CGFloat { t.textView.textContainerInset.width }
        func centred(_ t: EditorWindowController) -> Bool {
            let tv = t.textView
            guard let c = tv.textContainer else { return false }
            return abs(2 * inset(t) + c.size.width - tv.bounds.width) <= 1
        }
        func columnChars(_ t: EditorWindowController) -> CGFloat {
            let tv = t.textView, f = tv.font ?? Settings.shared.font
            let w = f.readableCharacterWidth
            return ((tv.textContainer?.size.width ?? 0) - 2 * (tv.textContainer?.lineFragmentPadding ?? 0)) / w
        }
        let lineHeight: CGFloat = {
            let f = mdTab.textView.font ?? Settings.shared.font
            return ceil(f.ascender - f.descender + f.leading)
        }()
        func lineStart(_ t: EditorWindowController, _ line: Int) -> Int { t.lineIndex.starts[line] }

        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                defaults.removeObject(forKey: "readableColumns")
                defaults.removeObject(forKey: "readableWidthDefault")
                focus(mdTab)
                mdTab.applyReadableWidth()
                swiftTab.applyReadableWidth()
                mdTab.window?.layoutIfNeeded()
                swiftTab.window?.layoutIfNeeded()
                print(String(format: "check: readable: view %.0f pt, inset %.0f pt, column %.1f characters",
                             mdTab.textView.bounds.width, inset(mdTab), columnChars(mdTab)))
                expect(!Settings.shared.readableWidthDefault, "Settings › Writing › Readable Width is unchecked")
                expect(!mdTab.readableWidthOn && inset(mdTab) == 4, "off by default in a Markdown tab", "inset \(inset(mdTab))")
                expect(!swiftTab.readableWidthOn && inset(swiftTab) == 4, "off in a Swift tab", "inset \(inset(swiftTab))")
                if let i = menuItem(action: #selector(AppDelegate.toggleReadableWidthMenu(_:))) {
                    expect(app.validateMenuItem(i) && i.state == .off, "View › Readable Width is unchecked in the Markdown tab")
                } else { expect(false, "View › Readable Width exists") }
                app.toggleReadableWidthMenu(nil)
                mdTab.window?.layoutIfNeeded()
                print(String(format: "check: readable on: view %.0f pt, inset %.0f pt, column %.1f characters",
                             mdTab.textView.bounds.width, inset(mdTab), columnChars(mdTab)))
                expect(mdTab.readableWidthOn && inset(mdTab) > 100, "the menu turns it on in a Markdown tab", "inset \(inset(mdTab))")
                expect(centred(mdTab), "the column is centred")
                expect(abs(columnChars(mdTab) - 72) < 1, "72 characters wide by default", "\(columnChars(mdTab))")
                let tv = mdTab.textView
                let host = tv.enclosingScrollView?.superview
                let textLeft = host.map { tv.convert(NSPoint(x: tv.textContainerOrigin.x, y: 0), to: $0).x } ?? -1
                expect(abs(mdTab.gutter.frame.maxX - textLeft) < 2 && mdTab.gutter.frame.minX > 30,
                       "line numbers sit just left of the column, not at the window edge",
                       "gutter \(mdTab.gutter.frame) text \(textLeft)")
            },
            { next in snapshot("readable-md.png", window: mdTab.window)(next) },
            sync {
                // The gutter: a wrapped paragraph's first line has its number beside it.
                let tv = mdTab.textView
                let line = 20
                tv.setSelectedRange(NSRange(location: lineStart(mdTab, line), length: 0))
                tv.scrollRangeToVisible(tv.selectedRange())
                mdTab.window?.displayIfNeeded()
                let scrollY = mdTab.scrollView.contentView.bounds.minY
                if let mid = mdTab.caretLineMidY(tv) {
                    let g = mdTab.gutter.line(atY: mid - scrollY)
                    expect(g == line, "the gutter's line number lines up with its text", "gutter \(String(describing: g)) for \(line)")
                } else { expect(false, "caret line found") }
                // Typing doesn't move the column.
                let before = inset(mdTab)
                if let w = mdTab.window { for ch in "typed " { TypingCheck.key(w, String(ch)) } }
                expect(inset(mdTab) == before && mdTab.text.contains("typed Paragraph 10"), "typing leaves the column where it is")
            },
            sync {
                // A narrower window: centred again.
                mdTab.window?.setContentSize(NSSize(width: 820, height: 720))
                mdTab.window?.layoutIfNeeded()
                expect(centred(mdTab) && inset(mdTab) > 4 && inset(mdTab) < 200, "a narrower window re-centres the column", "inset \(inset(mdTab))")
                sized(mdTab)
                mdTab.window?.layoutIfNeeded()
                // Typewriter Scrolling and Focus in the column.
                mdTab.setWriting(WritingModeState(typewriter: true, focus: true))
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                guard let w = mdTab.window else { return }
                let tv = mdTab.textView
                tv.setSelectedRange(NSRange(location: lineStart(mdTab, 60), length: 0))
                for ch in "more " { TypingCheck.key(w, String(ch)) }
                w.displayIfNeeded()
                let b = mdTab.scrollView.contentView.bounds
                let mid = mdTab.caretLineMidY(tv)
                let off = mid.map { $0 - b.midY } ?? .infinity
                expect(abs(off) <= lineHeight, "Typewriter Scrolling keeps the caret line at the middle", String(format: "%.1f pt off", off))
                expect(!mdTab.editing.focusDimmed.isEmpty, "Focus dims around the caret's paragraph")
                expect(centred(mdTab), "still centred with Writing Mode on")
            },
            { next in snapshot("readable-writing.png", window: mdTab.window)(next) },
            sync {
                mdTab.setWriting(WritingModeState())
                focus(mdTab)
                app.toggleReadableWidthMenu(nil)
                expect(!mdTab.readableWidthOn && inset(mdTab) == 4, "the menu item turns it off for the tab", "inset \(inset(mdTab))")
                app.toggleReadableWidthMenu(nil)
                expect(mdTab.readableWidthOn && centred(mdTab), "and on again")
                Settings.shared.readableColumns = 60
                mdTab.window?.layoutIfNeeded()
                expect(abs(columnChars(mdTab) - 60) < 1 && centred(mdTab), "Settings › Readable width sets the column", "\(columnChars(mdTab))")
                Settings.shared.wrapLines = false
                expect(inset(mdTab) == 4, "off while lines don't wrap", "inset \(inset(mdTab))")
                Settings.shared.wrapLines = true
                expect(centred(mdTab) && inset(mdTab) > 4, "back with Wrap Lines")
                // The menu wrote an explicit choice. The Writing default going off leaves it.
                Settings.shared.readableWidthDefault = false
                mdTab.window?.layoutIfNeeded()
                expect(mdTab.editing.readableWidth == true && mdTab.readableWidthOn && centred(mdTab),
                       "an explicit per-tab choice stays when the Writing default is off")
                let fresh = app.open(write("readable-fresh.md", "fresh\n"))!
                sized(fresh)
                fresh.window?.layoutIfNeeded()
                expect(!fresh.readableWidthOn && inset(fresh) == 4, "a new tab follows the unchecked default", "inset \(inset(fresh))")
                focus(swiftTab)
                app.toggleReadableWidthMenu(nil)
                expect(swiftTab.readableWidthOn && inset(swiftTab) > 4 && centred(swiftTab), "a code tab can turn it on")
                // The machine's settings as they were.
                for (k, v) in [("readableColumns", savedColumns), ("wrapLines", savedWrap), ("readableWidthDefault", savedDefault)] {
                    if let v { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) }
                }
            },
        ]
        steps += steps2
        run(steps)
    }
}
