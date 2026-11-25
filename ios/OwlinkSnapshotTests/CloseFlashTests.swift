import XCTest
import UIKit
import CedricCore

@_silgen_name("OWReadUserInterfaceStyleOverride")
func OWReadUserInterfaceStyleOverride(_ window: UIWindow, _ outStyle: UnsafeMutablePointer<Int>) -> Int32

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
    /// The window holds only the navigation controller's view, not the
    /// controller: kept here so it (and its `presenter`) live until tearDown.
    private var navs: [Nav] = []

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.theme)
    }

    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
        navs = []
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
        navs.append(nav)
        return (window, nav, editor, browser)
    }

    /// The style a theme draws the editor in, whatever the phone's.
    private func themed(_ theme: EditorTheme) -> UIUserInterfaceStyle {
        theme == .system ? .unspecified : (theme.palette(systemIsDark: false).isDark ? .dark : .light)
    }

    /// UIKit throws if `traitOverrides.userInterfaceStyle` is read when no
    /// override was ever set ("Can't return value for trait UserInterfaceStyle
    /// that has no override"). A missing override and an explicit
    /// `.unspecified` both mean the window follows the phone. After
    /// `EditorBarStyle.restore` the override is set and readable; during
    /// open it has never been set.
    private func traitOverrideFollowsThePhone(_ window: UIWindow) -> Bool {
        var raw: Int = -1
        if OWReadUserInterfaceStyleOverride(window, &raw) == 0 { return true }
        return UIUserInterfaceStyle(rawValue: raw) == .unspecified
    }

    private func assertOnPhone(_ window: UIWindow, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified, "\(what): window style", file: file, line: line)
        XCTAssertTrue(traitOverrideFollowsThePhone(window), "\(what): window trait override follows the phone", file: file, line: line)
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
            let (window, nav, editor, browser) = editor(theme: theme)
            withExtendedLifetime(nav) {
                XCTAssertTrue(editor.navigationController === nav, "\(theme): editor in its navigation controller")
                XCTAssertTrue(nav.presentingViewController === browser, "\(theme): presented by the browser")
                editor.viewWillAppear(false)
                editor.viewIsAppearing(false)
                editor.viewDidAppear(false)
                XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): window themed while open")
                var done = false
                editor.dismissEditor { done = true }
                XCTAssertTrue(done, "\(theme)")
                // Through the browser (the presenter), not the fallback.
                XCTAssertEqual(browser.styleAtDismiss, [.unspecified], "\(theme): window style as the dismiss starts")
                assertOnPhone(window, "\(theme) after dismissEditor")
            }
        }
    }

    /// Covered by a sheet (Settings), not dismissed: the window keeps the
    /// theme, so the title keeps its colour under and after the sheet.
    func testASheetOverTheEditorKeepsTheWindowThemed() {
        let (window, nav, editor, _) = editor(theme: .cedricNight)
        withExtendedLifetime(nav) {
            XCTAssertTrue(editor.navigationController === nav)
            editor.viewWillAppear(false)
            editor.viewIsAppearing(false)
            editor.viewDidAppear(false)
            XCTAssertFalse(nav.isBeingDismissed, "covered, not dismissed")
            editor.viewWillDisappear(true)
            editor.viewDidDisappear(true)
            XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
            editor.viewWillAppear(true)
            editor.viewDidAppear(true)
            XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        }
    }

    /// The fixed themes: the window's style differs from the phone's
    /// (unspecified) only for these, so a re-themed window shows.
    private var fixedThemes: [EditorTheme] { EditorTheme.allCases.filter { $0 != .system } }

    /// Settings (or Ask Cedric) is on its way out when the file is closed:
    /// the editor is told it appeared only after the close has handed the
    /// window back. The window stays on the phone's appearance; theming it
    /// again would uncover the browser in the theme's style.
    func testClosingWhileASheetIsDismissingDoesNotThemeTheWindowAgain() {
        for theme in fixedThemes {
            let (window, nav, editor, browser) = editor(theme: theme)
            withExtendedLifetime(nav) {
                editor.viewWillAppear(false)
                editor.viewIsAppearing(false)
                editor.viewDidAppear(false)
                // The sheet comes up over the editor.
                editor.viewWillDisappear(true)
                editor.viewDidDisappear(true)
                XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): themed under the sheet")
                // The sheet starts to go; the file is closed meanwhile.
                editor.viewWillAppear(true)
                editor.viewIsAppearing(true)
                editor.dismissEditor {}
                XCTAssertEqual(browser.styleAtDismiss, [.unspecified], "\(theme): window style as the dismiss starts")
                // The sheet's dismissal ends: a late appearance.
                editor.viewDidAppear(true)
                XCTAssertFalse(editor.themesWindow, "\(theme): late viewDidAppear")
                assertOnPhone(window, "\(theme) after a late viewDidAppear")
                editor.updateEdited()
                assertOnPhone(window, "\(theme) after a state change")
            }
        }
    }

    /// The editor's own dismissal under way (UIKit's close, not
    /// `dismissEditor`) and an appearance call arrives: the window stays on
    /// the phone's appearance.
    func testALateAppearanceDuringTheDismissalLeavesTheWindowOnThePhone() {
        for theme in fixedThemes {
            let (window, nav, editor, _) = editor(theme: theme)
            withExtendedLifetime(nav) {
                editor.viewWillAppear(false)
                editor.viewIsAppearing(false)
                editor.viewDidAppear(false)
                nav.dismissing = true
                editor.viewWillDisappear(true)
                assertOnPhone(window, "\(theme) as the close starts")
                editor.viewDidAppear(true)
                XCTAssertFalse(editor.themesWindow, "\(theme): late viewDidAppear")
                assertOnPhone(window, "\(theme) after a late viewDidAppear")
            }
        }
    }

    /// A dismissal that is cancelled (the editor comes back to
    /// viewDidAppear, no longer being dismissed): the window takes the
    /// theme again, so the document title gets its colour back.
    func testACancelledDismissalThemesTheWindowAgain() {
        for theme in fixedThemes {
            let (window, nav, editor, _) = editor(theme: theme)
            withExtendedLifetime(nav) {
                editor.viewWillAppear(false)
                editor.viewIsAppearing(false)
                editor.viewDidAppear(false)
                nav.dismissing = true
                editor.viewWillDisappear(true)
                assertOnPhone(window, "\(theme) as the close starts")
                // Cancelled: UIKit puts the editor back.
                nav.dismissing = false
                editor.viewWillAppear(true)
                editor.viewIsAppearing(true)
                editor.viewDidAppear(true)
                XCTAssertTrue(editor.themesWindow, "\(theme)")
                XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): window themed again (title colour)")
                XCTAssertEqual(window.traitOverrides.userInterfaceStyle, themed(theme), "\(theme): window trait again")
                XCTAssertEqual(nav.overrideUserInterfaceStyle, themed(theme), "\(theme): editor themed")
            }
        }
    }

    /// A sheet's dismissal that is cancelled (Settings dragged down, then
    /// let go): the editor was never being dismissed, so the window keeps
    /// the theme throughout and has it once the sheet has gone.
    func testACancelledSheetDismissalKeepsTheWindowThemed() {
        for theme in fixedThemes {
            let (window, nav, editor, _) = editor(theme: theme)
            withExtendedLifetime(nav) {
                editor.viewWillAppear(false)
                editor.viewIsAppearing(false)
                editor.viewDidAppear(false)
                editor.viewWillDisappear(true)
                editor.viewDidDisappear(true)
                // Dragged down, then let go: back under the sheet.
                editor.viewWillAppear(true)
                editor.viewWillDisappear(true)
                editor.viewDidDisappear(true)
                XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): themed under the sheet")
                // The sheet goes.
                editor.viewWillAppear(true)
                editor.viewIsAppearing(true)
                editor.viewDidAppear(true)
                XCTAssertEqual(window.overrideUserInterfaceStyle, themed(theme), "\(theme): window themed (title colour)")
                XCTAssertEqual(window.traitOverrides.userInterfaceStyle, themed(theme), "\(theme): window trait")
            }
        }
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

    /// The scene's window as `SceneDelegate` sets it up: its background is
    /// white with the phone in light mode and dark in dark mode, not the
    /// default (no colour, drawn black).
    func testTheScenesWindowHasThePhonesBackground() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        SceneDelegate.configure(window)
        windows.append(window)
        func rgba(_ style: UIUserInterfaceStyle) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
            guard let color = window.backgroundColor else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b, a)
        }
        guard let light = rgba(.light) else { return XCTFail("light mode: window has no background (draws black)") }
        XCTAssertEqual(light.3, 1, accuracy: 0.001, "light mode: opaque")
        XCTAssertGreaterThan(min(light.0, light.1, light.2), 0.9, "light mode: white, not black")
        guard let dark = rgba(.dark) else { return XCTFail("dark mode: window has no background") }
        XCTAssertEqual(dark.3, 1, accuracy: 0.001, "dark mode: opaque")
        XCTAssertLessThan(max(dark.0, dark.1, dark.2), 0.2, "dark mode: dark, no light flash")
    }
}
