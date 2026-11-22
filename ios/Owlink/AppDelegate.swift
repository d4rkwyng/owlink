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
            for k in [AppSettings.Key.fontSize, AppSettings.Key.wrap, AppSettings.Key.lineNumbers, AppSettings.Key.showContextBar, AppSettings.Key.owlHints, AppSettings.Key.theme,
                      AppSettings.Key.saveAutomatically, AppSettings.Key.openReadOnly,
                      AppSettings.Key.owlPlacement, AppSettings.Key.owlManualPlacement] {
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
        let tools = UIMenu(title: String(localized: "Text Tools"), children: [
            UICommand(title: String(localized: "Explain Regex"), action: #selector(EditorViewController.explainRegex)),
            UICommand(title: String(localized: "Decode Selection"), action: #selector(EditorViewController.decodeSelection)),
            UICommand(title: String(localized: "Find TODOs"), action: #selector(EditorViewController.findTodos)),
        ])
        builder.insertChild(tools, atEndOfMenu: .edit)

        let preview = UIKeyCommand(title: String(localized: "Markdown Preview"), action: #selector(EditorViewController.togglePreview),
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
        let statistics = UICommand(title: String(localized: "Show Statistics"), action: #selector(EditorViewController.showStatistics))
        builder.insertChild(UIMenu(options: .displayInline, children: [preview, focus, detach, bigger, bigger2, smaller, actual, wrap, contextBar, statistics]), atStartOfMenu: .view)

        func key(_ title: String, _ action: Selector, _ input: String, _ modifiers: UIKeyModifierFlags = .command) -> UIKeyCommand {
            UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        }
        func command(_ title: String, _ action: Selector) -> UICommand { UICommand(title: title, action: action) }
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
        let explain = UIKeyCommand(title: String(localized: "Explain Selection"), action: #selector(EditorViewController.explainSelection),
                                   input: "e", modifierFlags: [.command, .alternate])
        let rewrite = UIKeyCommand(title: String(localized: "Rewrite Selection"), action: #selector(EditorViewController.rewriteSelection),
                                   input: "e", modifierFlags: [.command, .alternate, .shift])
        let settings = UIKeyCommand(title: String(localized: "Settings…"), action: #selector(EditorViewController.showSettings),
                                    input: ",", modifierFlags: .command)
        builder.insertSibling(UIMenu(title: "Cedric", children: [ask, explain, rewrite, check, settings]), afterMenu: .view)
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
