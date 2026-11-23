import UIKit
import CedricCore

/// Where Fix Typos… finds words and their guesses. The app's is the
/// system's on-device checker (`TextCheckerSpelling`); tests can pass
/// their own.
@MainActor
protocol SpellStepChecking: AnyObject {
    /// Misspelled words in `text` (offsets in `text`).
    func misspellings(in text: String) -> [NSRange]
    /// Suggestions for `word`, best first.
    func guesses(for word: String) -> [String]
    /// Ignore All: not flagged again by this checker.
    func ignore(_ word: String)
    /// Learn Word: added to the user's on-device dictionary.
    func learn(_ word: String)
}

/// UITextChecker: the system's checker, on the device (nothing downloaded,
/// nothing sent anywhere). One per pass, so Ignore All stays with it.
@MainActor
final class TextCheckerSpelling: SpellStepChecking {
    private let checker = UITextChecker()
    let language: String

    init(language: String) {
        self.language = language
    }

    /// The checker's language for this editor: the keyboard's, else the
    /// first preferred language the checker has, else its first.
    static func language(for textView: UITextView?) -> String {
        let available = UITextChecker.availableLanguages
        let wanted = [textView?.textInputMode?.primaryLanguage].compactMap { $0 } + Locale.preferredLanguages
        for w in wanted {
            let id = w.replacingOccurrences(of: "-", with: "_")
            if available.contains(id) { return id }
            let code = String(id.prefix { $0 != "_" })
            if let match = available.first(where: { $0 == code || $0.hasPrefix(code + "_") }) { return match }
        }
        return available.first ?? "en_US"
    }

    func misspellings(in text: String) -> [NSRange] {
        let length = (text as NSString).length
        var out: [NSRange] = []
        var at = 0
        while at < length {
            let r = checker.rangeOfMisspelledWord(in: text, range: NSRange(location: 0, length: length),
                                                  startingAt: at, wrap: false, language: language)
            guard r.location != NSNotFound, r.length > 0, r.location >= at else { break }
            out.append(r)
            at = NSMaxRange(r)
        }
        return out
    }

    func guesses(for word: String) -> [String] {
        checker.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: language) ?? []
    }

    func ignore(_ word: String) { checker.ignoreWord(word) }

    func learn(_ word: String) { UITextChecker.learnWord(word) }
}

/// Fix Typos… on iOS (the Mac's SpellStepController): one misspelled word
/// at a time, from the caret to the end and round from the top, in a small
/// card over the editor: its suggestions (the first preselected), Change,
/// Change All, Skip, Ignore All, Learn Word and Done, with "N of M".
///
/// Keys when the card has focus: Return = Change, Tab or ⌘→ = Skip,
/// Esc = Done, ↑ ↓ pick a suggestion. The card isn't modal: the document
/// can be edited meanwhile, and the words still to come follow the edits
/// (`textEdited`, from the editor's storage handler).
///
/// The words are those the Mac's step-through finds (SpellScope: prose in
/// Plain Text and Markdown minus code, links and markup; comments and
/// strings in code; never data, URLs or paths). The document is checked in
/// SpellStepper's chunks: at most `chunksPerTurn` a turn while looking for
/// the next word, the rest one per idle turn in a normal document and
/// only on demand in large mode. Each Change is its own undo step; Change
/// All is one.
@MainActor
final class SpellStepController {
    private weak var editor: EditorViewController?
    private(set) var stepper: SpellStepper
    let checker: SpellStepChecking
    let card = SpellStepCard()
    private(set) var guesses: [String] = []
    /// Our own edits: not reported back to the stepper as the user's.
    private var applying = false
    private var scanScheduled = false
    private(set) var isOpen = false
    /// Chunks checked per run-loop turn while looking for the next word.
    static let chunksPerTurn = 4
    /// Chunks checked so far (for the tests).
    private(set) var scannedChunks = 0
    var onClose: (() -> Void)?
    private var painted: NSTextRange?
    private var textViewHadFocus = false
    /// The keyboard's frame changes move the card; removed on close (and in
    /// deinit, should the editor go without closing it).
    nonisolated(unsafe) private var keyboardObserver: NSObjectProtocol?
    /// Whether the keyboard observer is registered (for the tests).
    var hasKeyboardObserver: Bool { keyboardObserver != nil }

    var current: SpellStepItem? { stepper.current }

    init(editor: EditorViewController, checker: SpellStepChecking) {
        self.editor = editor
        self.checker = checker
        let tv = editor.textView
        stepper = SpellStepper(text: tv.textStorage.string as NSString, caret: tv.selectedRange.location)
        card.onChange = { [weak self] in self?.change() }
        card.onChangeAll = { [weak self] in self?.changeAll() }
        card.onSkip = { [weak self] in self?.skip() }
        card.onIgnore = { [weak self] in self?.ignoreAll() }
        card.onLearn = { [weak self] in self?.learn() }
        card.onDone = { [weak self] in self?.done() }
    }

    /// The backstop: the editor went without a close. The card went with
    /// its view; the observer is unregistered here (any thread may do so).
    deinit {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    }

    /// Large mode: words are looked for only when the next one is needed.
    private var onDemandOnly: Bool { editor?.writingLargeReason != nil }

    private var canEdit: Bool {
        guard let editor else { return false }
        return editor.editGate.isEditable && editor.textView.isEditable
    }

    // MARK: Start and scan

    /// Starts at the caret: the first word as soon as one is found.
    func start() {
        guard let editor, !isOpen else { return }
        isOpen = true
        textViewHadFocus = editor.textView.isFirstResponder
        editor.view.addSubview(card)
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        showNext()
        card.becomeFirstResponder()
    }

    /// Fix Typos… again while open: the card comes forward.
    func bringForward() {
        guard let editor, isOpen else { return }
        editor.view.bringSubviewToFront(card)
        card.becomeFirstResponder()
        reveal()
    }

    /// Words in `chunk` the checker flags, in scope, not in links or paths.
    private func scan(_ chunk: NSRange) -> [SpellStepEdit] {
        guard let editor else { return [] }
        scannedChunks += 1
        let ns = editor.textView.textStorage.string as NSString
        let chunk = NSIntersectionRange(chunk, NSRange(location: 0, length: ns.length))
        guard chunk.length > 0 else { return [] }
        var found: [SpellStepItem] = []
        for s in scope(for: chunk, in: ns) where s.length > 0 {
            for r in checker.misspellings(in: ns.substring(with: s)) {
                let abs = NSRange(location: s.location + r.location, length: r.length)
                guard NSMaxRange(abs) <= NSMaxRange(s), !SpellScope.isInLinkOrPath(ns, at: abs) else { continue }
                found.append(SpellStepItem(range: abs, word: ns.substring(with: abs)))
            }
        }
        return stepper.add(found)
    }

    /// The parts of `range` spelling is checked in (EditorSpelling.scope on the Mac).
    private func scope(for range: NSRange, in ns: NSString) -> [NSRange] {
        guard let editor else { return [] }
        let index = editor.lineIndex
        guard index.lineCount > 0, index.length == ns.length else { return [] }
        let first = index.line(containing: range.location)
        let last = index.line(containing: NSMaxRange(range))
        let tokens = editor.highlightEngine.tokens(forLines: first..<(last + 1), in: ns, index: index)
        return SpellScope.ranges(language: editor.document.language.language, tokens: tokens, in: range)
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
        if !onDemandOnly, !stepper.scanComplete { scheduleScan() }
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.scanTurn() }
        }
    }

    private func scanTurn() {
        scanScheduled = false
        guard isOpen else { return }
        if stepper.current == nil {
            showNext()
            return
        }
        if let c = stepper.nextChunk() { applyAuto(scan(c)) }
        updateUI(searching: false)
        if !onDemandOnly, !stepper.scanComplete { scheduleScan() }
    }

    // MARK: UI

    /// `place`: also moves the card (not from inside an edit: TextKit 2
    /// must not lay out mid-edit).
    private func updateUI(searching: Bool, place: Bool = true) {
        let p = stepper.progress
        let word: String, progress: String
        if let c = stepper.current {
            word = "“\(c.word)”"
            guesses = checker.guesses(for: c.word)
            progress = String(localized: "\(p.index) of \(p.total)") + (p.final ? "" : "+")
        } else {
            guesses = []
            progress = ""
            if searching {
                word = String(localized: "Checking…")
            } else {
                word = stepper.changed > 0
                    ? String(localized: "No more typos. Changed \(stepper.changed).") : String(localized: "No more typos.")
            }
        }
        let has = stepper.current != nil
        card.update(word: word, progress: progress, guesses: guesses, hasWord: has, canChange: has && canEdit && !guesses.isEmpty)
        if place {
            if !has { clearPaint() }
            position()
        }
    }

    /// Selects the word, scrolls to it and marks it (a selection isn't
    /// drawn while the card has focus).
    private func reveal() {
        guard let editor, let c = stepper.current else { return }
        editor.textView.selectedRange = c.range
        editor.revealRange(c.range)
        paint(c.range)
        position()
    }

    private func paint(_ range: NSRange) {
        clearPaint()
        guard let editor, let layout = editor.textView.textLayoutManager, let content = layout.textContentManager,
              let a = content.location(layout.documentRange.location, offsetBy: range.location),
              let b = content.location(a, offsetBy: range.length),
              let r = NSTextRange(location: a, end: b) else { return }
        layout.addRenderingAttribute(.backgroundColor, value: UIColor.systemRed.withAlphaComponent(0.22), for: r)
        painted = r
    }

    private func clearPaint() {
        if let painted, let layout = editor?.textView.textLayoutManager {
            layout.removeRenderingAttribute(.backgroundColor, for: painted)
        }
        painted = nil
    }

    /// Beside the word on a wide screen (below it, else above), else across
    /// the bottom or the top, away from the word; always above the keyboard.
    func position() {
        guard let editor, isOpen else { return }
        let view = editor.view!
        var area = view.bounds.inset(by: view.safeAreaInsets)
        let keyboard = view.keyboardLayoutGuide.layoutFrame
        if keyboard.height > 0, keyboard.minY < area.maxY { area.size.height = max(0, keyboard.minY - area.minY) }
        area = area.insetBy(dx: 8, dy: 8)
        let wide = view.traitCollection.horizontalSizeClass == .regular && area.width >= 600
        card.compact = !wide
        let width = min(wide ? 360 : 440, area.width)
        let height = card.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                  withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel).height
        var word: CGRect?
        let tv = editor.textView
        if let c = stepper.current, let s = tv.position(from: tv.beginningOfDocument, offset: c.range.location),
           let e = tv.position(from: s, offset: c.range.length), let r = tv.textRange(from: s, to: e) {
            let rect = tv.firstRect(for: r)
            if !rect.isNull, !rect.isInfinite, !rect.isEmpty { word = tv.convert(rect, to: view) }
        }
        var origin: CGPoint
        if wide, let w = word {
            origin = CGPoint(x: w.minX - 20, y: w.maxY + 6)
            if origin.y + height > area.maxY { origin.y = w.minY - 6 - height }
        } else {
            origin = CGPoint(x: area.midX - width / 2, y: area.maxY - height)
            if let w = word, w.midY > area.midY { origin.y = area.minY }
        }
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - height))
        card.frame = CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    var selectedGuess: String? { card.selectedGuess }

    // MARK: Actions

    func change() {
        guard stepper.current != nil else { if stepper.isFinished { done() }; return }
        guard canEdit, let rep = selectedGuess, let edit = stepper.change(to: rep) else { return }
        apply([edit], name: String(localized: "Change Spelling"))
        showNext()
    }

    func changeAll() {
        guard stepper.current != nil, canEdit, let rep = selectedGuess else { return }
        apply(stepper.changeAll(to: rep), name: String(localized: "Change All Spelling"))
        showNext()
    }

    func skip() {
        guard stepper.current != nil else { return }
        stepper.skip()
        showNext()
    }

    func ignoreAll() {
        guard let c = stepper.current else { return }
        checker.ignore(c.word)
        stepper.ignoreAll()
        showNext()
    }

    func learn() {
        guard let c = stepper.current else { return }
        checker.learn(c.word)
        stepper.ignoreAll()
        showNext()
    }

    func done() { close() }

    /// Done, close, the document going or reloading: the card goes, the text stays as it is.
    /// `restoringFocus`: the text view gets the keys back if it had them (not
    /// when the editor itself is going).
    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        clearPaint()
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        keyboardObserver = nil
        let hadFocus = card.isFirstResponder
        card.removeFromSuperview()
        if restoringFocus, hadFocus, textViewHadFocus { editor?.textView.becomeFirstResponder() }
        onClose?()
    }

    /// Change All's later finds, changed as they are found.
    private func applyAuto(_ edits: [SpellStepEdit]) {
        if !edits.isEmpty { apply(edits, name: String(localized: "Change All Spelling")) }
    }

    /// Makes `edits` (last first, from the stepper) as one undo step,
    /// through the editor's own edit path (undo, colouring, line index,
    /// bookmarks).
    private func apply(_ edits: [SpellStepEdit], name: String) {
        guard let editor, !edits.isEmpty else { return }
        let ascending = edits.sorted { $0.range.location < $1.range.location }
        let first = ascending[0]
        let caret = NSRange(location: first.range.location + (first.replacement as NSString).length, length: 0)
        applying = true
        defer { applying = false }
        editor.applyTextEdits(ascending.map { ($0.range, $0.replacement) }, selection: caret, actionName: name)
    }

    /// Every edit to the text (EditorViewController.storageEdited): the
    /// user's move the words still to come.
    func textEdited(_ oldRange: NSRange, newLength: Int) {
        guard isOpen, !applying else { return }
        let had = stepper.current != nil
        stepper.textEdited(oldRange, newLength: newLength)
        // Called mid-edit (processEditing): the paint and the card's place
        // wait for the next turn.
        if had && stepper.current == nil {
            // The word itself was edited: on to the next (after this edit is done).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isOpen, self.stepper.current == nil else { return }
                self.clearPaint()
                self.showNext()
            }
        } else {
            updateUI(searching: false, place: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isOpen else { return }
                if let c = self.stepper.current { self.paint(c.range) }
                self.position()
            }
        }
    }
}

/// The step-through's card: the word, "N of M", the suggestions and the
/// buttons. Keys reach it while it has focus (tap it to give it focus).
final class SpellStepCard: UIView, UITableViewDataSource, UITableViewDelegate {
    var onChange: (() -> Void)?
    var onChangeAll: (() -> Void)?
    var onSkip: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onLearn: (() -> Void)?
    var onDone: (() -> Void)?

    let wordLabel = UILabel()
    let progressLabel = UILabel()
    let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let hint = UILabel()
    private(set) var guesses: [String] = []
    private(set) var changeButton: UIButton!
    private(set) var changeAllButton: UIButton!
    private(set) var skipButton: UIButton!
    private(set) var ignoreButton: UIButton!
    private(set) var learnButton: UIButton!
    private(set) var doneButton: UIButton!
    private var tableHeight: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 30

    /// A phone (or a narrow window): fewer rows, no key hint.
    var compact = true {
        didSet {
            guard compact != oldValue else { return }
            tableHeight.constant = Self.rowHeight * (compact ? 3 : 4)
            hint.isHidden = compact
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        accessibilityIdentifier = "spellStep.card"
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        wordLabel.font = .preferredFont(forTextStyle: .headline)
        wordLabel.adjustsFontForContentSizeCategory = true
        wordLabel.lineBreakMode = .byTruncatingMiddle
        wordLabel.accessibilityIdentifier = "spellStep.word"
        progressLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
        progressLabel.textColor = .secondaryLabel
        progressLabel.textAlignment = .right
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        progressLabel.accessibilityIdentifier = "spellStep.progress"
        let title = UILabel()
        title.text = String(localized: "Fix Typos")
        title.font = .preferredFont(forTextStyle: .caption1)
        title.textColor = .secondaryLabel
        let top = UIStackView(arrangedSubviews: [wordLabel, progressLabel])
        top.spacing = 8

        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.register(UITableViewCell.self, forCellReuseIdentifier: "g")
        table.layer.cornerRadius = 8
        table.backgroundColor = .tertiarySystemGroupedBackground
        table.accessibilityIdentifier = "spellStep.suggestions"
        emptyLabel.text = String(localized: "No Suggestions")
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        table.backgroundView = emptyLabel
        tableHeight = table.heightAnchor.constraint(equalToConstant: Self.rowHeight * 3)
        tableHeight.isActive = true

        func button(_ title: String, _ id: String, prominent: Bool = false, _ action: @escaping () -> Void) -> UIButton {
            var config: UIButton.Configuration = prominent ? .borderedProminent() : .bordered()
            config.title = title
            config.buttonSize = .small
            config.titleLineBreakMode = .byTruncatingTail
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            b.accessibilityIdentifier = id
            return b
        }
        changeButton = button(String(localized: "Change"), "spellStep.change", prominent: true) { [weak self] in self?.onChange?() }
        changeAllButton = button(String(localized: "Change All"), "spellStep.changeAll") { [weak self] in self?.onChangeAll?() }
        skipButton = button(String(localized: "Skip"), "spellStep.skip") { [weak self] in self?.onSkip?() }
        ignoreButton = button(String(localized: "Ignore All"), "spellStep.ignoreAll") { [weak self] in self?.onIgnore?() }
        ignoreButton.accessibilityHint = String(localized: "Ignore this word everywhere in this document")
        learnButton = button(String(localized: "Learn Word"), "spellStep.learn") { [weak self] in self?.onLearn?() }
        learnButton.accessibilityHint = String(localized: "Add this word to your spelling dictionary")
        doneButton = button(String(localized: "Done"), "spellStep.done") { [weak self] in self?.onDone?() }
        let row1 = UIStackView(arrangedSubviews: [changeButton, changeAllButton, skipButton])
        let row2 = UIStackView(arrangedSubviews: [ignoreButton, learnButton, doneButton])
        for r in [row1, row2] { r.distribution = .fillEqually; r.spacing = 6 }

        hint.text = String(localized: "Return: Change   Tab or ⌘→: Skip   Esc: Done")
        hint.font = .preferredFont(forTextStyle: .caption2)
        hint.textColor = .tertiaryLabel
        hint.isHidden = true

        let stack = UIStackView(arrangedSubviews: [title, top, table, row1, row2, hint])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        // A tap on the card (not a button) gives it the keys back.
        let tap = UITapGestureRecognizer(target: self, action: #selector(takeFocus))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc private func takeFocus() { becomeFirstResponder() }

    func update(word: String, progress: String, guesses: [String], hasWord: Bool, canChange: Bool) {
        wordLabel.text = word
        progressLabel.text = progress
        self.guesses = guesses
        table.reloadData()
        emptyLabel.isHidden = !guesses.isEmpty || !hasWord
        if !guesses.isEmpty { table.selectRow(at: IndexPath(row: 0, section: 0), animated: false, scrollPosition: .top) }
        changeButton.isEnabled = canChange
        changeAllButton.isEnabled = canChange
        for b in [skipButton, ignoreButton, learnButton] { b?.isEnabled = hasWord }
    }

    var selectedGuess: String? {
        let r = table.indexPathForSelectedRow?.row ?? 0
        return guesses.indices.contains(r) ? guesses[r] : nil
    }

    /// ↑ ↓: the suggestion to change to.
    func moveSelection(by delta: Int) {
        guard !guesses.isEmpty else { return }
        let r = table.indexPathForSelectedRow?.row ?? 0
        let next = IndexPath(row: min(max(0, r + delta), guesses.count - 1), section: 0)
        table.selectRow(at: next, animated: false, scrollPosition: .none)
        table.scrollToRow(at: next, at: .none, animated: false)
    }

    // MARK: Keys

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        func key(_ input: String, _ mods: UIKeyModifierFlags = [], _ title: String? = nil, _ action: Selector) -> UIKeyCommand {
            let k = title.map { UIKeyCommand(title: $0, action: action, input: input, modifierFlags: mods) }
                ?? UIKeyCommand(input: input, modifierFlags: mods, action: action)
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
        return [
            key("\r", [], String(localized: "Change"), #selector(keyChange)),
            key("\t", [], String(localized: "Skip"), #selector(keySkip)),
            key(UIKeyCommand.inputRightArrow, .command, nil, #selector(keySkip)),
            key(UIKeyCommand.inputEscape, [], String(localized: "Done"), #selector(keyDone)),
            key(UIKeyCommand.inputUpArrow, [], nil, #selector(keyUp)),
            key(UIKeyCommand.inputDownArrow, [], nil, #selector(keyDown)),
        ]
    }

    @objc func keyChange() { onChange?() }
    @objc func keySkip() { onSkip?() }
    @objc func keyDone() { onDone?() }
    @objc func keyUp() { moveSelection(by: -1) }
    @objc func keyDown() { moveSelection(by: 1) }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { guesses.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "g", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = guesses[indexPath.row]
        content.textProperties.lineBreakMode = .byTruncatingTail
        content.textProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        becomeFirstResponder()
    }
}

extension EditorViewController {
    /// Whether spelling is checked in this document at all (SpellScope.checks):
    /// Fix Typos… covers prose, and comments and strings in code, as on the Mac.
    var spellingChecksThisDocument: Bool {
        SpellScope.checks(language: document.language.language, fileName: document.fileURL.lastPathComponent)
    }

    /// Edit › Spelling and Grammar › Fix Typos… and the editor menu's.
    @objc func fixTypos() { startFixTypos() }

    /// Starts (or brings back) the step-through. Nil for data files, where
    /// spelling isn't checked.
    @discardableResult
    func startFixTypos(checker: SpellStepChecking? = nil) -> SpellStepController? {
        guard spellingChecksThisDocument else {
            toast(String(localized: "Spelling isn’t checked in data files."))
            return nil
        }
        if let s = spellStep, s.isOpen {
            s.bringForward()
            return s
        }
        let s = SpellStepController(editor: self, checker: checker ?? TextCheckerSpelling(language: TextCheckerSpelling.language(for: textView)))
        spellStep = s
        s.onClose = { [weak self, weak s] in
            if let self, self.spellStep === s { self.spellStep = nil }
        }
        s.start()
        return s
    }

    /// The editor menu's Fix Typos….
    func fixTyposAction() -> UIAction {
        let a = UIAction(title: String(localized: "Fix Typos…"), image: UIImage(systemName: "textformat.abc.dottedunderline")) { [weak self] _ in
            self?.fixTypos()
        }
        a.accessibilityIdentifier = "editor.menu.fixTypos"
        if !spellingChecksThisDocument { a.attributes = .disabled }
        return a
    }
}
