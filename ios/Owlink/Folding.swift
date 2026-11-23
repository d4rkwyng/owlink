import UIKit
import CedricCore

// Code folding, as on the Mac (CedricApp/Folding.swift). Regions come from
// FoldScanner (CedricCore), on demand. An editor's FoldingController is
// made on its first fold; until then every hook is a nil check.
//
// Hiding: the controller becomes the content storage's delegate and
// answers `shouldEnumerate` false for paragraphs in a folded range, so
// TextKit 2 neither lays them out nor draws them. The text storage never
// changes: save, undo, copy, find, export and print see the whole text.
// Once nothing is folded the delegate goes back to what it was.
// Not to be confused with FoldLayout (an iPhone Duo's hardware fold).

/// What the gutter shows in a line's fold column.
enum FoldMark { case none, open, folded }

@MainActor
final class FoldingController: NSObject, NSTextContentStorageDelegate {
    private weak var textView: UITextView?
    private(set) var state = FoldState()
    /// A copy for the layout callback (TextKit calls it on the main thread,
    /// but the protocol isn't main-actor isolated).
    nonisolated(unsafe) private var hiddenForLayout = FoldState()
    /// The content storage's delegate before ours (nil on a stock UITextView).
    nonisolated(unsafe) private weak var previousDelegate: NSTextContentStorageDelegate?
    private var installed = false
    /// The selection before the last change, for key moves over a fold.
    private var lastSelection: NSRange
    private var adjustingSelection = false
    private var pills: [FoldPillButton] = []
    /// The folds changed (relayout, gutter).
    var onChange: (() -> Void)?

    init(textView: UITextView) {
        self.textView = textView
        lastSelection = textView.selectedRange
    }

    var isEmpty: Bool { state.isEmpty }

    nonisolated func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                                        options: NSTextContentManager.EnumerationOptions) -> Bool {
        if let r = textElement.elementRange, !hiddenForLayout.isEmpty {
            let o = textContentManager.offset(from: textContentManager.documentRange.location, to: r.location)
            if hiddenForLayout.isHidden(o) { return false }
        }
        return previousDelegate?.textContentManager?(textContentManager, shouldEnumerate: textElement, options: options) ?? true
    }

    nonisolated func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        previousDelegate?.textContentStorage?(textContentStorage, textParagraphWith: range)
    }

    private var contentStorage: NSTextContentStorage? {
        textView?.textLayoutManager?.textContentManager as? NSTextContentStorage
    }

    /// Whether the content storage asks this controller (for tests).
    var isInstalled: Bool { installed && contentStorage?.delegate === self }

    // MARK: Folding and unfolding

    func fold(_ regions: [FoldRegion], index: LineIndex) {
        var changed: Int?
        for r in regions {
            guard let rr = r.hiddenRange(in: index), !state.folds.contains(rr) else { continue }
            state.add(rr)
            changed = min(changed ?? rr.location, rr.location)
        }
        if let changed { apply(from: changed) }
    }

    func unfold(_ ranges: [NSRange]) {
        var from = Int.max
        for r in ranges where state.folds.contains(r) {
            state.remove(r)
            from = min(from, r.location)
        }
        if from != .max { apply(from: from) }
    }

    func unfoldAll() {
        guard let first = state.folds.first?.location else { return }
        state.removeAll()
        apply(from: first)
    }

    /// The text was replaced (open, reload): folds are gone, without a relayout.
    func reset() {
        state.removeAll()
        hiddenForLayout = state
        uninstall()
        pills.forEach { $0.removeFromSuperview() }
        pills = []
        if let tv = textView { lastSelection = tv.selectedRange }
    }

    private func install() {
        guard !installed, let cs = contentStorage else { return }
        if cs.delegate !== self { previousDelegate = cs.delegate }
        cs.delegate = self
        installed = true
    }

    private func uninstall() {
        guard installed else { return }
        if let cs = contentStorage, cs.delegate === self { cs.delegate = previousDelegate }
        previousDelegate = nil
        installed = false
    }

    /// After the fold state changed: TextKit lays out again from `from` to
    /// the end (fragments below a changed fold move), and a caret that is
    /// now hidden goes to the end of its header line.
    private func apply(from: Int) {
        hiddenForLayout = state
        if state.isEmpty { uninstall() } else { install() }
        guard let tv = textView, let tlm = tv.textLayoutManager, let cs = contentStorage else { onChange?(); return }
        let ns = tv.textStorage.string as NSString
        let len = ns.length
        let start = max(0, min(from - 1, len))
        if let s = cs.location(cs.documentRange.location, offsetBy: start), let r = NSTextRange(location: s, end: cs.documentRange.endLocation) {
            tlm.invalidateLayout(for: r)
        }
        let nl = len > 0 && ns.character(at: len - 1) == 10
        let sel = tv.selectedRange
        if !state.isEmpty, sel.location != NSNotFound, let h = state.caretIsHidden(sel.location, length: len, endsWithNewline: nl) {
            setSelection(NSRange(location: max(0, h.location - 1), length: 0))
        }
        tlm.textViewportLayoutController.layoutViewport()
        tv.setNeedsLayout()
        tv.setNeedsDisplay()
        onChange?()
    }

    private func setSelection(_ r: NSRange) {
        guard let tv = textView else { return }
        adjustingSelection = true
        defer { adjustingSelection = false }
        tv.selectedRange = r
        lastSelection = r
    }

    // MARK: Following the text

    /// Every character edit (storageEdited): folds before it shift, a fold
    /// it touches opens.
    func textEdited(oldRange: NSRange, newLength: Int, storage: NSTextStorage) {
        guard !state.isEmpty else { return }
        let ns = storage.string as NSString
        let inserted = NSRange(location: oldRange.location, length: newLength)
        let newline = newLength > 0 && ns.rangeOfCharacter(from: .newlines, options: [], range: inserted).location != NSNotFound
        let oldLength = ns.length - newLength + oldRange.length
        let before = state.folds.first?.location ?? 0
        let opened = state.adjust(oldRange: oldRange, newLength: newLength, insertsNewline: newline, oldLength: oldLength)
        hiddenForLayout = state
        guard opened else { return }
        // TextKit is in the middle of the edit: lay out again after it.
        let from = min(before, oldRange.location)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.apply(from: from) }
        }
    }

    /// The selection changed (UIKit says after the fact). A key move
    /// (arrows, with or without Shift) that lands in hidden text skips past
    /// it in the direction it went; anything else (a tap, find, Go to Line,
    /// bookmarks) that lands in hidden text opens the folds it lands in.
    /// A selection that covers a whole fold leaves it folded.
    func selectionChanged(byKey: Bool) {
        guard let tv = textView, !adjustingSelection else { return }
        let new = tv.selectedRange
        let old = lastSelection
        lastSelection = new
        guard !state.isEmpty, new.location != NSNotFound else { return }
        let ns = tv.textStorage.string as NSString
        let len = ns.length
        let nl = len > 0 && ns.character(at: len - 1) == 10
        if byKey {
            let target: NSRange
            if new.length == 0 {
                let from = old.location + (old.length > 0 && new.location >= NSMaxRange(old) ? old.length : 0)
                target = NSRange(location: state.navigationTarget(new.location, from: from, length: len, endsWithNewline: nl), length: 0)
            } else {
                // A selection extended by keys: each end skips as a caret would.
                let s = state.navigationTarget(new.location, from: old.location, length: len, endsWithNewline: nl)
                let e = state.navigationTarget(NSMaxRange(new), from: NSMaxRange(old), length: len, endsWithNewline: nl)
                target = NSRange(location: min(s, e), length: abs(e - s))
            }
            if target != new { setSelection(target) }
            return
        }
        unfold(state.foldsToOpen(for: new, length: len, endsWithNewline: nl))
    }

    // MARK: Lines

    /// The pill's label for a hidden range: "⋯ 42 lines".
    static func label(for hidden: NSRange, _ index: LineIndex) -> String {
        let n = FoldState.lineCount(of: hidden, index)
        return n == 1 ? String(localized: "⋯ 1 line") : String(localized: "⋯ \(n) lines")
    }

    // MARK: Pills

    /// The pills shown now (for tests).
    var visiblePills: [FoldPillButton] { pills.filter { !$0.isHidden } }

    /// A "⋯ N lines" button after each folded header line in view (a view
    /// in the text's coordinates, so it scrolls with it; not an attachment:
    /// the text never changes). A tap unfolds the outermost folds there.
    func layoutPills(index: LineIndex, font: UIFont, foreground: UIColor, background: UIColor) {
        guard let tv = textView else { return }
        var used = 0
        if !state.isEmpty, index.length == tv.textStorage.length, let vr = SyntaxColorizer.visibleRange(tv) {
            let lo = vr.location, hi = NSMaxRange(vr)
            for h in state.hidden where h.location > 0 {
                let header = index.line(containing: h.location - 1)
                let end = NSMaxRange(index.contentRange(ofLine: header))
                guard end >= lo, end <= hi, let pos = tv.position(from: tv.beginningOfDocument, offset: end) else { continue }
                let caret = tv.caretRect(for: pos)
                guard !caret.isNull, !caret.isInfinite else { continue }
                if used == pills.count {
                    let b = FoldPillButton()
                    b.addTarget(self, action: #selector(pillTapped(_:)), for: .touchUpInside)
                    b.onActivate = { [weak self, weak b] in
                        guard let self, let b else { return }
                        self.pillTapped(b)
                    }
                    tv.addSubview(b)
                    pills.append(b)
                }
                let b = pills[used]
                used += 1
                b.configure(label: Self.label(for: h, index), header: header, hidden: h, font: font, foreground: foreground, background: background)
                let size = b.intrinsicContentSize
                let height = min(max(caret.height, 14), size.height)
                b.frame = CGRect(x: caret.maxX + 8, y: caret.midY - height / 2, width: size.width, height: height)
                b.isHidden = false
            }
        }
        for b in pills[used...] { b.isHidden = true }
    }

    @objc private func pillTapped(_ sender: FoldPillButton) {
        unfold(state.folds(startingAt: sender.hiddenRange.location))
    }

    /// VoiceOver: a UITextView is one accessibility element, so the pills
    /// inside it are never visited. The text view offers one custom action
    /// per visible pill instead ("Unfold line 3, ⋯ 4 lines"), which opens
    /// what a tap on that pill opens; the text itself reads as before.
    var pillAccessibilityActions: [UIAccessibilityCustomAction] {
        visiblePills.map { b in
            let name = String(localized: "Unfold line \(b.headerLine + 1), \(b.accessibilityLabel ?? "")")
            let a = UIAccessibilityCustomAction(name: name) { [weak self, weak b] _ in
                guard let self, let b, !b.isHidden else { return false }
                self.pillTapped(b)
                return true
            }
            return a
        }
    }
}

/// The "⋯ N lines" pill on a folded header.
final class FoldPillButton: UIButton {
    private(set) var hiddenRange = NSRange(location: 0, length: 0)
    /// The folded header's line (0-based).
    private(set) var headerLine = 0
    /// What a tap does (VoiceOver, Full Keyboard Access and Voice Control
    /// activate the pill without a touch).
    var onActivate: (() -> Void)?

    func configure(label: String, header: Int, hidden: NSRange, font: UIFont, foreground: UIColor, background: UIColor) {
        hiddenRange = hidden
        headerLine = header
        isAccessibilityElement = true
        accessibilityTraits = .button
        var c = UIButton.Configuration.plain()
        c.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
        c.attributedTitle = AttributedString(label, attributes: AttributeContainer([.font: font, .foregroundColor: foreground]))
        c.background.backgroundColor = background
        c.background.strokeColor = foreground.withAlphaComponent(0.6)
        c.background.strokeWidth = 1
        c.background.cornerRadius = 8
        c.cornerStyle = .capsule
        configuration = c
        accessibilityIdentifier = "editor.foldPill"
        accessibilityLabel = label
        accessibilityHint = String(localized: "Unfolds the hidden lines.")
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate, !isHidden else { return false }
        onActivate()
        return true
    }
}

// MARK: - The editor

extension EditorViewController {
    /// Folding applies: a language that folds, outside large mode.
    var foldingAvailable: Bool {
        document.language.language.foldKind != .none && writingLargeReason == nil
    }

    func foldScanner() -> FoldScanner? {
        guard foldingAvailable else { return nil }
        let text = textView.textStorage.string as NSString
        let index = lineIndex
        guard index.length == text.length else { return nil }
        let language = document.language.language
        let fences = markdownFenceIndex
        return FoldScanner(language: language, text: text, index: index, engine: highlightEngine,
                           inFence: language == .markdown ? { fences.isInFence(text, index: index, line: $0) } : nil,
                           tabWidth: resolvedLineIndentation(text).indentation.width)
    }

    /// The editor's controller, made on the first fold.
    func makeFolding() -> FoldingController {
        if let f = folding { return f }
        let f = FoldingController(textView: textView)
        f.onChange = { [weak self] in self?.foldsChanged() }
        textView.extraAccessibilityActions = { [weak f] in f?.pillAccessibilityActions ?? [] }
        folding = f
        return f
    }

    /// Something is folded.
    var hasFolds: Bool { folding?.isEmpty == false }

    /// The fold column's mark for each line in `lines` (0-based), for the gutter.
    func foldMarks(lines: [Int]) -> [Int: FoldMark] {
        guard foldingAvailable else { return [:] }
        let folded = Set(folding?.state.headerLines(lineIndex) ?? [])
        let scanner = foldScanner()
        var out: [Int: FoldMark] = [:]
        for l in lines {
            if folded.contains(l) { out[l] = .folded } else if scanner?.startsRegion(l) == true { out[l] = .open }
        }
        return out
    }

    /// A tap in the gutter's fold column; false when nothing folds on that
    /// line (the tap then toggles the bookmark, as on the number).
    @discardableResult
    func toggleFold(line: Int) -> Bool {
        guard foldingAvailable else { return false }
        if let f = folding, case let mine = f.state.folds(header: line, lineIndex), !mine.isEmpty {
            f.unfold(mine)
            return true
        }
        guard let r = foldScanner()?.region(at: line) else { return false }
        makeFolding().fold([r], index: lineIndex)
        return true
    }

    /// Fold: the region the caret's line starts, else the innermost one
    /// around the caret not yet folded.
    func foldAtCaret() {
        guard let scanner = foldScanner() else { return }
        let index = lineIndex
        let folded = Set(folding?.state.folds ?? [])
        guard let r = scanner.enclosingRegion(of: caretLine, excluding: { $0.hiddenRange(in: index).map(folded.contains) ?? true }) else {
            nothingToFold()
            return
        }
        makeFolding().fold([r], index: index)
    }

    /// Unfold: the folds on the caret's line.
    func unfoldAtCaret() {
        guard let f = folding else { return }
        f.unfold(f.state.folds(header: caretLine, lineIndex))
    }

    /// Fold All; with `level`, Fold to Level N: the regions at depth N and
    /// deeper fold, the ones above them open.
    func foldAll(level: Int = 1) {
        guard let scanner = foldScanner() else { return }
        let regions = scanner.allRegions().filter { $0.depth >= level }
        guard !regions.isEmpty else { nothingToFold(); return }
        let f = makeFolding()
        f.unfoldAll()
        f.fold(regions, index: lineIndex)
    }

    func unfoldAll() {
        folding?.unfoldAll()
    }

    private func nothingToFold() {
        let s = String(localized: "Nothing to fold here.")
        toast(s)
        announceAccessibility(s)
    }

    /// The fold state changed: the gutter (shown while something is
    /// folded), the pills, the invisibles.
    func foldsChanged() {
        invisiblesOverlay.textChanged()
        layoutGutter()
        UIAccessibility.post(notification: .layoutChanged, argument: textView)
    }

    /// Language or large mode changed: the old regions don't apply.
    func foldingContextChanged() {
        guard let f = folding, !f.isEmpty else { return }
        f.unfoldAll()
    }

    @objc func foldMenu(_ sender: Any?) { foldAtCaret() }
    @objc func unfoldMenu(_ sender: Any?) { unfoldAtCaret() }
    @objc func foldAllMenu(_ sender: Any?) { foldAll() }
    @objc func unfoldAllMenu(_ sender: Any?) { unfoldAll() }
    @objc func foldToLevelMenu(_ sender: Any?) {
        guard let level = (sender as? UICommand)?.propertyList as? Int else { return }
        foldAll(level: level)
    }

    static let foldingActions: Set<Selector> = [#selector(foldMenu(_:)), #selector(foldAllMenu(_:)), #selector(foldToLevelMenu(_:))]
    static let unfoldingActions: Set<Selector> = [#selector(unfoldMenu(_:)), #selector(unfoldAllMenu(_:))]

    /// What the Folding commands may do now: (fold, unfold, unfold all).
    /// Unfold is enabled whenever anything is folded, as on the Mac;
    /// unfoldAtCaret() decides what to open.
    var foldingMenuState: (fold: Bool, unfold: Bool, unfoldAll: Bool) {
        let available = foldingAvailable
        let folded = available && hasFolds
        return (available, folded, folded)
    }

    /// The ⋯ menu's Folding submenu; disabled where the language doesn't
    /// fold, in large mode, or with nothing folded to open.
    func foldingMenu() -> UIMenu {
        let s = foldingMenuState
        func item(_ title: String, _ id: String, _ symbol: String, enabled: Bool,
                  _ perform: @escaping (EditorViewController) -> Void) -> UIAction {
            let a = UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                guard let self else { return }
                perform(self)
            }
            a.accessibilityIdentifier = id
            if !enabled { a.attributes = .disabled }
            return a
        }
        let levels = (1...3).map { (level: Int) in
            item(String(localized: "Fold to Level \(level)"), "editor.menu.foldToLevel\(level)", "\(level).square", enabled: s.fold) {
                $0.foldAll(level: level)
            }
        }
        let menu = UIMenu(title: String(localized: "Folding"), image: UIImage(systemName: "chevron.down.square"), children: [
            item(String(localized: "Fold"), "editor.menu.fold", "chevron.down", enabled: s.fold) { $0.foldAtCaret() },
            item(String(localized: "Unfold"), "editor.menu.unfold", "chevron.right", enabled: s.unfold) { $0.unfoldAtCaret() },
            item(String(localized: "Fold All"), "editor.menu.foldAll", "rectangle.compress.vertical", enabled: s.fold) { $0.foldAll() },
            item(String(localized: "Unfold All"), "editor.menu.unfoldAll", "rectangle.expand.vertical", enabled: s.unfoldAll) { $0.unfoldAll() },
            UIMenu(options: .displayInline, children: levels),
        ])
        return menu
    }
}
