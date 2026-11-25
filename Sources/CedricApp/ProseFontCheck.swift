import AppKit
import CedricCore

/// Part of CEDRIC_CHECK=settings: Settings › Writing's prose font (0.4.1,
/// UX review #9). Off by default (a Markdown tab keeps the monospaced
/// font); the checkbox turns it on for Markdown and plain text only;
/// the font popup and the size field apply at once; zoom scales it; a
/// language change switches fonts; line numbers, folding, Readable Width,
/// Typewriter Scrolling and Focus keep working with it; a large document
/// stays monospaced. Snapshots:
/// settings-writing-prose.png, prose-font-editor.png.
@MainActor
extension DevChecks {
    static func proseFontSteps(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        let restore = keepDefaults(["useProseFont", "proseFontName", "proseFontSize", "fontSize"])
        var s: SettingsWindowController? { SettingsWindowController.shared }
        let paragraphs = (1...12).map { "Paragraph \($0). The quick brown fox jumps over the lazy dog, and then it rests a while in the shade." }
        let text = "# Notes\n\n" + paragraphs.prefix(6).joined(separator: "\n\n") + "\n\n## More\n\n" + paragraphs.dropFirst(6).joined(separator: "\n\n") + "\n"
        let prose = app.open(write("prose.md", text))!
        let code = app.open(write("prose.swift", "func f() {\n    let x = 1\n}\n"))!
        let plain = app.open(write("prose.txt", "Plain words here.\n"))!
        for t in [prose, code, plain] { sized(t) }
        func isMono(_ t: EditorWindowController) -> Bool { t.textView.font?.isFixedPitch == true }
        func storageFont(_ t: EditorWindowController) -> NSFont? { t.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                let d = UserDefaults.standard
                for k in ["useProseFont", "proseFontName", "proseFontSize"] { d.removeObject(forKey: k) }
                Settings.shared.fontSize = Settings.defaultFontSize
                guard let s else { expect(false, "Settings is open"); return }
                s.select(.writing)
                s.refresh()
                expect(!Settings.shared.useProseFont && s.useProseFont.state == .off, "prose font: off by default")
                expect(!s.proseFontPopup.isEnabled && !s.proseFontSize.isEnabled, "its font and size are disabled while off")
                expect(isMono(prose) && prose.textView.font == Settings.shared.font, "off: a Markdown tab keeps the monospaced editor font",
                       prose.textView.font?.fontName ?? "-")
                expect(s.proseFontPopup.itemTitles.count > 20, "the popup lists the installed families", "\(s.proseFontPopup.numberOfItems)")
                expect(s.proseFontPopup.itemTitles.contains("Georgia") || s.proseFontPopup.itemTitles.contains("Helvetica"),
                       "…proportional ones too, not only fixed-pitch")
                s.useProseFont.performClick(nil)
            },
            sync {
                guard let s else { return }
                expect(Settings.shared.useProseFont && s.proseFontPopup.isEnabled, "the checkbox turns it on and enables the popup")
                expect(!isMono(prose) && prose.textView.font?.familyName == NSFont.systemFont(ofSize: 15).familyName,
                       "Markdown tab: the system font by default", prose.textView.font?.fontName ?? "-")
                expect(prose.textView.font?.pointSize == 15, "at 15 pt by default", "\(prose.textView.font?.pointSize ?? 0)")
                expect(storageFont(prose) == prose.textView.font, "the text itself is in it (not only new typing)")
                expect(!isMono(plain), "plain text tab: the prose font too")
                expect(isMono(code) && code.textView.font == Settings.shared.font, "Swift tab: keeps the monospaced font", code.textView.font?.fontName ?? "-")
                // New York: the system serif.
                let ny = s.proseFontPopup.indexOfItem(withRepresentedObject: ProseFont.systemSerif)
                s.proseFontPopup.selectItem(at: ny)
                s.changed(s.proseFontPopup)
                expect(Settings.shared.proseFontName == ProseFont.systemSerif && ["New York", "Serif"].contains { prose.textView.font?.familyName?.contains($0) == true },
                       "New York (System Serif) applies at once", prose.textView.font?.familyName ?? "-")
                if let g = s.proseFontPopup.itemTitles.firstIndex(of: "Georgia") {
                    s.proseFontPopup.selectItem(at: g)
                    s.changed(s.proseFontPopup)
                    expect(prose.textView.font?.familyName == "Georgia" && Settings.shared.proseFontName == prose.textView.font?.fontName,
                           "an installed family (Georgia) applies, saved by its regular face", Settings.shared.proseFontName ?? "nil")
                    s.refresh()
                    expect(s.proseFontPopup.titleOfSelectedItem == "Georgia", "the popup shows the saved family")
                }
                s.proseFontSize.integerValue = 18
                s.changed(s.proseFontSize)
                expect(prose.textView.font?.pointSize == 18 && Settings.shared.proseFontSize == 18, "the size field sets its size",
                       "\(prose.textView.font?.pointSize ?? 0)")
                expect(code.textView.font?.pointSize == Settings.defaultFontSize, "…and not the code font's")
                app.zoomIn(nil)
                expect(prose.textView.font?.pointSize == 19.5 && code.textView.font?.pointSize == 14,
                       "View › Zoom In scales both fonts (18 → 19.5 pt at 108%)", "\(prose.textView.font?.pointSize ?? 0)")
                app.zoomReset(nil)
                expect(prose.textView.font?.pointSize == 18, "Actual Size puts it back")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // Language change: code font in Swift, prose font back in Markdown.
                prose.setLanguage(.swift)
                expect(isMono(prose) && storageFont(prose)?.isFixedPitch == true, "Markdown tab set to Swift: monospaced font")
                prose.setLanguage(.markdown)
                expect(!isMono(prose) && storageFont(prose) == prose.textView.font, "set back to Markdown: the prose font")
                // Large mode keeps the monospaced font (a proportional font slows typing on a huge line).
                let big = app.open(write("prose-big.txt", String(repeating: "word ", count: 6000)))!
                expect(big.isLargeDocument && isMono(big) && storageFont(big)?.isFixedPitch == true,
                       "a large plain-text document keeps the monospaced font", big.textView.font?.fontName ?? "-")
                big.window?.close()
                // Gutter, folding, Readable Width.
                Settings.shared.showLineNumbers = true
                prose.window?.layoutIfNeeded()
                expect(prose.gutter.window != nil && !prose.gutter.isHidden && prose.gutter.frame.width > 20, "line numbers show beside prose",
                       "\(prose.gutter.frame.width)")
                expect(prose.gutter.foldColumn > 0, "the gutter keeps its fold column for Markdown headings")
                focus(prose)
                NSApp.sendAction(#selector(AppDelegate.foldAllMenu(_:)), to: app, from: nil)
                expect((prose.folding?.state.folds.count ?? 0) == 2, "Text › Folding › Fold All folds both headings", "\(prose.folding?.state.folds ?? [])")
                NSApp.sendAction(#selector(AppDelegate.unfoldAllMenu(_:)), to: app, from: nil)
                expect((prose.folding?.state.folds.count ?? 0) == 0, "Unfold All")
                prose.setReadableWidth(true)
                prose.window?.layoutIfNeeded()
                let tv = prose.textView, f = tv.font!
                let chars = ((tv.textContainer?.size.width ?? 0) - 2 * (tv.textContainer?.lineFragmentPadding ?? 0)) / f.readableCharacterWidth
                expect(prose.readableWidthOn && abs(chars - CGFloat(Settings.shared.readableColumns)) < 1.5,
                       "Readable Width: the column holds the setting's characters, by the font's average letter", String(format: "%.1f", chars))
                let zeros = ((tv.textContainer?.size.width ?? 0)) / ("0" as NSString).size(withAttributes: [.font: f]).width
                print(String(format: "check: prose readable column: %.1f average letters, %.1f zeros", chars, zeros))
            },
            sync {
                // Typewriter Scrolling and Focus.
                focus(prose)
                let tv = prose.textView
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                NSApp.sendAction(#selector(AppDelegate.toggleTypewriterMenu(_:)), to: app, from: nil)
                NSApp.sendAction(#selector(AppDelegate.toggleFocusMenu(_:)), to: app, from: nil)
                for _ in 0..<6 { tv.insertText("More prose. ", replacementRange: tv.selectedRange()); tv.insertNewline(nil) }
                prose.window?.layoutIfNeeded()
            },
            sync {
                let tv = prose.textView
                let mid = prose.caretLineMidY(tv) ?? -999
                let off = mid - prose.scrollView.contentView.bounds.midY
                let line = ceil(tv.font!.ascender - tv.font!.descender + tv.font!.leading)
                expect(prose.editing.writing.typewriter && abs(off) <= line, "Typewriter Scrolling keeps the caret line in the middle with the prose font",
                       String(format: "%.1f pt off", off))
                expect(!prose.focusDimmedRanges(in: tv).isEmpty, "Focus dims the other paragraphs")
            },
            { next in snapshot("prose-font-editor.png", window: prose.window)(next) },
            sync { if let s { s.select(.writing); s.window?.makeKeyAndOrderFront(nil) } },
            { next in snapshot("settings-writing-prose.png", window: SettingsWindowController.shared?.window)(next) },
            sync {
                NSApp.sendAction(#selector(AppDelegate.toggleTypewriterMenu(_:)), to: app, from: nil)
                NSApp.sendAction(#selector(AppDelegate.toggleFocusMenu(_:)), to: app, from: nil)
                s?.useProseFont.performClick(nil)
                expect(!Settings.shared.useProseFont && isMono(prose) && storageFont(prose)?.isFixedPitch == true,
                       "turned off: Markdown is monospaced again")
                restore()
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                for t in [prose, code, plain] { t.window?.close() }
            },
        ]
        steps += steps2
        return steps
    }
}
