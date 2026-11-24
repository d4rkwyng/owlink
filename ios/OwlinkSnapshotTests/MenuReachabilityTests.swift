import XCTest
import UIKit
import CedricCore

/// The ••• menu is short (0.5.2 (18): Derek found it too long) and nothing
/// that was reachable before it was trimmed went away. Built here, as in
/// OverflowMenuTests, for three size classes (iPhone compact, iPad regular,
/// iPad compact as in a split) and two kinds of document (Markdown, with
/// its preview, and plain text).
///
/// "Reachable", each layout on its own: by touch with the bar as wide as it
/// gets (its buttons, their long-press menus, and the ••• menu), by touch
/// with every bar button collapsed into the ••• menu (each as its
/// `menuRepresentation`), and with a keyboard (the editor's key commands
/// and the menu bar's, MenuBar). The iPads are built as iPads (idiom and
/// more than one window, WindowSupport), so New Window and Open Preview in
/// New Window are in their menus. The baseline is a dump taken at b60886f
/// (MenuReachabilityBaseline.swift, written by testDumpReachableCommands).
@MainActor
final class MenuReachabilityTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var savedInvisibles = false

    override func setUp() async throws {
        // A title that changes with a setting (Show / Hide Invisibles).
        savedInvisibles = AppSettings.showInvisibles
        AppSettings.showInvisibles = false
    }

    override func tearDown() async throws {
        AppSettings.showInvisibles = savedInvisibles
        WindowSupport.overrideForTests = nil
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    struct SizeClass {
        let name: String
        let width: UIUserInterfaceSizeClass
        let size: CGSize
        /// Read mode on open: the default on an iPhone (an Edit button).
        let readMode: Bool
        /// An iPad: the idiom, and more than one window.
        let iPad: Bool
    }

    static let sizeClasses = [
        SizeClass(name: "iPhone compact", width: .compact, size: CGSize(width: 390, height: 844), readMode: true, iPad: false),
        SizeClass(name: "iPad regular", width: .regular, size: CGSize(width: 1024, height: 768), readMode: false, iPad: true),
        SizeClass(name: "iPad compact", width: .compact, size: CGSize(width: 507, height: 1024), readMode: false, iPad: true),
    ]
    static let documents = ["md", "txt"]

    private func editor(_ sc: SizeClass, _ ext: String) -> EditorViewController {
        // Kept until the next editor (or tearDown): the menus are built when read.
        WindowSupport.overrideForTests = (multipleScenes: sc.iPad, isPhone: !sc.iPad)
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(ext == "md" ? .markdown : .plain)
        doc.text = ext == "md" ? "# Owls\n\nHoot.\n" : "Owls\n\nHoot.\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: sc.readMode)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = sc.width
        nav.traitOverrides.userInterfaceIdiom = sc.iPad ? .pad : .phone
        let window = UIWindow(frame: CGRect(origin: .zero, size: sc.size))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    // MARK: Menu model

    /// What the system puts in the ••• menu for a collapsed bar button.
    private func overflowRepresentation(_ item: UIBarButtonItem) -> UIMenuElement {
        if let rep = item.menuRepresentation { return rep }
        let title = item.title ?? item.accessibilityLabel ?? ""
        let primary = UIAction(title: title) { _ in }
        if let menu = item.menu { return UIMenu(title: title, children: [primary] + menu.children) }
        return primary
    }

    private func barItems(_ editor: EditorViewController) -> [UIBarButtonItem] {
        (editor.navigationItem.rightBarButtonItems ?? []).reversed()
    }

    /// The ••• menu with the given bar buttons collapsed into it.
    private func overflowMenu(_ editor: EditorViewController, collapsing: [UIBarButtonItem]) -> UIMenu {
        UIMenu(children: collapsing.map(overflowRepresentation) + editor.moreMenuItems())
    }

    /// Every set of bar buttons a narrow bar may collapse, by the buttons'
    /// visibility priorities (BarCollapse), Undo and Redo included: a
    /// 402-pt iPhone collapsed those two and kept Edit (the b18 gate).
    private func collapseSets(_ editor: EditorViewController) -> [[UIBarButtonItem]] {
        BarCollapse.collapseSets(barItems(editor))
    }

    private func titles(_ element: UIMenuElement) -> [String] {
        switch element {
        case let menu as UIMenu:
            return menu.children.flatMap(titles)
        case let action as UIWindowScene.ActivationAction:
            // New Window: the system hides it in a host that can't open
            // windows (this iPhone simulator); an iPad shows it. Offering
            // it or not is the app's choice (WindowSupport).
            return action.title.isEmpty ? [] : [action.title]
        case let action as UIAction:
            return action.attributes.contains(.hidden) || action.title.isEmpty ? [] : [action.title]
        case let command as UICommand:
            return command.attributes.contains(.hidden) || command.title.isEmpty ? [] : [command.title]
        default:
            return []
        }
    }

    /// Rows at the top level of a menu: an inline group's rows count one
    /// each, a submenu is one row.
    func topLevelRows(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { e -> [String] in
            switch e {
            case let menu as UIMenu where menu.options.contains(.displayInline) && [.small, .medium].contains(menu.preferredElementSize) && !menu.children.isEmpty:
                // Small or medium elements: side by side, one row.
                return [topLevelRows(menu.children).joined(separator: " | ")]
            case let menu as UIMenu where menu.options.contains(.displayInline) || menu.title.isEmpty:
                return topLevelRows(menu.children)
            case let menu as UIMenu:
                return [menu.title + " ›"]
            case let action as UIAction:
                return action.attributes.contains(.hidden) ? [] : [action.title]
            case let command as UICommand:
                return command.attributes.contains(.hidden) ? [] : [command.title]
            default:
                return ["(deferred)"]
            }
        }
    }

    /// Every command title reachable, by layout: by touch with the bar
    /// wide (`expanded`) and with it collapsed (`collapsed`), and with a
    /// keyboard (`keys`).
    struct Reach {
        var expanded: Set<String> = []
        var collapsed: Set<String> = []
        var keys: Set<String> = []
        var all: Set<String> { expanded.union(collapsed).union(keys) }
    }

    private func reach(_ sc: SizeClass, _ ext: String) -> Reach {
        let editor = editor(sc, ext)
        var r = Reach()
        for item in barItems(editor) {
            if let t = item.title ?? item.accessibilityLabel, !t.isEmpty { r.expanded.insert(t) }
            if let menu = item.menu { r.expanded.formUnion(titles(menu)) }
        }
        r.expanded.formUnion(editor.moreMenuItems().flatMap(titles))
        r.collapsed = Set(titles(overflowMenu(editor, collapsing: barItems(editor))))
        r.keys = Set((editor.keyCommands ?? []).compactMap { $0.title.isEmpty ? nil : $0.title })
        for i in MenuBar.insertions(hasFind: true, hasSpelling: true, hasAppSettings: true) { r.keys.formUnion(titles(i.menu)) }
        return r
    }

    private func key(_ sc: SizeClass, _ ext: String) -> String { "\(sc.name) \(ext)" }

    // MARK: Tests

    /// Prints what is reachable now, as Swift, for the baseline file.
    func testDumpReachableCommands() {
        var out = "// Reachable command titles, dumped by MenuReachabilityTests.testDumpReachableCommands.\n"
        out += "extension MenuReachabilityTests {\n    static let baseline: [String: (expanded: [String], collapsed: [String], keys: [String])] = [\n"
        func list(_ s: Set<String>) -> String { s.sorted().map { "\"\($0)\"" }.joined(separator: ", ") }
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let r = reach(sc, ext)
                out += "        \"\(key(sc, ext))\": (expanded: [\(list(r.expanded))],\n"
                out += "            collapsed: [\(list(r.collapsed))],\n"
                out += "            keys: [\(list(r.keys))]),\n"
                let editor = editor(sc, ext)
                print("MENU-ROWS \(key(sc, ext)) none collapsed: \(topLevelRows(editor.moreMenuItems()))")
                for set in collapseSets(editor) {
                    print("MENU-ROWS \(key(sc, ext)) collapsed \(set.compactMap(\.accessibilityIdentifier)): \(topLevelRows(set.map(overflowRepresentation) + editor.moreMenuItems()))")
                }
            }
        }
        out += "    ]\n}\n"
        print("REACH-DUMP-BEGIN\n" + out + "REACH-DUMP-END")
    }

    /// Everything reachable at b60886f still is, per size class and
    /// document, layout by layout: by touch with the bar as wide as it gets,
    /// by touch with every button collapsed into the ••• menu, and at all
    /// (a keyboard too).
    func testEverythingReachableBeforeStillIs() throws {
        XCTAssertEqual(Self.baseline.count, Self.sizeClasses.count * Self.documents.count)
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let base = try XCTUnwrap(Self.baseline[key(sc, ext)], key(sc, ext))
                let now = reach(sc, ext)
                XCTAssertEqual(Set(base.expanded).subtracting(now.expanded).sorted(), [], "\(key(sc, ext)): no longer reachable by touch (bar not collapsed)")
                XCTAssertEqual(Set(base.collapsed).subtracting(now.collapsed).sorted(), [], "\(key(sc, ext)): no longer reachable by touch (bar collapsed)")
                XCTAssertEqual(Set(base.expanded + base.collapsed + base.keys).subtracting(now.all).sorted(), [], "\(key(sc, ext)): no longer reachable at all")
            }
        }
    }

    /// On an iPad, New Window and (Markdown) Open Preview in New Window are
    /// reachable by touch, with the bar wide and collapsed (Codex b18
    /// round 1: the baseline had been built without the iPad's windows).
    func testWindowCommandsReachableByTouchOnIPad() {
        for sc in Self.sizeClasses where sc.iPad {
            for ext in Self.documents {
                let now = reach(sc, ext)
                let want = ext == "md" ? ["New Window", "Open Preview in New Window"] : ["New Window"]
                for title in want {
                    XCTAssertTrue(now.expanded.contains(title), "\(key(sc, ext)): \(title) by touch (bar not collapsed)")
                    XCTAssertTrue(now.collapsed.contains(title), "\(key(sc, ext)): \(title) by touch (bar collapsed)")
                }
            }
        }
    }

    /// Share… (new in 0.5.2 (18), a copy of the document in the share
    /// sheet) is reachable by touch in every layout, bar wide and collapsed,
    /// in Share & Export › beside Print… and the exports.
    func testShareReachableByTouch() {
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let now = reach(sc, ext)
                for title in ["Share…", "Print…", "Export as HTML…", "Export as PDF…"] {
                    XCTAssertTrue(now.expanded.contains(title), "\(key(sc, ext)): \(title) by touch (bar not collapsed)")
                    XCTAssertTrue(now.collapsed.contains(title), "\(key(sc, ext)): \(title) by touch (bar collapsed)")
                }
                let editor = editor(sc, ext)
                let share = allSubmenus(editor.moreMenuItems()).first { $0.title == "Share & Export" }
                XCTAssertEqual(share.map(titles), ["Share…", "Print…", "Export as HTML…", "Export as PDF…"], key(sc, ext))
            }
        }
    }

    /// At most seven rows at the top of the ••• menu, for each size class
    /// and document: with no bar button collapsed into it, and with every
    /// set of buttons a narrow bar may collapse (Undo and Redo too, by
    /// their priorities, whatever the width: 375, 402, 440 pt or a split).
    /// Eight at most: the eighth is the one row the history buttons make,
    /// first (Undo, Redo, and Edit / Done on an iPhone in read mode).
    func testTopLevelHasAtMostSevenRows() {
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let editor = editor(sc, ext)
                let none = topLevelRows(editor.moreMenuItems())
                XCTAssertLessThanOrEqual(none.count, 7, "\(key(sc, ext)), none collapsed: \(none.count) rows: \(none)")
                let sets = collapseSets(editor)
                XCTAssertGreaterThan(sets.count, 2, "\(key(sc, ext)): the bar's priorities give no order to collapse in")
                for set in sets {
                    assertRowBudget(editor, collapsed: set, "\(key(sc, ext)), collapsed \(set.compactMap(\.accessibilityIdentifier))")
                }
            }
        }
    }

    /// The row budget with `collapsed` in the ••• menu: seven rows, eight
    /// at most, the eighth the history row (Undo and Redo side by side,
    /// with Edit / Done), first; and every collapsed button's command still
    /// in the menu, by touch.
    private func assertRowBudget(_ editor: EditorViewController, collapsed: [UIBarButtonItem], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let rows = topLevelRows(collapsed.map(overflowRepresentation) + editor.moreMenuItems())
        let history = rows.filter { $0.contains("Undo") || $0.contains("Redo") || ["Edit", "Done", "Read Only"].contains($0) }
        XCTAssertLessThanOrEqual(history.count, 1, "\(name): Undo, Redo and Edit take \(history.count) rows: \(rows)", file: file, line: line)
        XCTAssertLessThanOrEqual(rows.count, history.isEmpty ? 7 : 8, "\(name): \(rows.count) rows: \(rows)", file: file, line: line)
        if !history.isEmpty { XCTAssertEqual(rows.first, history.first, "\(name): the history row not first: \(rows)", file: file, line: line) }
        let menu = Set(titles(UIMenu(children: collapsed.map(overflowRepresentation) + editor.moreMenuItems())))
        for item in collapsed where ["editor.undo", "editor.redo", "editor.edit"].contains(item.accessibilityIdentifier ?? "") {
            let title = item.title ?? item.accessibilityLabel ?? "?"
            XCTAssertTrue(menu.contains(title), "\(name): \(title) collapsed and not in the ••• menu: \(rows)", file: file, line: line)
        }
    }
}
