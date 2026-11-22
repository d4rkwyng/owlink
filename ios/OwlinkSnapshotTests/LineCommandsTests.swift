import XCTest
import UIKit
import CedricCore

@MainActor
final class LineCommandsTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor(_ text: String, readOnly: Bool = false) -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift"))
        doc.language.choose(.swift)
        doc.text = text
        let editor = EditorViewController(document: doc, readModeOnOpen: readOnly)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }

    private func showSheet(_ sheet: LineFilterViewController) -> UINavigationController {
        let nav = UINavigationController(rootViewController: sheet)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return nav
    }

    func testDuplicateAndMoveUndo() {
        let editor = editor("one\ntwo\n")
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        editor.duplicateLine(nil)
        XCTAssertEqual(editor.textView.text, "one\ntwo\ntwo\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one\ntwo\n")
        editor.moveLineUp(nil)
        XCTAssertEqual(editor.textView.text, "two\none\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one\ntwo\n")
    }

    func testCommentAndIndentUndo() {
        let editor = editor("let x = 1\n")
        editor.lineIndentation = Indentation(usesTabs: false, width: 4)
        editor.commentSelection(nil)
        XCTAssertEqual(editor.textView.text, "// let x = 1\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "let x = 1\n")
        editor.indentLines(nil)
        XCTAssertEqual(editor.textView.text, "    let x = 1\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "let x = 1\n")
    }

    func testReadOnlyRefusesCommands() {
        let editor = editor("one\n", readOnly: true)
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.duplicateLine(_:)), withSender: nil))
        editor.duplicateLine(nil)
        XCTAssertEqual(editor.textView.text, "one\n")
    }

    func testFilterIsOneUndoStepAndReportsErrors() async throws {
        let editor = editor("keep\nDROP\nkeep\ndrop")
        let result = try await editor.filterLines(pattern: "^drop$", regex: true, caseSensitive: false, keep: false)
        XCTAssertEqual(result, .removed(2))
        XCTAssertEqual(editor.textView.text, "keep\nkeep")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "keep\nDROP\nkeep\ndrop")
        do {
            _ = try await editor.filterLines(pattern: "(", regex: true, caseSensitive: true, keep: true)
            XCTFail("Invalid regex was accepted")
        } catch { XCTAssertEqual(error as? LineFilter.FilterError, .invalidPattern) }
        XCTAssertEqual(editor.textView.text, "keep\nDROP\nkeep\ndrop")
    }

    func testConvertIndentationIsUndoable() {
        let editor = editor("    one\n        two")
        editor.lineIndentation = Indentation(usesTabs: false, width: 4)
        editor.convertIndentationToTabs(nil)
        XCTAssertEqual(editor.textView.text, "\tone\n\t\ttwo")
        XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: true, width: 4))
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "    one\n        two")
        XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: false, width: 4))
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.textView.text, "\tone\n\t\ttwo")
        XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: true, width: 4))
    }

    func testMoveBoundariesAndMultilineSelectionRoundTrip() {
        let editor = editor("one\ntwo\nthree")
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.moveLineUp(nil)
        XCTAssertEqual(editor.textView.text, "one\ntwo\nthree")
        editor.textView.selectedRange = NSRange(location: 8, length: 5)
        editor.moveLineDown(nil)
        XCTAssertEqual(editor.textView.text, "one\ntwo\nthree")
        let original = NSRange(location: 4, length: 9)
        editor.textView.selectedRange = original
        editor.moveLineUp(nil)
        XCTAssertEqual(editor.textView.text, "two\nthree\none")
        let moved = editor.textView.selectedRange
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "one\ntwo\nthree")
        XCTAssertEqual(editor.textView.selectedRange, original)
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.textView.text, "two\nthree\none")
        XCTAssertEqual(editor.textView.selectedRange, moved)
        let end = (editor.textView.text as NSString).length
        editor.textView.selectedRange = NSRange(location: end, length: 0)
        editor.duplicateLine(nil)
        XCTAssertEqual(editor.textView.text, "two\nthree\none\none")
    }

    func testCommentTwiceAndNoSyntax() throws {
        let editor = editor("one\ntwo")
        editor.textView.selectedRange = NSRange(location: 0, length: 7)
        editor.commentSelection(nil)
        XCTAssertEqual(editor.textView.text, "// one\n// two")
        editor.commentSelection(nil)
        XCTAssertEqual(editor.textView.text, "one\ntwo")
        editor.setLanguage(.json)
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.commentSelection(_:)), withSender: nil))
        let comment = try XCTUnwrap(editor.lineEditMenu().children.compactMap { $0 as? UIAction }
            .first { $0.title == String(localized: "Comment Selection") })
        XCTAssertTrue(comment.attributes.contains(.disabled))
    }

    func testOutdentAndReadOnlyRefusals() async throws {
        let editor = editor("    one\n    two")
        editor.lineIndentation = Indentation(usesTabs: false, width: 4)
        editor.textView.selectedRange = NSRange(location: 0, length: 15)
        editor.outdentLines(nil)
        XCTAssertEqual(editor.textView.text, "one\ntwo")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "    one\n    two")
        editor.setEditLock(.readMode, true)
        editor.indentLines(nil)
        editor.convertIndentationToTabs(nil)
        let result = try await editor.filterLines(pattern: "one", regex: false, caseSensitive: true, keep: true)
        XCTAssertEqual(result, .notEditable)
        XCTAssertEqual(editor.textView.text, "    one\n    two")
        XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: false, width: 4))
        let menu = editor.lineEditMenu()
        XCTAssertTrue(menu.children.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) })
        let indentationMenu = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first)
        XCTAssertTrue(indentationMenu.children.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) })
        editor.setEditLock(.readMode, false)
        let enabledMenu = editor.lineEditMenu()
        let names = enabledMenu.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertTrue(names.contains(String(localized: "Indent")))
        XCTAssertTrue(names.contains(String(localized: "Outdent")))
        XCTAssertTrue(names.contains(String(localized: "Keep Lines Matching…")))
        XCTAssertTrue(names.contains(String(localized: "Delete Lines Matching…")))
        XCTAssertTrue(enabledMenu.children.compactMap { $0 as? UIAction }.allSatisfy { !$0.attributes.contains(.disabled) })
    }

    func testKeepAndNoChange() async throws {
        let editor = editor("keep\nother\nkeep")
        let noChange = try await editor.filterLines(pattern: "missing", regex: false, caseSensitive: true, keep: false)
        XCTAssertEqual(noChange, .noChange)
        XCTAssertEqual(editor.textView.text, "keep\nother\nkeep")
        XCTAssertFalse(editor.textView.undoManager?.canUndo ?? true)
        let kept = try await editor.filterLines(pattern: "keep", regex: false, caseSensitive: true, keep: true)
        XCTAssertEqual(kept, .removed(1))
        XCTAssertEqual(editor.textView.text, "keep\nkeep")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "keep\nother\nkeep")
    }

    func testCRLFDocumentStaysCRLF() throws {
        let decoded = try XCTUnwrap(TextCodec.decode(Data("one\r\ntwo\r\n".utf8)))
        let editor = editor(decoded.text)
        editor.document.lineEnding = decoded.lineEnding
        editor.duplicateLine(nil)
        let encoded = try XCTUnwrap(TextCodec.encode(editor.textView.text, encoding: .utf8,
                                                      lineEnding: editor.document.lineEnding, includeBOM: false))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "one\r\none\r\ntwo\r\n")
    }

    func testReloadClearsIndentationOverride() {
        let editor = editor("    one")
        editor.lineIndentation = Indentation(usesTabs: true, width: 4)
        editor.document.onReload?()
        XCTAssertNil(editor.lineIndentation)
    }

    private func withIndentDefaultsRestored(_ body: () -> Void) {
        let defaults = AppSettings.defaults
        let keys = [AppSettings.Key.indentWithTabs, AppSettings.Key.tabWidth]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            AppSettings.post()
        }
        body()
    }

    func testDefaultIndentationAndOpenEditorUpdates() {
        withIndentDefaultsRestored {
            AppSettings.defaults.removeObject(forKey: AppSettings.Key.indentWithTabs)
            AppSettings.defaults.removeObject(forKey: AppSettings.Key.tabWidth)
            let editor = editor("no indent")
            let spaces = Indentation(usesTabs: false, width: 4)
            XCTAssertEqual(AppSettings.defaultIndentation, spaces)
            XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString), spaces)

            AppSettings.defaultIndentation = Indentation(usesTabs: true, width: 8)
            XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString), Indentation(usesTabs: true, width: 8))
            editor.indentLines(nil)
            XCTAssertEqual(editor.textView.text, "\tno indent")
            editor.outdentLines(nil)
            XCTAssertEqual(editor.textView.text, "no indent")

            editor.textView.text = "        no indent"
            editor.textView.selectedRange = NSRange(location: 0, length: 0)
            editor.outdentLines(nil)
            XCTAssertEqual(editor.textView.text, "no indent")
        }
    }

    func testDefaultIndentationSettingsAndNotification() {
        withIndentDefaultsRestored {
            let changed = expectation(forNotification: AppSettings.changed, object: nil)
            AppSettings.defaultIndentation = Indentation(usesTabs: true, width: 8)
            wait(for: [changed], timeout: 1)
            XCTAssertTrue(AppSettings.defaults.bool(forKey: "indentWithTabs"))
            XCTAssertEqual(AppSettings.defaults.integer(forKey: "tabWidth"), 8)
            XCTAssertEqual(AppSettings.defaultIndentation, Indentation(usesTabs: true, width: 8))

            var invalid = Indentation(usesTabs: false, width: 4)
            // These checks rely on width being a public mutable var that bypasses the init clamp.
            invalid.width = 99
            AppSettings.defaultIndentation = invalid
            XCTAssertEqual(AppSettings.defaults.integer(forKey: "tabWidth"), 16)
            XCTAssertEqual(AppSettings.defaultIndentation.width, 16)
            invalid.width = -2
            AppSettings.defaultIndentation = invalid
            XCTAssertEqual(AppSettings.defaultIndentation.width, 1)
            AppSettings.defaults.set(99, forKey: AppSettings.Key.tabWidth)
            XCTAssertEqual(AppSettings.defaultIndentation.width, 16)
            AppSettings.defaults.set(0, forKey: AppSettings.Key.tabWidth)
            XCTAssertEqual(AppSettings.defaultIndentation.width, 4)
        }
    }

    func testStoredNonListedIndentWidth() {
        withIndentDefaultsRestored {
            AppSettings.defaults.set(false, forKey: AppSettings.Key.indentWithTabs)
            AppSettings.defaults.set(5, forKey: AppSettings.Key.tabWidth)
            XCTAssertEqual(AppSettings.defaultIndentation, Indentation(usesTabs: false, width: 5))
        }
    }

    func testTabsDefaultToWidthFourWhenTabWidthIsMissing() {
        withIndentDefaultsRestored {
            AppSettings.defaults.set(true, forKey: AppSettings.Key.indentWithTabs)
            AppSettings.defaults.removeObject(forKey: AppSettings.Key.tabWidth)
            XCTAssertEqual(AppSettings.defaultIndentation, Indentation(usesTabs: true, width: 4))
        }
    }

    func testEmptyDocumentUsesSavedDefaultForTabAndReturn() {
        withIndentDefaultsRestored {
            AppSettings.defaults.set(true, forKey: AppSettings.Key.indentWithTabs)
            AppSettings.defaults.set(8, forKey: AppSettings.Key.tabWidth)
            let editor = editor("")
            XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString),
                           Indentation(usesTabs: true, width: 8))

            let tabRange = editor.textView.selectedRange
            XCTAssertTrue(editor.textView(editor.textView, shouldChangeTextIn: tabRange, replacementText: "\t"))
            editor.textView.text = "\t"
            XCTAssertEqual(editor.textView.text, "\t")
            editor.textView.text += "if ready {"
            let end = (editor.textView.text as NSString).length
            editor.textView.selectedRange = NSRange(location: end, length: 0)
            XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange,
                                           replacementText: "\n"))
            XCTAssertEqual(editor.textView.text, "\tif ready {\n\t\t")
        }
    }

    func testChangedDefaultAppliesToTabAndReturn() {
        withIndentDefaultsRestored {
            AppSettings.defaultIndentation = Indentation(usesTabs: false, width: 2)
            let editor = editor("if ready {")
            let end = (editor.textView.text as NSString).length
            editor.textView.selectedRange = NSRange(location: end, length: 0)
            AppSettings.defaultIndentation = Indentation(usesTabs: true, width: 8)
            XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\n"))
            XCTAssertEqual(editor.textView.text, "if ready {\n\t")
            editor.textView.undoManager?.undo()
            XCTAssertEqual(editor.textView.text, "if ready {")
            AppSettings.defaultIndentation = Indentation(usesTabs: false, width: 8)
            editor.textView.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\t"))
            XCTAssertEqual(editor.textView.text, "        if ready {")
        }
    }

    func testDetectedIndentationWinsOverSavedDefault() {
        withIndentDefaultsRestored {
            let defaults = AppSettings.defaults
            defaults.set(true, forKey: AppSettings.Key.indentWithTabs)
            defaults.set(8, forKey: AppSettings.Key.tabWidth)
            let editor = editor("  one\n  two")
            XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString), Indentation(usesTabs: false, width: 2))
            editor.indentLines(nil)
            XCTAssertTrue(editor.textView.text.hasPrefix("    one"))
        }
    }

    func testConversionRestoresUnspecifiedIndentationOnUndo() {
        let editor = editor("    one\n    two")
        XCTAssertNil(editor.lineIndentation)
        editor.convertIndentationToTabs(nil)
        XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: true, width: 4))
        editor.textView.undoManager?.undo()
        XCTAssertNil(editor.lineIndentation)
        XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString), Indentation(usesTabs: false, width: 4))
    }

    func testModeOnlyConversionPreservesTextAndSelection() {
        let editor = editor("no indent")
        let selection = NSRange(location: 1, length: 4)
        editor.textView.selectedRange = selection
        let generation = editor.generation
        editor.convertIndentationToTabs(nil)
        XCTAssertEqual(editor.textView.text, "no indent")
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertEqual(editor.generation, generation)
        XCTAssertEqual(editor.lineIndentation?.usesTabs, true)
        editor.textView.undoManager?.undo()
        XCTAssertNil(editor.lineIndentation)
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertEqual(editor.generation, generation)
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.lineIndentation?.usesTabs, true)
    }

    func testModeOnlyConversionRefreshesUndoButtons() {
        let editor = editor("no indent")
        editor.loadViewIfNeeded()
        XCTAssertFalse(editor.undoBarItem.isEnabled)
        editor.convertIndentationToTabs(nil)
        XCTAssertTrue(editor.undoBarItem.isEnabled)
    }

    private func actions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return actions(menu.children) }
            return []
        }
    }

    private func tabInterval(_ editor: EditorViewController) -> CGFloat? {
        (editor.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.defaultTabInterval
    }

    func testIndentUsingTabsAndSpacesKeepsTextAndDrivesIndent() {
        withIndentDefaultsRestored {
            AppSettings.defaultIndentation = Indentation(usesTabs: false, width: 4)
            let editor = editor("one\ntwo")
            editor.textView.selectedRange = NSRange(location: 0, length: 0)
            editor.indentUsingTabs(nil)
            XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: true, width: 4))
            XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString), Indentation(usesTabs: true, width: 4))
            XCTAssertEqual(editor.textView.text, "one\ntwo")
            XCTAssertFalse(editor.textView.undoManager?.canUndo ?? false)
            editor.indentLines(nil)
            XCTAssertEqual(editor.textView.text, "\tone\ntwo")
            editor.outdentLines(nil)
            XCTAssertEqual(editor.textView.text, "one\ntwo")

            editor.indentUsingSpaces(nil)
            XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: false, width: 4))
            XCTAssertEqual(editor.textView.text, "one\ntwo")
            editor.textView.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\t"))
            XCTAssertEqual(editor.textView.text, "    one\ntwo")
        }
    }

    func testTabWidthPickKeepsModeAndText() {
        withIndentDefaultsRestored {
            AppSettings.defaultIndentation = Indentation(usesTabs: false, width: 4)
            let editor = editor("one")
            editor.textView.selectedRange = NSRange(location: 0, length: 0)
            editor.setTabWidth(8)
            XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: false, width: 8))
            XCTAssertEqual(editor.currentLineIndentation(editor.textView.text as NSString), Indentation(usesTabs: false, width: 8))
            XCTAssertEqual(editor.textView.text, "one")
            editor.indentLines(nil)
            XCTAssertEqual(editor.textView.text, "        one")
            editor.textView.undoManager?.undo()
            XCTAssertEqual(editor.textView.text, "one")

            editor.indentUsingTabs(nil)
            editor.setTabWidth(2)
            XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: true, width: 2))
            XCTAssertEqual(editor.textView.text, "one")
            editor.setIndentation(Indentation(usesTabs: false, width: 2))
            editor.indentLines(nil)
            XCTAssertEqual(editor.textView.text, "  one")
        }
    }

    func testIndentationMenusShowWhatIsInEffect() {
        withIndentDefaultsRestored {
            AppSettings.defaultIndentation = Indentation(usesTabs: false, width: 4)
            let editor = editor("no indent")
            @MainActor func state(_ id: String) -> UIMenuElement.State? {
                actions(editor.moreMenuItems()).first { $0.accessibilityIdentifier == id }?.state
            }
            XCTAssertEqual(state("editor.indentUsingSpaces"), .on)
            XCTAssertEqual(state("editor.indentUsingTabs"), .off)
            XCTAssertEqual(state("editor.tabWidth.4"), .on)
            editor.setIndentation(Indentation(usesTabs: true, width: 8))
            XCTAssertEqual(state("editor.indentUsingSpaces"), .off)
            XCTAssertEqual(state("editor.indentUsingTabs"), .on)
            XCTAssertEqual(state("editor.tabWidth.8"), .on)
            XCTAssertEqual(state("editor.tabWidth.4"), .off)
            let titles = actions([editor.indentationMenu()]).map(\.title)
            XCTAssertEqual(titles, [String(localized: "Indent Using Spaces"), String(localized: "Indent Using Tabs"),
                                    "Tab Width: 2", "Tab Width: 3", "Tab Width: 4", "Tab Width: 8",
                                    String(localized: "Convert Indentation to Spaces"), String(localized: "Convert Indentation to Tabs")])
            // The Text menu's Line › Indentation has the same picks.
            XCTAssertTrue(actions([editor.lineEditMenu()]).contains { $0.accessibilityIdentifier == "editor.tabWidth.8" && $0.state == .on })

            let spaces = UICommand(title: "", action: #selector(EditorViewController.indentUsingSpaces(_:)))
            let width8 = UICommand(title: "", action: #selector(EditorViewController.tabWidthMenu(_:)), propertyList: 8)
            editor.validate(spaces)
            editor.validate(width8)
            XCTAssertEqual(spaces.state, .off)
            XCTAssertEqual(width8.state, .on)
        }
    }

    func testIndentationPicksWorkReadOnlyButConvertDoesNot() {
        let editor = editor("    one\n    two")
        editor.setEditLock(.readMode, true)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.indentUsingTabs(_:)), withSender: nil))
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.tabWidthMenu(_:)), withSender: nil))
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.convertIndentationToTabs(_:)), withSender: nil))
        let items = actions([editor.indentationMenu()])
        for id in ["editor.indentUsingSpaces", "editor.indentUsingTabs", "editor.tabWidth.2", "editor.tabWidth.8"] {
            XCTAssertEqual(items.first { $0.accessibilityIdentifier == id }?.attributes.contains(.disabled), false, id)
        }
        for id in ["editor.convertIndentationToSpaces", "editor.convertIndentationToTabs"] {
            XCTAssertEqual(items.first { $0.accessibilityIdentifier == id }?.attributes.contains(.disabled), true, id)
        }
        editor.tabWidthMenu(UICommand(title: "", action: #selector(EditorViewController.tabWidthMenu(_:)), propertyList: 2))
        XCTAssertEqual(editor.lineIndentation, Indentation(usesTabs: false, width: 2))
        XCTAssertEqual(editor.textView.text, "    one\n    two")
    }

    func testTabWidthSetsTabStops() throws {
        let editor = editor("\tone\n\t\ttwo")
        let font = editor.textView.font
        editor.setTabWidth(2)
        let narrow = try XCTUnwrap(tabInterval(editor))
        editor.setTabWidth(8)
        let wide = try XCTUnwrap(tabInterval(editor))
        XCTAssertEqual(editor.textView.font, font)
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertEqual(wide, narrow * 4, accuracy: 0.01)
        let stored = try XCTUnwrap(editor.textView.textStorage.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(stored.defaultTabInterval, wide, accuracy: 0.01)
        XCTAssertTrue(stored.tabStops.isEmpty)
        XCTAssertEqual(editor.textView.text, "\tone\n\t\ttwo")
    }

    func testLoadedDocumentHasDefaultTabStops() throws {
        withIndentDefaultsRestored {
            AppSettings.defaultIndentation = Indentation(usesTabs: true, width: 8)
            let editor = editor("\tone")
            let loaded = tabInterval(editor)
            editor.setTabWidth(8)
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded ?? 0, tabInterval(editor) ?? -1, accuracy: 0.01)
        }
    }

    func testCancellingFilterTaskThrowsCancellation() async throws {
        let editor = editor(String(repeating: "line\n", count: 200_000))
        let filter = Task { try await editor.filterLines(pattern: "line", regex: false, caseSensitive: true, keep: false) }
        await Task.yield()
        filter.cancel()
        do {
            let result = try await filter.value
            XCTFail("expected cancellation, got \(result)")
        } catch is CancellationError {}
        XCTAssertTrue(editor.textView.text.hasPrefix("line\n"))
    }

    func testResolvedIndentationForCommandsAndTyping() {
        let editor = editor("  if ready {\n  other")
        editor.textView.selectedRange = NSRange(location: 12, length: 0)
        XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\n"))
        XCTAssertEqual(editor.textView.text, "  if ready {\n    \n  other")
        editor.textView.undoManager?.undo()
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.indentLines(nil)
        XCTAssertTrue(editor.textView.text.hasPrefix("    if"))
        editor.textView.undoManager?.undo()
        editor.textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\t"))
        XCTAssertTrue(editor.textView.text.hasPrefix("    if"))
    }

    func testFilterRejectsStaleResultWithoutBlockingMainThread() async throws {
        let editor = editor(String(repeating: "line\n", count: 10_000))
        let filter = Task { try await editor.filterLines(pattern: "line", regex: false, caseSensitive: true, keep: false) }
        await Task.yield()
        editor.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "changed\n")
        editor.textViewDidChange(editor.textView)
        let result = try await filter.value
        XCTAssertEqual(result, .stale)
        XCTAssertTrue(editor.textView.text.hasPrefix("changed\n"))
    }

    func testFilterSheetInputAndDefaultsBeforeValidation() async throws {
        let keys = ["filterLinesPattern", "filterLinesRegex", "filterLinesMatchCase"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let editor = editor("one\ntwo")
        let sheet = editor.makeLineFilter(keep: false)
        let nav = showSheet(sheet)
        try await Task.sleep(for: .milliseconds(500))
        sheet.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let field = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? UITextField }.first)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.smartQuotesType, .no)
        XCTAssertEqual(field.smartDashesType, .no)
        XCTAssertEqual(field.spellCheckingType, .no)
        XCTAssertEqual(field.autocapitalizationType, .none)
        XCTAssertEqual(field.returnKeyType, .done)
        XCTAssertEqual(field.clearButtonMode, .whileEditing)
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(descendants(sheet.view).contains { $0 is UIScrollView })
        field.text = ""
        XCTAssertFalse(sheet.textFieldShouldReturn(field))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "filterLinesPattern"), "")
        for _ in 0..<50 {
            if sheet.presentedViewController is UIAlertController || nav.presentedViewController is UIAlertController { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sheet.presentedViewController is UIAlertController || nav.presentedViewController is UIAlertController)
        XCTAssertEqual(editor.textView.text, "one\ntwo")
    }

    func testFilterSheetShowsProgressAndNoMatchFeedback() async throws {
        let keys = ["filterLinesPattern", "filterLinesRegex", "filterLinesMatchCase"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let editor = editor("one\ntwo")
        let sheet = LineFilterViewController(keep: false, pattern: "missing") { _, _, _ in
            try? await Task.sleep(for: .milliseconds(500))
            return nil
        }
        _ = showSheet(sheet)
        sheet.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let field = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? UITextField }.first)
        _ = sheet.textFieldShouldReturn(field)
        let spinner = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? UIActivityIndicatorView }.first)
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertFalse(try XCTUnwrap(sheet.navigationItem.rightBarButtonItem).isEnabled)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(spinner.isAnimating)

        let active = editor.makeLineFilter(keep: false)
        _ = showSheet(active)
        try await Task.sleep(for: .milliseconds(500))
        let input = try XCTUnwrap(descendants(active.view).compactMap { $0 as? UITextField }.first)
        input.text = "missing"
        _ = active.textFieldShouldReturn(input)
        try await Task.sleep(for: .milliseconds(500))
        let labels = descendants(editor.view).compactMap { $0 as? UILabel }
        XCTAssertTrue(labels.contains { $0.accessibilityIdentifier == "editor.toast" && $0.text == String(localized: "No lines matched or removed.") })
        XCTAssertEqual(editor.textView.text, "one\ntwo")
    }
}
