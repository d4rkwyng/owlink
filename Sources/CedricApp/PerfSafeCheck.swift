import AppKit
import CedricCore

/// CEDRIC_CHECK=perfsafe (0.5.4 performance work): what is now cached or
/// skipped gives exactly what building it afresh gives.
/// - The status bar's three pull-downs are built only when the language,
///   encoding, guess, file, line ending or mixed flag changes: a caret
///   move keeps the same menus, equal item for item to a fresh build, and
///   each change builds them again, with the right title and tick.
/// - `baseAttributes()` is cached by font, tab width and text colour, and
///   equals a fresh measure after zoom, a tab width change and a theme
///   change.
/// - `SyntaxColorizer.recolorAll()` makes its whole-text pass on every
///   theme and language change (it is not skipped): switching to Plain
///   Text after colouring lines far down, back to Swift, a theme change
///   and the prose font's appearance pass leave no stale colour anywhere.
///   The prose font is off for the run (then on for one step), through a
///   run-local override: the saved switch is neither read nor written.
@MainActor
extension DevChecks {
    static func perfSafeCheck(_ app: AppDelegate) {
        let body = (0..<600).map { "let value\($0) = \"text\" // note \($0)" }.joined(separator: "\n") + "\n"
        let tab = app.open(write("perf.swift", body))!
        sized(tab)
        let bar = tab.statusBar
        let buttons = [bar.languageButton, bar.encodingButton, bar.lineEndingButton]

        func describe(_ b: NSPopUpButton) -> [String] {
            [b.title] + (b.menu?.items ?? []).map { i in
                "\(i.isSeparatorItem ? "-" : i.title)|\(i.state.rawValue)|\(i.isEnabled)|\(i.representedObject.map { "\($0)" } ?? "nil")|"
                    + "\(i.action.map(NSStringFromSelector) ?? "nil")|\(i.target === tab)"
            }
        }
        /// The menus as shown, then as a fresh build makes them: equal.
        func menusMatchAFreshBuild(_ what: String) {
            let shown = buttons.map(describe)
            tab.forgetStatusAndAttributeCachesForChecks()
            tab.updateStatus()
            let fresh = buttons.map(describe)
            expect(shown == fresh, "\(what): the pull-downs equal a fresh build", "\(zip(shown, fresh).filter { $0 != $1 })")
        }
        func checked(_ b: NSPopUpButton) -> [String] {
            (b.menu?.items ?? []).filter { $0.state == .on }.map { $0.representedObject.map { "\($0)" } ?? $0.title }
        }

        /// What `baseAttributes()` should be, measured afresh.
        func attributesMatchAFreshMeasure(_ what: String) {
            let a = tab.baseAttributes()
            let b = tab.baseAttributes()
            let para = a[.paragraphStyle] as? NSParagraphStyle
            expect((a[.paragraphStyle] as AnyObject) === (b[.paragraphStyle] as AnyObject), "\(what): the attributes are cached")
            let font = tab.editorFont
            let space = (String(repeating: " ", count: tab.tabWidth) as NSString).size(withAttributes: [.font: font]).width
            expect((a[.font] as? NSFont) == font && para?.defaultTabInterval == space && para?.tabStops.isEmpty == true
                   && (a[.foregroundColor] as? NSColor) == NSColor(hex: tab.palette.foreground),
                   "\(what): font, tab interval and text colour as measured afresh",
                   "\(String(describing: a[.font])) \(para?.defaultTabInterval ?? -1) vs \(font) \(space)")
            tab.forgetStatusAndAttributeCachesForChecks()
            let fresh = tab.baseAttributes()
            expect((fresh[.font] as? NSFont) == (a[.font] as? NSFont)
                   && (fresh[.paragraphStyle] as? NSParagraphStyle) == para
                   && (fresh[.foregroundColor] as? NSColor) == (a[.foregroundColor] as? NSColor), "\(what): equal to a fresh build")
        }

        /// Every character's text colour: the theme's text colour on lines
        /// not coloured; on coloured lines that or a token colour of the
        /// current palette.
        func colorsAreCurrent(_ what: String, tokensAllowed: Bool = true) {
            guard let storage = tab.textView.textStorage else { expect(false, what, "no storage"); return }
            let p = tab.palette
            let fg = NSColor(hex: p.foreground)
            let tokenColors = Set(TokenKind.allCases.map { NSColor(hex: p.color(for: $0)) })
            let index = tab.lineIndex
            var bad: [String] = []
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                let c = value as? NSColor
                if c == fg { return }
                let line = index.line(containing: range.location)
                if tokensAllowed, let c, tokenColors.contains(c), tab.colorizer.isColored(line) { return }
                bad.append("line \(line + 1) \(range) \(c.map { "\($0)" } ?? "nil")")
                if bad.count > 3 { stop.pointee = true }
            }
            expect(bad.isEmpty, what, bad.joined(separator: "; "))
        }

        var builds = 0
        var savedFontSize: Any?
        let savedProseSwitch = UserDefaults.standard.object(forKey: "useProseFont") as? NSObject
        let savedProseName = UserDefaults.standard.object(forKey: "proseFontName") as? NSObject
        var themePasses = 0
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                // A prose font in the user's settings must not change what
                // a language switch does here: off for this run, not saved.
                Settings.shared.useProseFontOverride = false
                // Counted before the theme is applied: its pass, not one
                // from opening, is what the next step sees.
                themePasses = tab.colorizer.fullPasses
                TypingCheck.apply(TypingCheck.ThemeCase(name: "light", theme: .light, system: nil))
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // The theme: the whole-text pass runs (text set in the text
                // colour is not a reason to skip it).
                expect(tab.colorizer.fullPasses > themePasses, "the light theme: the whole-text recolour runs",
                       "made \(tab.colorizer.fullPasses - themePasses)")
                expect(!Settings.shared.useProseFont && tab.editorFont == Settings.shared.font,
                       "the prose font is off for the run: the code font", "\(tab.editorFont)")
                expect(tab.colorizer.isColored(0), "…and the viewport is coloured")
                let keyword = tab.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                expect(keyword == NSColor(hex: tab.palette.color(for: .keyword)), "\"let\" in the keyword colour", "\(String(describing: keyword))")
                colorsAreCurrent("open: no stale colour")

                // Caret moves: the same menus, not built again.
                tab.updateStatus()
                builds = tab.statusMenuBuilds
                let before = buttons.map { $0.menu }
                let skips = tab.statusMenuSkips
                for loc in [5, 50, 500, 5_000, 0] { tab.textView.setSelectedRange(NSRange(location: loc, length: 0)) }
                tab.textView.setSelectedRange(NSRange(location: 3, length: 40))
                expect(tab.statusMenuBuilds == builds && tab.statusMenuSkips >= skips + 6, "caret moves don't rebuild the pull-downs",
                       "built \(tab.statusMenuBuilds - builds), skipped \(tab.statusMenuSkips - skips)")
                expect(zip(before, buttons.map { $0.menu }).allSatisfy { $0 != nil && $0 === $1 }, "…the same menus stay")
                expect(bar.position.stringValue == "Ln 1, Col 4", "the position still follows the caret", bar.position.stringValue)
                menusMatchAFreshBuild("after caret moves")
                expect(checked(bar.languageButton) == [Language.swift.rawValue] && bar.languageButton.title == tab.doc.languageChoice.displayTitle,
                       "Swift ticked and shown", "\(checked(bar.languageButton)) \(bar.languageButton.title)")

                // A language change builds them again.
                builds = tab.statusMenuBuilds
                tab.setLanguage(.json)
                expect(tab.statusMenuBuilds > builds && checked(bar.languageButton) == [Language.json.rawValue]
                       && bar.languageButton.title == tab.doc.languageChoice.displayTitle, "a language change rebuilds: JSON ticked and shown",
                       "\(checked(bar.languageButton)) \(bar.languageButton.title)")
                menusMatchAFreshBuild("after a language change")
                tab.setLanguage(.swift)

                // An encoding change (and a guess) too.
                builds = tab.statusMenuBuilds
                let encoding = tab.doc.encoding
                tab.doc.encoding = .latin1
                tab.updateStatus()
                expect(tab.statusMenuBuilds > builds && bar.encodingButton.title == TextEncoding.latin1.displayName
                       && checked(bar.encodingButton) == ["save:" + TextEncoding.latin1.rawValue], "an encoding change rebuilds",
                       "\(bar.encodingButton.title) \(checked(bar.encodingButton))")
                menusMatchAFreshBuild("after an encoding change")
                builds = tab.statusMenuBuilds
                tab.doc.encodingGuessed = true
                tab.updateStatus()
                expect(tab.statusMenuBuilds > builds && bar.encodingButton.title == "\(TextEncoding.latin1.shortName) (guessed)",
                       "a guess rebuilds", bar.encodingButton.title)
                tab.doc.encodingGuessed = false
                tab.doc.encoding = encoding
                tab.updateStatus()
                expect(bar.encodingButton.title == encoding.displayName, "and back", bar.encodingButton.title)
                expect(bar.encodingButton.menu?.items.contains { $0.title == "Reopen with Encoding" } == true, "a file: Reopen with Encoding listed")

                // A line ending change, through the pull-down as a click does.
                builds = tab.statusMenuBuilds
                let item = bar.lineEndingButton.menu?.items.first { ($0.representedObject as? String) == LineEnding.crlf.rawValue }
                if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
                expect(tab.statusMenuBuilds > builds && bar.lineEndingButton.title == "CRLF" && checked(bar.lineEndingButton) == [LineEnding.crlf.rawValue],
                       "a line ending change rebuilds: CRLF ticked and shown", "\(bar.lineEndingButton.title) \(checked(bar.lineEndingButton))")
                menusMatchAFreshBuild("after a line ending change")

                // A pull-down's menu replaced from elsewhere: built again.
                bar.languageButton.menu = NSMenu()
                tab.updateStatus()
                expect(checked(bar.languageButton) == [Language.swift.rawValue], "a replaced menu is built again")
                menusMatchAFreshBuild("after a replaced menu")

                // baseAttributes: cached, and equal to a fresh measure.
                attributesMatchAFreshMeasure("open")
                // Zoom for this run only: the saved size is never written.
                savedFontSize = UserDefaults.standard.object(forKey: "fontSize")
                Settings.shared.fontSizeOverride = Settings.shared.fontSize == 20 ? 17 : 20
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                expect(tab.editorFont.pointSize == Settings.shared.fontSizeOverride, "zoomed for this run",
                       "\(tab.editorFont.pointSize)")
                attributesMatchAFreshMeasure("zoomed")
                Settings.shared.fontSizeOverride = nil
                expect(UserDefaults.standard.object(forKey: "fontSize") as? NSObject == savedFontSize as? NSObject,
                       "the saved font size is left as it was", "\(String(describing: UserDefaults.standard.object(forKey: "fontSize")))")
                tab.setIndentation(Indentation(usesTabs: true, width: 7))
                attributesMatchAFreshMeasure("tab width 7")
                tab.setIndentation(Indentation(usesTabs: false, width: 4))
                // Colour lines far down, then come back to the top.
                tab.textView.scrollRangeToVisible(NSRange(location: (tab.text as NSString).length, length: 0))
            },
            waitFor("the end is coloured, in time") { tab.colorizer.isColored(tab.lineIndex.lineCount - 2) },
            sync {
                expect(tab.colorizer.isColored(tab.lineIndex.lineCount - 2), "the end was coloured")
                // The last line's "let" really is in the keyword colour, so
                // Plain Text below has a distant token colour to undo.
                let last = tab.lineIndex.contentRange(ofLine: tab.lineIndex.lineCount - 2)
                let lastLine = (tab.text as NSString).substring(with: last)
                let distant = tab.textView.textStorage?.attribute(.foregroundColor, at: last.location, effectiveRange: nil) as? NSColor
                expect(lastLine.hasPrefix("let value599") && distant == NSColor(hex: tab.palette.color(for: .keyword))
                       && distant != NSColor(hex: tab.palette.foreground),
                       "the last line's \"let\" is in the keyword colour", "\(lastLine.prefix(14)) \(String(describing: distant))")
                // Scrolled to the very top, not only until line 1 shows.
                if let clip = tab.textView.enclosingScrollView?.contentView {
                    clip.scroll(to: .zero)
                    tab.textView.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            },
            // Line 1 stayed coloured from before: wait for the viewport
            // itself to be back at the top too.
            waitFor("back at the top, coloured, in time") { tab.textView.visibleRect.minY < 1 && tab.colorizer.isColored(0) },
        ]
        steps += steps3
        let steps4: [Step] = [
            sync {
                expect(tab.textView.visibleRect.minY < 1, "back at the top", "\(tab.textView.visibleRect)")
                var made = tab.colorizer.fullPasses
                tab.setLanguage(.plain)
                expect(tab.colorizer.fullPasses == made + 1, "Plain Text after colouring: the whole-text pass runs",
                       "\(tab.colorizer.fullPasses - made)")
                colorsAreCurrent("Plain Text: every character in the text colour, the end too", tokensAllowed: false)
                made = tab.colorizer.fullPasses
                tab.setLanguage(.swift)
                expect(tab.colorizer.fullPasses == made + 1, "Swift again over plain text: the whole-text pass runs, once",
                       "\(tab.colorizer.fullPasses - made)")
                let keyword = tab.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                expect(keyword == NSColor(hex: tab.palette.color(for: .keyword)), "Swift again: \"let\" coloured")
                colorsAreCurrent("Swift again: no stale colour")

                // The prose font on (for this step only), in a font other
                // than the code font: Plain Text takes it, so the language
                // pass and the appearance (font) pass both run, and neither
                // leaves a stale colour; Swift again takes the code font
                // back, with both passes again.
                Settings.shared.proseFontNameOverride = ProseFont.systemSerif
                if Settings.shared.proseFont.fontName == Settings.shared.font.fontName {
                    Settings.shared.proseFontNameOverride = "Helvetica"
                }
                Settings.shared.useProseFontOverride = true
                made = tab.colorizer.fullPasses
                tab.setLanguage(.plain)
                let prose = Settings.shared.font(for: .plain)
                expect(prose == Settings.shared.proseFont && prose.fontName != Settings.shared.font.fontName,
                       "the prose font differs from the code font", "\(prose.fontName) vs \(Settings.shared.font.fontName)")
                expect(tab.editorFont == prose && tab.textView.font == prose
                       && (tab.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == prose,
                       "the prose font on: Plain Text in it", "\(String(describing: tab.textView.font)) vs \(prose)")
                expect(tab.colorizer.fullPasses == made + 2, "the prose font's Plain Text: the language and appearance passes run",
                       "\(tab.colorizer.fullPasses - made)")
                colorsAreCurrent("the prose font's Plain Text: every character in the text colour", tokensAllowed: false)
                attributesMatchAFreshMeasure("the prose font")
                made = tab.colorizer.fullPasses
                tab.setLanguage(.swift)
                expect(tab.editorFont == Settings.shared.font && tab.textView.font == Settings.shared.font,
                       "the prose font on: Swift in the code font", "\(String(describing: tab.textView.font))")
                expect(tab.colorizer.fullPasses == made + 2, "the prose font's Swift: the language and appearance passes run",
                       "\(tab.colorizer.fullPasses - made)")
                let proseKeyword = tab.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                expect(proseKeyword == NSColor(hex: tab.palette.color(for: .keyword)), "the prose font's Swift: \"let\" coloured")
                colorsAreCurrent("the prose font's Swift: no stale colour")
                Settings.shared.useProseFontOverride = false
                Settings.shared.proseFontNameOverride = nil
                expect(UserDefaults.standard.object(forKey: "proseFontName") as? NSObject == savedProseName,
                       "the saved prose font is left as it was",
                       "\(String(describing: UserDefaults.standard.object(forKey: "proseFontName")))")
                expect(UserDefaults.standard.object(forKey: "useProseFont") as? NSObject == savedProseSwitch,
                       "the saved prose font switch is left as it was",
                       "\(String(describing: UserDefaults.standard.object(forKey: "useProseFont")))")
                TypingCheck.apply(TypingCheck.ThemeCase(name: "dracula", theme: .dracula, system: nil))
            },
        ]
        steps += steps4
        let steps5: [Step] = [
            waitFor("the theme change reaches the tab, in time") {
                tab.palette.name.lowercased().contains("dracula")
                    && (tab.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                        == NSColor(hex: tab.palette.color(for: .keyword))
            },
            sync {
                let p = tab.palette
                expect(p.name.lowercased().contains("dracula"), "the theme changed", p.name)
                colorsAreCurrent("a theme change: every character in the new theme's colours")
                let keyword = tab.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                expect(keyword == NSColor(hex: p.color(for: .keyword)), "\"let\" in the new keyword colour")
                attributesMatchAFreshMeasure("a theme change")
                // Marked text: no pass at all (as before), then one.
                let made = tab.colorizer.fullPasses
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                tab.textView.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                tab.colorizer.recolorAll()
                expect(tab.colorizer.fullPasses == made, "under marked text: no whole-text pass")
                tab.textView.unmarkText()
                tab.undoManager?.undo()
            },
            // (The committed "ka" stays: the edit has settled once the index
            // matches the storage and the viewport is coloured again.)
            waitFor("the marked text committed and settled, in time") {
                !tab.textView.hasMarkedText() && tab.lineIndex.length == (tab.textView.textStorage?.length ?? -1)
                    && tab.colorizer.isColored(0)
            },
            sync {
                let made = tab.colorizer.fullPasses
                tab.colorizer.recolorAll()
                expect(tab.colorizer.fullPasses == made + 1, "after marked text: the whole-text pass runs again")
                colorsAreCurrent("after marked text: no stale colour")
                TypingCheck.apply(TypingCheck.ThemeCase(name: "light", theme: .light, system: nil))
                Settings.shared.useProseFontOverride = nil
                expect(UserDefaults.standard.object(forKey: "useProseFont") as? NSObject == savedProseSwitch,
                       "the end: the saved prose font switch is left as it was")
                tab.doc.markSaved()
            },
        ]
        steps += steps5
        run(steps)
    }
}
