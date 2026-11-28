import UIKit
import PDFKit
import UniformTypeIdentifiers
import CedricCore

/// One window: the Files-style document browser, which presents an editor
/// for the document picked. Every window (iPad scenes, Stage Manager) has
/// its own browser and editor.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// Set up a scene's window before anything is put in it. Its background
    /// is the system background, not a window's default black, behind the
    /// browser as an editor opens or closes.
    static func configure(_ window: UIWindow) {
        window.backgroundColor = EditorBarStyle.windowBackground
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let browser = DocumentBrowserViewController()
        let w = UIWindow(windowScene: ws)
        Self.configure(w)
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
        // A viewer left up (no Done) stops its file access now.
        DocumentViewers.tearDown(presentedBy: window?.rootViewController)
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

    static func documentToOpen() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkOpen"), i + 1 < args.count else { return nil }
        let name = args[i + 1]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(name)
        let fresh = args.contains("-OwlinkFreshSample")
        if fresh || !FileManager.default.fileExists(atPath: url.path),
           let sample = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                        withExtension: (name as NSString).pathExtension, subdirectory: "Samples") {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: sample, to: url)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    /// A new document's import (the + button). An Open In import that
    /// `open(_:importIfNeeded:)` reveals is its completion's (UIKit calls
    /// both, this first).
    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt source: URL, toDestinationURL dest: URL) {
        guard importGate.delegateOwns(source) else { return }
        presentDocument(at: dest)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt url: URL, error: Error?) {
        guard importGate.delegateOwns(url) else { return }
        alert(String(localized: "Couldn’t create the document"), error?.localizedDescription)
    }

    // MARK: Opening

    /// Which callback presents an import (see `ImportPresentationGate`).
    private var importGate = ImportPresentationGate()

    func open(_ url: URL, importIfNeeded: Bool) {
        if importIfNeeded {
            importGate.beginReveal(url)
            revealDocument(at: url, importIfNeeded: true) { [weak self] revealed, error in
                guard let self, self.importGate.finishReveal(url) else { return }
                if let revealed { self.presentDocument(at: revealed) } else { self.alert(String(localized: "Couldn’t open the file"), error?.localizedDescription) }
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
        // PDF and Office / iWork files open read-only in a viewer, as on
        // the Mac (`DocumentViewerRoute`: name, type, first bytes). Not
        // for "Open as Text" (binaryOK), a crash-recovery restore, or a
        // launch reopen: those open only the editor, and skip a file that
        // routes to a viewer (below).
        if !binaryOK, recovered == nil, !reopening, presentViewerIfNeeded(at: url) { return }
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
        // A reopen or a restore goes to the editor only if the file is
        // still the editor's: a viewer file (a PDF with no NUL bytes passes
        // the editor's binary check) isn't opened, the reopen forgets its
        // record, and a recovery record is left as it is (not cleared).
        if !binaryOK, recovered != nil || reopening {
            let decision = DocumentViewerRoute.editorOnlyOpen(DocumentViewerRoute.route(for: url), reopening: reopening)
            if !decision.opensEditor {
                if recovered != nil { alert(String(localized: "Couldn’t open \(url.lastPathComponent)"), nil) }
                finishReopen(false)
                return
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

    /// Shows `url` in the read-only PDF or Quick Look viewer when its
    /// route says so; false when it is the editor's (nothing shown).
    ///
    /// The file's security scope (a file picked in Files, or opened in
    /// place from another app) is started before the first bytes are read
    /// and kept by the viewer until Done (or until the viewer goes away);
    /// every other way out stops it here. A viewer is deliberately not
    /// remembered as `LastOpenDocument` (nor in `OpenDocuments`): the
    /// launch reopen goes through `TextDocument`, and it would route a
    /// PDF into the text editor. Viewers never write, so several windows
    /// may show the same file.
    @discardableResult
    func presentViewerIfNeeded(at url: URL) -> Bool {
        let access = ScopedFileAccess(url)
        let viewer: UIViewController
        switch DocumentViewerRoute.route(for: url) {
        case .editor:
            access.stop()
            return false
        case .pdf:
            // A damaged PDF: an alert and no viewer (Mac parity).
            guard let pdf = PDFDocument(url: url) else {
                access.stop()
                alert(String(localized: "Couldn’t open \(url.lastPathComponent)"), nil)
                return true
            }
            viewer = PDFViewerController(document: pdf, url: url, access: access)
        case .quickLook(let format):
            viewer = QuickLookViewerController(url: url, format: format, access: access)
        }
        present(DocumentViewers.navigationController(for: viewer, traits: traitCollection), animated: true)
        return true
    }

    private func alert(_ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }
}

/// One import, one presentation owner. UIKit reports an Open In import
/// twice: the browser delegate's `didImportDocumentAt` (or
/// `failedToImportDocumentAt`) and then `revealDocument`'s completion.
/// While a reveal of a source is in flight, the delegate leaves it to the
/// completion, which presents (or alerts) once per reveal. An import with
/// no reveal (a new document) is the delegate's alone.
struct ImportPresentationGate {
    private var revealing: Set<String> = []

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    mutating func beginReveal(_ source: URL) { revealing.insert(Self.key(source)) }

    /// Whether a delegate callback for `source` presents (or alerts).
    func delegateOwns(_ source: URL) -> Bool { !revealing.contains(Self.key(source)) }

    /// The reveal's completion: true once per reveal begun (it presents
    /// or alerts), false for a repeated or unknown completion.
    mutating func finishReveal(_ source: URL) -> Bool { revealing.remove(Self.key(source)) != nil }
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
