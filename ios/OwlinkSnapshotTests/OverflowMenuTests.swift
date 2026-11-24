import XCTest
import UIKit
import CedricCore

/// The editor's ••• menu is the system overflow menu: the bar buttons that
/// don't fit (each as its `menuRepresentation`, or by default an action
/// named for the button, a submenu if it has a menu) followed by the
/// editor's `additionalOverflowItems` (moreMenuItems). Built here for a
/// Markdown document with its preview, as an iPhone (compact width, every
/// bar button collapsed) and an iPad (regular width, with none and with
/// all of them collapsed: a narrow iPad bar collapses them too). No command
/// is listed twice, and Focus Preview is there exactly once, in the
/// Preview submenu beside the other preview modes.
@MainActor
final class OverflowMenuTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func markdownEditor(width: UIUserInterfaceSizeClass) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "# Owls\n\nHoot.\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = width
        let size = width == .compact ? CGSize(width: 390, height: 844) : CGSize(width: 1024, height: 768)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    /// What the system puts in the overflow menu for a collapsed button.
    private func overflowRepresentation(_ item: UIBarButtonItem) -> UIMenuElement {
        if let rep = item.menuRepresentation { return rep }
        let title = item.title ?? item.accessibilityLabel ?? ""
        let primary = UIAction(title: title) { _ in }
        if let menu = item.menu { return UIMenu(title: title, children: [primary] + menu.children) }
        return primary
    }

    private func overflowMenu(_ editor: EditorViewController, collapsed: Bool, focus: Bool = false) -> UIMenu {
        let bar = collapsed ? (editor.navigationItem.rightBarButtonItems ?? []).reversed().map(overflowRepresentation) : []
        return UIMenu(children: bar + (focus ? editor.focusMenuItems() : editor.moreMenuItems()))
    }

    /// Every command in the menu, with the submenu titles above it.
    private func flatten(_ element: UIMenuElement, path: [String] = []) -> [(title: String, path: [String])] {
        switch element {
        case let menu as UIMenu:
            let inner = menu.options.contains(.displayInline) || menu.title.isEmpty ? path : path + [menu.title]
            return menu.children.flatMap { flatten($0, path: inner) }
        case let action as UIAction:
            return action.attributes.contains(.hidden) ? [] : [(action.title, path)]
        case let command as UICommand:
            return command.attributes.contains(.hidden) ? [] : [(command.title, path)]
        default:
            return []
        }
    }

    private func assertNoDuplicates(_ menu: UIMenu, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let titles = flatten(menu).map(\.title)
        let dupes = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(dupes, [], "\(name): listed more than once", file: file, line: line)
    }

    private func assertOneFocusPreviewInPreviewSubmenu(_ menu: UIMenu, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let focus = flatten(menu).filter { $0.title == "Focus Preview" }
        XCTAssertEqual(focus.count, 1, "\(name): Focus Preview \(focus.count) times: \(focus.map(\.path))", file: file, line: line)
        XCTAssertEqual(focus.first?.path, ["Preview"], "\(name): Focus Preview not in the Preview submenu", file: file, line: line)
        // Next to the other preview modes.
        let preview = flatten(menu).filter { $0.path == ["Preview"] }.map(\.title)
        XCTAssertTrue(preview.contains("Preview"), "\(name): no Preview toggle in the Preview submenu: \(preview)", file: file, line: line)
    }

    func testIPhoneCompactMenuHasNoDuplicates() {
        let editor = markdownEditor(width: .compact)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.togglePreview), withSender: nil))
        for collapsed in [true, false] {
            let menu = overflowMenu(editor, collapsed: collapsed)
            assertNoDuplicates(menu, "iPhone, collapsed \(collapsed)")
            assertOneFocusPreviewInPreviewSubmenu(menu, "iPhone, collapsed \(collapsed)")
        }
    }

    func testIPadRegularMenuHasNoDuplicates() {
        let editor = markdownEditor(width: .regular)
        for collapsed in [false, true] {
            let menu = overflowMenu(editor, collapsed: collapsed)
            assertNoDuplicates(menu, "iPad, collapsed \(collapsed)")
            assertOneFocusPreviewInPreviewSubmenu(menu, "iPad, collapsed \(collapsed)")
        }
    }

    /// With Save automatically off the bar has a Save button: collapsed,
    /// it doesn't add a second Save to the menu's file group.
    func testSaveButtonDoesNotRepeatSave() {
        let was = AppSettings.saveAutomatically
        defer { AppSettings.saveAutomatically = was }
        AppSettings.saveAutomatically = false
        for width in [UIUserInterfaceSizeClass.compact, .regular] {
            let editor = markdownEditor(width: width)
            let menu = overflowMenu(editor, collapsed: true)
            XCTAssertEqual(flatten(menu).filter { $0.title == "Save" }.count, 1, "width \(width.rawValue)")
            assertNoDuplicates(menu, "Save button, width \(width.rawValue)")
        }
    }

    /// The groups: view/preview, file, find/marks/navigation, then the rest.
    func testMenuIsGroupedInline() throws {
        let editor = markdownEditor(width: .compact)
        let groups = editor.moreMenuItems().compactMap { $0 as? UIMenu }
        XCTAssertGreaterThanOrEqual(groups.count, 4)
        let titles = groups.prefix(3).map { flatten($0).map(\.title) }
        XCTAssertEqual(groups.prefix(4).map { $0.options.contains(.displayInline) }, [true, true, true, true])
        XCTAssertEqual(Array(titles[0].prefix(2)), ["Preview", "Focus Preview"])
        XCTAssertTrue(titles[0].contains("Wrap Lines") && titles[0].contains("Readable Width"))
        XCTAssertEqual(titles[1], ["Save", "Print…", "Export as HTML…", "Export as PDF…"])
        XCTAssertEqual(Array(titles[2].prefix(5)), ["Find and Replace", "Mark All", "Clear Marks", "Go to Line…", "Open Quickly…"])
        // Nothing dropped: the identifiers the UI tests use are all there.
        let ids = Set(actions(editor.moreMenuItems()).compactMap(\.accessibilityIdentifier))
        for id in ["editor.menu.focusPreview", "editor.menu.print", "editor.menu.exportHTML", "editor.menu.exportPDF",
                   "editor.menu.quickOpen", "tools.menu.todos", "stats.menu", "editor.menu.wrapLines",
                   "editor.menu.showInvisibles", "editor.menu.readableWidth", "editor.menu.fixTypos"] {
            XCTAssertTrue(ids.contains(id), "\(id) missing")
        }
        for title in ["Ask Cedric", "Check with Cedric", "Settings", "Statistics…", "Find TODOs"] {
            XCTAssertTrue(flatten(UIMenu(children: editor.moreMenuItems())).contains { $0.title == title }, "\(title) missing")
        }
    }

    private func actions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.flatMap { e -> [UIAction] in
            if let m = e as? UIMenu { return actions(m.children) }
            return (e as? UIAction).map { [$0] } ?? []
        }
    }

    func testFocusPreviewOverflowMenuHasNoDuplicates() {
        for width in [UIUserInterfaceSizeClass.compact, .regular] {
            let editor = markdownEditor(width: width)
            editor.toggleFocusPreview()
            XCTAssertTrue(editor.focusOn)
            for collapsed in [false, true] {
                let menu = overflowMenu(editor, collapsed: collapsed, focus: true)
                assertNoDuplicates(menu, "Focus Preview, width \(width.rawValue), collapsed \(collapsed)")
                XCTAssertEqual(flatten(menu).filter { $0.title == "Exit Focus Preview" }.count, 1)
                XCTAssertFalse(flatten(menu).contains { $0.title == "Focus Preview" })
            }
        }
    }

    /// The iPad menu bar: no menu lists a command title twice (hidden
    /// shortcut aliases like ⌘= for Bigger aside), and Focus Preview is in
    /// it once, under View with its shortcut.
    func testMenuBarHasNoDuplicatesWithinAMenu() {
        for (find, spelling) in [(true, true), (false, false)] {
            let all = MenuBar.insertions(hasFind: find, hasSpelling: spelling)
            var byTarget: [String: [UIMenuElement]] = [:]
            for i in all {
                let key: String
                switch i.place {
                case .startOf(let id), .endOf(let id), .replacing(let id): key = id.rawValue
                case .after: key = i.menu.title
                }
                byTarget[key, default: []].append(i.menu)
            }
            for (target, menus) in byTarget {
                assertNoDuplicates(UIMenu(children: menus), "menu bar \(target)")
            }
            let focus = all.flatMap { flatten($0.menu) }.filter { $0.title == "Focus Preview" }
            XCTAssertEqual(focus.count, 1)
            let view = all.first { $0.place == .startOf(.view) }?.menu.children.compactMap { $0 as? UIKeyCommand }
            XCTAssertEqual(view?.first { $0.title == "Preview" }?.input, "p")
            XCTAssertEqual(view?.first { $0.title == "Preview" }?.modifierFlags, [.command, .shift])
        }
    }
}
