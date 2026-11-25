import UIKit
import UniformTypeIdentifiers
import CedricCore

/// One window: the Files-style document browser, which presents an editor
/// for the document picked. Every window (iPad scenes, Stage Manager) has
/// its own browser and editor.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let browser = DocumentBrowserViewController()
        let w = UIWindow(windowScene: ws)
        w.rootViewController = browser
        // Launch opens a file of its own (a URL from another app,
        // `-OwlinkOpen`), or reopens the last document: decided once per
        // process, by the first window whichever it does, so windows
        // opened later start at the browser.
        let openingExplicitFile = !options.urlContexts.isEmpty || TestLaunch.active
        let reopenLast = Self.launchReopen.consider(openingExplicitFile: openingExplicitFile,
                                                    reopenSetting: AppSettings.reopenFilesFromLastSession)
        // Held before the browser shows: its viewDidAppear mustn't offer
        // recovery copies over the document being reopened.
        if reopenLast { RecoveryOffer.reopenStarted() }
        w.makeKeyAndVisible()
        window = w
        ws.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 400)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-OwlinkOrientation"), index + 1 < args.count {
            let orientation: UIInterfaceOrientationMask?
            switch args[index + 1] {
            case "landscape": orientation = .landscape
            case "landscapeLeft": orientation = .landscapeLeft
            case "landscapeRight": orientation = .landscapeRight
            case "portrait": orientation = .portrait
            default:
                NSLog("Invalid -OwlinkOrientation: %@", args[index + 1])
                orientation = nil
            }
            if let orientation {
                DispatchQueue.main.async {
                    ws.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
                        NSLog("Could not set Owlink orientation: %@", error.localizedDescription)
                    }
                }
            }
        } else if args.contains("-OwlinkOrientation") {
            NSLog("Missing value for -OwlinkOrientation")
        }
        // A debug check or preview instead of the browser: no offer, and
        // no reopen, so the hold ends too.
        func skipLaunchOffer() {
            RecoveryOffer.skipLaunchOffer()
            if reopenLast { RecoveryOffer.reopenCancelled() }
        }
        if let out = SelfCheck.outDir {
            skipLaunchOffer()
            SelfCheck.run(in: w, browser: browser, out: out)
            return
        }
        if let out = RevertCheck.outDir {
            skipLaunchOffer()
            RevertCheck.run(in: w, browser: browser, out: out)
            return
        }
        if let out = SaveCheck.outDir {
            skipLaunchOffer()
            SaveCheck.run(in: w, browser: browser, out: out)
            return
        }
        if let index = args.firstIndex(of: "-OwlinkShowLicence") {
            if index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                if let preview = ModelLicencePreview.resolve(modelID: args[index + 1]) {
                    skipLaunchOffer()
                    w.rootViewController = UIHostingController(rootView: preview)
                    return
                }
            } else {
                NSLog("Missing value for -OwlinkShowLicence")
            }
        }
        #endif
        if openingExplicitFile { RecoveryOffer.skipLaunchOffer() }
        if let ctx = options.urlContexts.first {
            browser.open(ctx.url, importIfNeeded: !ctx.options.openInPlace)
        } else if let url = TestLaunch.documentToOpen() {
            browser.presentDocument(at: url)
        } else if reopenLast {
            if let url = LastOpenDocument.shared.resolve() {
                // The hold ends when the open does.
                browser.reopenLastDocument(at: url)
            } else {
                // Nothing to reopen: offer now if the browser already showed.
                RecoveryOffer.reopenFinished(opened: false, browser: browser)
            }
        }
    }

    /// Menu-bar and keyboard commands (⌘, Settings…, ⌘W, ⇧⌘P…) with no
    /// first responder in the editor go up the chain from the window, past
    /// this scene delegate: they go to this window's editor (see
    /// `EditorCommandRouting`). The scene the command came from is the one
    /// that shows the result.
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if let editor = EditorCommandRouting.editor(presentedBy: window?.rootViewController),
           editor.canPerformAction(action, withSender: sender) {
            return editor
        }
        return super.target(forAction: action, withSender: sender)
    }

    /// The launch's reopen decision, taken by the process's first window.
    private static var launchReopen = LaunchReopenGate()

    /// The window went away: its documents are no longer open in it.
    func sceneDidDisconnect(_ scene: UIScene) {
        OpenDocuments.registry.removeAll(window: scene.session.persistentIdentifier)
        // Its documents' detached previews go blank (or follow another
        // window that has the document open).
        DetachedPreviews.editorWindowGone(scene.session.persistentIdentifier)
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let ctx = contexts.first, let browser = window?.rootViewController as? DocumentBrowserViewController else { return }
        browser.open(ctx.url, importIfNeeded: !ctx.options.openInPlace)
    }
}

/// Launch arguments for the UI tests and screenshots:
/// `-OwlinkOpen <name>` opens Documents/<name>, copying the bundled sample
/// of that name there first if it isn't there yet (`-OwlinkFreshSample`
/// copies it again).
enum TestLaunch {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-OwlinkOpen") }

    /// Defaults are the live launch's; the tests pass their own folder,
    /// bundle and store to run the same path (twice, for a second window).
    @MainActor static func documentToOpen(
        arguments args: [String] = ProcessInfo.processInfo.arguments,
        documentsDirectory docs: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        bundle: Bundle = .main,
        recovery: RecoveryStore = SaveSafetyStores.recovery,
        queue: DispatchQueue? = SaveSafetyStores.queue,
        now: Date = Date()
    ) -> URL? {
        guard let i = args.firstIndex(of: "-OwlinkOpen"), i + 1 < args.count else { return nil }
        let name = args[i + 1]
        let url = docs.appendingPathComponent(name)
        // Once per process: a second window (New Window, ⌥⌘N) must not wipe
        // the document, or its recovery record, under the first one's editor.
        let fresh = claimFreshSample(requested: args.contains("-OwlinkFreshSample"))
        if fresh || !FileManager.default.fileExists(atPath: url.path),
           let sample = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                   withExtension: (name as NSString).pathExtension, subdirectory: "Samples") {
            if fresh {
                prepareFreshSample(sample, at: url, recovery: recovery, queue: queue, now: now)
            } else {
                try? FileManager.default.copyItem(at: sample, to: url)
            }
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether `-OwlinkFreshSample` has been acted on in this process.
    @MainActor private(set) static var freshSampleConsumed = false

    /// True the first time it is asked with `requested` set, false after
    /// (and whenever `requested` is false).
    @MainActor static func claimFreshSample(requested: Bool) -> Bool {
        guard requested, !freshSampleConsumed else { return false }
        freshSampleConsumed = true
        return true
    }

    /// For the tests (any configuration): lets the next launch claim it again.
    @MainActor static func resetFreshSampleClaim() { freshSampleConsumed = false }

    /// `-OwlinkFreshSample`: puts the bundled `sample` at `url` as if it
    /// were new. An earlier test's unsaved text for that document (its
    /// recovery record) is cleared, and the copy is dated now (`copyItem`
    /// keeps the bundle's older date, which a leftover record would beat),
    /// so no "Owlink closed with unsaved changes… Restore?" comes up over
    /// the next test. Other documents' records are left alone, and launches
    /// without `-OwlinkFreshSample` keep the recovery offer as it is.
    ///
    /// The record is cleared only once the copy is in place and dated: a
    /// failed fixture keeps it (and says so in the log). With `queue` (the
    /// recovery stores' queue) the clear runs on it, after any write this
    /// process already queued, so such a write can't bring the record back.
    @discardableResult
    static func prepareFreshSample(_ sample: URL, at url: URL, recovery: RecoveryStore,
                                   queue: DispatchQueue? = nil, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        // Staged beside it and dated first, then swapped in whole: a sample
        // that can't be copied, dated or swapped in leaves the document as
        // it was (it is never removed ahead of the swap).
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".fresh-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try fm.copyItem(at: sample, to: staged)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: staged.path)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: url)
            }
        } catch {
            if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: staged) }
            restoreOriginalIfRelocated(error: error, to: url, fileManager: fm)
            NSLog("Owlink: -OwlinkFreshSample couldn't put %@ at %@ (%@); its recovery record is kept",
                  sample.path, url.path, String(describing: error))
            return false
        }
        let paths = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path])
        let clear = { for path in paths { recovery.clear(documentPath: path) } }
        if let queue { queue.sync(execute: clear) } else { clear() }
        return true
    }

    /// A failed `replaceItemAt` can leave the original moved aside (named
    /// in the error's `NSFileOriginalItemLocationKey`) with nothing at
    /// `url`; this puts it back so the document is never lost. (The key is
    /// documented in NSFileManager.h but not exported as a symbol.)
    static let originalItemLocationKey = "NSFileOriginalItemLocationKey"

    static func restoreOriginalIfRelocated(error: Error, to url: URL, fileManager fm: FileManager = .default) {
        guard !fm.fileExists(atPath: url.path),
              let original = (error as NSError).userInfo[originalItemLocationKey] as? URL,
              fm.fileExists(atPath: original.path) else { return }
        try? fm.moveItem(at: original, to: url)
    }
}

final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    init() {
        super.init(forOpening: TextDocument.browsableTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        shouldShowFileExtensions = true
        let settings = UIBarButtonItem(image: UIImage(systemName: "gear"), primaryAction: UIAction { [weak self] _ in
            let host = UIHostingSettings.make()
            self?.present(host, animated: true)
        })
        settings.accessibilityIdentifier = "browser.settings"
        additionalTrailingNavigationBarButtonItems = [settings]
    }

    /// See `EditorCommandRouting`: with an editor up, the editor's commands.
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if let editor = EditorCommandRouting.editor(presentedBy: self), editor.canPerformAction(action, withSender: sender) {
            return editor
        }
        return super.target(forAction: action, withSender: sender)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Unsaved text left by a crash or a forced quit (once per launch).
        if presentedViewController == nil { RecoveryOffer.offerLeftovers(from: self) }
    }

    // MARK: Delegate

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, ImportMode) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(localized: "Untitled") + ".txt")
        do {
            try Data().write(to: url)
            importHandler(url, .move)
        } catch {
            importHandler(nil, .none)
        }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { presentDocument(at: url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt source: URL, toDestinationURL dest: URL) {
        presentDocument(at: dest)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt url: URL, error: Error?) {
        alert(String(localized: "Couldn’t create the document"), error?.localizedDescription)
    }

    // MARK: Opening

    func open(_ url: URL, importIfNeeded: Bool) {
        if importIfNeeded {
            revealDocument(at: url, importIfNeeded: true) { [weak self] revealed, error in
                if let revealed { self?.presentDocument(at: revealed) } else { self?.alert(String(localized: "Couldn’t open the file"), error?.localizedDescription) }
            }
        } else {
            presentDocument(at: url)
        }
    }

    /// `recovered`: unsaved text to put back (Restore at launch chosen).
    /// This window's scene session, the key `OpenDocuments` uses.
    private var windowID: String { view.window?.windowScene?.session.persistentIdentifier ?? "main" }

    /// Already open in another window (iPad): bring that one forward rather
    /// than open a second copy that would overwrite the first's saves.
    private func bringForwardIfOpenElsewhere(_ url: URL) -> Bool {
        guard let session = OpenDocuments.otherWindow(having: url, than: windowID) else { return false }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil) { [weak self] error in
            self?.alert(String(localized: "\(url.lastPathComponent) is open in another window"), error.localizedDescription)
        }
        return true
    }

    /// Launch with "Reopen files from last session": opens the last
    /// document quietly. If it can't be opened the record is forgotten and
    /// the browser stays, with no alert.
    func reopenLastDocument(at url: URL) {
        RecoveryOffer.reopenStarted()
        presentDocument(at: url, reopening: true)
    }

    func presentDocument(at url: URL, binaryOK: Bool = false, recovered: RecoveryRecord? = nil, reopening: Bool = false) {
        // Every way a reopen ends clears the hold on the recovery offer,
        // even with this browser gone, and a reopen that failed forgets
        // the record (and its security scope).
        let finishReopen: (Bool) -> Void = { [weak self] opened in
            guard reopening else { return }
            if !opened { LastOpenDocument.shared.forget(url) }
            if let self {
                RecoveryOffer.reopenFinished(opened: opened, browser: self)
            } else {
                RecoveryOffer.reopenCancelled()
            }
        }
        if bringForwardIfOpenElsewhere(url) { finishReopen(false); return }
        let doc = TextDocument(fileURL: url)
        doc.openBinaryAnyway = binaryOK
        doc.open { [weak self] ok in
            guard let self else {
                if ok { doc.close(completionHandler: nil) }
                finishReopen(false)
                return
            }
            // Opened meanwhile in another window: that one keeps it.
            if ok, self.bringForwardIfOpenElsewhere(url) {
                doc.close(completionHandler: nil)
                finishReopen(false)
                return
            }
            if !ok, reopening {
                finishReopen(false)
                return
            }
            guard ok else {
                if !binaryOK, (try? Data(contentsOf: url, options: .mappedIfSafe)).map(TextCodec.looksBinary) == true {
                    let a = UIAlertController(title: String(localized: "This looks like a binary file"),
                                              message: String(localized: "Open it as text anyway? Saving it may damage it."), preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                    a.addAction(UIAlertAction(title: String(localized: "Open as Text"), style: .destructive) { _ in
                        self.presentDocument(at: url, binaryOK: true, recovered: recovered)
                    })
                    self.present(a, animated: true)
                } else {
                    self.alert(String(localized: "Couldn’t open \(url.lastPathComponent)"), nil)
                }
                return
            }
            // Unsaved text from a crash, newer than the file: restored if
            // asked for at launch, else offered when the editor appears.
            var recovery: EditorViewController.Recovery?
            if let recovered {
                recovery = .restore(recovered)
            } else if !OpenDocuments.isOpen(doc.recoveryPath),
                      let r = SaveSafetyStores.recovery.pending(documentPath: doc.recoveryPath, documentModified: doc.fileModificationDate) {
                recovery = .offer(r)
            }
            let editor = EditorViewController(document: doc, recovery: recovery, windowID: self.windowID)
            // Open in an editor: reopened at the next launch until closed.
            LastOpenDocument.shared.remember(doc.fileURL)
            let nav = EditorNavigationController(rootViewController: editor)
            nav.modalPresentationStyle = .fullScreen
            nav.navigationBar.prefersLargeTitles = false
            self.present(nav, animated: true)
            finishReopen(true)
        }
    }

    private func alert(_ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }
}

import SwiftUI

enum UIHostingSettings {
    static func make() -> UIViewController {
        let host = UIHostingController(rootView: SettingsView())
        host.modalPresentationStyle = .formSheet
        return host
    }
}

/// The editor's navigation controller: the editor decides whether the
/// status bar and home indicator show (hidden in Focus Preview).
final class EditorNavigationController: UINavigationController {
    /// See `EditorCommandRouting`: a sheet over the editor (Ask Cedric,
    /// Settings) hands its unhandled commands to its presenter, this
    /// controller, which hands them to the editor it shows.
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if let editor = topViewController as? EditorViewController, editor.canPerformAction(action, withSender: sender) {
            return editor
        }
        return super.target(forAction: action, withSender: sender)
    }

    /// ⌘, Settings… for the editor and every sheet over it (they hand
    /// their commands to this controller): Owlink's Settings ahead of the
    /// system's ⌘,, which opens the system Settings app, even before the
    /// menu bar has its own (0.5.2 (18)).
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [MenuBar.settingsKey()]
    }

    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { topViewController }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let owl = (topViewController as? EditorViewController)?.owlSprite,
           owl.superview === view, view.subviews.last !== owl {
            view.bringSubviewToFront(owl)
        }
    }
}

/// Why menu-bar commands need routing to the editor: UIKit sends a key
/// command or menu-bar command to the first responder and up its chain.
/// The editor is the child of a navigation controller the document browser
/// presents. With nothing in the editor first responder (reading, the
/// keyboard hidden, Ask Cedric just closed) the chain starts outside it,
/// and from a sheet over the editor (Ask Cedric, Settings) it goes sheet →
/// presenter (the navigation controller) → browser → window → scene: past
/// the editor, never into it. So ⌘, (Settings…) and the rest did nothing
/// (grayed out in the menu bar), and worked only while Ask Cedric's docked
/// panel, inside the editor, held the keyboard. The navigation controller,
/// the browser and the scene delegate hand such commands to the editor.
@MainActor enum EditorCommandRouting {
    /// The editor `root` (a window's document browser) presents, if any,
    /// and not on its way out.
    static func editor(presentedBy root: UIViewController?) -> EditorViewController? {
        guard let nav = root?.presentedViewController as? UINavigationController, !nav.isBeingDismissed else { return nil }
        return nav.viewControllers.first as? EditorViewController
    }

    /// What the editor's navigation controller shows over the editor: the
    /// topmost presented controller that is on screen and not on its way
    /// out.
    enum Modal: Equatable {
        case none
        /// The Ask Cedric sheet: at half height it leaves the editor in
        /// view, undimmed and in use (the text can keep the keyboard).
        case askCedric
        /// Settings, Open Quickly, Statistics, the share sheet…
        case sheet
        /// An alert (Go to Line, Save / Don't Save…): it takes the keys.
        case alert
    }

    static func modal(over base: UIViewController) -> Modal {
        var top: UIViewController?
        var next = base.presentedViewController
        while let shown = next, !shown.isBeingDismissed, shown.viewIfLoaded?.window != nil {
            top = shown
            next = shown.presentedViewController
        }
        switch top {
        case nil: return .none
        case is UIAlertController: return .alert
        case is AskSheetHost: return .askCedric
        default: return .sheet
        }
    }

    /// Commands that stay available over a sheet other than Ask Cedric:
    /// Settings (it goes on top, or does nothing when it is the sheet), and
    /// Close and Save (Close takes the sheet with the editor; their alerts
    /// go on top of the sheet).
    static let availableOverASheet: Set<Selector> = [
        #selector(EditorViewController.showSettings),
        #selector(EditorViewController.closeDocument),
        #selector(EditorViewController.saveDocument),
    ]

    /// The policy, for the editor's own chain and for the navigation
    /// controller, browser and scene that hand commands to it:
    /// - nothing up: every command;
    /// - Ask Cedric's sheet: every command. The editor is in view and in
    ///   use; what presents goes on top of Ask Cedric (the editor's
    ///   `present`), and Ask Cedric… does nothing (already open);
    /// - another sheet: only `availableOverASheet`;
    /// - an alert: none.
    static func allows(_ action: Selector, over modal: Modal) -> Bool {
        switch modal {
        case .none, .askCedric: return true
        case .sheet: return availableOverASheet.contains(action)
        case .alert: return false
        }
    }

}
