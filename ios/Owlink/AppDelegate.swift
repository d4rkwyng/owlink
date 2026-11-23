import UIKit
import CedricCore
import CedricAI

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BuiltInSetup.install()
        // No document is open yet: opened-version copies left by a crash go.
        SaveSafetyStores.revert.clearAll()
        // Safety copies (conflict versions and the like) are kept 7 days.
        let copies = SaveSafetyStores.copies
        DispatchQueue.global(qos: .utility).async { copies.prune() }
        if ProcessInfo.processInfo.arguments.contains("-OwlinkResetSettings") {
            for k in AppSettings.launchResetKeys {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        // "Open Preview in New Window" (or a preview dragged out, or one
        // restored after a relaunch): a preview-only window.
        let route = PreviewWindows.route(activities: options.userActivities.map { ($0.activityType, $0.userInfo) },
                                         sessionUserInfo: session.userInfo)
        if case .preview = route {
            c.delegateClass = PreviewSceneDelegate.self
        } else {
            c.delegateClass = SceneDelegate.self
        }
        return c
    }

    // MARK: Menus (iPad menu bar, ⌘-hold overlay, hardware keyboards)

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let save = UIKeyCommand(title: String(localized: "Save"), action: #selector(EditorViewController.saveDocument),
                                input: "s", modifierFlags: .command)
        let close = UIKeyCommand(title: String(localized: "Close"), action: #selector(EditorViewController.closeDocument),
                                 input: "w", modifierFlags: .command)
        let window = UIKeyCommand(title: String(localized: "New Window"), action: #selector(EditorViewController.newWindow),
                                  input: "n", modifierFlags: [.command, .alternate])
        let print = UICommand(title: String(localized: "Print…"), action: #selector(EditorViewController.printDocument))
        let exportHTML = UICommand(title: String(localized: "Export as HTML…"), action: #selector(EditorViewController.exportHTMLDocument))
        let exportPDF = UICommand(title: String(localized: "Export as PDF…"), action: #selector(EditorViewController.exportPDFDocument))
        builder.insertChild(UIMenu(options: .displayInline, children: [save, print, exportHTML, exportPDF, close, window]), atEndOfMenu: .file)

        let goTo = UIKeyCommand(title: String(localized: "Go to Line…"), action: #selector(EditorViewController.goToLine),
                                input: "l", modifierFlags: .command)
        builder.insertChild(UIMenu(options: .displayInline, children: [goTo]), atEndOfMenu: .edit)
        // Mark All / Clear Marks, with the Mac's shortcuts, in Edit › Find.
        let marks = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: String(localized: "Mark All"), action: #selector(EditorViewController.markAll),
                         input: "m", modifierFlags: [.control, .command]),
            UIKeyCommand(title: String(localized: "Clear Marks"), action: #selector(EditorViewController.clearMarks),
                         input: "m", modifierFlags: [.control, .command, .shift]),
        ])
        if builder.menu(for: .find) != nil {
            builder.insertChild(marks, atEndOfMenu: .find)
        } else {
            builder.insertChild(marks, atEndOfMenu: .edit)
        }
        let copyHTML = UICommand(title: String(localized: "Copy as HTML"), action: #selector(EditorViewController.copyAsHTML))
        let copyRich = UICommand(title: String(localized: "Copy as Rich Text"), action: #selector(EditorViewController.copyAsRichText))
        let tools = UIMenu(title: String(localized: "Text Tools"), children: [
            UICommand(title: String(localized: "Explain Regex"), action: #selector(EditorViewController.explainRegex)),
            UICommand(title: String(localized: "Decode Selection"), action: #selector(EditorViewController.decodeSelection)),
            UICommand(title: String(localized: "Find TODOs"), action: #selector(EditorViewController.findTodos)),
        ])
        builder.insertChild(tools, atEndOfMenu: .edit)
        builder.insertChild(UIMenu(options: .displayInline, children: [copyHTML, copyRich]), atEndOfMenu: .edit)
        // Edit › Spelling and Grammar: the Mac's two settings (checkmarks via validate).
        let proofing = [
            UICommand(title: String(localized: "Check Spelling While Typing"), action: #selector(EditorViewController.toggleCheckSpelling)),
            UICommand(title: String(localized: "Check Grammar in Prose"), action: #selector(EditorViewController.toggleCheckGrammar)),
        ]
        if builder.menu(for: .spelling) != nil {
            builder.insertChild(UIMenu(options: .displayInline, children: proofing), atEndOfMenu: .spelling)
        } else {
            builder.insertChild(UIMenu(title: String(localized: "Spelling and Grammar"), children: proofing), atEndOfMenu: .edit)
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
        builder.insertChild(UIMenu(options: .displayInline, children: [preview, focus, detach, bigger, bigger2, smaller, actual, wrap, invisibles, contextBar, statistics]), atStartOfMenu: .view)
        let writing = UIMenu(title: String(localized: "Writing Mode"), children: [
            UICommand(title: String(localized: "Typewriter Scrolling"), action: #selector(EditorViewController.toggleTypewriter)),
            UICommand(title: String(localized: "Focus"), action: #selector(EditorViewController.toggleWritingFocus)),
            UIMenu(options: .displayInline, children: [
                UICommand(title: String(localized: "Focus on Paragraph"), action: #selector(EditorViewController.focusParagraph)),
                UICommand(title: String(localized: "Focus on Sentence"), action: #selector(EditorViewController.focusSentence)),
            ]),
        ])
        builder.insertChild(writing, atEndOfMenu: .view)

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
        builder.insertSibling(UIMenu(title: String(localized: "Text"), children: [line, indentation, bookmarks, folding]), afterMenu: .edit)
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
        builder.remove(menu: .format)
        builder.insertSibling(UIMenu(title: String(localized: "Format"), children: [markdown]), afterMenu: .view)

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
        builder.insertSibling(UIMenu(title: "Cedric", children: [ask, explain, rewrite, check, checkScript, settings]), afterMenu: .view)
    }
}

/// The built-in model engine: llama.cpp is compiled into the app for iOS
/// device builds only (no simulator slice in the pinned XCFramework).
enum BuiltInSetup {
    static func install() {
        #if CEDRIC_BUILTIN
        BuiltInPlatform.runtime = LlamaRuntime()
        #endif
    }
}
