import XCTest
import UIKit
import CedricCore

/// The ••• menu is short (0.5.2 (18): Derek found it too long) and nothing
/// that was reachable before it was trimmed went away. Built here, as in
/// OverflowMenuTests, for three size classes (iPhone compact, iPad regular,
/// iPad compact as in a split) and two kinds of document (Markdown, with
/// its preview, and plain text).
///
/// "Reachable": by touch, the bar's buttons (and their long-press menus)
/// plus the ••• menu with none of them collapsed into it, and the ••• menu
/// with every bar button collapsed into it (each as its
/// `menuRepresentation`); with a keyboard, also the editor's key commands
/// and the menu bar's (MenuBar). The baseline is a dump taken at b60886f
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
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    struct SizeClass {
        let name: String
        let width: UIUserInterfaceSizeClass
        let size: CGSize
        /// Read mode on open: the default on an iPhone (an Edit button).
        let readMode: Bool
    }

    static let sizeClasses = [
        SizeClass(name: "iPhone compact", width: .compact, size: CGSize(width: 390, height: 844), readMode: true),
        SizeClass(name: "iPad regular", width: .regular, size: CGSize(width: 1024, height: 768), readMode: false),
        SizeClass(name: "iPad compact", width: .compact, size: CGSize(width: 507, height: 1024), readMode: false),
    ]
    static let documents = ["md", "txt"]

    private func editor(_ sc: SizeClass, _ ext: String) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(ext == "md" ? .markdown : .plain)
        doc.text = ext == "md" ? "# Owls\n\nHoot.\n" : "Owls\n\nHoot.\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: sc.readMode)
        let nav = UINavigationController(rootViewController: editor)
        nav.traitOverrides.horizontalSizeClass = sc.width
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

    /// The bar buttons a narrow bar collapses: all but Undo and Redo (an
    /// iPhone keeps those two in the bar, as the UI dump shows).
    private func narrowCollapse(_ editor: EditorViewController) -> [UIBarButtonItem] {
        barItems(editor).filter { !["editor.undo", "editor.redo"].contains($0.accessibilityIdentifier ?? "") }
    }

    private func titles(_ element: UIMenuElement) -> [String] {
        switch element {
        case let menu as UIMenu:
            return menu.children.flatMap(titles)
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

    /// Every command title reachable, by channel.
    struct Reach {
        var expanded: Set<String> = []
        var collapsed: Set<String> = []
        var keys: Set<String> = []
        var touch: Set<String> { expanded.intersection(collapsed) }
        var all: Set<String> { touch.union(keys) }
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
        out += "extension MenuReachabilityTests {\n    static let baseline: [String: (touch: [String], all: [String])] = [\n"
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let r = reach(sc, ext)
                let touch = r.touch.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                let all = r.all.subtracting(r.touch).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                out += "        \"\(key(sc, ext))\": (touch: [\(touch)],\n            all: [\(all)]),\n"
                let editor = editor(sc, ext)
                print("MENU-ROWS \(key(sc, ext)) none collapsed: \(topLevelRows(editor.moreMenuItems()))")
                print("MENU-ROWS \(key(sc, ext)) narrow: \(topLevelRows(narrowCollapse(editor).map(overflowRepresentation) + editor.moreMenuItems()))")
            }
        }
        out += "    ]\n}\n"
        print("REACH-DUMP-BEGIN\n" + out + "REACH-DUMP-END")
    }

    /// Everything reachable at b60886f still is, per size class and
    /// document: by touch with the bar as wide as it gets and with every
    /// button collapsed into the ••• menu, and with a keyboard too.
    func testEverythingReachableBeforeStillIs() throws {
        XCTAssertEqual(Self.baseline.count, Self.sizeClasses.count * Self.documents.count)
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let base = try XCTUnwrap(Self.baseline[key(sc, ext)], key(sc, ext))
                let now = reach(sc, ext)
                let touch = Set(base.touch)
                XCTAssertEqual(touch.subtracting(now.expanded).sorted(), [], "\(key(sc, ext)): no longer reachable by touch (bar not collapsed)")
                XCTAssertEqual(touch.subtracting(now.collapsed).sorted(), [], "\(key(sc, ext)): no longer reachable by touch (bar collapsed)")
                XCTAssertEqual(touch.union(base.all).subtracting(now.all).sorted(), [], "\(key(sc, ext)): no longer reachable at all")
            }
        }
    }

    /// Six or seven rows at the top of the ••• menu, for each size class
    /// and document: with no bar button collapsed into it, and with the
    /// ones a narrow bar collapses (all but Undo and Redo).
    func testTopLevelHasSixOrSevenRows() {
        for sc in Self.sizeClasses {
            for ext in Self.documents {
                let editor = editor(sc, ext)
                let none = topLevelRows(editor.moreMenuItems())
                let narrow = topLevelRows(narrowCollapse(editor).map(overflowRepresentation) + editor.moreMenuItems())
                for (what, rows) in [("none collapsed", none), ("narrow bar", narrow)] {
                    XCTAssertTrue((6...7).contains(rows.count), "\(key(sc, ext)), \(what): \(rows.count) rows: \(rows)")
                }
            }
        }
    }
}
