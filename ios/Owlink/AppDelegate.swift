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
            for k in [AppSettings.Key.fontSize, AppSettings.Key.wrap, AppSettings.Key.lineNumbers, AppSettings.Key.owlHints, AppSettings.Key.theme,
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
        builder.insertChild(UIMenu(options: .displayInline, children: [save, close, window]), atEndOfMenu: .file)

        let goTo = UIKeyCommand(title: String(localized: "Go to Line…"), action: #selector(EditorViewController.goToLine),
                                input: "l", modifierFlags: .command)
        builder.insertChild(UIMenu(options: .displayInline, children: [goTo]), atEndOfMenu: .edit)

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
        builder.insertChild(UIMenu(options: .displayInline, children: [preview, focus, detach, bigger, bigger2, smaller, actual, wrap]), atStartOfMenu: .view)

        let ask = UIKeyCommand(title: String(localized: "Ask Cedric…"), action: #selector(EditorViewController.askCedric),
                               input: "k", modifierFlags: [.command, .shift])
        let check = UIKeyCommand(title: String(localized: "Check with Cedric"), action: #selector(EditorViewController.checkWithCedric),
                                 input: "h", modifierFlags: [.command, .alternate])
        let settings = UIKeyCommand(title: String(localized: "Settings…"), action: #selector(EditorViewController.showSettings),
                                    input: ",", modifierFlags: .command)
        builder.insertSibling(UIMenu(title: "Cedric", children: [ask, check, settings]), afterMenu: .view)
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
