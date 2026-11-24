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
        WindowSupport.overrideForTests = nil
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

    /// The groups (0.5.2 (18), seven rows, file actions first as in
    /// document apps): Save, Share & Export › | Find ›, Preview ›, Ask
    /// Cedric | More ›, Settings. The preview modes first in their
    /// submenu, the view toggles together, Save beside Share…, Print and the
    /// exports (Share & Export ›), find, marks and navigation together, and
    /// nothing dropped.
    func testMenuIsGroupedInline() throws {
        let editor = markdownEditor(width: .compact)
        let groups = editor.moreMenuItems().compactMap { $0 as? UIMenu }
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { $0.options.contains(.displayInline) }, [true, true, true])
        let tops = groups.map { $0.children.map { e in (e as? UIMenu).map { $0.title + " ›" } ?? (e as? UIAction)?.title ?? "?" } }
        XCTAssertEqual(tops, [["Save", "Share & Export ›"], ["Find ›", "Preview ›", "Ask Cedric"], ["More ›", "Settings"]])
        let all = flatten(UIMenu(children: editor.moreMenuItems()))
        func titles(under path: [String]) -> [String] { all.filter { $0.path == path }.map(\.title) }
        XCTAssertEqual(Array(titles(under: ["Preview"]).prefix(2)), ["Preview", "Focus Preview"])
        let view = titles(under: ["More", "View"])
        XCTAssertTrue(view.contains("Wrap Lines") && view.contains("Readable Width") && view.contains("Show Invisibles"), "\(view)")
        XCTAssertEqual(titles(under: ["Share & Export"]), ["Share…", "Print…", "Export as HTML…", "Export as PDF…"])
        XCTAssertFalse(allSubmenus(editor.moreMenuItems()).contains { $0.title == "Export & Print" }, "Export & Print › is gone from More ›")
        XCTAssertEqual(titles(under: ["Find"]), ["Find", "Find and Replace", "Find TODOs", "Mark All", "Clear Marks"])
        XCTAssertEqual(Array(titles(under: ["More"]).prefix(3)), ["Go to Line…", "Open Quickly…", "Statistics…"])
        // Nothing dropped: the identifiers the UI tests use are all there.
        let ids = Set(actions(editor.moreMenuItems()).compactMap(\.accessibilityIdentifier))
        for id in ["editor.menu.focusPreview", "editor.menu.print", "editor.menu.exportHTML", "editor.menu.exportPDF",
                   "editor.menu.quickOpen", "tools.menu.todos", "stats.menu", "editor.menu.wrapLines",
                   "editor.menu.showInvisibles", "editor.menu.readableWidth", "editor.menu.fixTypos", "editor.menu.share"] {
            XCTAssertTrue(ids.contains(id), "\(id) missing")
        }
        for title in ["Ask Cedric", "Check with Cedric", "Settings", "Statistics…", "Find TODOs", "Share…"] {
            XCTAssertTrue(flatten(UIMenu(children: editor.moreMenuItems())).contains { $0.title == title }, "\(title) missing")
        }
    }

    // MARK: Top-level order, per layout

    private struct Layout {
        let name: String
        let width: UIUserInterfaceSizeClass
        let size: CGSize
        let readMode: Bool
        let iPad: Bool
    }

    private static let layouts = [
        Layout(name: "iPhone compact", width: .compact, size: CGSize(width: 390, height: 844), readMode: true, iPad: false),
        Layout(name: "iPad regular", width: .regular, size: CGSize(width: 1024, height: 768), readMode: false, iPad: true),
        Layout(name: "iPad compact", width: .compact, size: CGSize(width: 507, height: 1024), readMode: false, iPad: true),
    ]

    private func editor(_ layout: Layout, _ ext: String) -> EditorViewController {
        WindowSupport.overrideForTests = (multipleScenes: layout.iPad, isPhone: !layout.iPad)
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(ext == "md" ? .markdown : .plain)
        doc.text = ext == "md" ? "# Owls\n\nHoot.\n" : "Owls\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: layout.readMode)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = layout.width
        nav.traitOverrides.userInterfaceIdiom = layout.iPad ? .pad : .phone
        let window = UIWindow(frame: CGRect(origin: .zero, size: layout.size))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    /// The top level as groups of rows: an inline group's rows, a submenu
    /// as "Title ›".
    private func topGroups(_ elements: [UIMenuElement]) -> [[String]] {
        elements.map { e -> [String] in
            guard let group = e as? UIMenu, group.options.contains(.displayInline) || group.title.isEmpty else {
                return [(e as? UIMenu).map { $0.title + " ›" } ?? (e as? UIAction)?.title ?? "?"]
            }
            return group.children.compactMap { c -> String? in
                if let m = c as? UIMenu { return m.options.contains(.displayInline) && m.children.isEmpty ? nil : m.title + " ›" }
                if let a = c as? UIAction { return a.attributes.contains(.hidden) ? nil : a.title }
                return "?"
            }
        }.filter { !$0.isEmpty }
    }

    /// The ••• menu with the bar buttons a narrow bar collapses: all but
    /// Undo and Redo (an iPhone keeps those two in the bar).
    private func narrowMenu(_ editor: EditorViewController) -> UIMenu {
        let bar = (editor.navigationItem.rightBarButtonItems ?? []).reversed()
            .filter { !["editor.undo", "editor.redo"].contains($0.accessibilityIdentifier ?? "") }
        return UIMenu(children: bar.map(overflowRepresentation) + editor.moreMenuItems())
    }

    /// The exact top level of the ••• menu, groups and order, for each
    /// layout and document: with no bar button collapsed into it, and with
    /// the ones a narrow bar collapses (an iPhone in read mode adds Edit,
    /// first).
    func testTopLevelOrderPerLayout() {
        defer { WindowSupport.overrideForTests = nil }
        for layout in Self.layouts {
            for ext in ["md", "txt"] {
                let name = "\(layout.name) \(ext)"
                let editor = editor(layout, ext)
                let preview = ext == "md" ? "Preview ›" : "View ›"
                let want = [["Save", "Share & Export ›"], ["Find ›", preview, "Ask Cedric"], ["More ›", "Settings"]]
                XCTAssertEqual(topGroups(editor.moreMenuItems()), want, "\(name), none collapsed")
                XCTAssertEqual(topGroups(editor.moreMenuItems()).flatMap { $0 }.first, "Save", "\(name): Save first")
                let collapsed = narrowMenu(editor).children
                let edit = layout.readMode && !layout.iPad
                XCTAssertEqual(topGroups(collapsed), (edit ? [["Edit"]] : []) + want, "\(name), bar collapsed")
                let rows = topGroups(collapsed).flatMap { $0 }
                XCTAssertEqual(Array(rows.prefix(edit ? 2 : 1)), edit ? ["Edit", "Save"] : ["Save"], "\(name), bar collapsed: Save first (after Edit)")
                assertNoDuplicates(narrowMenu(editor), "\(name), bar collapsed")
                assertNoDuplicates(overflowMenu(editor, collapsed: true), "\(name), every button collapsed")
                assertNoDuplicates(overflowMenu(editor, collapsed: false), "\(name), none collapsed")
            }
        }
    }

    // MARK: Share…

    /// Share… shows the share sheet with one item: a copy of the document
    /// as it is now, as a file named like the document; the copy goes when
    /// the sheet is done.
    func testShareSharesACopyNamedForTheDocument() throws {
        for ext in ["md", "txt"] {
            let editor = editor(Self.layouts[0], ext)
            defer { WindowSupport.overrideForTests = nil }
            editor.textView.text += "Unsaved line.\n"
            let share = try XCTUnwrap(actions(editor.moreMenuItems()).first { $0.accessibilityIdentifier == "editor.menu.share" })
            XCTAssertEqual(share.title, "Share…")
            XCTAssertTrue(flatten(UIMenu(children: editor.moreMenuItems())).contains { $0.title == "Share…" && $0.path == ["Share & Export"] })
            editor.shareDocumentCopy()
            // The share sheet presents once its activities are loaded.
            for _ in 0..<50 where editor.presentedViewController == nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let activity = try XCTUnwrap(editor.presentedViewController as? UIActivityViewController, "\(ext): no share sheet")
            XCTAssertEqual(editor.sharedCopyItems.count, 1)
            let file = try XCTUnwrap(editor.sharedCopyItems.first)
            XCTAssertTrue(file.isFileURL)
            XCTAssertEqual(file.lastPathComponent, editor.document.displayName)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), editor.textView.text)
            activity.completionWithItemsHandler?(nil, false, nil, nil)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the copy stays after the sheet")
            editor.dismiss(animated: false)
        }
    }

    /// Without a preview (plain text) the view toggles take Preview's
    /// place at the top, as View ›; no title twice, collapsed or not, on
    /// any width (an iPad in a split is compact too).
    func testPlainTextMenuHasViewAndNoDuplicates() {
        for width in [UIUserInterfaceSizeClass.compact, .regular] {
            let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
            doc.text = "Owls\n"
            let editor = EditorViewController(document: doc, readModeOnOpen: width == .compact)
            let nav = UINavigationController(rootViewController: editor)
            nav.traitOverrides.horizontalSizeClass = width
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width == .compact ? 390 : 1024, height: 800))
            window.rootViewController = nav
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            windows.append(window)
            for collapsed in [false, true] {
                let menu = overflowMenu(editor, collapsed: collapsed)
                assertNoDuplicates(menu, "plain text, width \(width.rawValue), collapsed \(collapsed)")
                XCTAssertFalse(flatten(menu).contains { $0.title == "Focus Preview" })
                XCTAssertEqual(flatten(menu).filter { $0.path == ["View"] }.map(\.title), ["Wrap Lines", "Show Invisibles", "Readable Width"])
            }
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

/// Every submenu of a menu tree, nested ones too (the ••• menu keeps most
/// of its commands in submenus: More ›, View ›, …).
@MainActor func allSubmenus(_ elements: [UIMenuElement]) -> [UIMenu] {
    elements.compactMap { $0 as? UIMenu }.flatMap { [$0] + allSubmenus($0.children) }
}
