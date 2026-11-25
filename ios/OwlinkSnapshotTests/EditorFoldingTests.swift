import XCTest
import UIKit
import CedricCore

/// Code folding without a drawn window: the controller's state and its
/// TextKit 2 hiding, the gutter's fold column, and the menu's enablement.
@MainActor
final class EditorFoldingTests: XCTestCase {
    // Lines: 0 "func a() {", 1 "    one()", 2 "    if x {", 3 "        two()", 4 "    }", 5 "}", 6 "tail", 7 "".
    private let swift = "func a() {\n    one()\n    if x {\n        two()\n    }\n}\ntail\n"

    private func textView(_ text: String) -> EditorDocumentTextView {
        let tv = EditorDocumentTextView(usingTextLayoutManager: true)
        tv.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        tv.text = text
        return tv
    }

    private func editor(_ text: String, _ language: Language = .swift, ext: String = "swift") -> EditorViewController {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext))
        doc.language.choose(language)
        doc.text = text
        let editor = EditorViewController(document: doc)
        editor.loadViewIfNeeded()
        return editor
    }

    private func caret(_ editor: EditorViewController, line: Int) {
        editor.textView.selectedRange = NSRange(location: editor.lineIndex.starts[line], length: 0)
    }

    /// The offsets of the paragraphs TextKit enumerates (asks the delegate).
    private func enumeratedParagraphs(_ tv: UITextView) -> [Int] {
        guard let cm = tv.textLayoutManager?.textContentManager else { return [] }
        var out: [Int] = []
        cm.enumerateTextElements(from: cm.documentRange.location) { e in
            if let r = e.elementRange { out.append(cm.offset(from: cm.documentRange.location, to: r.location)) }
            return true
        }
        return out
    }

    private func regions(_ text: String) -> [FoldRegion] {
        FoldScanner(language: .swift, text: text as NSString, index: LineIndex(text as NSString)).allRegions()
    }

    // MARK: The controller

    func testFoldHidesParagraphsAndLeavesTextAlone() throws {
        let tv = textView(swift)
        let index = LineIndex(swift as NSString)
        let cs = try XCTUnwrap(tv.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let before = cs.delegate
        let allParagraphs = enumeratedParagraphs(tv)
        XCTAssertTrue(allParagraphs.contains(index.starts[3]))
        let f = FoldingController(textView: tv)
        f.fold([FoldRegion(header: 2, last: 3)], index: index)
        XCTAssertTrue(f.isInstalled)
        XCTAssertTrue(cs.delegate === f)
        XCTAssertEqual(f.state.folds, [NSRange(location: index.starts[3], length: index.starts[4] - index.starts[3])])
        XCTAssertEqual(enumeratedParagraphs(tv), allParagraphs.filter { $0 != index.starts[3] })
        // Only hidden: the storage (save, copy, find, print, export) has all of it.
        XCTAssertEqual(tv.text, swift)
        XCTAssertEqual((tv.text as NSString).substring(with: NSRange(location: index.starts[1], length: index.starts[6] - index.starts[1])),
                       "    one()\n    if x {\n        two()\n    }\n}\n")
        f.unfold(f.state.folds)
        XCTAssertTrue(f.isEmpty)
        XCTAssertFalse(f.isInstalled)
        XCTAssertTrue(cs.delegate === before)
        XCTAssertEqual(enumeratedParagraphs(tv), allParagraphs)
    }

    func testNestedFoldsAndUnfoldAll() {
        let tv = textView(swift)
        let index = LineIndex(swift as NSString)
        let all = enumeratedParagraphs(tv)
        let f = FoldingController(textView: tv)
        f.fold(regions(swift), index: index)
        XCTAssertEqual(f.state.folds.count, 2)
        XCTAssertEqual(f.state.headerLines(index), [0, 2])
        XCTAssertEqual(enumeratedParagraphs(tv), all.filter { !(index.starts[1]..<index.starts[5]).contains($0) })
        // The outer pill opens the outer fold; the inner stays folded.
        f.unfold(f.state.folds(startingAt: index.starts[1]))
        XCTAssertEqual(f.state.headerLines(index), [2])
        f.fold(regions(swift), index: index)
        f.unfoldAll()
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(tv.text, swift)
    }

    func testCaretInFoldedTextMovesToHeader() {
        let tv = textView(swift)
        let index = LineIndex(swift as NSString)
        tv.selectedRange = NSRange(location: index.starts[3] + 4, length: 0)
        let f = FoldingController(textView: tv)
        f.fold([FoldRegion(header: 2, last: 3)], index: index)
        XCTAssertEqual(tv.selectedRange, NSRange(location: index.starts[3] - 1, length: 0))
    }

    func testKeyMovesSkipAndOtherSelectionsReveal() {
        let tv = textView(swift)
        let index = LineIndex(swift as NSString)
        let f = FoldingController(textView: tv)
        let headerEnd = index.starts[3] - 1
        tv.selectedRange = NSRange(location: headerEnd, length: 0)
        f.selectionChanged(byKey: false)
        f.fold([FoldRegion(header: 2, last: 3)], index: index)
        // → from the end of the header lands in the fold: it skips past.
        tv.selectedRange = NSRange(location: index.starts[3], length: 0)
        f.selectionChanged(byKey: true)
        XCTAssertEqual(tv.selectedRange, NSRange(location: index.starts[4], length: 0))
        XCTAssertFalse(f.isEmpty)
        // ← from the line after: back to the end of the header.
        tv.selectedRange = NSRange(location: index.starts[4] - 1, length: 0)
        f.selectionChanged(byKey: true)
        XCTAssertEqual(tv.selectedRange, NSRange(location: headerEnd, length: 0))
        // A selection that covers the whole fold leaves it folded.
        tv.selectedRange = NSRange(location: index.starts[2], length: index.starts[5] - index.starts[2])
        f.selectionChanged(byKey: false)
        XCTAssertFalse(f.isEmpty)
        // Find or Go to Line landing inside opens it.
        tv.selectedRange = NSRange(location: index.starts[3] + 2, length: 3)
        f.selectionChanged(byKey: false)
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(tv.selectedRange, NSRange(location: index.starts[3] + 2, length: 3))
    }

    func testEditsShiftOrOpenFolds() {
        let tv = textView(swift)
        let index = LineIndex(swift as NSString)
        let f = FoldingController(textView: tv)
        f.fold([FoldRegion(header: 2, last: 3)], index: index)
        let fold = f.state.folds[0]
        // Typing above shifts it.
        tv.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// x\n")
        f.textEdited(oldRange: NSRange(location: 0, length: 0), newLength: 5, storage: tv.textStorage)
        XCTAssertEqual(f.state.folds, [NSRange(location: fold.location + 5, length: fold.length)])
        // Typing below leaves it.
        let end = tv.textStorage.length
        tv.textStorage.replaceCharacters(in: NSRange(location: end - 5, length: 0), with: "z")
        f.textEdited(oldRange: NSRange(location: end - 5, length: 0), newLength: 1, storage: tv.textStorage)
        XCTAssertEqual(f.state.folds, [NSRange(location: fold.location + 5, length: fold.length)])
        // Typing inside opens it.
        let inside = fold.location + 5 + 2
        tv.textStorage.replaceCharacters(in: NSRange(location: inside, length: 0), with: "q")
        f.textEdited(oldRange: NSRange(location: inside, length: 0), newLength: 1, storage: tv.textStorage)
        XCTAssertTrue(f.isEmpty)
    }

    func testPillLabels() {
        let index = LineIndex(swift as NSString)
        XCTAssertEqual(FoldingController.label(for: NSRange(location: index.starts[3], length: index.starts[4] - index.starts[3]), index),
                       "⋯ 1 line")
        XCTAssertEqual(FoldingController.label(for: NSRange(location: index.starts[1], length: index.starts[5] - index.starts[1]), index),
                       "⋯ 4 lines")
    }

    // MARK: The gutter

    func testGutterFoldColumnTapsFoldOrBookmark() {
        let g = LineNumberGutter(frame: CGRect(x: 0, y: 0, width: 50, height: 200))
        g.rows = [.init(line: 1, midY: 10), .init(line: 2, midY: 30), .init(line: 3, midY: 50)]
        g.foldMarks = [1: .open, 3: .folded]
        var folded: [Int] = [], bookmarked: [Int] = []
        g.onTapFold = { folded.append($0); return true }
        g.onTapLine = { bookmarked.append($0) }
        // No fold column (plain text): marks aren't shown, taps bookmark.
        XCTAssertEqual(g.foldMarkedRows, [:])
        g.handleTap(at: CGPoint(x: 45, y: 10))
        XCTAssertEqual(folded, [])
        XCTAssertEqual(bookmarked, [1])
        g.foldColumn = LineNumberGutter.foldColumnWidth
        XCTAssertEqual(g.foldMarkedRows, [1: .open, 3: .folded])
        g.handleTap(at: CGPoint(x: 45, y: 10))
        g.handleTap(at: CGPoint(x: 45, y: 50))
        XCTAssertEqual(folded, [1, 3])
        // The number itself, or a line with no mark, still toggles a bookmark.
        g.handleTap(at: CGPoint(x: 10, y: 10))
        g.handleTap(at: CGPoint(x: 45, y: 30))
        XCTAssertEqual(bookmarked, [1, 1, 2])
        // Nothing folds after all: the bookmark.
        g.onTapFold = { _ in false }
        g.handleTap(at: CGPoint(x: 45, y: 50))
        XCTAssertEqual(bookmarked, [1, 1, 2, 3])
    }

    // MARK: The editor and its menu

    private func menuItems(_ editor: EditorViewController) -> [String: UIAction] {
        var out: [String: UIAction] = [:]
        func walk(_ e: [UIMenuElement]) {
            for x in e {
                if let a = x as? UIAction, let id = a.accessibilityIdentifier { out[id] = a }
                if let m = x as? UIMenu { walk(m.children) }
            }
        }
        walk(editor.foldingMenu().children)
        return out
    }

    private func enabled(_ editor: EditorViewController) -> Set<String> {
        Set(menuItems(editor).filter { !$0.value.attributes.contains(.disabled) }.keys)
    }

    func testMenuHasEveryCommand() {
        let ids = Set(menuItems(editor(swift)).keys)
        XCTAssertEqual(ids, ["editor.menu.fold", "editor.menu.unfold", "editor.menu.foldAll", "editor.menu.unfoldAll",
                             "editor.menu.foldToLevel1", "editor.menu.foldToLevel2", "editor.menu.foldToLevel3"])
        // In the ••• menu (under More › since 0.5.2 (18)).
        XCTAssertTrue(allSubmenus(editor(swift).moreMenuItems()).contains { $0.title == String(localized: "Folding") })
    }

    func testMenuEnablementFollowsState() {
        let e = editor(swift)
        XCTAssertEqual(enabled(e), ["editor.menu.fold", "editor.menu.foldAll", "editor.menu.foldToLevel1",
                                    "editor.menu.foldToLevel2", "editor.menu.foldToLevel3"])
        XCTAssertFalse(e.canPerformAction(#selector(EditorViewController.unfoldAllMenu(_:)), withSender: nil))
        caret(e, line: 3)
        e.foldAtCaret()
        XCTAssertEqual(e.folding?.state.headerLines(e.lineIndex), [2])
        XCTAssertEqual(e.caretLine, 2)
        XCTAssertTrue(enabled(e).isSuperset(of: ["editor.menu.unfold", "editor.menu.unfoldAll"]))
        XCTAssertTrue(e.canPerformAction(#selector(EditorViewController.unfoldAllMenu(_:)), withSender: nil))
        // Unfold stays enabled when the caret is not on a header, as on the Mac.
        caret(e, line: 6)
        XCTAssertTrue(enabled(e).contains("editor.menu.unfold"))
        caret(e, line: 2)
        e.unfoldAtCaret()
        XCTAssertFalse(e.hasFolds)
        XCTAssertEqual(e.textView.text, swift)
    }

    func testFoldAllAndLevels() {
        let e = editor(swift)
        e.foldAll()
        XCTAssertEqual(e.folding?.state.headerLines(e.lineIndex), [0, 2])
        e.foldAll(level: 2)
        XCTAssertEqual(e.folding?.state.headerLines(e.lineIndex), [2])
        e.unfoldAll()
        XCTAssertFalse(e.hasFolds)
        // A gutter mark toggles one region.
        XCTAssertTrue(e.toggleFold(line: 0))
        XCTAssertEqual(e.folding?.state.headerLines(e.lineIndex), [0])
        XCTAssertTrue(e.toggleFold(line: 0))
        XCTAssertFalse(e.hasFolds)
        XCTAssertFalse(e.toggleFold(line: 6))
        XCTAssertEqual(e.textView.text, swift)
    }

    func testGutterMarks() {
        let e = editor(swift)
        XCTAssertEqual(e.foldMarks(lines: Array(0..<8)), [0: .open, 2: .open])
        _ = e.toggleFold(line: 2)
        XCTAssertEqual(e.foldMarks(lines: [0, 2, 5]), [0: .open, 2: .folded])
    }

    /// As on the Mac (CedricApp foldMarks uses the cheap startsRegion): a
    /// `{` closed on the next line shows ▾, and its tap folds nothing (the
    /// gutter then toggles the bookmark).
    func testEmptyRegionMarkMatchesMac() {
        let e = editor("func a() {\n}\ntail\n")
        XCTAssertEqual(e.foldMarks(lines: [0, 1, 2]), [0: .open])
        XCTAssertFalse(e.toggleFold(line: 0))
        XCTAssertFalse(e.hasFolds)
    }

    // MARK: VoiceOver

    /// An editor laid out without a window, folded, with its pills placed.
    private func foldedWithPills() throws -> EditorViewController {
        let e = editor(swift)
        e.view.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        e.view.layoutIfNeeded()
        e.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        e.foldAll()
        e.view.layoutIfNeeded()
        e.layoutGutter()
        XCTAssertEqual(e.folding?.state.headerLines(e.lineIndex), [0, 2])
        return e
    }

    func testPillIsAnAccessibilityElementThatUnfolds() throws {
        let e = try foldedWithPills()
        let f = try XCTUnwrap(e.folding)
        // Line 0's fold hides the line 2 header, so only its pill shows.
        let pill = try XCTUnwrap(f.visiblePills.first)
        XCTAssertEqual(f.visiblePills.count, 1)
        XCTAssertTrue(pill.isAccessibilityElement)
        XCTAssertTrue(pill.accessibilityTraits.contains(.button))
        XCTAssertEqual(pill.accessibilityIdentifier, "editor.foldPill")
        XCTAssertEqual(pill.accessibilityLabel, "⋯ 4 lines")
        XCTAssertEqual(pill.accessibilityHint, String(localized: "Unfolds the hidden lines."))
        // Activating it opens the outermost fold there, as a tap does.
        XCTAssertTrue(pill.accessibilityActivate())
        XCTAssertEqual(f.state.headerLines(e.lineIndex), [2])
        XCTAssertEqual(e.textView.text, swift)
    }

    func testTextViewOffersAnUnfoldActionPerPill() throws {
        let e = try foldedWithPills()
        let f = try XCTUnwrap(e.folding)
        let unfold = String(localized: "Unfold line 1, ⋯ 4 lines")
        let action = try XCTUnwrap(e.textView.accessibilityCustomActions?.first { $0.name == unfold })
        XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
        XCTAssertEqual(f.state.headerLines(e.lineIndex), [2])
        // The inner header is visible now: its pill and action follow.
        e.layoutGutter()
        XCTAssertEqual(f.visiblePills.map(\.accessibilityLabel), ["⋯ 1 line"])
        let names = e.textView.accessibilityCustomActions?.map(\.name) ?? []
        XCTAssertTrue(names.contains(String(localized: "Unfold line 3, ⋯ 1 line")), "\(names)")
        XCTAssertFalse(names.contains(unfold))
        e.unfoldAll()
        e.layoutGutter()
        XCTAssertFalse((e.textView.accessibilityCustomActions ?? []).contains { $0.name.hasPrefix(String(localized: "Unfold line")) })
    }

    // MARK: Pill placement

    func testPillFrameClampsInsideContent() {
        let content = CGRect(x: 40, y: 0, width: 300, height: 1000)
        let size = CGSize(width: 60, height: 18)
        // Room after the line: 8 pt after the last glyph, centred on it.
        XCTAssertEqual(FoldingController.pillFrame(caret: CGRect(x: 100, y: 50, width: 2, height: 20), size: size, content: content),
                       CGRect(x: 110, y: 51, width: 60, height: 18))
        // No room: the right edge meets the content's right edge, same line.
        XCTAssertEqual(FoldingController.pillFrame(caret: CGRect(x: 320, y: 50, width: 2, height: 20), size: size, content: content),
                       CGRect(x: 280, y: 51, width: 60, height: 18))
        // Wider than the content: never under the gutter, narrowed to fit.
        XCTAssertEqual(FoldingController.pillFrame(caret: CGRect(x: 60, y: 50, width: 2, height: 20), size: CGSize(width: 400, height: 18),
                                                   content: content),
                       CGRect(x: 40, y: 51, width: 300, height: 18))
    }

    /// iPhone width (390 pt, compact), lines wrapped: headers whose last
    /// glyph sits anywhere along the line, some right at the edge. Every
    /// pill stays inside the text container (right inset, or Readable
    /// Width's margin, included), right of the gutter, on its header's line,
    /// and takes the tap.
    func testLongFoldedHeaderPillStaysInsideIPhoneWidth() throws {
        let wrap = AppSettings.wrap
        AppSettings.wrap = true
        defer { AppSettings.wrap = wrap }
        var text = ""
        for k in 0..<36 {
            text += "    mutating func hoot\(String(repeating: "o", count: k))() -> String {\n        \"hoo\"\n    }\n"
        }
        for readable in [false, true] {
            let e = editor(text)
            e.traitOverrides.horizontalSizeClass = .compact
            if readable { e.toggleReadableWidth() }
            e.view.frame = CGRect(x: 0, y: 0, width: 390, height: 4000)
            e.view.layoutIfNeeded()
            e.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            e.foldAll()
            e.view.layoutIfNeeded()
            e.layoutGutter()
            let tv = e.textView
            let f = try XCTUnwrap(e.folding)
            let pills = f.visiblePills
            XCTAssertEqual(pills.count, 36, "readable \(readable)")
            let inset = tv.textContainerInset
            // The gutter draws in the left inset: right of it is clear of the gutter.
            let minX = inset.left, maxX = tv.bounds.width - inset.right
            XCTAssertLessThan(maxX, 390, "readable \(readable)")
            var clamped = 0
            for b in pills {
                let r = b.frame
                XCTAssertGreaterThanOrEqual(r.minX, minX - 0.5, "line \(b.headerLine + 1) readable \(readable) \(r)")
                XCTAssertLessThanOrEqual(r.maxX, maxX + 0.5, "line \(b.headerLine + 1) readable \(readable) \(r)")
                XCTAssertGreaterThan(r.width, 0)
                XCTAssertEqual(r.width, b.intrinsicContentSize.width, accuracy: 0.5)
                // On the header's last line fragment.
                let end = NSMaxRange(e.lineIndex.contentRange(ofLine: b.headerLine))
                let caret = tv.caretRect(for: try XCTUnwrap(tv.position(from: tv.beginningOfDocument, offset: end)))
                XCTAssertEqual(r.midY, caret.midY, accuracy: 0.5)
                if caret.maxX + 8 + b.intrinsicContentSize.width > maxX { clamped += 1 }
                // Tappable: the pill is what a touch at its centre hits.
                XCTAssertTrue(tv.hitTest(CGPoint(x: r.midX, y: r.midY), with: nil) === b, "line \(b.headerLine + 1) readable \(readable)")
            }
            // Some headers end where the old placement ran off the edge.
            XCTAssertGreaterThan(clamped, 0, "readable \(readable)")
            // VoiceOver still opens it.
            let last = try XCTUnwrap(pills.last)
            let header = last.headerLine
            XCTAssertTrue(last.accessibilityActivate())
            XCTAssertFalse(f.state.headerLines(e.lineIndex).contains(header))
            XCTAssertEqual(tv.text, text)
        }
    }

    func testLanguagesThatDontFold() {
        for (language, ext) in [(Language.plain, "txt"), (.csv, "csv"), (.diff, "diff"), (.html, "html")] {
            let e = editor("a {\n  b\n}\n# h\n  x\n", language, ext: ext)
            XCTAssertFalse(e.foldingAvailable, "\(language)")
            XCTAssertTrue(enabled(e).isEmpty, "\(language)")
            XCTAssertEqual(e.foldMarks(lines: [0, 1, 2, 3]), [:])
            XCTAssertFalse(e.toggleFold(line: 0))
            e.foldAll()
            XCTAssertFalse(e.hasFolds)
        }
    }

    func testMarkdownHeadingsFold() {
        let md = "# A\ntext\n## B\nmore\n```\n# not a heading\n```\n# C\n"
        let e = editor(md, .markdown, ext: "md")
        e.foldAll()
        XCTAssertEqual(e.folding?.state.headerLines(e.lineIndex), [0, 2])
        XCTAssertEqual(e.textView.text, md)
    }

    func testLanguageChangeAndLargeModeTurnFoldingOff() {
        let e = editor(swift)
        e.foldAll()
        XCTAssertTrue(e.hasFolds)
        e.setLanguage(.plain)
        XCTAssertFalse(e.hasFolds)
        XCTAssertFalse(e.foldingAvailable)

        let long = "func a() {\n" + String(repeating: "x", count: LargeDocument.lineThreshold + 10) + "\n}\n"
        let big = editor(long)
        XCTAssertFalse(big.foldingAvailable)
        XCTAssertTrue(enabled(big).isEmpty)
        big.foldAll()
        XCTAssertFalse(big.hasFolds)
    }

    func testReloadDropsFolds() {
        let e = editor(swift)
        e.foldAll()
        e.document.text = swift + "more\n"
        e.document.onReload?()
        XCTAssertFalse(e.hasFolds)
        XCTAssertEqual(e.folding?.isInstalled, false)
    }
}
