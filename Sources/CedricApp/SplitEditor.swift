import AppKit
import CedricCore

// View › Split Editor: two panes on one document. The second pane is an
// EditorTextView + GutterView + NSScrollView whose NSTextLayoutManager is
// added to the SAME ChunkedContentStorage, so both panes show and edit one
// text storage, with one undo manager (the window's) and one LineIndex.
// It is built on the first split and torn down on unsplit (its layout
// manager removed from the content storage, its views released): a tab
// that is never split has no second pane, and every hook below is a nil
// check (`splitEditor`).
//
// Commands act on the focused pane: `EditorWindowController.textView` is
// the active pane's text view (PaneFocus: the pane last focused, kept
// while the find bar or a panel has the focus). Per-view state that stays
// with the primary pane: spelling and grammar marks, the owl's overlay.

/// One editor pane: a text view in a scroll view, with its gutter, laid
/// out by an EditorContainer.
@MainActor
final class EditorPane {
    let textView: EditorTextView
    let scrollView: NSScrollView
    let gutter: GutterView
    let container: EditorContainer
    /// The line at the top when the user last scrolled this pane: kept
    /// there when the window is resized.
    var anchorLine = 0
    var restoringAnchor = false
    /// Its scroll and frame observers (removed with the pane).
    var observers: [NSObjectProtocol] = []

    init(textView: EditorTextView) {
        let g = GutterView(), s = NSScrollView()
        self.textView = textView
        gutter = g
        scrollView = s
        container = EditorContainer(gutter: g, scrollView: s)
    }
}

/// The split view holding the two panes (in the tab's `split`, where the
/// primary pane's container was).
final class EditorSplitView: NSSplitView {
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }
    override var dividerColor: NSColor { color }
}

/// A split tab's second pane and the split view between the two.
@MainActor
final class SplitEditor: NSObject, NSSplitViewDelegate {
    let primary: EditorPane
    let second: EditorPane
    let view = EditorSplitView()
    var focus = PaneFocus()
    var activePane: EditorPane { focus.active == .second ? second : primary }

    init(primary: EditorPane, second: EditorPane, sideBySide: Bool) {
        self.primary = primary
        self.second = second
        super.init()
        view.isVertical = sideBySide
        view.dividerStyle = .thin
        view.delegate = self
    }

    var sideBySide: Bool { view.isVertical }

    private var length: CGFloat { view.isVertical ? view.bounds.width : view.bounds.height }

    /// The first pane's share of the room.
    var ratio: Double {
        let first = view.isVertical ? primary.container.frame.width : primary.container.frame.height
        return SplitEditorState.ratio(position: Double(first), total: Double(length), thickness: Double(view.dividerThickness))
    }

    func setRatio(_ r: Double) {
        guard length > 0 else { return }
        view.adjustSubviews()
        let pos = SplitEditorState.dividerPosition(ratio: r, total: Double(length), thickness: Double(view.dividerThickness))
        view.setPosition(CGFloat(pos), ofDividerAt: 0)
    }

    func applyPalette(_ p: EditorPalette) {
        view.color = NSColor(hex: p.gutterForeground).withAlphaComponent(0.35)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        max(proposed, CGFloat(SplitEditorState.minPane))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        min(proposed, length - view.dividerThickness - CGFloat(SplitEditorState.minPane))
    }
}

// MARK: - The tab

extension EditorWindowController {
    var isSplit: Bool { splitEditor != nil }

    /// Up to this many UTF-16 units the new pane is laid out whole on split.
    static let splitFullLayoutLimit = 200_000

    /// Read-only or not, in both panes (binary files, Follow File). A
    /// read-only file stays read-only until Allow Editing (ReadOnlyFile.swift).
    func setEditable(_ on: Bool) {
        let editable = on && !fileBlocksTyping
        panes.forEach { $0.textView.isEditable = editable }
    }

    /// View › Split Editor.
    func toggleSplit() {
        if isSplit { unsplit() } else { splitPanes() }
    }

    /// Builds the second pane on the same content storage and puts both
    /// panes where the editor was. `focusSecond`: the new pane takes the
    /// focus (the menu command); a restored split keeps the saved one.
    func splitPanes(sideBySide: Bool = false, ratio: Double = 0.5, focusSecond: Bool = true) {
        guard splitEditor == nil, let window, let cs = primaryTextView.contentStorage else { return }
        let first = primaryTextView
        let pane = EditorPane(textView: EditorTextView.make(sharing: cs))
        configure(pane)
        let tv = pane.textView
        tv.isEditable = first.isEditable
        tv.language = first.language
        tv.folding = folding
        tv.font = editorFont
        tv.textColor = NSColor(hex: palette.foreground)
        tv.typingAttributes = baseAttributes()
        applyPaneAppearance(pane, palette: palette)
        applyWrap(wrapsLines, to: pane)

        // The split view takes the editor's place (by identity: a folder
        // sidebar, the preview or Find in Files may be docked around it).
        let hadFocus = window.firstResponder === first
        let outer = split
        let index = outer.arrangedSubviews.firstIndex(of: primaryPane.container) ?? 0
        let positions = Self.dividerPositions(outer)
        let frame = primaryPane.container.frame
        let s = SplitEditor(primary: primaryPane, second: pane, sideBySide: sideBySide)
        primaryPane.container.removeFromSuperview()
        s.view.frame = frame
        s.view.addArrangedSubview(primaryPane.container)
        s.view.addArrangedSubview(pane.container)
        outer.insertArrangedSubview(s.view, at: index)
        Self.restoreDividers(positions, in: outer)
        splitEditor = s
        // Its checking types follow the primary pane's (spelling off: none).
        spelling.apply()
        // The status items follow the split as they follow the editor alone.
        s.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorColumnMoved(_:)),
                                               name: NSView.frameDidChangeNotification, object: s.view)
        s.applyPalette(palette)
        s.view.layoutSubtreeIfNeeded()
        s.setRatio(ratio)
        alignStatusBar()

        // A small document is laid out whole at once, as the first pane's
        // is: a layout manager that joins a text later has laid out only
        // its viewport, so its view is one screen tall and the wheel
        // couldn't scroll it. A bigger one fills in as TextKit lays it out.
        if let tlm = tv.textLayoutManager, (tv.textStorage?.length ?? 0) <= Self.splitFullLayoutLimit, !isLargeDocument {
            let t0 = DispatchTime.now()
            tlm.ensureLayout(for: tlm.documentRange)
            lastSplitLayoutMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        }
        observePane(pane)
        colorizer.secondTextView = tv
        updateGutterWidth()
        // The new pane starts where the first one is.
        tv.setSelectedRange(first.selectedRange())
        scrollToLine(primaryTopLine, in: pane)
        s.focus.split(focusSecond: false)
        if focusSecond {
            window.makeFirstResponder(tv)
        } else if hadFocus {
            window.makeFirstResponder(first)
        }
        colorizer.scheduleViewport()
        onChange?(self)
    }

    /// Unsplit: the second pane goes (its layout manager leaves the
    /// content storage, its views and observers are released) and the
    /// primary pane takes the editor's place again.
    func unsplit(closing: Bool = false) {
        guard let s = splitEditor else { return }
        let pane = s.second
        let hadFocus = window.map { $0.firstResponder === pane.textView || $0.firstResponder === primaryTextView } ?? false
        pane.observers.forEach { NotificationCenter.default.removeObserver($0) }
        pane.observers = []
        colorizer.secondTextView = nil
        if pane.textView.multiCarets != nil { pane.textView.endMultiCarets() }
        detachPane(pane)
        pane.textView.folding = nil
        if let cs = primaryTextView.contentStorage, let tlm = pane.textView.textLayoutManager {
            cs.removeTextLayoutManager(tlm)
            if let mine = primaryTextView.textLayoutManager { cs.primaryTextLayoutManager = mine }
        }
        s.focus.unsplit()
        splitEditor = nil
        s.view.delegate = nil
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: s.view)
        guard !closing else { return }
        let outer = split
        let index = outer.arrangedSubviews.firstIndex(of: s.view) ?? 0
        let positions = Self.dividerPositions(outer)
        let frame = s.view.frame
        pane.container.removeFromSuperview()
        primaryPane.container.removeFromSuperview()
        s.view.removeFromSuperview()
        primaryPane.container.frame = frame
        outer.insertArrangedSubview(primaryPane.container, at: index)
        Self.restoreDividers(positions, in: outer)
        alignStatusBar()
        if hadFocus { window?.makeFirstResponder(primaryTextView) }
        updateStatus()
        refreshHighlights()
        updateBracketMatch()
        onChange?(self)
    }

    /// View › Switch Split Orientation: top/bottom ⇄ side by side, same ratio.
    func switchSplitOrientation() {
        guard let s = splitEditor else { NSSound.beep(); return }
        let r = s.ratio
        s.view.isVertical.toggle()
        s.view.adjustSubviews()
        s.setRatio(r)
        colorizer.scheduleViewport()
        setGuttersNeedDisplay()
        onChange?(self)
    }

    /// View › Move Focus to Other Pane.
    func focusOtherPane() {
        guard let s = splitEditor, let other = s.focus.other else { NSSound.beep(); return }
        window?.makeFirstResponder(other == .second ? s.second.textView : primaryTextView)
    }

    /// A pane's text view became first responder: commands follow it.
    func paneFocused(_ tv: EditorTextView) {
        guard let s = splitEditor else { return }
        let was = textView
        s.focus.focused(tv === s.second.textView ? .second : .first)
        guard textView !== was else { return }
        contextBar?.refreshInlineSelectionStates()
        // Editing and the input system go through the content storage's
        // primary layout manager: the focused pane's.
        if let tlm = tv.textLayoutManager { tv.contentStorage?.primaryTextLayoutManager = tlm }
        // The caret's marks (occurrences, bracket match) belong to the
        // pane with the caret.
        if !was.occurrenceRanges.isEmpty || !was.bracketRanges.isEmpty {
            was.occurrenceRanges = []
            was.bracketRanges = []
            was.needsDisplay = true
        }
        updateStatus()
        scheduleHighlights()
        updateBracketMatch()
        setGuttersNeedDisplay()
    }

    /// For the session.
    var sessionSplit: SplitEditorState? {
        guard let s = splitEditor else { return nil }
        return SplitEditorState(sideBySide: s.sideBySide, ratio: s.ratio, topLine: topLine(in: s.second),
                                secondFocused: s.focus.active == .second ? true : nil)
    }

    /// A split from the session, after the first frame.
    func restoreSplit(_ st: SplitEditorState) {
        AfterFirstFrame.run { [weak self] in
            guard let self, self.splitEditor == nil, self.window != nil else { return }
            self.splitPanes(sideBySide: st.sideBySide, ratio: st.ratio, focusSecond: st.secondFocused == true)
            guard let s = self.splitEditor else { return }
            let top = st.topLine
            // Once the new pane has its size.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.splitEditor === s else { return }
                self.scrollToLine(top, in: s.second)
                s.second.anchorLine = top
            }
        }
    }

    /// The text view's context menu: Split Editor, and the orientation while split.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        if view.selectedRange().length > 0 {
            if let editor = view as? EditorTextView { paneFocused(editor) }
            menu.addItem(.separator())
            let explain = NSMenuItem(title: String(localized: "Explain Selection"),
                                     action: #selector(AppDelegate.explainSelectionMenu(_:)), keyEquivalent: "")
            let rewrite = NSMenuItem(title: String(localized: "Rewrite Selection"),
                                     action: #selector(AppDelegate.rewriteSelectionMenu(_:)), keyEquivalent: "")
            explain.target = NSApp.delegate
            rewrite.target = NSApp.delegate
            menu.addItem(explain)
            menu.addItem(rewrite)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: isSplit ? String(localized: "Close Split") : String(localized: "Split Editor"),
                                action: #selector(toggleSplitAction(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if let s = splitEditor {
            let o = NSMenuItem(title: s.sideBySide ? String(localized: "Split Top and Bottom") : String(localized: "Split Side by Side"),
                               action: #selector(switchSplitOrientationAction(_:)), keyEquivalent: "")
            o.target = self
            menu.addItem(o)
        }
        return menu
    }

    @objc func toggleSplitAction(_ sender: Any?) { toggleSplit() }
    @objc func switchSplitOrientationAction(_ sender: Any?) { switchSplitOrientation() }

    private static func dividerPositions(_ v: NSSplitView) -> [CGFloat] {
        // Frames as laid out now (a panel just closed may not have given its room back yet).
        v.layoutSubtreeIfNeeded()
        return v.arrangedSubviews.dropLast().map { v.isVertical ? $0.frame.maxX : $0.frame.maxY }
    }

    private static func restoreDividers(_ positions: [CGFloat], in v: NSSplitView) {
        v.adjustSubviews()
        for (i, p) in positions.enumerated() where i < v.arrangedSubviews.count - 1 { v.setPosition(p, ofDividerAt: i) }
    }
}

// MARK: - The menu

extension AppDelegate {
    @objc func toggleSplitEditorMenu(_ sender: Any?) { currentTab?.toggleSplit() }
    @objc func switchSplitOrientationMenu(_ sender: Any?) { currentTab?.switchSplitOrientation() }
    @objc func moveFocusToOtherPaneMenu(_ sender: Any?) { currentTab?.focusOtherPane() }

    func validateSplitItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleSplitEditorMenu(_:)):
            item.state = currentTab?.isSplit == true ? .on : .off
            return currentTab != nil
        case #selector(switchSplitOrientationMenu(_:)):
            item.title = currentTab?.splitEditor?.sideBySide == true ? String(localized: "Split Top and Bottom")
                : String(localized: "Split Side by Side")
            return currentTab?.isSplit == true
        case #selector(moveFocusToOtherPaneMenu(_:)):
            return currentTab?.isSplit == true
        default: return nil
        }
    }
}

/// View › Split Editor and its two companions.
@MainActor
func splitEditorMenuItems() -> [NSMenuItem] {
    [
        item(String(localized: "Split Editor"), #selector(AppDelegate.toggleSplitEditorMenu(_:)), "\\", [.control, .command]),
        item(String(localized: "Split Side by Side"), #selector(AppDelegate.switchSplitOrientationMenu(_:))),
        item(String(localized: "Move Focus to Other Pane"), #selector(AppDelegate.moveFocusToOtherPaneMenu(_:))),
    ]
}
