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
        // The pinned group (an iPad's Undo, Redo, Edit / Done) stays in the
        // bar however narrow (UIKit never collapses it), as its buttons or
        // their representative's menu.
        if let pinned = editor.navigationItem.pinnedTrailingGroup {
            var inBar = Set(pinned.barButtonItems.compactMap { $0.title ?? $0.accessibilityLabel }.filter { !$0.isEmpty })
            r.expanded.formUnion(inBar)
            if let menu = pinned.representativeItem?.menu { inBar = Set(titles(menu)) }
            r.collapsed.formUnion(inBar)
        }
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

    /// On an iPad, Undo, Redo and (read mode) Edit / Done are the bar's
    /// pinned group, which UIKit never collapses into the ••• menu, and
    /// not among the buttons that can collapse; its representative (a
    /// narrow slide-over) has the three, by touch. On an iPhone they are
    /// among the bar's buttons (and not pinned).
    func testHistoryPinnedOnIPadOnly() {
        defer { EditorViewController.barPrioritiesOverrideForTests = nil }
        for priorities in BarCollapse.priorityPaths {
            EditorViewController.barPrioritiesOverrideForTests = priorities
            for sc in Self.sizeClasses {
                for readMode in [false, true] {
                    let name = "\(sc.name), read mode \(readMode), priorities \(priorities)"
                    let editor = editor(SizeClass(name: sc.name, width: sc.width, size: sc.size, readMode: readMode, iPad: sc.iPad), "md")
                    let want = ["editor.undo", "editor.redo"] + (readMode ? ["editor.edit"] : [])
                    let bar = barItems(editor).compactMap(\.accessibilityIdentifier)
                    let pinned = editor.navigationItem.pinnedTrailingGroup
                    if sc.iPad {
                        XCTAssertEqual(pinned?.barButtonItems.compactMap(\.accessibilityIdentifier), want, "\(name): not pinned")
                        XCTAssertEqual(bar.filter(want.contains), [], "\(name): among the buttons that collapse")
                        let rep = pinned?.representativeItem?.menu.map { UIMenu(children: [$0]) }
                        XCTAssertNotNil(rep, "\(name): no representative for a narrow bar")
                        let repTitles = rep.map(titles) ?? []
                        for t in ["Undo", "Redo"] + (readMode ? ["Edit"] : []) {
                            XCTAssertTrue(repTitles.contains(t), "\(name): \(t) not in the representative's menu")
                        }
                    } else {
                        XCTAssertNil(pinned, "\(name): pinned on an iPhone")
                        XCTAssertEqual(bar.filter(want.contains), want, "\(name): not in the bar")
                    }
                }
            }
        }
    }

    /// The iPad's pinned representative (editor.history: the one button a
    /// bar too narrow for the pinned group shows) by its menu, end to end
    /// at model level: Edit from it enters editing, typed text, its Undo
    /// removes it, its Redo restores it, its Done leaves editing; its
    /// Undo and Redo enabled exactly when there is something to undo or
    /// redo (never in read mode), as the pinned bar buttons are. (The
    /// representative itself isn't brought up on a simulator: a full-screen
    /// iPad's bar always fits the group, and no launch argument narrows the
    /// window; Codex b18 re-check 3, item 2.)
    func testPinnedRepresentativeRunsUndoRedoAndEdit() throws {
        defer { EditorViewController.barPrioritiesOverrideForTests = nil }
        for priorities in BarCollapse.priorityPaths {
            EditorViewController.barPrioritiesOverrideForTests = priorities
            for sc in Self.sizeClasses where sc.iPad {
                let name = "\(sc.name), priorities \(priorities)"
                let editor = editor(SizeClass(name: sc.name, width: sc.width, size: sc.size, readMode: true, iPad: true), "md")
                let pinned = try XCTUnwrap(editor.navigationItem.pinnedTrailingGroup, "\(name): nothing pinned")
                let rep = try XCTUnwrap(pinned.representativeItem, "\(name): no representative")
                XCTAssertEqual(rep.accessibilityIdentifier, "editor.history", name)
                func bar(_ id: String) throws -> UIBarButtonItem {
                    try XCTUnwrap(pinned.barButtonItems.first { $0.accessibilityIdentifier == id }, "\(name): no \(id) pinned")
                }
                // The representative's menu as it is now (rebuilt on each change).
                func item(_ id: String, line: UInt = #line) throws -> UIAction {
                    let menu = try XCTUnwrap(pinned.representativeItem?.menu, "\(name): the representative has no menu", line: line)
                    func find(_ e: UIMenuElement) -> UIAction? {
                        if let a = e as? UIAction { return a.accessibilityIdentifier == id ? a : nil }
                        return (e as? UIMenu)?.children.lazy.compactMap(find).first
                    }
                    return try XCTUnwrap(find(menu), "\(name): no \(id) in the representative's menu", line: line)
                }
                func enabled(_ id: String, line: UInt = #line) throws -> Bool {
                    try !item(id, line: line).attributes.contains(.disabled)
                }
                func states(_ undo: Bool, _ redo: Bool, _ when: String, line: UInt = #line) throws {
                    XCTAssertEqual(try enabled("editor.menu.undo", line: line), undo, "\(name): the representative's Undo \(when)", line: line)
                    XCTAssertEqual(try enabled("editor.menu.redo", line: line), redo, "\(name): the representative's Redo \(when)", line: line)
                    XCTAssertEqual(try bar("editor.undo").isEnabled, undo, "\(name): the pinned Undo \(when)", line: line)
                    XCTAssertEqual(try bar("editor.redo").isEnabled, redo, "\(name): the pinned Redo \(when)", line: line)
                }
                let original = editor.textView.text ?? ""
                // A turn of the run loop, as between two touches: the typing's
                // undo group closes (the undo manager groups by event).
                func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
                settle()

                // Read mode: Edit, nothing to undo or redo.
                XCTAssertEqual(try item("editor.menu.edit").title, "Edit", "\(name): read mode")
                try states(false, false, "in read mode")
                try item("editor.menu.edit").performWithSender(nil, target: nil)
                settle()
                XCTAssertTrue(editor.textView.isEditable, "\(name): Edit from the representative didn't enter editing")
                XCTAssertEqual(try item("editor.menu.edit").title, "Done", "\(name): editing")
                XCTAssertEqual(try bar("editor.edit").title, "Done", "\(name): editing, the pinned button")
                try states(false, false, "editing, nothing typed")

                // Typed: Undo from the representative removes it, Redo restores it.
                editor.textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
                editor.textView.insertText("hoot")
                settle()
                let typed = editor.textView.text ?? ""
                XCTAssertEqual(typed, original + "hoot", "\(name): typing")
                try states(true, false, "with typing to undo")
                try item("editor.menu.undo").performWithSender(nil, target: nil)
                settle()
                XCTAssertEqual(editor.textView.text, original, "\(name): Undo from the representative")
                try states(false, true, "after Undo")
                try item("editor.menu.redo").performWithSender(nil, target: nil)
                settle()
                XCTAssertEqual(editor.textView.text, typed, "\(name): Redo from the representative")
                try states(true, false, "after Redo")

                // Done: back to read mode, Undo and Redo disabled.
                try item("editor.menu.edit").performWithSender(nil, target: nil)
                settle()
                XCTAssertFalse(editor.textView.isEditable, "\(name): Done from the representative didn't leave editing")
                XCTAssertEqual(try item("editor.menu.edit").title, "Edit", "\(name): back in read mode")
                XCTAssertEqual(editor.textView.text, typed, "\(name): Done changed the text")
                try states(false, false, "back in read mode")
            }
        }
    }

    /// At most seven rows at the top of the ••• menu, for each size class
    /// and document: with no bar button collapsed into it, and with every
    /// set of buttons a narrow bar may collapse (Undo and Redo too, by
    /// their priorities, whatever the width: 375, 402, 440 pt or a split).
    /// Eight at most: the eighth is the one row the history buttons make,
    /// first (Undo, Redo, and Edit / Done on an iPhone in read mode).
    /// Before iOS 27 (no priorities, modelled on any runtime: Codex b18
    /// re-check 2) UIKit may collapse any set: each of Undo, Redo and Edit
    /// collapsed is its own row, so none is ever out of reach.
    func testTopLevelHasAtMostSevenRows() {
        defer { EditorViewController.barPrioritiesOverrideForTests = nil }
        for priorities in BarCollapse.priorityPaths {
            EditorViewController.barPrioritiesOverrideForTests = priorities
            for sc in Self.sizeClasses {
                for ext in Self.documents {
                    let editor = editor(sc, ext)
                    let name = "\(key(sc, ext)), priorities \(priorities)"
                    let none = topLevelRows(editor.moreMenuItems())
                    XCTAssertLessThanOrEqual(none.count, 7, "\(name), none collapsed: \(none.count) rows: \(none)")
                    let sets = collapseSets(editor)
                    let n = barItems(editor).count
                    if priorities && n >= 2 {
                        XCTAssertGreaterThan(sets.count, 2, "\(name): the bar's priorities give no order to collapse in")
                    } else {
                        // Without priorities, or one button (an iPad's txt
                        // bar: Find; the rest pinned): any set may collapse.
                        XCTAssertEqual(sets.count, 1 << n, "\(name): without priorities any set may collapse")
                    }
                    for set in sets {
                        assertRowBudget(editor, collapsed: set, priorities: priorities, iPad: sc.iPad, "\(name), collapsed \(set.compactMap(\.accessibilityIdentifier))")
                    }
                }
            }
        }
    }

    /// The row budget with `collapsed` in the ••• menu: seven rows, eight
    /// at most, the eighth the history row (Undo and Redo side by side,
    /// with Edit / Done), first. Without priorities: seven rows plus one
    /// for each of Undo, Redo and Edit collapsed, each a row of its own,
    /// first. Either way every collapsed button's command still in the
    /// menu, by touch, enabled as the button is.
    private func assertRowBudget(_ editor: EditorViewController, collapsed: [UIBarButtonItem], priorities: Bool, iPad: Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let rows = topLevelRows(collapsed.map(overflowRepresentation) + editor.moreMenuItems())
        let history = rows.filter { $0.contains("Undo") || $0.contains("Redo") || ["Edit", "Done", "Read Only"].contains($0) }
        let gone = collapsed.filter { ["editor.undo", "editor.redo", "editor.edit"].contains($0.accessibilityIdentifier ?? "") }
        if iPad {
            // An iPad: seven rows, never a history row (Undo, Redo and
            // Edit / Done pinned in the bar).
            XCTAssertEqual(history, [], "\(name): a history row on an iPad: \(rows)", file: file, line: line)
            XCTAssertLessThanOrEqual(rows.count, 7, "\(name): \(rows.count) rows: \(rows)", file: file, line: line)
        } else if priorities {
            XCTAssertLessThanOrEqual(history.count, 1, "\(name): Undo, Redo and Edit take \(history.count) rows: \(rows)", file: file, line: line)
            XCTAssertLessThanOrEqual(rows.count, history.isEmpty ? 7 : 8, "\(name): \(rows.count) rows: \(rows)", file: file, line: line)
        } else {
            XCTAssertEqual(history.count, gone.count, "\(name): one row for each of Undo, Redo and Edit collapsed: \(rows)", file: file, line: line)
            XCTAssertLessThanOrEqual(rows.count, 7 + gone.count, "\(name): \(rows.count) rows: \(rows)", file: file, line: line)
        }
        XCTAssertEqual(Array(rows.prefix(history.count)), history, "\(name): the history rows not first: \(rows)", file: file, line: line)
        let menu = UIMenu(children: collapsed.map(overflowRepresentation) + editor.moreMenuItems())
        let titled = Set(titles(menu))
        for item in gone {
            let title = item.title ?? item.accessibilityLabel ?? "?"
            XCTAssertTrue(titled.contains(title), "\(name): \(title) collapsed and not in the ••• menu: \(rows)", file: file, line: line)
            let action = allActions(menu).first { $0.title == title }
            XCTAssertEqual(action.map { !$0.attributes.contains(.disabled) }, item.isEnabled, "\(name): \(title) in the ••• menu not enabled as its button is", file: file, line: line)
        }
    }

    private func allActions(_ element: UIMenuElement) -> [UIAction] {
        if let menu = element as? UIMenu { return menu.children.flatMap(allActions) }
        return (element as? UIAction).map { [$0] } ?? []
    }
}
