import UIKit
import CedricCore

struct IndentationChange {
    let value: Indentation?
}

// Format › Markdown on iOS (the Mac's MarkdownCommands): the shared
// transforms in CedricCore, each one undo step, only for an editable
// Markdown document. As on the Mac, the line commands (headings, lists,
// quote, tables) refuse inside fenced code; inline styles, links, Checkbox
// and Code Block don't.
extension EditorViewController {
    /// An immutable copy of the text for work off the main thread or for a
    /// later "did it change?" comparison. On iOS, NSTextStorage.string can
    /// hand back the live mutable backing string (bridging doesn't copy it),
    /// so a background reader could see it change under it.
    nonisolated static func immutableCopy(_ storage: NSTextStorage) -> NSString {
        NSString(string: storage.string)
    }

    var markdownEditable: Bool {
        document.language.language == .markdown && editGate.isEditable && textView.isEditable && textView.markedTextRange == nil
    }

    static let markdownActions: Set<Selector> = [
        #selector(markdownBoldMenu(_:)), #selector(markdownItalicMenu(_:)), #selector(markdownStrikethroughMenu(_:)),
        #selector(markdownCodeMenu(_:)), #selector(markdownLinkMenu(_:)), #selector(markdownImageMenu(_:)),
        #selector(markdownBodyMenu(_:)), #selector(markdownHeading1Menu(_:)), #selector(markdownHeading2Menu(_:)),
        #selector(markdownHeading3Menu(_:)), #selector(markdownBulletListMenu(_:)), #selector(markdownNumberedListMenu(_:)),
        #selector(toggleCheckboxMenu(_:)), #selector(markdownQuoteMenu(_:)), #selector(markdownCodeBlockMenu(_:)),
        #selector(markdownTableMenu(_:)), #selector(formatTableMenu(_:)),
    ]

    @discardableResult
    func applyTextEdit(_ edit: TextEdit, actionName: String, indentation: IndentationChange? = nil,
                       bookmarks: Bookmarks? = nil) -> Bool {
        applyTextEdits([(edit.range, edit.replacement)], selection: edit.selection, actionName: actionName,
                       indentation: indentation, bookmarks: bookmarks)
    }

    /// Several edits (ascending, not overlapping, in the current text's
    /// coordinates) as one undo step. They are applied last to first, each
    /// as its own range edit, so earlier ranges stay valid. `indentation`
    /// also changes the line indentation (Convert Indentation), restored
    /// by Undo; with no text change only the undo items refresh.
    /// Bookmarks go to `bookmarks` when given (Move Line), else stay with
    /// the lines whose text survives (Bookmarks.replacing): the counts-only
    /// follow-up in storageEdited would merge every bookmark in a
    /// multi-line replacement onto its first line. Undo and redo put the
    /// set back as it was.
    @discardableResult
    func applyTextEdits(_ edits: [(range: NSRange, replacement: String)], selection: NSRange, actionName: String,
                        indentation: IndentationChange? = nil, bookmarks explicitMarks: Bookmarks? = nil) -> Bool {
        let storage = textView.textStorage
        let length = storage.length
        var floor = 0
        for edit in edits {
            guard edit.range.location != NSNotFound, edit.range.location >= floor, edit.range.length >= 0,
                  NSMaxRange(edit.range) <= length else { return false }
            floor = NSMaxRange(edit.range)
        }
        guard !edits.isEmpty else { return false }
        let previousSelection = textView.selectedRange
        let previousIndentation = lineIndentation
        let original = storage.string as NSString
        let changesText = edits.contains { original.substring(with: $0.range) != $0.replacement }
        let previousBookmarks = bookmarks
        var marks = explicitMarks
        if marks == nil, changesText, !bookmarks.isEmpty {
            // Last to first, as the text is changed: earlier ranges and the
            // lines above them are still those of the original text.
            var m = bookmarks
            if edits.count == 1, let edit = edits.first {
                m = m.replacing(edit.range, with: edit.replacement, in: original, firstLine: lineIndex.line(containing: edit.range.location))
            } else {
                let working = NSMutableString(string: original)
                for edit in edits.reversed() {
                    m = m.replacing(edit.range, with: edit.replacement, in: working,
                                    firstLine: lineIndex.line(containing: edit.range.location))
                    working.replaceCharacters(in: edit.range, with: edit.replacement)
                }
            }
            marks = m
        }
        // The inverse, in the new text's coordinates.
        var inverse: [(range: NSRange, replacement: String)] = []
        inverse.reserveCapacity(edits.count)
        var shift = 0
        for edit in edits {
            let newLength = (edit.replacement as NSString).length
            inverse.append((NSRange(location: edit.range.location + shift, length: newLength), original.substring(with: edit.range)))
            shift += newLength - edit.range.length
        }
        let undo = textView.undoManager
        let grouping = undo.map { !$0.isUndoing && !$0.isRedoing } ?? false
        // Close the system's open typing group first, so the edit is its own
        // undo step. groupsByEvent is off until the next turn (the run loop
        // would otherwise end the group closed here); one restore is pending
        // at a time, keeping the original value even for two edits a turn.
        if grouping, let undo, undo.groupingLevel > 0 {
            if pendingGroupsByEvent == nil {
                pendingGroupsByEvent = undo.groupsByEvent
                DispatchQueue.main.async { [weak self, undo] in
                    if let restore = self?.pendingGroupsByEvent { undo.groupsByEvent = restore }
                    self?.pendingGroupsByEvent = nil
                }
            }
            undo.groupsByEvent = false
            undo.endUndoGrouping()
        }
        // Insert through the storage so typographic smart quotes cannot rewrite
        // the characters, and so UITextView.replace cannot close our undo group.
        // Scrolls from here on (the replacement, revealRange, and the reveal
        // in textViewDidChange) lay the gutter out on the next turn.
        let wasApplyingTextEdits = isApplyingTextEdits
        isApplyingTextEdits = true
        defer { isApplyingTextEdits = wasApplyingTextEdits }
        if grouping { undo?.beginUndoGrouping() }
        undo?.disableUndoRegistration()
        if changesText {
            if edits.count > 1 { storage.beginEditing() }
            for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.replacement) }
            if edits.count > 1 { storage.endEditing() }
        }
        let bookmarksMoved = changesText && marks != nil
        if bookmarksMoved, var marks {
            marks.clamp(lineCount: lineIndex.lineCount)
            bookmarks = marks
        }
        textView.selectedRange = selection
        if let indentation { lineIndentation = indentation.value; applyTabStops() }
        undo?.enableUndoRegistration()
        undo?.registerUndo(withTarget: self) { target in
            _ = target.applyTextEdits(inverse, selection: previousSelection, actionName: actionName,
                                      indentation: indentation == nil ? nil : IndentationChange(value: previousIndentation),
                                      bookmarks: bookmarksMoved ? previousBookmarks : nil)
        }
        if grouping, let undo, undo.groupingLevel > 0 {
            undo.setActionName(actionName)
            undo.endUndoGrouping()
        }
        revealRange(selection)
        contextBar?.refreshStates()
        // storage.replaceCharacters does not call the text-view delegate;
        // textViewDidChange also redraws the gutter with the bookmarks, on
        // the next turn (TextKit 2 can spin finding the visible range mid-edit).
        if changesText { textViewDidChange(textView) } else { updateUndoItems() }
        return true
    }

    func isInMarkdownFence(at offset: Int, in text: NSString) -> Bool {
        markdownFenceIndex.isInFence(text, index: lineIndex, line: lineIndex.line(containing: offset))
    }

    private func markdownEdit(_ name: String, allowFence: Bool = true, _ transform: (NSString, NSRange) -> TextEdit?) {
        guard markdownEditable else { return }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return }
        if !allowFence, isInMarkdownFence(at: selection.location, in: text) { return }
        guard let edit = transform(text, selection) else { return }
        applyTextEdit(edit, actionName: name)
    }

    private func markdownStyle(_ style: MarkdownFormat.Style, name: String) {
        markdownEdit(name) { MarkdownFormat.toggle(style, in: $0, selection: $1) }
    }

    private func withClipboardURL(_ apply: @escaping (String?) -> Void) {
        guard markdownEditable else { return }
        let pasteboard = UIPasteboard.general
        if pasteboard.hasURLs {
            apply(pasteboard.url?.absoluteString)
        } else if pasteboard.hasStrings {
            let selection = textView.selectedRange
            let generation = generation
            let changeCount = pasteboard.changeCount
            pasteboard.detectPatterns(for: [.probableWebURL]) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.markdownEditable, self.generation == generation,
                          self.textView.selectedRange == selection else { return }
                    let isURL = (try? result.get().contains(.probableWebURL)) == true
                    apply(isURL && pasteboard.changeCount == changeCount ? pasteboard.string : nil)
                }
            }
        } else {
            apply(nil)
        }
    }

    @objc func markdownBoldMenu(_ sender: Any?) { markdownStyle(.bold, name: String(localized: "Bold")) }
    @objc func markdownItalicMenu(_ sender: Any?) { markdownStyle(.italic, name: String(localized: "Italic")) }
    @objc func markdownStrikethroughMenu(_ sender: Any?) { markdownStyle(.strikethrough, name: String(localized: "Strikethrough")) }
    @objc func markdownCodeMenu(_ sender: Any?) { markdownStyle(.code, name: String(localized: "Inline Code")) }
    @objc func markdownLinkMenu(_ sender: Any?) {
        withClipboardURL { [weak self] clip in
            self?.markdownEdit(String(localized: "Link")) { MarkdownFormat.link(in: $0, selection: $1, clipboard: clip) }
        }
    }
    @objc func markdownImageMenu(_ sender: Any?) {
        withClipboardURL { [weak self] clip in
            self?.markdownEdit(String(localized: "Image Link")) { MarkdownBlocks.image(in: $0, selection: $1, clipboard: clip) }
        }
    }
    private func markdownHeading(_ level: Int, name: String) {
        markdownEdit(name, allowFence: false) { MarkdownBlocks.heading(level, in: $0, selection: $1) }
    }
    @objc func markdownBodyMenu(_ sender: Any?) { markdownHeading(0, name: String(localized: "Body")) }
    @objc func markdownHeading1Menu(_ sender: Any?) { markdownHeading(1, name: String(localized: "Heading 1")) }
    @objc func markdownHeading2Menu(_ sender: Any?) { markdownHeading(2, name: String(localized: "Heading 2")) }
    @objc func markdownHeading3Menu(_ sender: Any?) { markdownHeading(3, name: String(localized: "Heading 3")) }
    @objc func markdownBulletListMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Bulleted List"), allowFence: false) { MarkdownBlocks.list(.bullet, in: $0, selection: $1) }
    }
    @objc func markdownNumberedListMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Numbered List"), allowFence: false) { MarkdownBlocks.list(.numbered, in: $0, selection: $1) }
    }
    @objc func toggleCheckboxMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Checkbox")) { MarkdownLists.toggleTasks(in: $0, selection: $1) }
    }
    @objc func markdownQuoteMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Quote"), allowFence: false) { MarkdownBlocks.quote(in: $0, selection: $1) }
    }
    @objc func markdownCodeBlockMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Code Block")) { MarkdownBlocks.codeBlock(in: $0, selection: $1) }
    }
    @objc func markdownTableMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Insert Table"), allowFence: false) { MarkdownBlocks.insertTable(in: $0, selection: $1) }
    }
    @objc func formatTableMenu(_ sender: Any?) {
        markdownEdit(String(localized: "Format Table"), allowFence: false) { MarkdownTable.format(in: $0, selection: $1) }
    }

    @objc func toggleContextBarMenu() {
        AppSettings.showContextBar.toggle()
        UIMenuSystem.main.setNeedsRebuild()
    }
}
