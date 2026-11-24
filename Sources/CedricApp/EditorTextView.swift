import AppKit
import CedricCore

/// The editing surface: an NSTextView on TextKit 2 (NSTextLayoutManager),
/// which lays out only what is near the viewport, so large files open
/// quickly. Adds the current-line highlight and drawn invisibles; text
/// colours come from `SyntaxColorizer` as text-storage attributes.
final class EditorTextView: NSTextView {
    var palette: EditorPalette = EditorPalettes.light
    var showInvisibles = false { didSet { needsDisplay = true } }
    /// Limits continuous spell checking to comments, strings and prose (Spelling.swift).
    weak var spelling: EditorSpelling?
    /// Misspellings the checker has marked (in scope), for the checks.
    var markedMisspellings: [NSRange] = []
    /// Grammar in prose (Grammar.swift): the issues' ranges, drawn as
    /// green dotted underlines; their suggestions in the right-click menu.
    weak var grammar: EditorGrammar?
    var grammarRanges: [NSRange] = []
    /// The last menu a right-click on a grammar underline built (checks).
    var lastGrammarMenu: NSMenu?
    /// Drawn behind the text (EditingFeatures.swift): other occurrences of
    /// the selection or word, Mark All's marks, and the bracket pair at
    /// the caret. Only ranges in or near the visible text.
    var occurrenceRanges: [NSRange] = []
    var markRanges: [NSRange] = []
    var bracketRanges: [NSRange] = []
    /// Told of every change before NSTextView registers its undo for it
    /// (EditorWindowController.textWillChange).
    var beforeChange: (([NSValue]) -> Void)?

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        beforeChange?(affectedRanges)
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        beforeChange?([NSValue(range: affectedCharRange)])
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: Multiple carets (MultiCaretEditing.swift)

    /// nil: one caret, NSTextView's own selection (the zero-cost path:
    /// every override below checks only this). With 2 or more: every
    /// caret, sorted; `multiPrimary`'s is also NSTextView's selection (IME,
    /// accessibility, the status bar, the find bar use it), the others are
    /// drawn here.
    var multiCarets: [MultiCaret.Caret]? {
        didSet { if let folding, let multiCarets { folding.carets(multiCarets) } }
    }
    var multiPrimary = 0
    /// Set while the multi-caret layer sets NSTextView's selection or edits
    /// the text: any other selection change collapses to one caret.
    var multiOwnsSelection = false
    var multiApplying = false
    /// ⌘D's search text, and whether it matches whole words (it started
    /// from a bare caret).
    var multiNeedle: (text: String, wholeWord: Bool)?

    // MARK: Folding (Folding.swift)

    /// The tab's folding, from its first fold (nil: every hook is a nil check).
    weak var folding: FoldingController?
    /// Set while a key command (arrows, word and page moves) runs: its
    /// selection change skips hidden text rather than opening it.
    private(set) var keyNavigating = false
    /// The "⋯ N lines" pills drawn last, for clicks.
    var foldPills: [(rect: NSRect, hidden: NSRange)] = []

    /// The view and its TextKit 2 stack. With `sharing`, a second view on
    /// the same text (View › Split Editor): its own layout manager added
    /// to that content storage, so both show and edit one text storage.
    static func make(sharing shared: ChunkedContentStorage? = nil) -> EditorTextView {
        let layoutManager = NSTextLayoutManager()
        let content = shared ?? ChunkedContentStorage()
        content.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.drawsBackground = true
        return tv
    }

    var contentStorage: ChunkedContentStorage? { textLayoutManager?.textContentManager as? ChunkedContentStorage }

    /// View › Readable Width (ReadableWidthView.swift): the text column's
    /// width in points, centred by the horizontal inset; nil when off.
    var readableColumnWidth: CGFloat? {
        didSet { if oldValue != readableColumnWidth { updateReadableInset() } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        var newSize = newSize
        // Tiling the scroll view (the gutter moves into the column's margin,
        // so this view gets wider) tries to make the text exactly as tall as
        // the visible area. The document is taller; keeping that short height
        // makes typewriter scrolling clamp to the top.
        if let clip = enclosingScrollView?.contentView {
            let visible = clip.bounds.height
            let inset = enclosingScrollView?.contentInsets.bottom ?? 0
            let fillingClip = abs(newSize.height - visible) < 1 || (inset > 0 && abs(newSize.height - (visible - inset)) < 1)
            if fillingClip, frame.height > visible + 100 { newSize.height = frame.height }
        }
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // Typing grows the height only: nothing to do then.
        if widthChanged, readableColumnWidth != nil { updateReadableInset() }
    }

    func updateReadableInset() {
        let w = CGFloat(readableColumnWidth.map { ReadableWidth.inset(viewWidth: Double(bounds.width), column: Double($0)) }
            ?? ReadableWidth.minimumInset)
        guard textContainerInset.width != w else { return }
        textContainerInset = NSSize(width: w, height: textContainerInset.height)
        // The gutter follows the column (EditorContainer).
        enclosingScrollView?.superview?.needsLayout = true
    }

    /// View › Writing Mode › Typewriter Scrolling (WritingMode.swift): set
    /// only while it is on; returns true when it scrolled in place of
    /// NSTextView's minimal scroll to the caret.
    var onScrollRangeToVisible: ((NSRange) -> Bool)?

    override func scrollRangeToVisible(_ range: NSRange) {
        if let hook = onScrollRangeToVisible, range == selectedRange(), hook(range) { return }
        super.scrollRangeToVisible(range)
    }

    /// This view became first responder (View › Split Editor: commands
    /// follow the focused pane).
    var onFocus: ((EditorTextView) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(self) }
        return ok
    }

    // MARK: Range conversion

    func textRange(for range: NSRange) -> NSTextRange? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let doc = tcm.documentRange.location
        guard let start = tcm.location(doc, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func offset(of location: NSTextLocation) -> Int {
        guard let tcm = textLayoutManager?.textContentManager else { return 0 }
        return tcm.offset(from: tcm.documentRange.location, to: location)
    }

    /// The character range laid out for the viewport (plus what TextKit
    /// laid out around it).
    var viewportCharacterRange: NSRange? {
        guard let tlm = textLayoutManager, let vr = tlm.textViewportLayoutController.viewportRange else { return nil }
        let start = offset(of: vr.location)
        return NSRange(location: start, length: max(0, offset(of: vr.endLocation) - start))
    }

    /// The layout fragment at the top of the visible rect (laid out if
    /// needed), else the viewport's first: TextKit's viewport can lag a
    /// scroll by a layout pass.
    var firstVisibleLocation: NSTextLocation? {
        guard let tlm = textLayoutManager else { return nil }
        let top = CGPoint(x: 0, y: max(0, visibleRect.minY - textContainerOrigin.y))
        if let frag = tlm.textLayoutFragment(for: top) { return frag.rangeInElement.location }
        return tlm.textViewportLayoutController.viewportRange?.location
    }

    /// Characters from the top of the visible rect to its bottom, joined
    /// with TextKit's viewport range. Inside an edit (a selection change
    /// TextKit makes while it takes the edit in) only the viewport range:
    /// laying out there runs on half-updated layout (it never came back
    /// in a chunked long line).
    var visibleCharacterRange: NSRange? {
        guard let tlm = textLayoutManager else { return nil }
        var result = viewportCharacterRange
        if tlm.textContentManager?.hasEditingTransaction == true { return result }
        let top = CGPoint(x: 0, y: max(0, visibleRect.minY - textContainerOrigin.y))
        let bottom = CGPoint(x: 0, y: max(0, visibleRect.maxY - textContainerOrigin.y))
        if let a = tlm.textLayoutFragment(for: top), let b = tlm.textLayoutFragment(for: bottom) ?? tlm.textLayoutFragment(for: top) {
            let start = offset(of: a.rangeInElement.location)
            let end = offset(of: b.rangeInElement.endLocation)
            let r = NSRange(location: start, length: max(0, end - start))
            result = result.map { NSUnionRange($0, r) } ?? r
        }
        return result
    }

    // MARK: Auto-indent, bracket and quote pairing (AutoEdit in CedricCore)

    /// The document's language (pairing is for code, not prose).
    var language: Language = .plain
    /// Where the line holding an offset starts (from the line index: O(log n)).
    var lineStartFor: ((Int) -> Int)?

    private var pairing: Bool { Settings.shared.autoCloseBrackets && AutoEdit.pairs(in: language) }

    private func unit(at i: Int) -> unichar? {
        let ns = string as NSString
        return i >= 0 && i < ns.length ? ns.character(at: i) : nil
    }

    /// Return: a newline with the line's indent (one step more after an
    /// opening bracket; between a pair, the closer on its own line).
    override func insertNewline(_ sender: Any?) {
        if multiCarets != nil { multiCommand(#selector(insertNewline(_:))); return }
        guard isEditable, !hasMarkedText(), let lineStartFor else { super.insertNewline(sender); return }
        let sel = selectedRange()
        // YAML: "- " items carry on (MarkdownLists handles both).
        if language == .yaml, onEdit != nil,
           let e = MarkdownLists.newline(in: string as NSString, selection: sel, language: .yaml) {
            applyEdit(e, String(localized: "Typing"))
            return
        }
        if let e = markdownEdit({ d, _ in MarkdownTable.newline(in: d, selection: sel) }) {
            applyEdit(e, String(localized: "Add Table Row"))
            return
        }
        if let e = markdownEdit({ MarkdownLists.newline(in: $0, selection: sel, language: language,
                                                        tabWidth: $1.width, useTabs: $1.usesTabs) }) {
            applyEdit(e, String(localized: "Typing"))
            return
        }
        let r = AutoEdit.newline(in: string as NSString, lineStart: lineStartFor(sel.location), caret: sel.location,
                                 after: NSMaxRange(sel), language: language, unit: indentation?().unit)
        guard r.text != "\n" || r.caret != 1 else { super.insertNewline(sender); return }
        insertText(r.text, replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + r.caret, length: 0))
    }

    // MARK: Tab and Shift-Tab (Indentation.swift)

    /// The document's indentation (tabs or spaces, width).
    var indentation: (() -> Indentation)?
    /// Whether Tab types spaces (else a tab character).
    var tabInsertsSpaces: (() -> Bool)?
    /// Indents (true) or outdents (false) the selected lines.
    var onShiftLines: ((Bool) -> Void)?

    /// Tab: with a selection over several lines, indents them; else a tab,
    /// or where spaces were chosen, spaces up to the next tab stop.
    override func insertTab(_ sender: Any?) {
        if multiCarets != nil { multiCommand(#selector(insertTab(_:))); return }
        guard isEditable, !hasMarkedText(), let indentation, let lineStartFor else { super.insertTab(sender); return }
        let sel = selectedRange()
        let ns = string as NSString
        // Markdown: Tab in a table goes to the next cell; in a list item it indents the item.
        if let e = markdownEdit({ d, _ in MarkdownTable.tab(in: d, selection: sel, forward: true) }) {
            applyEdit(e, String(localized: "Format Table"))
            return
        }
        if let e = markdownEdit({ MarkdownLists.shiftItem(in: $0, selection: sel, right: true, useTabs: $1.usesTabs, tabWidth: $1.width) }) {
            applyEdit(e, String(localized: "Indent"))
            return
        }
        if sel.length > 0, ns.rangeOfCharacter(from: .newlines, options: [], range: sel).location != NSNotFound {
            onShiftLines?(true)
            return
        }
        let ind = indentation()
        guard !ind.usesTabs, tabInsertsSpaces?() ?? true else { super.insertTab(sender); return }
        // The caret's column, tabs counted to their stops (a bounded look back).
        let start = lineStartFor(sel.location)
        var col = 0
        var i = max(start, sel.location - 4096)
        while i < sel.location { col = ns.character(at: i) == 9 ? (col / ind.width + 1) * ind.width : col + 1; i += 1 }
        insertText(String(repeating: " ", count: ind.width - col % ind.width), replacementRange: sel)
    }

    /// Shift-Tab: outdents the selected lines (or the caret's line).
    override func insertBacktab(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let onShiftLines else { super.insertBacktab(sender); return }
        let sel = selectedRange()
        if let e = markdownEdit({ d, _ in MarkdownTable.tab(in: d, selection: sel, forward: false) }) {
            applyEdit(e, String(localized: "Format Table"))
            return
        }
        if let e = markdownEdit({ MarkdownLists.shiftItem(in: $0, selection: sel, right: false, useTabs: $1.usesTabs, tabWidth: $1.width) }) {
            applyEdit(e, String(localized: "Outdent"))
            return
        }
        onShiftLines(false)
    }

    // MARK: Markdown editing (MarkdownLists, MarkdownTable in CedricCore)

    /// Applies an edit as one undo step (the window controller's `apply`).
    var onEdit: ((TextEdit, String) -> Void)?
    /// Whether the line holding an offset is inside a fenced code block.
    var inFence: ((Int) -> Bool)?

    /// `make`'s edit, in a Markdown tab, outside fenced code, with the
    /// selection on one line; nil otherwise (the key does what it did).
    func markdownEdit(_ make: (NSString, Indentation) -> TextEdit?) -> TextEdit? {
        guard language == .markdown, onEdit != nil else { return nil }
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0, ns.rangeOfCharacter(from: .newlines, options: [], range: sel).location != NSNotFound { return nil }
        if language == .markdown, inFence?(sel.location) == true { return nil }
        return make(ns, indentation?() ?? Indentation(usesTabs: false, width: 4))
    }

    func applyEdit(_ e: TextEdit, _ name: String) { onEdit?(e, name) }

    /// Typing an opener or quote pairs it, a closer steps over the one
    /// already there, and with a selection both go around it. Only for
    /// single typed characters (not paste, not input methods).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if multiCarets != nil { multiInsertText(string, replacementRange: replacementRange); return }
        if language == .python, isEditable, !hasMarkedText(), replacementRange.location == NSNotFound,
           (string as? String) == ":", realignPythonClause() { return }
        guard pairing, isEditable, !hasMarkedText(), replacementRange.location == NSNotFound,
              let s = (string as? String) ?? (string as? NSAttributedString)?.string, s.utf16.count == 1,
              let c = s.utf16.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let sel = selectedRange()
        switch AutoEdit.typing(c, before: unit(at: sel.location - 1), after: unit(at: NSMaxRange(sel)), hasSelection: sel.length > 0,
                               language: language, afterIsAutoClosed: autoClosers.contains(NSMaxRange(sel))) {
        case .skip?:
            autoClosers.removeAll { $0 == sel.location }
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        case .pair(let pair)?:
            super.insertText(pair, replacementRange: sel)
            autoClosers.append(sel.location + 1)
            if autoClosers.count > 16 { autoClosers.removeFirst() }
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        case .wrap(let open, let close)?:
            let inner = (self.string as NSString).substring(with: sel)
            super.insertText(open + inner + close, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
        case nil:
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    /// Python: ":" typed after `else`, `elif …`, `except …` or `finally`
    /// lines the clause up with its `if`/`try`/… (one undo step with the
    /// ":"). False when there's nothing to move.
    private func realignPythonClause() -> Bool {
        guard let e = pythonClauseEdit(selectedRange()) else { return false }
        super.insertText(e.replacement, replacementRange: e.range)
        return true
    }

    /// The realignment as an edit (the clause line from its start to the
    /// caret, re-indented, plus the ":"); nil when there's nothing to move.
    func pythonClauseEdit(_ sel: NSRange) -> TextEdit? {
        guard sel.length == 0, let lineStartFor else { return nil }
        let ns = self.string as NSString
        let start = lineStartFor(sel.location)
        guard sel.location - start <= 512 else { return nil }
        let head = ns.substring(with: NSRange(location: start, length: sel.location - start))
        var above: [String] = []
        var p = start
        while p > 0, above.count < 300 {
            let r = ns.lineRange(for: NSRange(location: p - 1, length: 0))
            above.append(r.length > 4096 ? "x" : ns.substring(with: r).trimmingCharacters(in: .newlines))
            p = r.location
        }
        guard let indent = LanguageIndent.pythonClauseIndent(head: head, above: above, tabWidth: indentation?().width ?? 4) else { return nil }
        let body = head.drop { $0 == " " || $0 == "\t" }
        let text = indent + body + ":"
        return TextEdit(range: NSRange(location: start, length: sel.location - start), replacement: text,
                        selection: NSRange(location: start + (text as NSString).length, length: 0))
    }

    /// Where closers that pairing typed are (a few, newest last): a quote
    /// steps over only one of these, not a quote that was already there.
    var autoClosers: [Int] = []

    /// Every character edit (the window controller's storageEdited, undo
    /// included): closers after it shift, ones inside it are gone.
    func textEdited(oldRange: NSRange, newLength: Int) {
        if let carets = multiCarets, !multiApplying {
            multiCarets = MultiCaret.shift(carets, oldRange: oldRange, newLength: newLength)
        }
        guard !autoClosers.isEmpty else { return }
        let delta = newLength - oldRange.length
        autoClosers = autoClosers.compactMap { k in
            if k >= NSMaxRange(oldRange) { return k + delta }
            return k < oldRange.location ? k : nil
        }
    }

    /// Backspace between a pair ("(|)", "\"|\"") deletes both.
    override func deleteBackward(_ sender: Any?) {
        if multiCarets != nil { multiCommand(#selector(deleteBackward(_:))); return }
        let sel = selectedRange()
        if pairing, isEditable, !hasMarkedText(), sel.length == 0,
           AutoEdit.deletesPair(before: unit(at: sel.location - 1), after: unit(at: sel.location), language: language) {
            super.insertText("", replacementRange: NSRange(location: sel.location - 1, length: 2))
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: Paste normalisation

    /// Paste and drop: plain text only, with CRLF/CR turned into LF
    /// before it reaches the text (inserted as one undoable typing edit).
    /// (v0 rejected the edit in shouldChangeText and re-inserted it later,
    /// which silently dropped pastes.)
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // Markdown: image files or a bitmap become image links (the window
        // controller copies them next to the document); a URL pasted over
        // a selection makes a link.
        if language == .markdown, isEditable, multiCarets == nil, let onImages {
            let sel = selectedRange()
            let files = Self.imageFiles(pboard)
            if !files.isEmpty { onImages(files, nil, sel); return true }
            if let s = pboard.string(forType: .string) {
                if inFence?(sel.location) != true, let e = MarkdownPaste.linkPaste(in: string as NSString, selection: sel, pasted: s) {
                    applyEdit(e, String(localized: "Paste"))
                    return true
                }
            } else if let data = pboard.data(forType: .png) ?? pboard.data(forType: .tiff) {
                onImages([], data, sel)
                return true
            }
        }
        guard let s = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        if multiCarets != nil { multiPaste(TextCodec.normalizeLineEndings(s)); return true }
        let normalized = TextCodec.normalizeLineEndings(s)
        insertText(normalized, replacementRange: selectedRange())
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        language == .markdown && onImages != nil ? [.string, .fileURL, .png, .tiff] : [.string]
    }

    /// Markdown: image files (or bitmap data) pasted or dropped, to go in
    /// at the range as image links. Set by the window controller.
    var onImages: ((_ files: [URL], _ bitmap: Data?, _ at: NSRange) -> Void)?

    /// The image files on a pasteboard (existing files with an image extension).
    static func imageFiles(_ pboard: NSPasteboard) -> [URL] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { MarkdownPaste.isImageFile($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Dropping files

    /// Opens files dropped on the text (each in its tab), as Notepad++
    /// does, instead of inserting their paths. Set by the window controller.
    var onDropFiles: (([URL]) -> Void)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if !types.contains(.fileURL) { types.append(.fileURL) }
        return types
    }

    /// The file and folder URLs a drag carries (none for text, or for a
    /// drag that started in this text view). A folder opens in the folder
    /// sidebar, as on the Dock icon (`AppDelegate.open`).
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard onDropFiles != nil, (info.draggingSource as? NSView) !== self else { return [] }
        return FileDrop.urls(info)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(info).isEmpty ? super.draggingEntered(info) : .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(info).isEmpty ? super.draggingUpdated(info) : .copy
    }

    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool {
        droppedFiles(info).isEmpty ? super.prepareForDragOperation(info) : true
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let files = droppedFiles(info)
        guard !files.isEmpty, let onDropFiles else { return super.performDragOperation(info) }
        // Markdown: image files go in as image links where they were
        // dropped; other files still open in tabs.
        if language == .markdown, isEditable, let onImages {
            let images = files.filter(MarkdownPaste.isImageFile)
            if !images.isEmpty {
                let others = files.filter { !MarkdownPaste.isImageFile($0) }
                var at = characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))
                if at == NSNotFound || at > (string as NSString).length { at = selectedRange().location }
                DispatchQueue.main.async {
                    onImages(images, nil, NSRange(location: at, length: 0))
                    if !others.isEmpty { onDropFiles(others) }
                }
                return true
            }
        }
        // After the drag session ends (opening a tab inside it upsets AppKit's drag bookkeeping).
        DispatchQueue.main.async { onDropFiles(files) }
        return true
    }

    override func concludeDragOperation(_ info: NSDraggingInfo?) {
        if let info, !droppedFiles(info).isEmpty { return }
        super.concludeDragOperation(info)
    }

    /// ⌘X with nothing selected cuts the whole line (EditingFeatures.swift).
    var onCutLine: (() -> Void)?

    override func cut(_ sender: Any?) {
        if multiCarets != nil, multiCopy(cut: true) { return }
        if selectedRange().length == 0, let onCutLine { onCutLine(); return }
        super.cut(sender)
    }

    override func copy(_ sender: Any?) {
        if multiCarets != nil, multiCopy(cut: false) { return }
        super.copy(sender)
    }

    /// Cut stays enabled with an empty selection (it cuts the line).
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(cut(_:)), selectedRange().length == 0, onCutLine != nil {
            return isEditable && (string as NSString).length > 0
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Multiple carets: the entry points (MultiCaretEditing.swift)

    /// Key commands (arrows, Delete, Return, Esc…) at every caret.
    override func doCommand(by selector: Selector) {
        if multiCarets != nil, multiCommand(selector) { return }
        if folding != nil {
            keyNavigating = true
            defer { keyNavigating = false }
            super.doCommand(by: selector)
            return
        }
        super.doCommand(by: selector)
    }

    /// ⌥-drag: a column of carets or selections; ⌘-click: add or remove a caret.
    override func mouseDown(with event: NSEvent) {
        // A click focuses this pane (split view: commands follow it), also
        // when the event reached the view without the window's own routing.
        if onFocus != nil, let w = window, w.firstResponder !== self { w.makeFirstResponder(self) }
        if let folding, !foldPills.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            if let hit = foldPills.first(where: { $0.rect.contains(p) }) {
                // The outermost folds there (an inner one stays folded).
                folding.unfold(folding.state.folds.filter { $0.location == hit.hidden.location })
                return
            }
        }
        if !event.modifierFlags.isDisjoint(with: [.option, .command]), multiMouseDown(event) { return }
        super.mouseDown(with: event)
    }

    /// An input method composes at the primary caret; the others wait for
    /// the committed text (multiInsertText).
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard multiCarets != nil else { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange); return }
        multiOwnsSelection = true
        defer { multiOwnsSelection = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        guard multiCarets != nil else { super.unmarkText(); return }
        multiOwnsSelection = true
        defer { multiOwnsSelection = false }
        super.unmarkText()
    }

    // MARK: Drawing

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // A selection the multi-caret layer didn't make (a click, find, go
        // to line, undo, a menu command) leaves one caret.
        if multiCarets != nil, !multiOwnsSelection { endMultiCarets() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let tlm = textLayoutManager else { return }
        let origin = textContainerOrigin

        // Current line: the paragraph holding the caret (only without a
        // multi-character selection, as in most editors).
        let sel = selectedRange()
        if sel.length == 0, let loc = textRange(for: NSRange(location: sel.location, length: 0))?.location,
           let frag = tlm.textLayoutFragment(for: loc) {
            var f = frag.layoutFragmentFrame
            // On the empty last line TextKit reports the previous paragraph; fine for v0.
            f.origin.x = 0
            f.size.width = bounds.width
            f.origin.y += origin.y
            NSColor(hex: palette.currentLine).setFill()
            f.intersection(rect).fill()
        }

        if let folding, !folding.isEmpty { drawFoldPills(in: rect, layoutManager: tlm, folding: folding) } else if !foldPills.isEmpty { foldPills = [] }
        drawHighlights(in: rect, layoutManager: tlm)
        if let carets = multiCarets { drawMultiCarets(carets, in: rect, layoutManager: tlm) }
        drawGrammarMarks(in: rect, layoutManager: tlm)
        if showInvisibles { drawInvisibles(in: rect, layoutManager: tlm) }
    }

    /// A rounded "⋯ 42 lines" after each folded header line, in the
    /// viewport (not a text attachment: the text never changes). A click
    /// on it unfolds (mouseDown).
    private func drawFoldPills(in rect: NSRect, layoutManager tlm: NSTextLayoutManager, folding: FoldingController) {
        foldPills.removeAll()
        guard let tab = delegate as? EditorWindowController, let tcm = tlm.textContentManager,
              let vp = tlm.textViewportLayoutController.viewportRange else { return }
        let vpStart = offset(of: vp.location)
        let vpEnd = vpStart + tcm.offset(from: vp.location, to: vp.endLocation)
        let origin = textContainerOrigin
        let font = NSFont.systemFont(ofSize: max(9, (self.font ?? Settings.shared.font).pointSize - 2))
        let fg = NSColor(hex: palette.gutterForeground)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        for h in folding.state.hidden where h.location > 0 {
            let at = h.location - 1 // the header line's newline: where its text ends
            guard at >= vpStart, at <= vpEnd, let loc = tcm.location(vp.location, offsetBy: at - vpStart) else { continue }
            var caret: CGRect?
            tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
                caret = f
                return false
            }
            guard let c = caret else { continue }
            let label = NSAttributedString(string: folding.label(for: h, tab.lineIndex), attributes: attrs)
            let size = label.size()
            let height = min(c.height, ceil(size.height) + 2)
            let r = NSRect(x: c.minX + origin.x + 8, y: c.minY + origin.y + (c.height - height) / 2, width: ceil(size.width) + 12, height: height)
            foldPills.append((r, h))
            guard r.intersects(rect) else { continue }
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
            NSColor(hex: palette.gutterBackground).setFill()
            path.fill()
            fg.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
            label.draw(at: NSPoint(x: r.minX + 6, y: r.minY + (height - size.height) / 2))
        }
    }

    /// Marks, occurrences and the matching bracket pair, clipped to the
    /// view (since macOS 14 `rect` can be larger than the bounds).
    private func drawHighlights(in rect: NSRect, layoutManager tlm: NSTextLayoutManager) {
        guard !markRanges.isEmpty || !occurrenceRanges.isEmpty || !bracketRanges.isEmpty else { return }
        let clip = rect.intersection(bounds)
        guard !clip.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        let match = NSColor(hex: palette.findMatch)
        let sel = selectedRange()
        forEachSegment(markRanges, clip: clip, layoutManager: tlm) { f in
            match.setFill()
            NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
        }
        forEachSegment(occurrenceRanges.filter { $0 != sel }, clip: clip, layoutManager: tlm) { f in
            match.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
        }
        let caret = NSColor(hex: palette.caret)
        forEachSegment(bracketRanges, clip: clip, layoutManager: tlm) { f in
            caret.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: f).fill()
            caret.withAlphaComponent(0.7).setStroke()
            let p = NSBezierPath(rect: f.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }

    /// Grammar issues: a green dotted line under the words (spelling's
    /// marks are the system's red ones), clipped to the view.
    private func drawGrammarMarks(in rect: NSRect, layoutManager tlm: NSTextLayoutManager) {
        guard !grammarRanges.isEmpty else { return }
        let clip = rect.intersection(bounds)
        guard !clip.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        NSColor(hex: palette.grammarMark).setStroke()
        forEachSegment(grammarRanges, clip: clip.insetBy(dx: 0, dy: -4), layoutManager: tlm) { f in
            let y = f.maxY - 1.5
            let p = NSBezierPath()
            p.move(to: NSPoint(x: f.minX, y: y))
            p.line(to: NSPoint(x: f.maxX, y: y))
            p.lineWidth = 2
            p.lineCapStyle = .round
            p.setLineDash([0.01, 3.5], count: 2, phase: 0)
            p.stroke()
        }
    }

    /// Draws the segments of `ranges` that lie in TextKit's viewport (the
    /// laid-out text); anything else is skipped, so a stale or far-away
    /// range never makes TextKit lay out other parts of a big document.
    /// Locations are found from the viewport's start, not the document's.
    func forEachSegment(_ ranges: [NSRange], clip: NSRect, layoutManager tlm: NSTextLayoutManager, _ draw: (NSRect) -> Void) {
        guard !ranges.isEmpty, let tcm = tlm.textContentManager,
              let vp = tlm.textViewportLayoutController.viewportRange else { return }
        let vpStart = offset(of: vp.location)
        let vpEnd = vpStart + tcm.offset(from: vp.location, to: vp.endLocation)
        let origin = textContainerOrigin
        for r in ranges where r.location >= vpStart && NSMaxRange(r) <= vpEnd {
            guard let start = tcm.location(vp.location, offsetBy: r.location - vpStart),
                  let end = tcm.location(start, offsetBy: r.length),
                  let tr = NSTextRange(location: start, end: end) else { continue }
            tlm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
                let f = frame.offsetBy(dx: origin.x, dy: origin.y)
                if f.intersects(clip) { draw(f) }
                return true
            }
        }
    }

    private func drawInvisibles(in rect: NSRect, layoutManager tlm: NSTextLayoutManager) {
        guard let start = firstVisibleLocation else { return }
        let font = self.font ?? Settings.shared.font
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.invisibles)]
        let dot = NSAttributedString(string: "·", attributes: attrs)
        let arrow = NSAttributedString(string: "→", attributes: attrs)
        let pilcrow = NSAttributedString(string: "¬", attributes: attrs)
        let origin = textContainerOrigin
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            if frame.minY + origin.y > rect.maxY { return false }
            if frame.maxY + origin.y < rect.minY { return true }
            guard let para = frag.textElement as? NSTextParagraph else { return true }
            let units = para.attributedString.string as NSString
            for line in frag.textLineFragments {
                let r = line.characterRange
                let lineOrigin = CGPoint(x: frame.minX + line.typographicBounds.minX + origin.x,
                                         y: frame.minY + line.typographicBounds.minY + origin.y)
                var i = r.location
                while i < r.location + r.length {
                    let c = units.character(at: i)
                    if c == 32 || c == 9 || c == 10 {
                        let p = line.locationForCharacter(at: i)
                        let glyph = c == 32 ? dot : c == 9 ? arrow : pilcrow
                        glyph.draw(at: CGPoint(x: lineOrigin.x + p.x, y: lineOrigin.y))
                    }
                    i += 1
                }
            }
            return true
        }
    }
}

/// Line numbers, drawn beside the scroll view (not as an NSRulerView: a
/// ruler can pull an NSTextView back to TextKit 1). Numbers come from the
/// line index, positions from the visible layout fragments.
final class GutterView: NSView {
    weak var textView: EditorTextView?
    var lineIndex: () -> LineIndex = { LineIndex() }
    var palette: EditorPalette = EditorPalettes.light { didSet { needsDisplay = true } }
    /// Bookmarked lines, drawn as a marker left of the number; a click on
    /// a line number toggles its bookmark.
    var bookmarks: () -> Bookmarks = { Bookmarks() }
    var onClickLine: ((Int) -> Void)?
    /// Git change bars against HEAD (nil: none, or the setting is off).
    var gitChanges: () -> GitLineChanges? = { nil }
    /// Folding: the column between the numbers and the git bars (0: the
    /// language doesn't fold), each line's mark (nil: no marks to draw),
    /// and a click in the column.
    static let foldColumnWidth: CGFloat = 12
    var foldColumn: CGFloat = 0 {
        didSet { if foldColumn != oldValue { needsDisplay = true; updateTrackingAreas() } }
    }
    var foldMarks: (_ hovering: Bool) -> ((Int) -> FoldMark)? = { _ in nil }
    /// False: nothing folds there (the click toggles the bookmark, as on the number).
    var onClickFold: ((Int) -> Bool)?
    /// The pointer is over the gutter: the fold triangles show.
    private(set) var hovering = false
    private var foldTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only for a language that folds (none is made for plain text).
        if foldColumn > 0, foldTracking == nil {
            let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(t)
            foldTracking = t
        } else if foldColumn == 0, let t = foldTracking {
            removeTrackingArea(t)
            foldTracking = nil
            hovering = false
        }
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func setHovering(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        needsDisplay = true
    }

    /// The fold column's x range (view coordinates).
    var foldColumnRange: ClosedRange<CGFloat> { (bounds.width - 5 - foldColumn)...(bounds.width - 5) }

    override var isFlipped: Bool { true }

    /// The change bars' colours: GitHub's, a shade lighter on dark themes.
    struct GitColors {
        let added, modified, deleted: NSColor
        init(_ p: EditorPalette) {
            added = NSColor(hex: p.isDark ? 0x3FB950 : 0x2DA44E)
            modified = NSColor(hex: p.isDark ? 0x58A6FF : 0x0969DA)
            deleted = NSColor(hex: p.isDark ? 0xF85149 : 0xCF222E)
        }
    }

    /// A deleted-lines mark: a small triangle on the boundary at `y`, at the gutter's right edge.
    private func drawDeleted(atY y: CGFloat, _ color: NSColor) {
        let x = bounds.width - 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x - 5, y: y - 4))
        p.line(to: NSPoint(x: x, y: y))
        p.line(to: NSPoint(x: x - 5, y: y + 4))
        p.close()
        color.setFill()
        p.fill()
    }

    /// A fold triangle: pointing right on a folded line, down on one that can fold.
    private func drawFoldMark(_ m: FoldMark, midY: CGFloat) {
        let cx = (foldColumnRange.lowerBound + foldColumnRange.upperBound) / 2
        let s: CGFloat = 3.5
        let p = NSBezierPath()
        if m == .folded {
            p.move(to: NSPoint(x: cx - s * 0.7, y: midY - s))
            p.line(to: NSPoint(x: cx + s * 0.9, y: midY))
            p.line(to: NSPoint(x: cx - s * 0.7, y: midY + s))
            NSColor(hex: palette.foreground).setFill()
        } else {
            p.move(to: NSPoint(x: cx - s, y: midY - s * 0.6))
            p.line(to: NSPoint(x: cx + s, y: midY - s * 0.6))
            p.line(to: NSPoint(x: cx, y: midY + s * 0.9))
            NSColor(hex: palette.gutterForeground).setFill()
        }
        p.close()
        p.fill()
    }

    /// The line whose number is drawn at `y` (view coordinates).
    func line(atY y: CGFloat) -> Int? {
        guard let tv = textView, let tlm = tv.textLayoutManager, let scroll = tv.enclosingScrollView else { return nil }
        let point = CGPoint(x: 0, y: y + scroll.contentView.bounds.minY - tv.textContainerOrigin.y)
        guard let frag = tlm.textLayoutFragment(for: point) else { return nil }
        return lineIndex().line(containing: tv.offset(of: frag.rangeInElement.location))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let line = line(atY: p.y) else { super.mouseDown(with: event); return }
        if foldColumn > 0, p.x >= foldColumnRange.lowerBound - 2, let onClickFold, onClickFold(line) { return }
        onClickLine?(line)
    }

    /// Wide enough for the largest line number.
    func requiredWidth(lines: Int, font: NSFont) -> CGFloat {
        let digits = max(3, String(lines).count)
        let w = ("8" as NSString).size(withAttributes: [.font: gutterFont(font)]).width
        return ceil(CGFloat(digits) * w + 18 + foldColumn)
    }

    private func gutterFont(_ f: NSFont) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(8, f.pointSize - 1), weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: palette.gutterBackground).setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
        guard let tv = textView, let tlm = tv.textLayoutManager, let scroll = tv.enclosingScrollView,
              let start = tv.firstVisibleLocation else { return }
        let index = lineIndex()
        let font = gutterFont(tv.font ?? Settings.shared.font)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.gutterForeground)]
        let currentAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: palette.foreground)]
        let currentLine = index.line(containing: tv.selectedRange().location)
        let scrollY = scroll.contentView.bounds.minY
        let originY = tv.textContainerOrigin.y
        let textFont = tv.font ?? Settings.shared.font
        let marks = bookmarks()
        let markColor = NSColor(hex: palette.caret)
        let git = gitChanges()
        let gitColors = GitColors(palette)
        let foldMark = foldColumn > 0 ? foldMarks(hovering) : nil
        let numberRight = bounds.width - 8 - foldColumn
        // The last line drawn and its bottom: a deletion at the very end
        // is drawn below it (the empty last line may have no fragment).
        var lastDrawn: (line: Int, bottom: CGFloat)?
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            let y = frame.minY + originY - scrollY
            if y > self.bounds.maxY { return false }
            if y + frame.height < 0 { return true }
            let offset = tv.offset(of: frag.rangeInElement.location)
            let line = index.line(containing: offset)
            // A long line in chunks (large mode) has several fragments:
            // number only the first.
            guard line < index.lineCount, index.starts[line] == offset else { return true }
            let s = NSAttributedString(string: String(line + 1), attributes: line == currentLine ? currentAttrs : attrs)
            let size = s.size()
            // Align with the first line's baseline.
            let baselineY = y + (frag.textLineFragments.first?.typographicBounds.minY ?? 0) + textFont.ascender - font.ascender
            s.draw(at: CGPoint(x: numberRight - size.width, y: baselineY))
            if let foldMark {
                let m = foldMark(line)
                if m != .none {
                    let rowHeight = frag.textLineFragments.first?.typographicBounds.height ?? frame.height
                    self.drawFoldMark(m, midY: y + (frag.textLineFragments.first?.typographicBounds.minY ?? 0) + rowHeight / 2)
                }
            }
            if marks.contains(line) {
                // A bookmark: a rounded tab at the gutter's left edge, as tall as the line.
                let h = max(6, min(frame.height, textFont.boundingRectForFont.height))
                markColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: y + 1, width: 5, height: h - 2), xRadius: 2, yRadius: 2).fill()
            }
            if let git {
                // A change bar at the right edge, beside the text, as tall as the line (all its wrapped rows).
                if let kind = git.lines[line] {
                    (kind == .added ? gitColors.added : gitColors.modified).setFill()
                    NSRect(x: self.bounds.width - 4, y: y, width: 3, height: frame.height).fill()
                }
                if git.deletedBefore.contains(line) { self.drawDeleted(atY: max(y, 4), gitColors.deleted) }
                lastDrawn = (line, y + frame.height)
            }
            return true
        }
        if let git, let last = lastDrawn, last.line + 1 >= index.lineCount - 1, git.deletedBefore.contains(last.line + 1) {
            drawDeleted(atY: last.bottom, gitColors.deleted)
        }
        // The last empty line after a trailing newline has no fragment in
        // some TextKit versions; number it from the previous one.
    }
}
