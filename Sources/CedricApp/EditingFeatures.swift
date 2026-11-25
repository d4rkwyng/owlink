import AppKit
import CedricCore

/// Per-tab state for the editing extras: highlight-all, Mark All,
/// bookmarks. Created with the tab but does nothing until used (no timers
/// or scans at launch).
@MainActor
final class EditingState {
    /// Debounces highlight-all after a selection change.
    var highlightTimer: Timer?
    /// Mark All's needle (nil: no marks) and its count in the whole text
    /// (nil when not counted: no marks, or a document too big to recount
    /// on every edit).
    var markNeedle: Occurrences.Needle?
    var markCount: Int?
    var markCountTimer: Timer?
    /// Bookmarked lines; follow edits (EditorWindowController.storageEdited).
    var bookmarks = Bookmarks()

    /// Status-bar counts: debounced for big ranges; the whole document's
    /// are cached until the text changes (any storage edit drops them).
    var countsTimer: Timer?
    var documentCounts: TextCounts?? { didSet { if documentCounts == nil { countsGeneration &+= 1 } } }
    /// Moves on every text change (documentCounts dropped): a count made
    /// off the main thread is shown only if this hasn't moved meanwhile.
    var countsGeneration = 0
    /// The newest background count asked for; older ones are dropped.
    var countsRequest = 0

    /// View › Writing Mode for this tab (WritingMode.swift): off by default.
    var writing = WritingModeState()
    /// View › Readable Width switched for this tab (nil: the Writing
    /// default, off until that checkbox is on; ReadableWidthView.swift).
    var readableWidth: Bool?
    /// What Focus last applied, per text view: the focus and visible
    /// ranges, their ends counted from the text's end (WritingMode.swift).
    var focusDimmed: [ObjectIdentifier: [Int]] = [:]
    var focusPending = false
    /// The cheap part of that (focus and scroll position), tested first.
    var focusPrecheck: [ObjectIdentifier: [Int]] = [:]
    /// Typewriter scrolls made (the checks: one per keystroke at most).
    var typewriterScrolls = 0
    /// Viewport layouts the typewriter asked for (perf hooks).
    var typewriterLayouts = 0
    /// Typewriter and Focus passes that did the work (perf hooks).
    var typewriterPasses = 0, focusPasses = 0
    /// Each view's caret, text length and scroll after its last typewriter pass.
    var typewriterLast: [ObjectIdentifier: [Int]] = [:]
    /// The stats popover's word goal (a file's is also in the session's
    /// `wordGoals`, by path); never written into the text.
    var wordGoal: Int?
    /// The stats popover while it is shown (StatsPopover.swift).
    var statsPopover: StatsPopover?
    /// Today's word count (DailyWords.swift): one note after typing pauses.
    /// Never per keystroke. `dailyArm` moves when a reload arms a new
    /// baseline, so a count of the previous text is dropped.
    var dailyTimer: Timer?
    var dailyArm = 0

    func stop() {
        countsTimer?.invalidate()
        countsTimer = nil
        dailyTimer?.invalidate()
        dailyTimer = nil
        highlightTimer?.invalidate()
        highlightTimer = nil
        markCountTimer?.invalidate()
        markCountTimer = nil
    }
}

// MARK: - Highlight all occurrences, Mark All

extension EditorWindowController {
    /// Mark counts are kept up to date while typing only below this size
    /// (UTF-16 units); a bigger document is counted when Mark All runs.
    static let markRecountLimit = 2_000_000

    /// After a selection change: highlight a moment later, so a burst of
    /// typing or caret moves costs one search of the visible text.
    func scheduleHighlights() {
        editing.highlightTimer?.invalidate()
        // Several carets (MultiCaretEditing.swift): occurrence highlighting
        // pauses, and the status bar counts carets.
        if textView.multiCarets != nil {
            editing.highlightTimer = nil
            showMultiCaretStatus()
            return
        }
        let t = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHighlights() }
        }
        RunLoop.main.add(t, forMode: .common)
        editing.highlightTimer = t
    }

    /// The text to search for highlights: the visible text and a margin,
    /// never the whole document.
    private var highlightRange: NSRange? { highlightRange(in: textView) }

    private func highlightRange(in textView: EditorTextView) -> NSRange? {
        guard let vis = textView.visibleCharacterRange else { return nil }
        let len = (textView.string as NSString).length
        let start = max(0, vis.location - 2_000)
        return NSRange(location: start, length: min(len, NSMaxRange(vis) + 2_000) - start)
    }

    /// Recomputes the occurrence and mark ranges for the visible text.
    func refreshHighlights() {
        editing.highlightTimer?.invalidate()
        editing.highlightTimer = nil
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        var occ: [NSRange] = []
        var marks: [NSRange] = []
        if let range = highlightRange {
            if Settings.shared.highlightOccurrences, !textView.hasMarkedText(), textView.multiCarets == nil,
               let needle = Occurrences.needle(selection: sel, in: ns) {
                occ = Occurrences.find(needle, in: ns, range: range)
                // Only worth tinting if it occurs somewhere else too.
                if occ.count < 2 { occ = [] }
            }
            if let m = editing.markNeedle { marks = Occurrences.find(m, in: ns, range: range) }
        }
        if occ != textView.occurrenceRanges || marks != textView.markRanges {
            textView.occurrenceRanges = occ
            textView.markRanges = marks
            textView.needsDisplay = true
        }
        // Split: Mark All's marks show in the other pane too (occurrences
        // and the bracket match stay with the caret's pane).
        if let s = splitEditor {
            let other = textView === s.second.textView ? primaryTextView : s.second.textView
            var otherMarks: [NSRange] = []
            if let m = editing.markNeedle, let range = highlightRange(in: other) { otherMarks = Occurrences.find(m, in: ns, range: range) }
            if otherMarks != other.markRanges {
                other.markRanges = otherMarks
                other.needsDisplay = true
            }
        }
    }

    /// Edit › Find › Mark All: marks every occurrence of the selection (or
    /// the word under the caret) until Clear Marks. Marks follow the text
    /// as it changes: only the needle is kept, and the visible text is
    /// searched again.
    func markAll() {
        let ns = textView.string as NSString
        guard let needle = Occurrences.needle(selection: textView.selectedRange(), in: ns) else { NSSound.beep(); return }
        editing.markNeedle = needle
        editing.markCount = Occurrences.count(needle, in: ns)
        refreshHighlights()
        updateStatus()
    }

    func clearMarks() {
        editing.markNeedle = nil
        editing.markCount = nil
        editing.markCountTimer?.invalidate()
        refreshHighlights()
        updateStatus()
    }

    var hasMarks: Bool { editing.markNeedle != nil }

    /// After an edit: recount the marks a moment later (small documents
    /// only), and highlight again.
    func editingTextChanged() {
        // The ranges are stale after an edit: drop them until the pause
        // (refreshHighlights) finds them again.
        for tv in panes.map(\.textView) where !tv.occurrenceRanges.isEmpty || !tv.markRanges.isEmpty {
            tv.occurrenceRanges = []
            tv.markRanges = []
            tv.needsDisplay = true
        }
        if let needle = editing.markNeedle {
            editing.markCountTimer?.invalidate()
            if (textView.string as NSString).length <= Self.markRecountLimit {
                let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.editing.markNeedle == needle else { return }
                        self.editing.markCount = Occurrences.count(needle, in: self.textView.string as NSString)
                        self.updateStatus()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                editing.markCountTimer = t
            } else {
                editing.markCount = nil
            }
        }
        scheduleHighlights()
    }
}

// MARK: - Matching bracket

extension EditorWindowController {
    /// Boxes the bracket next to the caret and its partner (a bounded
    /// scan: AutoEdit.matchingBracket), right away on every caret move.
    func updateBracketMatch() {
        let sel = textView.selectedRange()
        var ranges: [NSRange] = []
        if sel.length == 0, !textView.hasMarkedText(),
           let (a, b) = AutoEdit.matchingBracket(in: textView.string as NSString, caret: sel.location) {
            ranges = [a, b]
        }
        if ranges != textView.bracketRanges {
            textView.bracketRanges = ranges
            textView.needsDisplay = true
        }
    }
}

// MARK: - Word, line and character counts

extension EditorWindowController {
    /// Ranges up to this many units are counted at once; longer ones a
    /// moment after typing or selecting stops.
    static let immediateCountLimit = 50_000

    /// Updates the status bar's counts: of the selection if there is one,
    /// else of the document. Past `TextStats.maxCounted` units only lines
    /// are shown (from the line index, no scan).
    func scheduleCounts() {
        editing.countsTimer?.invalidate()
        editing.countsTimer = nil
        let sel = textView.selectedRange()
        let length = sel.length > 0 ? sel.length : lineIndex.length
        let cached = sel.length == 0 && editing.documentCounts != nil
        if cached || length <= Self.immediateCountLimit || length > TextStats.maxCounted {
            updateCounts()
            return
        }
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCounts() }
        }
        RunLoop.main.add(t, forMode: .common)
        editing.countsTimer = t
    }

    func updateCounts() {
        editing.countsTimer = nil
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        if sel.length > 0 {
            if sel.length > Self.immediateCountLimit, sel.length <= TextStats.maxCounted {
                countInBackground(ns, range: sel, selection: true)
                return
            }
            if let c = TextStats.count(ns, range: sel) {
                showCounts(c, selection: true)
            } else {
                let a = lineIndex.line(containing: sel.location), b = lineIndex.line(containing: max(sel.location, NSMaxRange(sel) - 1))
                showLinesOnly(b - a + 1, selection: true)
            }
            return
        }
        if let cached = editing.documentCounts {
            if let c = cached { showCounts(c, selection: false) } else { showDocumentLines() }
            return
        }
        if ns.length > Self.immediateCountLimit, ns.length <= TextStats.maxCounted {
            countInBackground(ns, range: NSRange(location: 0, length: ns.length), selection: false)
            return
        }
        let counts = TextStats.count(ns, range: NSRange(location: 0, length: ns.length))
        editing.documentCounts = .some(counts)
        if let c = counts { showCounts(c, selection: false) } else { showDocumentLines() }
    }

    /// Big ranges (50 K to 1 M units) are counted off the main thread, on
    /// a copy of the text, and shown if neither the text nor the selection
    /// changed meanwhile (else a newer count is on its way). The status bar
    /// keeps its last counts until then.
    private func countInBackground(_ ns: NSString, range: NSRange, selection: Bool) {
        struct Snapshot: @unchecked Sendable { let text: NSString }   // an immutable copy
        let snap = Snapshot(text: ns.substring(with: range) as NSString)
        let generation = editing.countsGeneration
        let sel = textView.selectedRange()
        editing.countsRequest &+= 1
        let request = editing.countsRequest
        DispatchQueue.global(qos: .userInitiated).async {
            let counts = TextStats.count(snap.text, range: NSRange(location: 0, length: snap.text.length))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.editing.countsRequest == request, self.editing.countsGeneration == generation,
                          self.textView.selectedRange() == sel, let counts else { return }
                    if !selection { self.editing.documentCounts = .some(counts) }
                    self.showCounts(counts, selection: selection)
                }
            }
        }
    }

    private func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(many)" }

    private func showCounts(_ c: TextCounts, selection: Bool) {
        let s = [plural(c.words, String(localized: "word"), String(localized: "words")),
                 plural(c.lines, String(localized: "line"), String(localized: "lines")),
                 plural(c.characters, String(localized: "character"), String(localized: "characters"))].joined(separator: " · ")
        statusBar.counts.stringValue = selection ? String(localized: "Selected: \(s)") : s
    }

    private func showLinesOnly(_ n: Int, selection: Bool) {
        let s = plural(n, String(localized: "line"), String(localized: "lines"))
        statusBar.counts.stringValue = selection ? String(localized: "Selected: \(s)") : s
    }

    private func showDocumentLines() {
        // As TextStats counts: an empty last line (after a final newline) isn't one.
        showLinesOnly(lineIndex.lineCount - (lineIndex.lineCount > 1 && lineIndex.lineLength(lineIndex.lineCount - 1) == 0 ? 1 : 0),
                      selection: false)
    }
}

// MARK: - Line operations

/// Text › Line: what to do to the selected lines.
enum LineCommand {
    case duplicate, moveUp, moveDown, delete, toggleComment

    var actionName: String {
        switch self {
        case .duplicate: return String(localized: "Duplicate Line")
        case .moveUp: return String(localized: "Move Line Up")
        case .moveDown: return String(localized: "Move Line Down")
        case .delete: return String(localized: "Delete Line")
        case .toggleComment: return String(localized: "Comment Selection")
        }
    }
}

extension EditorWindowController {
    /// Applies one line command to the selection as one undo step; beeps
    /// when there's nothing to do (top line up, no comments in JSON…).
    func perform(_ command: LineCommand) {
        guard textView.isEditable, !textView.hasMarkedText() else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let edit: TextEdit?
        switch command {
        case .duplicate: edit = LineOperations.duplicate(sel, in: ns)
        case .moveUp: edit = LineOperations.moveUp(sel, in: ns)
        case .moveDown: edit = LineOperations.moveDown(sel, in: ns)
        case .delete: edit = LineOperations.deleteLines(sel, in: ns)
        case .toggleComment: edit = LineOperations.toggleComment(sel, in: ns, syntax: doc.language.commentSyntax)
        }
        guard let edit else { NSSound.beep(); return }
        // A moved line takes its bookmark along.
        var moved: Bookmarks?
        if command == .moveUp || command == .moveDown, !editing.bookmarks.isEmpty {
            let block = LineOperations.lineBlock(sel, in: ns)
            let firstLine = lineIndex.line(containing: block.location)
            let lastLine = block.length == 0 ? firstLine : lineIndex.line(containing: NSMaxRange(block) - 1)
            moved = editing.bookmarks
            moved?.moveLines(firstLine..<(lastLine + 1), by: command == .moveUp ? -1 : 1)
        }
        apply(edit, actionName: command.actionName, bookmarks: moved)
    }

    /// One `TextEdit` as one undoable change, inserted in the theme's text
    /// colour (the highlighter recolours it), then its selection.
    /// `bookmarks`: where they go (else they follow their lines' text).
    func apply(_ edit: TextEdit, actionName: String, bookmarks: Bookmarks? = nil) {
        replaceAsOneStep(edit.range, with: edit.replacement, actionName: actionName, bookmarks: bookmarks)
        let len = (textView.string as NSString).length
        let s = NSRange(location: min(edit.selection.location, len), length: min(edit.selection.length, len - min(edit.selection.location, len)))
        textView.setSelectedRange(s)
        textView.scrollRangeToVisible(s)
        colorizer.scheduleViewport()
    }

    /// Replaces `range` with `replacement` as one undo step (Line
    /// commands, Replace All, Text Tools, filters), in the theme's text
    /// colour. Bookmarks go to `bookmarks` if given, else stay with the
    /// lines whose text survives the edit (Bookmarks.replacing): the
    /// counts-only follow-up in storageEdited would merge every bookmark
    /// in a multi-line replacement onto its first line.
    @discardableResult
    func replaceAsOneStep(_ range: NSRange, with replacement: String, actionName: String?, bookmarks: Bookmarks? = nil) -> Bool {
        guard let storage = textView.textStorage else { return false }
        // A refusal (marked text, or the view is no longer editable) must
        // not open a group: closing and naming it left an empty "Cedric's
        // Edit" step when bookmarks were being tracked. Those are the only
        // reasons shouldChangeText refuses, so they are asked here, and
        // shouldChangeText itself stays inside the group, after the first
        // bookmark record: called before the group, AppKit registers the
        // text's undo ahead of that record and an undo then restores the
        // bookmarks before the text moves them again (tools-check bookmarks).
        let accepted = textView.isEditable && !textView.hasMarkedText()
        let marks: Bookmarks? = accepted
            ? (bookmarks ?? (editing.bookmarks.isEmpty ? nil
                : editing.bookmarks.replacing(range, with: replacement, in: storage.string as NSString,
                                              firstLine: lineIndex.line(containing: range.location))))
            : nil
        let plan = OwlApplyUndo.plan(changeAccepted: accepted, tracksBookmarks: marks != nil)
        let um = textView.undoManager
        let before = editing.bookmarks
        if plan.openGroup {
            textView.breakUndoCoalescing()
            um?.beginUndoGrouping()
        }
        // Undo and redo put the bookmarks back as they were (the text's own
        // undo only moves them by line counts, which drops a moved or
        // deleted line's bookmark): one record before the text change and
        // one after, so each sets them once the text is back.
        if plan.registerBookmarkBefore { registerBookmarks(before, setNow: true) }
        var changed = false
        // A mixed file's breaks through an edit that keeps every line
        // (Convert Indentation, Indent, Outdent): each stays as it was
        // (LineBreakTracking.swift), rather than all becoming the most
        // common kind, which a save then wrote.
        keptLineBreaks = nil
        if plan.replaceText, let breaks = doc.lineBreaks, breaks.isMixed {
            let ns = storage.string as NSString
            if NSMaxRange(range) <= ns.length, LineBreaks.keepsLines(ns.substring(with: range) as NSString, replacement as NSString) {
                keptLineBreaks = (range, breaks.kinds(in: range, of: ns))
            }
        }
        defer { keptLineBreaks = nil }
        if plan.replaceText, textView.shouldChangeText(in: range, replacementString: replacement) {
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: baseAttributes()))
            storage.endEditing()
            textView.didChangeText()
            changed = true
        }
        if changed, plan.registerBookmarkAfter, var marks {
            marks.clamp(lineCount: lineIndex.lineCount)
            editing.bookmarks = marks
            setGuttersNeedDisplay()
            registerBookmarks(marks, setNow: false)
        }
        if plan.closeAndNameGroup {
            um?.endUndoGrouping()
            if let actionName { um?.setActionName(actionName) }
        }
        return changed
    }

    /// An undo record for bookmarks inside an undo group. Undoing a group
    /// runs its records last first, and redoing it runs them in the
    /// order they were made, so a record made before the text change
    /// runs after the text's own undo, and one made after it runs after
    /// the text's redo. `setNow`: this run sets `marks`; each run
    /// registers the opposite, for the next undo or redo.
    private func registerBookmarks(_ marks: Bookmarks, setNow: Bool) {
        textView.undoManager?.registerUndo(withTarget: self) { tab in
            MainActor.assumeIsolated {
                if setNow {
                    var m = marks
                    m.clamp(lineCount: tab.lineIndex.lineCount)
                    tab.editing.bookmarks = m
                    tab.setGuttersNeedDisplay()
                    tab.onChange?(tab)
                }
                tab.registerBookmarks(marks, setNow: !setNow)
            }
        }
    }

    /// ⌘X with nothing selected: cuts the caret's line (with its newline).
    func cutLine() {
        // Not while an input method is composing (as `perform`).
        guard textView.isEditable, !textView.hasMarkedText() else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let block = LineOperations.lineBlock(sel, in: ns)
        var line = ns.substring(with: block)
        if !line.hasSuffix("\n") { line += "\n" }
        guard !(block.length == 0 && ns.length == 0) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(line, forType: .string)
        apply(LineOperations.deleteLines(sel, in: ns), actionName: String(localized: "Cut Line"))
    }
}

// MARK: - Bookmarks

extension EditorWindowController {
    var caretLine: Int { lineIndex.line(containing: textView.selectedRange().location) }

    func toggleBookmark(line: Int? = nil) {
        editing.bookmarks.toggle(line ?? caretLine)
        bookmarksChanged()
    }

    func goToBookmark(next: Bool) {
        let b = editing.bookmarks
        guard let line = next ? b.next(after: caretLine) : b.previous(before: caretLine) else { NSSound.beep(); return }
        goToLine(line + 1)
    }

    func clearBookmarks() {
        editing.bookmarks.removeAll()
        bookmarksChanged()
    }

    /// Bookmarks every line with a match: the find bar's search when it is
    /// open and has one, else the selection or the word under the caret.
    /// Returns how many lines were bookmarked.
    @discardableResult
    func bookmarkAllMatches() -> Int {
        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        if isFindBarOpen, !findBar.findField.stringValue.isEmpty,
           let re = try? FindEngine.regex(findBar.findField.stringValue, findBar.options) {
            ranges = FindEngine.matches(re, in: ns).map(\.range)
        } else if let needle = Occurrences.needle(selection: textView.selectedRange(), in: ns) {
            ranges = Occurrences.findAll(needle, in: ns)
        }
        guard !ranges.isEmpty else { NSSound.beep(); return 0 }
        let lines = Set(ranges.map { lineIndex.line(containing: $0.location) })
        editing.bookmarks.insert(contentsOf: lines)
        bookmarksChanged()
        return lines.count
    }

    private func bookmarksChanged() {
        setGuttersNeedDisplay()
        onChange?(self) // saved with the session
    }
}

// MARK: - Menu actions

extension AppDelegate {
    @objc func markAllMenu(_ sender: Any?) { currentTab?.markAll() }
    @objc func clearMarksMenu(_ sender: Any?) { currentTab?.clearMarks() }
    @objc func toggleHighlightOccurrences(_ sender: Any?) { Settings.shared.highlightOccurrences.toggle() }
    @objc func toggleAutoCloseBrackets(_ sender: Any?) { Settings.shared.autoCloseBrackets.toggle() }
    @objc func duplicateLineMenu(_ sender: Any?) { currentTab?.perform(.duplicate) }
    @objc func moveLineUpMenu(_ sender: Any?) { currentTab?.perform(.moveUp) }
    @objc func moveLineDownMenu(_ sender: Any?) { currentTab?.perform(.moveDown) }
    @objc func deleteLineMenu(_ sender: Any?) { currentTab?.perform(.delete) }
    @objc func toggleCommentMenu(_ sender: Any?) { currentTab?.perform(.toggleComment) }
    @objc func toggleBookmarkMenu(_ sender: Any?) { currentTab?.toggleBookmark() }
    @objc func nextBookmarkMenu(_ sender: Any?) { currentTab?.goToBookmark(next: true) }
    @objc func previousBookmarkMenu(_ sender: Any?) { currentTab?.goToBookmark(next: false) }
    @objc func bookmarkAllMatchesMenu(_ sender: Any?) { currentTab?.bookmarkAllMatches() }
    @objc func clearBookmarksMenu(_ sender: Any?) { currentTab?.clearBookmarks() }

    /// Validation for the editing extras; nil: not one of ours.
    func validateEditingItem(_ item: NSMenuItem) -> Bool? {
        let tab = currentTab
        switch item.action {
        case #selector(markAllMenu(_:)): return tab != nil
        case #selector(clearMarksMenu(_:)): return tab?.hasMarks == true
        case #selector(duplicateLineMenu(_:)), #selector(moveLineUpMenu(_:)), #selector(moveLineDownMenu(_:)),
             #selector(deleteLineMenu(_:)):
            return tab?.textView.isEditable == true
        case #selector(toggleBookmarkMenu(_:)):
            let marked = tab.map { $0.editing.bookmarks.contains($0.caretLine) } ?? false
            item.title = marked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark Line")
            return tab != nil
        case #selector(bookmarkAllMatchesMenu(_:)): return tab != nil
        case #selector(nextBookmarkMenu(_:)), #selector(previousBookmarkMenu(_:)), #selector(clearBookmarksMenu(_:)):
            return tab?.editing.bookmarks.isEmpty == false
        case #selector(toggleCommentMenu(_:)):
            return tab?.textView.isEditable == true && tab?.doc.language.commentSyntax != nil
        case #selector(toggleAutoCloseBrackets(_:)):
            item.state = Settings.shared.autoCloseBrackets ? .on : .off
            return true
        case #selector(toggleHighlightOccurrences(_:)):
            item.state = Settings.shared.highlightOccurrences ? .on : .off
            return true
        default: return nil
        }
    }
}
