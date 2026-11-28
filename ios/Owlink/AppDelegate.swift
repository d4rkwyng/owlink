import UIKit
import CedricCore
import CedricAI

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BuiltInSetup.install()
        BuiltInPreload.ifWanted()
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
        MenuBar.build(builder)
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
