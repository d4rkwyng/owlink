import AppKit
import CedricCore

/// Edit › Spelling and Grammar › Fix Typos… (⌥⌘;) and the owl's "Fix
/// Typos…": one misspelled word at a time, from the caret to the end and
/// round from the top, in a small panel beside the word: its suggestions
/// (the first preselected), Change, Change All, Skip, Ignore All, Learn
/// Word and Done, with "N of M".
///
/// Keys in the panel: Return = Change, Tab or ⌘→ = Skip, Esc = Done,
/// ↑ ↓ pick a suggestion. The panel isn't modal: the document can be
/// edited meanwhile, and the words still to come follow the edits.
///
/// The words are those continuous checking would mark (EditorSpelling's
/// scope: prose in Plain Text and Markdown, comments and strings in
/// code, never URLs or paths), in the checker's language. The document is
/// checked in chunks of about 16 K characters (SpellStepper): in a normal
/// document the rest is checked one chunk per run-loop turn after the
/// first word shows; in large mode only when the next word is needed,
/// a few chunks per turn, so a huge file is never checked in one go.
/// Each Change is its own undo step; Change All is one.
@MainActor
final class SpellStepController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var tab: EditorWindowController?
    private(set) var stepper: SpellStepper
    let panel: SpellStepPanel
    private let wordLabel = NSTextField(labelWithString: "")
    let progressLabel = NSTextField(labelWithString: "")
    let table = NSTableView()
    private(set) var guesses: [String] = []
    private(set) var changeButton: NSButton!
    private(set) var changeAllButton: NSButton!
    private(set) var skipButton: NSButton!
    private(set) var ignoreButton: NSButton!
    private(set) var learnButton: NSButton!
    private(set) var doneButton: NSButton!
    /// Our own edits: not reported back to the stepper as the user's.
    private var applying = false
    private var scanScheduled = false
    /// Chunks checked per run-loop turn while looking for the next word.
    static let chunksPerTurn = 4
    /// The check's Learn Word: learned and then forgotten again (Learn
    /// Word writes to the user's own dictionary).
    var onLearn: ((String) -> Void)?
    var onClose: (() -> Void)?

    var current: SpellStepItem? { stepper.current }

    init(tab: EditorWindowController) {
        self.tab = tab
        let tv = tab.textView
        stepper = SpellStepper(text: tv.string as NSString, caret: tv.selectedRange().location)
        panel = SpellStepPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 236),
                               styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        buildPanel()
    }

    // MARK: Panel

    private func buildPanel() {
        panel.title = String(localized: "Fix Typos")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        panel.onClose = { [weak self] in self?.finish(closePanel: false) }

        wordLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        wordLabel.lineBreakMode = .byTruncatingMiddle
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [wordLabel, progressLabel])
        top.distribution = .fill

        let col = NSTableColumn(identifier: .init("guess"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.allowsEmptySelection = true
        table.style = .plain
        table.target = self
        table.doubleAction = #selector(change(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        changeButton = button(String(localized: "Change"), #selector(change(_:)))
        changeButton.keyEquivalent = "\r"
        changeAllButton = button(String(localized: "Change All"), #selector(changeAll(_:)))
        skipButton = button(String(localized: "Skip"), #selector(skip(_:)))
        ignoreButton = button(String(localized: "Ignore All"), #selector(ignoreAll(_:)))
        ignoreButton.toolTip = String(localized: "Ignore this word everywhere in this document")
        learnButton = button(String(localized: "Learn Word"), #selector(learn(_:)))
        learnButton.toolTip = String(localized: "Add this word to your spelling dictionary")
        doneButton = button(String(localized: "Done"), #selector(done(_:)))
        doneButton.keyEquivalent = "\u{1b}"
        let row1 = NSStackView(views: [changeButton, changeAllButton, skipButton])
        let row2 = NSStackView(views: [ignoreButton, learnButton, NSView(), doneButton])
        for r in [row1, row2] { r.distribution = .fill; r.spacing = 6 }
        let hint = NSTextField(labelWithString: String(localized: "Return: Change   Tab or ⌘→: Skip   Esc: Done"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [top, scroll, row1, row2, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for v in [top, scroll, row2] { v.translatesAutoresizingMaskIntoConstraints = false }
        panel.contentView = stack
        for v in [top, scroll, row2] {
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
        }
        panel.initialFirstResponder = table
    }

    /// Keys the panel takes before its controls do.
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch e.keyCode {
        case 36, 76 where mods.isEmpty: change(nil); return true          // Return, Enter
        case 48 where mods.isEmpty: skip(nil); return true                // Tab
        case 124 where mods == .command: skip(nil); return true           // ⌘→
        case 53 where mods.isEmpty: done(nil); return true                // Esc
        default: return false
        }
    }

    // MARK: Start and scan

    /// Starts at the caret: the first word as soon as one is found.
    func start() {
        guard let tab, let w = tab.window else { return }
        w.addChildWindow(panel, ordered: .above)
        showNext()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(table)
    }

    /// Words in `chunk` the checker flags, in scope, not in links or paths.
    private func scan(_ chunk: NSRange) -> [SpellStepEdit] {
        guard let tab else { return [] }
        let ns = tab.textView.string as NSString
        let found = tab.spelling.misspellings(in: chunk).compactMap { r -> SpellStepItem? in
            guard NSMaxRange(r) <= ns.length, !SpellScope.isInLinkOrPath(ns, at: r) else { return nil }
            return SpellStepItem(range: r, word: ns.substring(with: r))
        }
        return stepper.add(found)
    }

    /// Shows the next word: from what has been found, else checking a few
    /// more chunks now and the rest on later turns.
    private func showNext() {
        var budget = Self.chunksPerTurn
        while stepper.advance() == nil {
            guard !stepper.scanComplete else { break }
            if budget == 0 {
                // Still looking: the next turn goes on (keys get through between).
                updateUI(searching: true)
                scheduleScan()
                return
            }
            budget -= 1
            if let c = stepper.nextChunk() { applyAuto(scan(c)) }
        }
        updateUI(searching: false)
        reveal()
        // A normal document: count the rest in idle turns. Large mode: on demand only.
        if !(tab?.extrasPaused ?? true), !stepper.scanComplete { scheduleScan() }
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            MainActor.assumeIsolated { self?.scanTurn() }
        }
    }

    private func scanTurn() {
        scanScheduled = false
        guard panel.isVisible || panel.parent != nil else { return }
        if stepper.current == nil {
            showNext()
            return
        }
        if let c = stepper.nextChunk() { applyAuto(scan(c)) }
        updateUI(searching: false)
        if !(tab?.extrasPaused ?? true), !stepper.scanComplete { scheduleScan() }
    }

    // MARK: UI

    private func updateUI(searching: Bool) {
        let p = stepper.progress
        if let c = stepper.current, let tab {
            wordLabel.stringValue = "“\(c.word)”"
            guesses = NSSpellChecker.shared.guesses(forWordRange: c.range, in: tab.textView.string, language: nil,
                                                    inSpellDocumentWithTag: tab.textView.spellCheckerDocumentTag) ?? []
            progressLabel.stringValue = String(localized: "\(p.index) of \(p.total)") + (p.final ? "" : "+")
        } else {
            guesses = []
            if searching {
                wordLabel.stringValue = String(localized: "Checking…")
                progressLabel.stringValue = ""
            } else {
                wordLabel.stringValue = stepper.changed > 0
                    ? String(localized: "No more typos. Changed \(stepper.changed).") : String(localized: "No more typos.")
                progressLabel.stringValue = ""
            }
        }
        table.reloadData()
        if !guesses.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        let has = stepper.current != nil
        changeButton.isEnabled = has && !guesses.isEmpty
        changeAllButton.isEnabled = has && !guesses.isEmpty
        for b in [skipButton, ignoreButton, learnButton] { b?.isEnabled = has }
        doneButton.keyEquivalent = "\u{1b}"
        // Nothing left: Return closes.
        if !has && !searching { doneButton.keyEquivalent = "\r"; changeButton.keyEquivalent = "" } else { changeButton.keyEquivalent = "\r" }
    }

    /// Selects the word, scrolls to it and puts the panel beside it.
    private func reveal() {
        guard let tab, let c = stepper.current else { return }
        let tv = tab.textView
        tv.setSelectedRange(c.range)
        tab.reveal(c.range)
        position()
    }

    /// Below the word, or above it when there is no room below.
    func position() {
        guard let tab, let c = stepper.current, let w = tab.window else { return }
        let tv = tab.textView
        var rect = tv.firstRect(forCharacterRange: c.range, actualRange: nil)
        if rect.isEmpty || rect.origin == .zero { rect = w.convertToScreen(tv.convert(tv.visibleRect, to: nil)) }
        let size = panel.frame.size
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
        var origin = NSPoint(x: rect.minX - 20, y: rect.minY - size.height - 6)
        if origin.y < screen.minY { origin.y = rect.maxY + 6 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrameOrigin(origin)
    }

    var selectedGuess: String? {
        let r = table.selectedRow
        return guesses.indices.contains(r) ? guesses[r] : guesses.first
    }

    // MARK: Actions

    @objc func change(_ sender: Any?) {
        guard stepper.current != nil else { if stepper.isFinished { done(nil) }; return }
        guard let rep = selectedGuess, let edit = stepper.change(to: rep) else { NSSound.beep(); return }
        apply([edit], name: String(localized: "Change Spelling"))
        showNext()
    }

    @objc func changeAll(_ sender: Any?) {
        guard let rep = selectedGuess else { NSSound.beep(); return }
        apply(stepper.changeAll(to: rep), name: String(localized: "Change All Spelling"))
        showNext()
    }

    @objc func skip(_ sender: Any?) {
        guard stepper.current != nil else { NSSound.beep(); return }
        stepper.skip()
        showNext()
    }

    @objc func ignoreAll(_ sender: Any?) {
        guard let c = stepper.current, let tab else { return }
        NSSpellChecker.shared.ignoreWord(c.word, inSpellDocumentWithTag: tab.textView.spellCheckerDocumentTag)
        stepper.ignoreAll()
        recheckMarks()
        showNext()
    }

    @objc func learn(_ sender: Any?) {
        guard let c = stepper.current else { return }
        if let onLearn { onLearn(c.word) } else { NSSpellChecker.shared.learnWord(c.word) }
        stepper.ignoreAll()
        recheckMarks()
        showNext()
    }

    @objc func done(_ sender: Any?) { finish(closePanel: true) }

    func finish(closePanel: Bool) {
        guard let tab else { return }
        if closePanel { panel.onClose = nil; panel.close() }
        tab.window?.removeChildWindow(panel)
        tab.window?.makeKeyAndOrderFront(nil)
        tab.window?.makeFirstResponder(tab.textView)
        onClose?()
    }

    /// The tab is closing: the panel goes with it.
    func closeWithTab() {
        panel.onClose = nil
        tab?.window?.removeChildWindow(panel)
        panel.close()
        onClose?()
    }

    /// Ignore All and Learn Word: the underlines go too.
    private func recheckMarks() {
        guard let tv = tab?.textView, tv.isContinuousSpellCheckingEnabled else { return }
        // The dictionary changed: AppKit's next pass must run, even the
        // one the first-frame check would have stood in for.
        tab?.primaryTextView.spellCoverage.clear()
        tv.isContinuousSpellCheckingEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
    }

    /// Change All's later finds, changed as they are found.
    private func applyAuto(_ edits: [SpellStepEdit]) {
        if !edits.isEmpty { apply(edits, name: String(localized: "Change All Spelling")) }
    }

    /// Makes `edits` (last first) as one undo step.
    private func apply(_ edits: [SpellStepEdit], name: String) {
        guard let tab, let storage = tab.textView.textStorage, !edits.isEmpty else { return }
        let tv = tab.textView
        let um = tv.undoManager
        applying = true
        defer { applying = false }
        tv.breakUndoCoalescing()
        um?.beginUndoGrouping()
        for e in edits where NSMaxRange(e.range) <= storage.length {
            guard tv.shouldChangeText(in: e.range, replacementString: e.replacement) else { continue }
            storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.replacement, attributes: tab.baseAttributes()))
            tv.didChangeText()
        }
        um?.setActionName(name)
        um?.endUndoGrouping()
        tv.breakUndoCoalescing()
    }

    /// Every edit to the text (EditorWindowController.storageEdited): the
    /// user's move the words still to come.
    func textEdited(_ oldRange: NSRange, newLength: Int) {
        guard !applying else { return }
        let had = stepper.current != nil
        stepper.textEdited(oldRange, newLength: newLength)
        if had && stepper.current == nil {
            // The word itself was edited: on to the next (after this edit is done).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stepper.current == nil, self.panel.parent != nil else { return }
                self.showNext()
            }
        } else {
            updateUI(searching: false)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { guesses.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("g")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        cell.stringValue = guesses[row]
        return cell
    }
}

/// The step-through's panel: keys reach the controller before its controls.
final class SpellStepPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let e = NSApp.currentEvent, let onKey, onKey(e) { return }
        close()
    }

    override func close() {
        super.close()
        let c = onClose
        onClose = nil
        c?()
    }
}

extension EditorWindowController {
    /// Whether spelling is checked in this tab at all (SpellScope.checks).
    var spellingChecksThisDocument: Bool {
        SpellScope.checks(language: doc.language, fileName: doc.fileURL?.lastPathComponent)
    }

    /// Edit › Spelling and Grammar › Fix Typos…: starts (or brings back) the step-through.
    func startSpellStep() {
        // Data files (JSON, CSV…) aren't spell checked: nothing to step through.
        guard spellingChecksThisDocument else { NSSound.beep(); return }
        if let s = spellStep, s.panel.parent != nil {
            s.panel.makeKeyAndOrderFront(nil)
            return
        }
        let s = SpellStepController(tab: self)
        spellStep = s
        s.onClose = { [weak self, weak s] in
            if let self, self.spellStep === s { self.spellStep = nil }
        }
        owl?.hideBubble()
        s.start()
    }
}
