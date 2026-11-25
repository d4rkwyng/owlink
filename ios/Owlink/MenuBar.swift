import UIKit
import CedricCore

/// The iPad menu bar (and the ⌘-hold overlay, and hardware-keyboard
/// shortcuts): what AppDelegate.buildMenu adds to the system's menus,
/// built here so the snapshot tests can check it (AppDelegate itself is
/// not in that target).
enum MenuBar {
    /// Where a menu goes in the system's main menu.
    enum Place: Equatable {
        case startOf(UIMenu.Identifier), endOf(UIMenu.Identifier), after(UIMenu.Identifier)
        /// In place of the menu itself (`replace(menu:with:)`), not only
        /// its children: nothing of the system's menu (its own command,
        /// its ⌘,) is left behind.
        case replacing(UIMenu.Identifier)
    }

    struct Insertion {
        let menu: UIMenu
        let place: Place
    }

    /// What `build` does to the system's menus: `UIMenuBuilder`'s calls,
    /// behind a protocol so the snapshot tests can record them.
    @MainActor protocol Editing {
        func menu(for identifier: UIMenu.Identifier) -> UIMenu?
        func remove(menu identifier: UIMenu.Identifier)
        func insertChild(_ menu: UIMenu, atStartOfMenu identifier: UIMenu.Identifier)
        func insertChild(_ menu: UIMenu, atEndOfMenu identifier: UIMenu.Identifier)
        func insertSibling(_ menu: UIMenu, afterMenu identifier: UIMenu.Identifier)
        func replace(menu identifier: UIMenu.Identifier, with menu: UIMenu)
    }

    /// The app's own builder.
    @MainActor struct BuilderEditing: Editing {
        let builder: any UIMenuBuilder
        func menu(for identifier: UIMenu.Identifier) -> UIMenu? { builder.menu(for: identifier) }
        func remove(menu identifier: UIMenu.Identifier) { builder.remove(menu: identifier) }
        func insertChild(_ menu: UIMenu, atStartOfMenu identifier: UIMenu.Identifier) { builder.insertChild(menu, atStartOfMenu: identifier) }
        func insertChild(_ menu: UIMenu, atEndOfMenu identifier: UIMenu.Identifier) { builder.insertChild(menu, atEndOfMenu: identifier) }
        func insertSibling(_ menu: UIMenu, afterMenu identifier: UIMenu.Identifier) { builder.insertSibling(menu, afterMenu: identifier) }
        func replace(menu identifier: UIMenu.Identifier, with menu: UIMenu) { builder.replace(menu: identifier, with: menu) }
    }

    /// Owlink's Settings… menu, in place of the app menu's `.preferences`.
    static let settingsMenuIdentifier = UIMenu.Identifier("net.cyduck.owlink.settings")

    /// The app menu's `.preferences` was seen and replaced by Owlink's
    /// Settings…: no more rebuilds are asked for on its account.
    @MainActor private(set) static var appSettingsReplaced = false
    /// Rebuilds asked for so far because the app menu had no Settings…
    /// item yet. Each build that still finds none asks for another (and
    /// a scene becoming active asks too), until one finds it or this
    /// reaches `maxAppSettingsRebuilds`: on a system that never adds the
    /// item, Settings… stays in the Cedric menu and the asking stops.
    @MainActor private(set) static var appSettingsRebuilds = 0
    /// The cap on those rebuilds (with `rebuildDelay`'s back-off, about a
    /// minute of trying).
    static let maxAppSettingsRebuilds = 12
    /// How long after build `attempt` (1, 2, …) the next one is asked
    /// for: a quarter second, doubling, at most eight seconds. Not the
    /// next main-queue turn: the system's item may come later than that.
    static func rebuildDelay(attempt: Int) -> TimeInterval {
        min(0.25 * pow(2, Double(max(attempt, 1) - 1)), 8)
    }
    /// Asks UIKit for a rebuild, `attempt` being its number (the tests
    /// record instead).
    @MainActor static var requestRebuild: @MainActor (_ attempt: Int) -> Void = { attempt in
        DispatchQueue.main.asyncAfter(deadline: .now() + rebuildDelay(attempt: attempt)) {
            MainActor.assumeIsolated { UIMenuSystem.main.setNeedsRebuild() }
        }
    }

    /// Asks for one more rebuild if `.preferences` hasn't been replaced
    /// yet and the cap isn't reached.
    @MainActor private static func rebuildForAppSettingsIfNeeded() {
        guard !appSettingsReplaced, appSettingsRebuilds < maxAppSettingsRebuilds else { return }
        appSettingsRebuilds += 1
        requestRebuild(appSettingsRebuilds)
    }

    /// A scene became active: a later point in the app's life at which
    /// the system's app menu may have its Settings… item by now. Asks for
    /// a rebuild if it still hasn't been replaced (within the same cap).
    @MainActor static func sceneDidActivate() {
        rebuildForAppSettingsIfNeeded()
    }

    @MainActor static func build(_ builder: any UIMenuBuilder) {
        apply(to: BuilderEditing(builder: builder))
    }

    /// 0.5.2 (18): ⌘, over Ask Cedric's sheet opened the system Settings
    /// app on a second launch. The recording shows the system Settings
    /// app coming up; it does not show when the app menu's `.preferences`
    /// ("Owlink Settings…", ⌘,) appeared, nor that it was the item that
    /// took ⌘, — replacing its children may already have been enough if
    /// the system's command was one of them. The likely cause, from the
    /// code: `hasAppSettings` was read once, so a menu built before the
    /// system added `.preferences` never put our ⌘, in its place. Now
    /// `.preferences` is replaced whole whenever a build finds it, and
    /// while no build has found it, builds are asked for again (with a
    /// back-off, and when a scene becomes active, up to a cap) until one
    /// finds and replaces it. (The responders' ⌘, — `settingsKey()` —
    /// is the other half, and stays whatever the menu does.)
    @MainActor static func apply(to builder: some Editing) {
        let hasAppSettings = builder.menu(for: .preferences) != nil
        let all = insertions(hasFind: builder.menu(for: .find) != nil, hasSpelling: builder.menu(for: .spelling) != nil,
                             hasAppSettings: hasAppSettings)
        // Owlink's own Format menu (Markdown) replaces the system's.
        builder.remove(menu: .format)
        for i in all {
            switch i.place {
            case .startOf(let id): builder.insertChild(i.menu, atStartOfMenu: id)
            case .endOf(let id): builder.insertChild(i.menu, atEndOfMenu: id)
            case .after(let id): builder.insertSibling(i.menu, afterMenu: id)
            case .replacing(let id): builder.replace(menu: id, with: i.menu)
            }
        }
        if hasAppSettings {
            appSettingsReplaced = true
        } else {
            rebuildForAppSettingsIfNeeded()
        }
    }

    /// For the tests: as at launch, nothing replaced, no rebuild asked for.
    @MainActor static func resetRebuildForTesting() {
        appSettingsReplaced = false
        appSettingsRebuilds = 0
    }

    /// ⌘, for the responders that stay in the chain whatever has the keys
    /// (the editor's navigation controller, Ask Cedric's sheet): Owlink's
    /// Settings, ahead of the system's ⌘, (the system Settings app). No
    /// title, so it is not listed a second time next to the menu's.
    @MainActor static func settingsKey() -> UIKeyCommand {
        let key = UIKeyCommand(input: ",", modifierFlags: .command, action: #selector(EditorViewController.showSettings))
        key.wantsPriorityOverSystemBehavior = true
        return key
    }

    /// In the order they are applied. `hasFind` / `hasSpelling`: the
    /// system's Edit › Find and Edit › Spelling menus exist.
    /// `hasAppSettings`: the app menu has the system's Settings… item.
    static func insertions(hasFind: Bool, hasSpelling: Bool, hasAppSettings: Bool = false) -> [Insertion] {
        var out: [Insertion] = []
        let save = UIKeyCommand(title: String(localized: "Save"), action: #selector(EditorViewController.saveDocument),
                                input: "s", modifierFlags: .command)
        let close = UIKeyCommand(title: String(localized: "Close"), action: #selector(EditorViewController.closeDocument),
                                 input: "w", modifierFlags: .command)
        let window = UIKeyCommand(title: String(localized: "New Window"), action: #selector(EditorViewController.newWindow),
                                  input: "n", modifierFlags: [.command, .alternate])
        let print = UICommand(title: String(localized: "Print…"), action: #selector(EditorViewController.printDocument))
        let exportHTML = UICommand(title: String(localized: "Export as HTML…"), action: #selector(EditorViewController.exportHTMLDocument))
        let exportPDF = UICommand(title: String(localized: "Export as PDF…"), action: #selector(EditorViewController.exportPDFDocument))
        out.append(Insertion(menu: UIMenu(options: .displayInline, children: [save, print, exportHTML, exportPDF, close, window]), place: .endOf(.file)))

        let goTo = UIKeyCommand(title: String(localized: "Go to Line…"), action: #selector(EditorViewController.goToLine),
                                input: "l", modifierFlags: .command)
        out.append(Insertion(menu: UIMenu(options: .displayInline, children: [goTo]), place: .endOf(.edit)))
        // Mark All / Clear Marks, with the Mac's shortcuts, in Edit › Find.
        let marks = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: String(localized: "Mark All"), action: #selector(EditorViewController.markAll),
                         input: "m", modifierFlags: [.control, .command]),
            UIKeyCommand(title: String(localized: "Clear Marks"), action: #selector(EditorViewController.clearMarks),
                         input: "m", modifierFlags: [.control, .command, .shift]),
        ])
        if hasFind {
            out.append(Insertion(menu: marks, place: .endOf(.find)))
        } else {
            out.append(Insertion(menu: marks, place: .endOf(.edit)))
        }
        let copyHTML = UICommand(title: String(localized: "Copy as HTML"), action: #selector(EditorViewController.copyAsHTML))
        let copyRich = UICommand(title: String(localized: "Copy as Rich Text"), action: #selector(EditorViewController.copyAsRichText))
        let tools = UIMenu(title: String(localized: "Text Tools"), children: [
            UICommand(title: String(localized: "Explain Regex"), action: #selector(EditorViewController.explainRegex)),
            UICommand(title: String(localized: "Decode Selection"), action: #selector(EditorViewController.decodeSelection)),
            UICommand(title: String(localized: "Find TODOs"), action: #selector(EditorViewController.findTodos)),
        ])
        out.append(Insertion(menu: tools, place: .endOf(.edit)))
        out.append(Insertion(menu: UIMenu(options: .displayInline, children: [copyHTML, copyRich]), place: .endOf(.edit)))
        // Edit › Spelling and Grammar: Fix Typos… (⌥⌘;) and the Mac's two settings (checkmarks via validate).
        let proofing = [
            UIKeyCommand(title: String(localized: "Fix Typos…"), action: #selector(EditorViewController.fixTypos),
                         input: ";", modifierFlags: [.command, .alternate]),
            UICommand(title: String(localized: "Check Spelling While Typing"), action: #selector(EditorViewController.toggleCheckSpelling)),
            UICommand(title: String(localized: "Check Grammar in Prose"), action: #selector(EditorViewController.toggleCheckGrammar)),
        ]
        if hasSpelling {
            out.append(Insertion(menu: UIMenu(options: .displayInline, children: proofing), place: .endOf(.spelling)))
        } else {
            out.append(Insertion(menu: UIMenu(title: String(localized: "Spelling and Grammar"), children: proofing), place: .endOf(.edit)))
        }

        let preview = UIKeyCommand(title: String(localized: "Preview"), action: #selector(EditorViewController.togglePreview),
                                   input: "p", modifierFlags: [.command, .shift])
        let focus = UIKeyCommand(title: String(localized: "Focus Preview"), action: #selector(EditorViewController.toggleFocusPreview),
                                 input: "p", modifierFlags: [.command, .alternate])
        let bigger = UIKeyCommand(title: String(localized: "Bigger"), action: #selector(EditorViewController.biggerFont),
                                  input: "+", modifierFlags: .command)
        let bigger2 = UIKeyCommand(title: String(localized: "Bigger"), action: #selector(EditorViewController.biggerFont),
                                   input: "=", modifierFlags: .command, propertyList: "=")
        bigger2.attributes = .hidden
        let smaller = UIKeyCommand(title: String(localized: "Smaller"), action: #selector(EditorViewController.smallerFont),
                                   input: "-", modifierFlags: .command)
        let actual = UIKeyCommand(title: String(localized: "Actual Size"), action: #selector(EditorViewController.actualSizeFont),
                                  input: "0", modifierFlags: .command)
        let wrap = UIKeyCommand(title: String(localized: "Wrap Lines"), action: #selector(EditorViewController.toggleWrap),
                                input: "w", modifierFlags: [.command, .alternate])
        let detach = UICommand(title: String(localized: "Open Preview in New Window"),
                               action: #selector(EditorViewController.openPreviewInNewWindow))
        let contextBar = UICommand(title: AppSettings.showContextBar ? String(localized: "Hide Context Bar") : String(localized: "Show Context Bar"),
                                   action: #selector(EditorViewController.toggleContextBarMenu))
        let invisibles = UICommand(title: AppSettings.showInvisibles ? String(localized: "Hide Invisibles") : String(localized: "Show Invisibles"),
                                   action: #selector(EditorViewController.toggleInvisibles))
        let statistics = UICommand(title: String(localized: "Show Statistics"), action: #selector(EditorViewController.showStatistics))
        out.append(Insertion(menu: UIMenu(options: .displayInline, children: [preview, focus, detach, bigger, bigger2, smaller, actual, wrap, invisibles, contextBar, statistics]), place: .startOf(.view)))
        let writing = UIMenu(title: String(localized: "Writing Mode"), children: [
            UICommand(title: String(localized: "Typewriter Scrolling"), action: #selector(EditorViewController.toggleTypewriter)),
            UICommand(title: String(localized: "Focus"), action: #selector(EditorViewController.toggleWritingFocus)),
            UIMenu(options: .displayInline, children: [
                UICommand(title: String(localized: "Focus on Paragraph"), action: #selector(EditorViewController.focusParagraph)),
                UICommand(title: String(localized: "Focus on Sentence"), action: #selector(EditorViewController.focusSentence)),
            ]),
        ])
        out.append(Insertion(menu: writing, place: .endOf(.view)))

        func key(_ title: String, _ action: Selector, _ input: String, _ modifiers: UIKeyModifierFlags = .command) -> UIKeyCommand {
            UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        }
        func command(_ title: String, _ action: Selector) -> UICommand { UICommand(title: title, action: action) }
        let line = UIMenu(title: String(localized: "Line"), children: [
            key(String(localized: "Duplicate Line"), #selector(EditorViewController.duplicateLine(_:)), "d", [.command, .shift]),
            key(String(localized: "Move Line Up"), #selector(EditorViewController.moveLineUp(_:)), UIKeyCommand.inputUpArrow, [.control, .command]),
            key(String(localized: "Move Line Down"), #selector(EditorViewController.moveLineDown(_:)), UIKeyCommand.inputDownArrow, [.control, .command]),
            key(String(localized: "Delete Line"), #selector(EditorViewController.deleteLine(_:)), "k", [.command, .shift]),
            key(String(localized: "Comment Selection"), #selector(EditorViewController.commentSelection(_:)), "/"),
            key(String(localized: "Indent"), #selector(EditorViewController.indentLines(_:)), "]"),
            key(String(localized: "Outdent"), #selector(EditorViewController.outdentLines(_:)), "["),
            command(String(localized: "Keep Lines Matching…"), #selector(EditorViewController.keepLinesMatching(_:))),
            command(String(localized: "Delete Lines Matching…"), #selector(EditorViewController.deleteLinesMatching(_:))),
        ])
        let indentation = UIMenu(title: String(localized: "Indentation"), children: [
            UIMenu(options: .displayInline, children: [
                command(String(localized: "Indent Using Spaces"), #selector(EditorViewController.indentUsingSpaces(_:))),
                command(String(localized: "Indent Using Tabs"), #selector(EditorViewController.indentUsingTabs(_:))),
            ]),
            UIMenu(options: .displayInline, children: Indentation.widths.map { width in
                UICommand(title: String(localized: "Tab Width: \(width)"), action: #selector(EditorViewController.tabWidthMenu(_:)),
                          propertyList: width)
            }),
            command(String(localized: "Convert Indentation to Spaces"), #selector(EditorViewController.convertIndentationToSpaces(_:))),
            command(String(localized: "Convert Indentation to Tabs"), #selector(EditorViewController.convertIndentationToTabs(_:))),
        ])
        // F2 is the function key's input character (NSF2FunctionKey on the
        // Mac); UIKit has no named constant for it.
        let f2 = "\u{F705}"
        let bookmarks = UIMenu(title: String(localized: "Bookmarks"), children: [
            key(String(localized: "Bookmark Line"), #selector(EditorViewController.toggleBookmarkMenu(_:)), f2, .command),
            key(String(localized: "Next Bookmark"), #selector(EditorViewController.nextBookmarkMenu(_:)), f2, []),
            key(String(localized: "Previous Bookmark"), #selector(EditorViewController.previousBookmarkMenu(_:)), f2, .shift),
            key(String(localized: "Clear Bookmarks"), #selector(EditorViewController.clearBookmarksMenu(_:)), f2, [.command, .shift]),
        ])
        // The Mac's shortcuts: ⌥⌘← / ⌥⌘→, with ⇧ for all.
        let left = UIKeyCommand.inputLeftArrow, right = UIKeyCommand.inputRightArrow
        let folding = UIMenu(title: String(localized: "Folding"), children: [
            key(String(localized: "Fold"), #selector(EditorViewController.foldMenu(_:)), left, [.command, .alternate]),
            key(String(localized: "Unfold"), #selector(EditorViewController.unfoldMenu(_:)), right, [.command, .alternate]),
            key(String(localized: "Fold All"), #selector(EditorViewController.foldAllMenu(_:)), left, [.command, .alternate, .shift]),
            key(String(localized: "Unfold All"), #selector(EditorViewController.unfoldAllMenu(_:)), right, [.command, .alternate, .shift]),
            UIMenu(options: .displayInline, children: (1...3).map { (level: Int) in
                UICommand(title: String(localized: "Fold to Level \(level)"), action: #selector(EditorViewController.foldToLevelMenu(_:)),
                          propertyList: level)
            }),
        ])
        out.append(Insertion(menu: UIMenu(title: String(localized: "Text"), children: [line, indentation, bookmarks, folding]), place: .after(.edit)))
        let markdown = UIMenu(title: String(localized: "Markdown"), children: [
            key(String(localized: "Bold"), #selector(EditorViewController.markdownBoldMenu(_:)), "b"),
            key(String(localized: "Italic"), #selector(EditorViewController.markdownItalicMenu(_:)), "i"),
            key(String(localized: "Strikethrough"), #selector(EditorViewController.markdownStrikethroughMenu(_:)), "x", [.command, .shift]),
            key(String(localized: "Inline Code"), #selector(EditorViewController.markdownCodeMenu(_:)), "`", .control),
            key(String(localized: "Link"), #selector(EditorViewController.markdownLinkMenu(_:)), "k"),
            command(String(localized: "Image Link"), #selector(EditorViewController.markdownImageMenu(_:))),
            command(String(localized: "Body"), #selector(EditorViewController.markdownBodyMenu(_:))),
            key(String(localized: "Heading 1"), #selector(EditorViewController.markdownHeading1Menu(_:)), "1"),
            key(String(localized: "Heading 2"), #selector(EditorViewController.markdownHeading2Menu(_:)), "2"),
            key(String(localized: "Heading 3"), #selector(EditorViewController.markdownHeading3Menu(_:)), "3"),
            command(String(localized: "Bulleted List"), #selector(EditorViewController.markdownBulletListMenu(_:))),
            command(String(localized: "Numbered List"), #selector(EditorViewController.markdownNumberedListMenu(_:))),
            key(String(localized: "Checkbox"), #selector(EditorViewController.toggleCheckboxMenu(_:)), "\r"),
            command(String(localized: "Quote"), #selector(EditorViewController.markdownQuoteMenu(_:))),
            command(String(localized: "Code Block"), #selector(EditorViewController.markdownCodeBlockMenu(_:))),
            command(String(localized: "Insert Table"), #selector(EditorViewController.markdownTableMenu(_:))),
            command(String(localized: "Format Table"), #selector(EditorViewController.formatTableMenu(_:))),
        ])
        out.append(Insertion(menu: UIMenu(title: String(localized: "Format"), children: [markdown]), place: .after(.view)))

        let ask = UIKeyCommand(title: String(localized: "Ask Cedric…"), action: #selector(EditorViewController.askCedric),
                               input: "k", modifierFlags: [.command, .shift])
        let check = UIKeyCommand(title: String(localized: "Check with Cedric"), action: #selector(EditorViewController.checkWithCedric),
                                 input: "h", modifierFlags: [.command, .alternate])
        let checkScript = UICommand(title: String(localized: "Check Script for Risks…"),
                                    action: #selector(EditorViewController.checkScriptForRisks))
        let explain = UIKeyCommand(title: String(localized: "Explain Selection"), action: #selector(EditorViewController.explainSelection),
                                   input: "e", modifierFlags: [.command, .alternate])
        let rewrite = UIKeyCommand(title: String(localized: "Rewrite Selection"), action: #selector(EditorViewController.rewriteSelection),
                                   input: "e", modifierFlags: [.command, .alternate, .shift])
        let settings = UIKeyCommand(title: String(localized: "Settings…"), action: #selector(EditorViewController.showSettings),
                                    input: ",", modifierFlags: .command)
        // ⌘, Settings…: iPadOS's app menu has its own "Owlink Settings…"
        // on ⌘, (orderFrontPreferencesPanel:), which opens Owlink's page in
        // the system Settings app. It took ⌘, over ours, so ⌘, left Owlink. Ours takes its place there (the whole
        // `.preferences` menu, see `apply`), ahead of the system's
        // behavior; without that item (older systems, or a menu built
        // before the system added it: `apply` builds again) it stays in
        // the Cedric menu. Settings… is in the menu bar once either way.
        settings.wantsPriorityOverSystemBehavior = true
        if hasAppSettings {
            out.append(Insertion(menu: UIMenu(title: "Cedric", children: [ask, explain, rewrite, check, checkScript]), place: .after(.view)))
            out.append(Insertion(menu: UIMenu(title: "", identifier: settingsMenuIdentifier, options: .displayInline, children: [settings]),
                                 place: .replacing(.preferences)))
        } else {
            out.append(Insertion(menu: UIMenu(title: "Cedric", children: [ask, explain, rewrite, check, checkScript, settings]), place: .after(.view)))
        }
        return out
    }
}
