import UIKit
import CedricCore

// Format › Markdown on iOS (the Mac's MarkdownCommands): the shared
// transforms in CedricCore, each one undo step, only for an editable
// Markdown document. As on the Mac, the line commands (headings, lists,
// quote, tables) refuse inside fenced code; inline styles, links, Checkbox
// and Code Block don't.
extension EditorViewController {
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
    func applyTextEdit(_ edit: TextEdit, actionName: String) -> Bool {
        let length = textView.textStorage.length
        guard edit.range.location != NSNotFound, edit.range.location >= 0, edit.range.length >= 0,
              NSMaxRange(edit.range) <= length,
              let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let range = textView.textRange(from: start, to: end) else { return false }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        textView.replace(range, withText: edit.replacement)
        undo?.setActionName(actionName)
        undo?.endUndoGrouping()
        textView.selectedRange = edit.selection
        revealRange(edit.selection)
        contextBar?.refreshStates()
        return true
    }

    func isInMarkdownFence(at offset: Int, in text: NSString) -> Bool {
        let index = LineIndex(text)
        return FenceIndex().isInFence(text, index: index, line: index.line(containing: offset))
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
