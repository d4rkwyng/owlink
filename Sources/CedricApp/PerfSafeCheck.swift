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

        var builds = 0
        run([
            sync {
                focus(tab)
                TypingCheck.apply(TypingCheck.ThemeCase(name: "light", theme: .light, system: nil))
            },
            sync {
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
                Settings.shared.fontSize += 3
            },
            sync {
                attributesMatchAFreshMeasure("zoomed")
                Settings.shared.fontSize -= 3
                tab.setIndentation(Indentation(usesTabs: true, width: 7))
                attributesMatchAFreshMeasure("tab width 7")
                tab.setIndentation(Indentation(usesTabs: false, width: 4))
                TypingCheck.apply(TypingCheck.ThemeCase(name: "dracula", theme: .dracula, system: nil))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let p = tab.palette
                expect(p.name.lowercased().contains("dracula"), "the theme changed", p.name)
                attributesMatchAFreshMeasure("a theme change")
                TypingCheck.apply(TypingCheck.ThemeCase(name: "light", theme: .light, system: nil))
                tab.doc.markSaved()
            },
        ])
    }
}
