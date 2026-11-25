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

    private func editor(_ layout: Layout, _ ext: String, bytes: Data? = nil) -> EditorViewController {
        WindowSupport.overrideForTests = (multipleScenes: layout.iPad, isPhone: !layout.iPad)
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(ext == "md" ? .markdown : .plain)
        doc.text = ext == "md" ? "# Owls\n\nHoot.\n" : "Owls\n"
        if let bytes { try? doc.load(fromContents: bytes, ofType: nil) }
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
            // Small or medium elements: side by side, one row.
            if group.options.contains(.displayInline), [.small, .medium].contains(group.preferredElementSize), !group.children.isEmpty {
                return [group.children.compactMap { ($0 as? UIAction)?.title ?? "?" }.joined(separator: " | ")]
            }
            return group.children.compactMap { c -> String? in
                if let m = c as? UIMenu { return m.options.contains(.displayInline) && m.children.isEmpty ? nil : m.title + " ›" }
                if let a = c as? UIAction { return a.attributes.contains(.hidden) ? nil : a.title }
                return "?"
            }
        }.filter { !$0.isEmpty }
    }

    /// The ••• menu with `collapsed` (bar buttons) in it.
    private func narrowMenu(_ editor: EditorViewController, _ collapsed: [UIBarButtonItem]) -> UIMenu {
        UIMenu(children: collapsed.map(overflowRepresentation) + editor.moreMenuItems())
    }

    /// The exact top level of the ••• menu, groups and order, for each
    /// layout and document: with no bar button collapsed into it, and with
    /// every set of buttons a narrow bar may collapse by their priorities
    /// (BarCollapse), Undo and Redo included: once one of Undo, Redo and
    /// Edit / Done has gone, one row of the three, first. Before iOS 27
    /// (no priorities, modelled on any runtime) any set may go, in any
    /// order: each of the three collapsed is its own row, first.
    func testTopLevelOrderPerLayout() {
        defer { WindowSupport.overrideForTests = nil; EditorViewController.barPrioritiesOverrideForTests = nil }
        for priorities in BarCollapse.priorityPaths {
            EditorViewController.barPrioritiesOverrideForTests = priorities
            for layout in Self.layouts {
                for ext in ["md", "txt"] {
                    let name = "\(layout.name) \(ext), priorities \(priorities)"
                    let editor = editor(layout, ext)
                    let preview = ext == "md" ? "Preview ›" : "View ›"
                    let want = [["Save", "Share & Export ›"], ["Find ›", preview, "Ask Cedric"], ["More ›", "Settings"]]
                    XCTAssertEqual(topGroups(editor.moreMenuItems()), want, "\(name), none collapsed")
                    XCTAssertEqual(topGroups(editor.moreMenuItems()).flatMap { $0 }.first, "Save", "\(name): Save first")
                    let bar = Array((editor.navigationItem.rightBarButtonItems ?? []).reversed())
                    let editTitle = bar.first { $0.accessibilityIdentifier == "editor.edit" }?.title
                    let historyRow = (["Undo", "Redo"] + [editTitle].compactMap { $0 }).joined(separator: " | ")
                    let sets = BarCollapse.collapseSets(bar)
                    if priorities && bar.count >= 2 {
                        XCTAssertGreaterThan(sets.count, 2, "\(name): the bar's priorities give no order to collapse in")
                    } else {
                        // Without priorities, or one button (an iPad's txt
                        // bar: Find; the rest pinned): any set may collapse.
                        XCTAssertEqual(sets.count, 1 << bar.count, "\(name): without priorities any set may collapse")
                    }
                    for set in sets {
                        let gone = set.compactMap(\.accessibilityIdentifier)
                        let historyGone = set.filter { ["editor.undo", "editor.redo", "editor.edit"].contains($0.accessibilityIdentifier ?? "") }
                        let lead: [String]
                        if priorities {
                            lead = historyGone.isEmpty ? [] : [historyRow]
                        } else {
                            lead = historyGone.map { $0.title ?? "?" }
                        }
                        let collapsed = narrowMenu(editor, set).children
                        XCTAssertEqual(topGroups(collapsed), lead.map { [$0] } + want, "\(name), collapsed \(gone)")
                        let rows = topGroups(collapsed).flatMap { $0 }
                        XCTAssertEqual(Array(rows.prefix(lead.count + 1)), lead + ["Save"], "\(name), collapsed \(gone): Save first (after the history rows)")
                        assertNoDuplicates(narrowMenu(editor, set), "\(name), collapsed \(gone)")
                    }
                    assertNoDuplicates(overflowMenu(editor, collapsed: true), "\(name), every button collapsed")
                    assertNoDuplicates(overflowMenu(editor, collapsed: false), "\(name), none collapsed")
                }
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

    /// Share… sends what Save would write, byte for byte: mixed LF/CRLF
    /// keep each line's own ending, a BOM stays (UTF-8 and UTF-16), with
    /// and without an unsaved edit.
    func testShareSendsTheBytesSaveWrites() throws {
        let utf16 = Data([0xFF, 0xFE]) + "Owls\r\nHoot\r\n".data(using: .utf16LittleEndian)!
        let documents: [(String, Data)] = [
            ("mixed LF/CRLF", Data("One\nTwo\r\nThree\nFour\r\n".utf8)),
            ("UTF-8 BOM", Data([0xEF, 0xBB, 0xBF]) + Data("Owls\nHoot\n".utf8)),
            ("UTF-8 BOM, mixed", Data([0xEF, 0xBB, 0xBF]) + Data("Owls\r\nHoot\nWhoo\r\n".utf8)),
            ("UTF-16 BOM", utf16),
        ]
        for (name, bytes) in documents {
            for edit in [false, true] {
                let editor = editor(Self.layouts[0], "txt", bytes: bytes)
                defer { WindowSupport.overrideForTests = nil }
                if edit { editor.textView.text += "Unsaved line.\n" }
                editor.shareDocumentCopy()
                for _ in 0..<50 where editor.presentedViewController == nil {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                let activity = try XCTUnwrap(editor.presentedViewController as? UIActivityViewController, "\(name): no share sheet")
                let file = try XCTUnwrap(editor.sharedCopyItems.first, name)
                let shared = try Data(contentsOf: file)
                let saved = try XCTUnwrap(try editor.document.contents(forType: "public.plain-text") as? Data, name)
                XCTAssertEqual(shared, saved, "\(name), edited \(edit): not what Save writes")
                if !edit { XCTAssertEqual(shared, bytes, "\(name): not the file's own bytes") }
                activity.completionWithItemsHandler?(nil, false, nil, nil)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(name): the copy stays after the sheet")
                editor.dismiss(animated: false)
            }
        }
    }

    private func shareCopies() -> Set<String> {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: caches.path)) ?? []
        return Set(names.filter { $0.hasPrefix("ShareCopy-") })
    }

    /// When UIKit can't show the share sheet (an alert is up, or the
    /// editor isn't on screen), Share… leaves no copy behind.
    func testRefusedShareLeavesNoCopy() throws {
        // An alert is up.
        let editor = editor(Self.layouts[0], "txt")
        defer { WindowSupport.overrideForTests = nil }
        let alert = UIAlertController(title: "Owls", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        editor.present(alert, animated: false)
        for _ in 0..<20 where editor.presentedViewController == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(editor.presentedViewController is UIAlertController)
        let before = shareCopies()
        editor.shareDocumentCopy()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.presentedViewController is UIActivityViewController)
        XCTAssertEqual(shareCopies().subtracting(before), [], "alert up: a copy is left in Caches")
        editor.dismiss(animated: false)

        // Not in a window.
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt"))
        doc.text = "Owls\n"
        let offscreen = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: offscreen)
        nav.loadViewIfNeeded()
        offscreen.loadViewIfNeeded()
        let before2 = shareCopies()
        offscreen.shareDocumentCopy()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(offscreen.presentedViewController)
        XCTAssertEqual(shareCopies().subtracting(before2), [], "off screen: a copy is left in Caches")
    }

    // MARK: Share… from the ••• menu (b18 review)

    private func waitFor(_ seconds: Double, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func shareAction(_ editor: EditorViewController) throws -> UIAction {
        try XCTUnwrap(actions(editor.moreMenuItems()).first { $0.accessibilityIdentifier == "editor.menu.share" })
    }

    /// Share… chosen in the ••• menu: nothing is written or presented from
    /// the menu's callback (the menu is still closing then); the sheet
    /// comes up after, from the ••• button (a popover on an iPad). Let go
    /// without its handler running (dismissed by the app, not by an
    /// activity), it takes its copy with it.
    func testShareFromMenuPresentsAfterTheMenuFromMore() throws {
        let editor = editor(Self.layouts[1], "md")
        defer { WindowSupport.overrideForTests = nil }
        let before = shareCopies()
        try shareAction(editor).performWithSender(nil, target: nil)
        XCTAssertEqual(editor.sharedCopyItems, [], "Share… wrote its copy from the menu's callback")
        XCTAssertNil(editor.presentedViewController, "Share… presented from the menu's callback")
        waitFor(10) { editor.navigationController?.presentedViewController is UIActivityViewController }
        let file = try XCTUnwrap(editor.sharedCopyItems.first, "no copy made")
        try autoreleasepool {
            let activity = try XCTUnwrap(editor.navigationController?.presentedViewController as? UIActivityViewController, "no share sheet")
            if let popover = activity.popoverPresentationController, let more = editor.navigationItem.overflowPresentationSource {
                XCTAssertTrue(popover.sourceItem === more, "the share popover isn't anchored to the ••• button")
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertNotNil(editor.navigationItem.overflowPresentationSource, "no ••• button to anchor to")
                XCTAssertNotNil(activity.popoverPresentationController?.sourceItem, "the share popover has no anchor")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the copy is gone while the sheet is up")
            activity.dismiss(animated: false)
        }
        waitFor(5) { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the copy stays after the sheet was dismissed")
        XCTAssertEqual(shareCopies().subtracting(before), [], "a copy is left in Caches")
    }

    /// Share… chosen in the ••• menu, and UIKit refuses the sheet (it never
    /// comes up, its handler never runs): no copy is left behind.
    func testShareFromMenuRefusedLeavesNoCopy() throws {
        let editor = editor(Self.layouts[0], "txt")
        defer { WindowSupport.overrideForTests = nil }
        var offered = 0
        editor.presentShareSheet = { _, _ in offered += 1 } // refused: not presented
        let before = shareCopies()
        try shareAction(editor).performWithSender(nil, target: nil)
        waitFor(5) { offered > 0 }
        XCTAssertEqual(offered, 1, "Share… never got to present its sheet")
        let file = try XCTUnwrap(editor.sharedCopyItems.first, "no copy made")
        waitFor(5) { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a refused share sheet left its copy")
        XCTAssertEqual(shareCopies().subtracting(before), [], "a copy is left in Caches")
        XCTAssertNil(editor.presentedViewController)
    }

    /// Share… chosen in the ••• menu, and the menu stays busy (closing)
    /// past the two-second wait: Share… gives up, writes no copy and
    /// presents nothing (Codex b18 re-check 2: it ran anyway, into the
    /// transition). Once idle again, Share… from the menu works.
    func testShareFromMenuStillBusyAtTheDeadlineDoesNothing() throws {
        let editor = editor(Self.layouts[0], "txt")
        defer { WindowSupport.overrideForTests = nil }
        var offered = 0
        editor.presentShareSheet = { _, _ in offered += 1 }
        var busy = true
        var polls = 0
        editor.shareWaitBusy = { polls += 1; return busy }
        let before = shareCopies()
        try shareAction(editor).performWithSender(nil, target: nil)
        waitFor(6) { editor.sharesSkippedBusy > 0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(editor.sharesSkippedBusy, 1, "Share… didn't give up at the deadline (polled \(polls) times)")
        XCTAssertGreaterThan(polls, 1, "Share… didn't wait for the menu")
        XCTAssertEqual(offered, 0, "Share… presented with the menu still busy")
        XCTAssertNil(editor.navigationController?.presentedViewController, "something presented with the menu still busy")
        XCTAssertEqual(editor.sharedCopyItems, [], "Share… wrote its copy with the menu still busy")
        XCTAssertEqual(shareCopies().subtracting(before), [], "a copy is left in Caches")
        // Idle: Share… from the menu goes ahead.
        busy = false
        try shareAction(editor).performWithSender(nil, target: nil)
        waitFor(5) { offered > 0 }
        XCTAssertEqual(offered, 1, "Share… didn't present once the menu was idle")
        XCTAssertEqual(editor.sharesSkippedBusy, 1)
        if let file = editor.sharedCopyItems.first {
            waitFor(5) { !FileManager.default.fileExists(atPath: file.path) }
        }
        XCTAssertEqual(shareCopies().subtracting(before), [], "a copy is left in Caches")
    }

    /// Share… chosen in the ••• menu just as an alert comes up: the sheet
    /// isn't shown over it, and no copy is left behind.
    func testShareFromMenuWithAnAlertUpLeavesNoCopy() throws {
        let editor = editor(Self.layouts[0], "txt")
        defer { WindowSupport.overrideForTests = nil }
        let before = shareCopies()
        try shareAction(editor).performWithSender(nil, target: nil)
        let alert = UIAlertController(title: "Owls", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        editor.present(alert, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(editor.navigationController?.presentedViewController is UIActivityViewController, "the share sheet over the alert")
        waitFor(5) { shareCopies().subtracting(before).isEmpty }
        XCTAssertEqual(shareCopies().subtracting(before), [], "alert up: a copy is left in Caches")
        editor.dismiss(animated: false)
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
