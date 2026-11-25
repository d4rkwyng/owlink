import XCTest
import UIKit
import CedricCore

/// Closing a file showed the document browser dark for a moment, then
/// light, with the phone in light mode (Derek, after build 18), and the
/// browser went dark under the editor as it slid in. The theme sets the
/// window's and its scene's interface style (so the iOS 26/27 document
/// title follows it), and that style reaches the browser too: it was set
/// as the editor started to appear and put back only after the close
/// animation had ended. And the scene's window had no background, which
/// draws black.
///
/// Every theme, as in the app: the window is themed only while the editor
/// covers the browser, and is back on the phone's appearance before the
/// close animation starts, while the editor itself keeps its theme from
/// its navigation controller. This bundle has no scene, so the editor's
/// appearance calls are made here in the order UIKit makes them on open
/// and close; the real round trips are UI tests (OwlinkUITests).
@MainActor
final class CloseFlashTests: XCTestCase {
    /// The editor's navigation controller, presented by `presenter`.
    final class Nav: UINavigationController {
        var presenter: UIViewController?
        var dismissing = false
        override var presentingViewController: UIViewController? { presenter }
        override var isBeingDismissed: Bool { dismissing }
    }

    /// Stands in for the document browser: records the window's style at
    /// the moment it is asked to dismiss the editor.
    final class Browser: UIViewController {
        var styleAtDismiss: [UIUserInterfaceStyle] = []
        weak var window: UIWindow?
        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
            styleAtDismiss.append(window?.overrideUserInterfaceStyle ?? .light)
            completion?()
        }
    }

    private var windows: [UIWindow] = []

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.theme)
    }

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.theme)
    }

    /// An editor whose view is in a window, as at the start of the open
    /// animation: no appearance calls made yet.
    private func editor(theme: EditorTheme) -> (UIWindow, Nav, EditorViewController, Browser) {
        AppSettings.theme = theme
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "# Owls\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: true)
        let nav = Nav(rootViewController: editor)
        let browser = Browser()
        nav.presenter = browser
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.backgroundColor = EditorBarStyle.windowBackground
        window.rootViewController = browser
        window.makeKeyAndVisible()
        browser.window = window
        nav.view.frame = window.bounds
        window.addSubview(nav.view)
        if editor.view.window == nil { nav.view.addSubview(editor.view) }
        windows.append(window)
        return (window, nav, editor, browser)
    }

    /// The style a theme draws the editor in, whatever the phone's.
    private func themed(_ theme: EditorTheme) -> UIUserInterfaceStyle {
        theme == .system ? .unspecified : (theme.palette(systemIsDark: false).isDark ? .dark : .light)
    }

    private func assertOnPhone(_ window: UIWindow, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified, "\(what): window style", file: file, line: line)
        XCTAssertEqual(window.traitOverrides.userInterfaceStyle, .unspecified, "\(what): window trait override", file: file, line: line)
    }

    // MARK: Open

    /// As the editor slides in, the browser under it stays on the phone's
    /// appearance; the editor already has its theme. Once it covers the
    /// browser the window takes the theme (the document title's colour).
    func testOpeningThemesTheWindowOnlyOnceTheEditorCoversTheBrowser() {
        for theme in EditorTheme.allCases {
            let (window, nav, editor, _) = editor(theme: theme)
            XCTAssertNotNil(editor.view.window, "\(theme): editor in the window")
            XCTAssertFalse(editor.themesWindow, "\(theme): no appearance calls yet")
            editor.viewWillAppear(true)
            editor.viewIsAppearing(true)
            assertOnPhone(window, "\(theme) while opening")
            XCTAssertEqual(nav.overrideUserInterfaceStyle, themed(theme), "\(theme): editor themed while opening")
            editor.viewDidAppear(true)
            XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): window themed once open (title colour)")
            XCTAssertEqual(window.traitOverrides.userInterfaceStyle, themed(theme), "\(theme): window trait once open")
            XCTAssertEqual(nav.overrideUserInterfaceStyle, themed(theme), "\(theme): editor themed once open")
        }
    }

    // MARK: Close

    /// The close starts (viewWillDisappear on a dismissal): the window is
    /// back on the phone before the browser is uncovered, stays there
    /// whatever the editor does during the animation, and the editor keeps
    /// its theme until it has gone.
    func testClosingPutsTheWindowBackOnThePhoneBeforeTheBrowserShows() {
        for theme in EditorTheme.allCases {
            let (window, nav, editor, _) = editor(theme: theme)
            editor.viewWillAppear(false)
            editor.viewIsAppearing(false)
            editor.viewDidAppear(false)
            XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): window themed while open")
            nav.dismissing = true
            editor.viewWillDisappear(true)
            assertOnPhone(window, "\(theme) as the close starts")
            XCTAssertFalse(editor.themesWindow, "\(theme)")
            XCTAssertEqual(nav.overrideUserInterfaceStyle, themed(theme), "\(theme): editor keeps its theme while closing")
            // A document state change (the close itself) during the animation.
            editor.updateEdited()
            assertOnPhone(window, "\(theme) during the close")
            editor.viewDidDisappear(true)
            assertOnPhone(window, "\(theme) after the close")
        }
    }

    /// The back chevron and ⌘W: the window is on the phone's appearance by
    /// the time the browser is asked to dismiss the editor.
    func testDismissEditorHandsTheWindowBackBeforeDismissing() {
        for theme in EditorTheme.allCases {
            let (window, _, editor, browser) = editor(theme: theme)
            editor.viewWillAppear(false)
            editor.viewIsAppearing(false)
            editor.viewDidAppear(false)
            var done = false
            editor.dismissEditor { done = true }
            XCTAssertTrue(done, "\(theme)")
            XCTAssertEqual(browser.styleAtDismiss, [.unspecified], "\(theme): window style as the dismiss starts")
            assertOnPhone(window, "\(theme) after dismissEditor")
        }
    }

    /// Covered by a sheet (Settings), not dismissed: the window keeps the
    /// theme, so the title keeps its colour under and after the sheet.
    func testASheetOverTheEditorKeepsTheWindowThemed() {
        let (window, _, editor, _) = editor(theme: .cedricNight)
        editor.viewWillAppear(false)
        editor.viewIsAppearing(false)
        editor.viewDidAppear(false)
        editor.viewWillDisappear(true)
        editor.viewDidDisappear(true)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        editor.viewWillAppear(true)
        editor.viewDidAppear(true)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
    }

    // MARK: The window behind the browser

    /// What shows where the browser hasn't drawn: white with the phone in
    /// light mode, dark in dark mode. A window's default draws black.
    func testWindowBackgroundFollowsThePhoneNotBlack() {
        func rgb(_ style: UIUserInterfaceStyle) -> (CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            EditorBarStyle.windowBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertEqual(a, 1, accuracy: 0.001, "opaque")
            return (r, g, b)
        }
        let light = rgb(.light)
        XCTAssertGreaterThan(min(light.0, light.1, light.2), 0.9, "light mode: white, not black")
        let dark = rgb(.dark)
        XCTAssertLessThan(max(dark.0, dark.1, dark.2), 0.2, "dark mode: stays dark, no light flash")
    }
}
