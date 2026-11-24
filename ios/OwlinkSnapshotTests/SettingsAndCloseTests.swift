import XCTest
import UIKit
import CedricCore

/// Settings opens from every way in, with and without Ask Cedric, and the
/// back chevron (Close) takes the editor away whatever it shows over itself
/// (0.5.2 (17), Derek's iPad check). This test bundle has no app or scene,
/// so modal presentations never finish here: the controllers around the
/// editor are stand-ins that report what the app's would (the document
/// browser presenting the editor's navigation controller, a sheet over
/// it). The real round trips are UI tests (OwlinkUITests).
@MainActor
final class SettingsAndCloseTests: XCTestCase {
    /// Stands in for a controller in the presentation chain.
    final class Stand: UIViewController {
        var presented: UIViewController?
        var presenting: UIViewController?
        var dismissing = false
        var forwardTo: UIResponder?
        var dismissCalls = 0
        var presentCalls: [UIViewController] = []
        override func present(_ controller: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentCalls.append(controller)
        }
        override var presentedViewController: UIViewController? { presented }
        override var presentingViewController: UIViewController? { presenting }
        override var isBeingDismissed: Bool { dismissing }
        override var next: UIResponder? { forwardTo ?? super.next }
        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
            dismissCalls += 1
            completion?()
        }
    }

    final class StandNav: UINavigationController {
        var presented: UIViewController?
        var presenting: UIViewController?
        override var presentedViewController: UIViewController? { presented }
        override var presentingViewController: UIViewController? { presenting }
    }

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor() -> (StandNav, EditorViewController) {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "# Owls\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: true)
        let nav = StandNav(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        windows.append(window)
        return (nav, editor)
    }

    /// A controller whose view is in a window, as a shown sheet's is.
    private func shownSheet() -> Stand {
        let s = Stand()
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        w.addSubview(s.view)
        w.isHidden = false
        windows.append(w)
        return s
    }

    // MARK: Where Settings goes

    func testSettingsGoesOnTheNavigationControllerWithNothingUp() {
        let (nav, editor) = editor()
        XCTAssertTrue(editor.sheetPresenter() === nav)
    }

    /// Ask Cedric up: Settings goes on top of it (the conversation stays).
    func testSettingsGoesOverAskCedric() {
        let (nav, editor) = editor()
        let ask = shownSheet()
        nav.presented = ask
        XCTAssertTrue(editor.sheetPresenter() === ask)
    }

    /// Never on a sheet on its way out, nor on one no longer on screen.
    func testSettingsSkipsAGoingOrDetachedSheet() {
        let (nav, editor) = editor()
        let going = shownSheet()
        going.dismissing = true
        nav.presented = going
        XCTAssertTrue(editor.sheetPresenter() === nav)
        nav.presented = Stand() // its view never in a window
        XCTAssertTrue(editor.sheetPresenter() === nav)
    }

    // MARK: Menu-bar commands (⌘, Settings…, ⌘W Close)

    /// The editor in the app's navigation controller.
    private func editorInNav() -> (EditorNavigationController, EditorViewController) {
        let (_, e) = editor()
        e.navigationController?.setViewControllers([], animated: false)
        return (EditorNavigationController(rootViewController: e), e)
    }

    /// From the editor's navigation controller (where a sheet over the
    /// editor hands its commands on), the commands reach the editor.
    func testMenuCommandsReachTheEditorFromItsNavigationController() {
        let (nav, editor) = editorInNav()
        for action in [#selector(EditorViewController.showSettings), #selector(EditorViewController.closeDocument),
                       #selector(EditorViewController.askCedric)] {
            XCTAssertTrue(nav.target(forAction: action, withSender: nil) as AnyObject? === editor, "\(action)")
        }
    }

    /// From a sheet over the editor (the chain goes sheet → its presenter).
    func testMenuCommandsReachTheEditorFromASheet() {
        let (nav, editor) = editorInNav()
        let sheet = Stand()
        sheet.forwardTo = nav
        XCTAssertTrue(sheet.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) as AnyObject? === editor,
                      "⌘, from Ask Cedric's sheet doesn't reach the editor")
    }

    /// With nothing first responder in the editor: the window's scene
    /// delegate and the browser hand the command to the editor shown.
    func testMenuCommandsReachTheEditorFromTheScene() {
        let (nav, editor) = editorInNav()
        let browser = Stand()
        browser.presented = nav
        let scene = SceneDelegate()
        let window = UIWindow(frame: .zero)
        window.rootViewController = browser
        scene.window = window
        windows.append(window)
        XCTAssertTrue(scene.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) as AnyObject? === editor)
        // No editor up: nothing to route to.
        browser.presented = nil
        XCTAssertFalse(scene.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) is EditorViewController)
    }

    /// ⌘, is Owlink's Settings…: in place of the app menu's own item
    /// when there is one (it opened the system Settings app), ahead of the
    /// system's behavior, and in the menu bar once either way.
    func testCommaSettingsIsOwlinksSettings() {
        func settings(_ all: [MenuBar.Insertion]) -> [(UIKeyCommand, MenuBar.Place)] {
            all.flatMap { i in Self.commands(i.menu).filter { $0.action == #selector(EditorViewController.showSettings) }.map { ($0, i.place) } }
        }
        let withAppMenu = settings(MenuBar.insertions(hasFind: true, hasSpelling: true, hasAppSettings: true))
        XCTAssertEqual(withAppMenu.count, 1)
        XCTAssertEqual(withAppMenu.first?.1, .replacing(.preferences))
        XCTAssertEqual(withAppMenu.first?.0.input, ",")
        XCTAssertEqual(withAppMenu.first?.0.modifierFlags, .command)
        XCTAssertEqual(withAppMenu.first?.0.wantsPriorityOverSystemBehavior, true)
        let without = settings(MenuBar.insertions(hasFind: true, hasSpelling: true, hasAppSettings: false))
        XCTAssertEqual(without.count, 1)
        XCTAssertEqual(without.first?.1, .after(.view))
    }

    static func commands(_ menu: UIMenu) -> [UIKeyCommand] {
        menu.children.flatMap { e -> [UIKeyCommand] in
            if let m = e as? UIMenu { return commands(m) }
            return (e as? UIKeyCommand).map { [$0] } ?? []
        }
    }

    // MARK: Commands over a modal (Codex review of 0.5.2 (17), must-fix 1)

    typealias Routing = EditorCommandRouting

    /// The policy: everything with nothing up or over Ask Cedric; over
    /// another sheet only Settings, Close and Save; over an alert nothing.
    func testWhatAModalLeavesAvailable() {
        let goToLine = #selector(EditorViewController.goToLine)
        let settings = #selector(EditorViewController.showSettings)
        let close = #selector(EditorViewController.closeDocument)
        let save = #selector(EditorViewController.saveDocument)
        let ask = #selector(EditorViewController.askCedric)
        for action in [goToLine, settings, close, save, ask] {
            XCTAssertTrue(Routing.allows(action, over: .none), "\(action)")
            XCTAssertTrue(Routing.allows(action, over: .askCedric), "\(action)")
            XCTAssertFalse(Routing.allows(action, over: .alert), "\(action)")
        }
        XCTAssertFalse(Routing.allows(goToLine, over: .sheet))
        XCTAssertFalse(Routing.allows(ask, over: .sheet))
        for action in [settings, close, save] { XCTAssertTrue(Routing.allows(action, over: .sheet), "\(action)") }
    }

    /// What is over the editor: the topmost live controller decides.
    func testTheModalOverTheEditor() {
        let (nav, _) = editor()
        XCTAssertEqual(Routing.modal(over: nav), .none)
        let settings = shownSheet()
        nav.presented = settings
        XCTAssertEqual(Routing.modal(over: nav), .sheet)
        let alert = UIAlertController(title: "Go to Line", message: nil, preferredStyle: .alert)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        w.addSubview(alert.view)
        w.isHidden = false
        windows.append(w)
        settings.presented = alert
        XCTAssertEqual(Routing.modal(over: nav), .alert)
        settings.presented = nil
        nav.presented = askSheet()
        XCTAssertEqual(Routing.modal(over: nav), .askCedric)
        // On its way out: not over the editor any more.
        let going = shownSheet()
        going.dismissing = true
        nav.presented = going
        XCTAssertEqual(Routing.modal(over: nav), .none)
    }

    private func askSheet() -> AskSheetHost {
        let host = AskSheetHost(rootView: AskCedricView(model: AskCedricModel(fileName: "README.md", language: .markdown)))
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        w.addSubview(host.view)
        w.isHidden = false
        windows.append(w)
        return host
    }

    /// The editor applies the policy itself, so the navigation controller,
    /// browser and scene (which ask it) apply it too: ⌘L is off over
    /// Settings and an alert, on over Ask Cedric; ⌘, and ⌘W stay on over a
    /// sheet.
    func testTheEditorAppliesThePolicy() {
        let (nav, editor) = editor()
        let goToLine = #selector(EditorViewController.goToLine)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.showStatistics), withSender: nil))
        nav.presented = askSheet()
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.showStatistics), withSender: nil))
        nav.presented = shownSheet()
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.showStatistics), withSender: nil))
        XCTAssertFalse(editor.canPerformAction(goToLine, withSender: nil))
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.askCedric), withSender: nil))
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.showSettings), withSender: nil))
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.closeDocument), withSender: nil))
    }

    /// What the editor presents goes on top of the sheet it shows (Go to
    /// Line over Ask Cedric was refused: the navigation controller was
    /// already presenting).
    func testTheEditorPresentsOnTopOfASheet() {
        let (nav, editor) = editor()
        let sheet = shownSheet()
        nav.presented = sheet
        editor.goToLine()
        XCTAssertEqual(sheet.presentCalls.count, 1)
        XCTAssertTrue(sheet.presentCalls.first is UIAlertController)
    }

    /// Opening Ask Cedric again keeps the open conversation.
    func testAskCedricOpensOnce() {
        let (_, editor) = editor()
        editor.askCedric()
        let first = editor.askModel
        XCTAssertNotNil(first)
        XCTAssertTrue(editor.askIsOpen)
        editor.askCedric()
        XCTAssertTrue(editor.askModel === first, "a second Ask Cedric replaced the open conversation")
    }

    // MARK: Close

    /// Close dismisses from the controller that presented the editor (the
    /// browser): the editor goes with any sheet over it. Dismissing the
    /// editor itself only took the sheet away.
    func testCloseDismissesFromTheBrowser() async throws {
        let (nav, editor) = editor()
        let browser = Stand()
        nav.presenting = browser
        nav.presented = shownSheet()
        let done = expectation(description: "dismissed")
        editor.dismissEditor { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(browser.dismissCalls, 1)
    }
}
