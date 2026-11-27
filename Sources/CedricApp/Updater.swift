import AppKit
import CedricCore

/// Owlink › Check for Updates… and Settings › General › Automatically
/// check for updates: Sparkle 2's SPUStandardUpdaterController
/// (docs/updates.md).
///
/// Sparkle.framework sits in Contents/Frameworks of a release build only
/// (Scripts/bundle-app.sh --release) and, like llama.framework, is loaded
/// with dlopen after the first frame, never linked. A release build carries
/// Owlink's feed and public key (`UpdateConfig`), so it loads Sparkle and,
/// with automatic checks on (Info.plist's SUEnableAutomaticChecks, until the
/// user turns them off), checks about once a day; it always asks before
/// installing (SUAutomaticallyUpdate false). A check build never loads it
/// and sends nothing. Sparkle itself checks the EdDSA signatures
/// (SUPublicEDKey) on the feed (SURequireSignedFeed) and on every update
/// before it installs anything.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    /// What the Info.plist allows; `.disabled(.frameworkMissing)` once a
    /// load has failed.
    private(set) var config: UpdateConfig
    /// The SPUStandardUpdaterController (started as it was created).
    private var controller: NSObject?

    override init() {
        config = UpdateConfig.from(info: Bundle.main.infoDictionary, checksEnabled: DevEnvironment.checksEnabled)
        super.init()
    }

    /// After the first frame: loads Sparkle and creates the controller,
    /// which starts the updater, only when the build is set up for updates.
    /// Sparkle then schedules its automatic check (about once a day) unless
    /// the user turned automatic checks off.
    func startIfConfigured() {
        guard config.isEnabled, controller == nil else { return }
        guard let c = Self.makeController() else {
            config = .disabled(.frameworkMissing)
            return
        }
        controller = c
    }

    var canCheck: Bool {
        guard config.isEnabled, let updater = controller?.value(forKey: "updater") as? NSObject else { return false }
        return updater.value(forKey: "canCheckForUpdates") as? Bool ?? false
    }

    func checkForUpdates() {
        guard canCheck, let c = controller else { NSSound.beep(); return }
        c.perform(NSSelectorFromString("checkForUpdates:"), with: nil)
    }

    /// Automatically check for updates: Sparkle's own setting (its user
    /// default, SUEnableAutomaticChecks, which falls back to Info.plist's
    /// true). Shown off and unchangeable while the updater is off (a check
    /// build), and nothing is written to the user's defaults then.
    var automaticallyChecks: Bool {
        get {
            guard config.isEnabled else { return false }
            if let updater = controller?.value(forKey: "updater") as? NSObject {
                return updater.value(forKey: "automaticallyChecksForUpdates") as? Bool ?? false
            }
            if let chosen = UserDefaults.standard.object(forKey: UpdateConfig.automaticChecksKey) as? Bool { return chosen }
            return Bundle.main.object(forInfoDictionaryKey: UpdateConfig.automaticChecksKey) as? Bool ?? false
        }
        set {
            guard config.isEnabled, let updater = controller?.value(forKey: "updater") as? NSObject else { return }
            updater.setValue(newValue, forKey: "automaticallyChecksForUpdates")
        }
    }

    /// The menu item's state: enabled only while Sparkle can check, else a
    /// tooltip saying why not.
    func validate(_ item: NSMenuItem) -> Bool {
        let ok = canCheck
        item.toolTip = ok ? nil : (config.tooltip ?? String(localized: "Owlink is already checking for updates."))
        return ok
    }

    /// Sparkle.framework from Contents/Frameworks, and a new
    /// SPUStandardUpdaterController, or nil. This initializer starts the
    /// updater itself (SPUStandardUpdaterController.h in Sparkle 2.10.1:
    /// "The updater is started automatically"), so nothing calls
    /// -startUpdater again.
    private static func makeController() -> NSObject? {
        guard let dir = Bundle.main.privateFrameworksURL else { return nil }
        let binary = dir.appendingPathComponent("Sparkle.framework/Sparkle").path
        guard FileManager.default.fileExists(atPath: binary), dlopen(binary, RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("SPUStandardUpdaterController")
        else { return nil }
        // [[SPUStandardUpdaterController alloc] initWithUpdaterDelegate:nil userDriverDelegate:nil]
        // through the methods' implementations: no Sparkle symbol is linked.
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithUpdaterDelegate:userDriverDelegate:")
        guard let allocMethod = class_getClassMethod(cls, allocSel),
              let initMethod = class_getInstanceMethod(cls, initSel)
        else { return nil }
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Init.self)
        guard let allocated = alloc(cls, allocSel) else { return nil }
        // alloc returns +1, which init consumes; init returns +1.
        return initialize(allocated.takeUnretainedValue(), initSel, nil, nil)?.takeRetainedValue() as? NSObject
    }
}

extension AppDelegate {
    /// Owlink › Check for Updates…
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }
}
