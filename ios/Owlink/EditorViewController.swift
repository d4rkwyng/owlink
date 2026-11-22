import UIKit
import UniformTypeIdentifiers
import SwiftUI
import CedricCore
import CedricAI

// The field was too transparent on dark custom themes, letting the editor show
// through. Restyle only this alert's field chrome; its private hierarchy keeps
// the walk bounded, and both lifecycle hooks overwrite later UIKit restyles.
private final class GoToLineAlertController: UIAlertController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        styleTextFieldBackgrounds()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        styleTextFieldBackgrounds()
    }

    private func styleTextFieldBackgrounds() {
        guard let textField = textFields?.first else { return }
        textField.backgroundColor = .systemBackground
        guard textField.isDescendant(of: view) else { return }
        var view = textField.superview
        while let current = view, current !== self.view {
            if current is UIVisualEffectView { break }
            current.backgroundColor = .systemBackground
            view = current.superview
        }
    }
}

/// One open document: a UITextView on an explicit TextKit 2 stack (as the
/// Mac's NSTextView), coloured by the core's highlighter, with the system
/// find and replace (⌘F, ⌥⌘F), a status line (language, encoding, line
/// ending, caret), Cedric's hints, the Markdown preview and Ask Cedric.
final class EditorViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    let document: TextDocument
    let textView = EditorDocumentTextView(usingTextLayoutManager: true)
    let invisiblesOverlay = InvisiblesOverlay()
    lazy var regexFind = RegexFind(editor: self)
    var contextBar: MarkdownContextBar?
    private(set) var lineIndex = LineIndex()
    let markdownFenceIndex = FenceIndex()
    /// Left inset of the text before line numbers claim any of it.
    private let editorTextInsetLeft: CGFloat = 8
    /// This file's Readable Width choice. Nil follows Settings, which is off.
    private var readableWidthChoice: Bool?
    private(set) var writing = WritingModeState()
    private var writingInset: CGFloat = 0
    private var writingBaseInset: UIEdgeInsets?
    private var writingUpdatePending = false
    private var writingCenterPending = false
    private var writingLayoutSize = CGSize.zero
    private(set) var writingLargeReason: LargeDocument.Reason?
    /// The text range last dimmed (offsets, from the last paint). Stored
    /// NSTextRanges go stale after edits, so clearing works from this and the
    /// current viewport instead.
    private var focusPaintedRange: NSRange?
    private var focusCache: [Int]?
    private var focusPalette: UInt32?
    /// Counts text edits: part of the dimming's cache key, so an edit before
    /// the focus never leaves the old paint standing.
    private var editCount = 0
    private var highlightTimer: Timer?
    /// Painted backgrounds, bottom to top: Mark All's marks, the other
    /// occurrences, the matching bracket pair.
    private enum HighlightKind { case mark, occurrence, bracket }
    private struct HighlightPaint {
        let range: NSRange
        let textRange: NSTextRange
        let kind: HighlightKind
        var bracket: Bool { kind == .bracket }
    }
    /// The selection, visible range, generation and setting the
    /// occurrences were found for, and the marks' needle.
    private struct HighlightKey: Equatable {
        var values: [Int]
        var mark: Occurrences.Needle?
    }
    private var highlightPainted: [HighlightPaint] = []
    private var highlightKey: HighlightKey?
    private var highlightBrackets: [NSRange] = []
    private var highlightOccurrenceRanges: [NSRange] = []
    private var highlightMarkRanges: [NSRange] = []
    /// Mark All: the needle (nil: no marks), kept until Clear Marks and
    /// searched again in the visible text after edits and scrolls; the
    /// whole-document count for the status bar (nil when not counted).
    private var markNeedle: Occurrences.Needle?
    private(set) var markCount: Int?
    private var markCountTimer: Timer?
    private var highlightBracketKey: [Int]?
    private var highlightPalette: UInt32?
    private var highlightCaretColor: UInt32?
    private var highlightContrast = false
    private var readableWidthOn: Bool { readableWidthChoice ?? AppSettings.readableWidthDefault }
    private var lastTextScrollOffsetY: CGFloat?
    /// A jump forces numbers on for this tab without changing the setting.
    private var jumpShowsLineNumbers = false
    private var lastLineNumbersSetting = AppSettings.lineNumbers
    /// Bookmarks keep the numbers on too, so their markers show.
    private var showLineNumbers: Bool { AppSettings.lineNumbers || jumpShowsLineNumbers || !bookmarks.isEmpty }
    /// 1-based line drawn stronger in the gutter, the one just jumped to.
    private var markedLine: Int?
    private let lineNumberGutter = LineNumberGutter()
    private var colorizer: SyntaxColorizer!
    let owl = EditorOwl()
    let hintBar = OwlHintBar()
    private let statusBar = UIView()
    private let statusLabel = UILabel()
    private let wordsButton = UIButton(type: .system)
    private var wordsTimer: Timer?
    private var wordCount: Int?
    private let dailyKey = UUID().uuidString
    private let dailyQueue = DispatchQueue(label: "app.owlink.dailyWords", qos: .utility)
    private var dailyTimer: Timer?
    private var gutterLayoutScheduled = false
    /// Set while applyTextEdits replaces the text and reveals the selection:
    /// a scroll then defers the gutter to the next turn (TextKit 2 can spin
    /// finding the visible range mid-edit). User scrolling stays inline.
    var isApplyingTextEdits = false
    /// Gutter layouts run by scheduleGutterLayout (for tests).
    private(set) var scheduledGutterLayoutCount = 0
    var dailyIdleInterval: TimeInterval = 1
    var dailyWordCountLimit = TextStats.maxCounted
    private var wordCountGeneration: Int?
    private var dailyBaselineArm = 0
    private var dailyBaselinePending = false
    private var dailyDropAfterBaseline = false
    private var dailyPendingWords: [Int] = []
    private static let dailyImmediateLimit = 100_000
    var dailyWords = DailyWordCounter.shared
    var copyPasteboard: any CopyPasteboard = SystemCopyPasteboard()
    var announceAccessibility: (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }
    private var toolStatesCache: (generation: Int, selection: NSRange, explain: Bool, decode: Bool)?
    private weak var statisticsSheet: StatisticsViewController?
    private var statisticsTimer: Timer?
    private let languageButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    /// In the bar that rides on the keyboard, only while it is up.
    let hideKeyboardButton = UIButton(type: .system)
    private let split = UIStackView()
    private(set) var preview: PreviewController?
    private(set) var previewOn = false
    var lineIndentation: Indentation?
    /// Bookmarked lines (0-based) for this open document; they follow
    /// edits (storageEdited, applyTextEdits) and are not kept on close or
    /// reload.
    var bookmarks = Bookmarks()
    private(set) var generation = 0
    var markdownPasteboardReader: () -> (urls: [URL], string: String?) = {
        let pasteboard = UIPasteboard.general
        return (pasteboard.urls ?? [], pasteboard.string)
    }
    /// This text view's groupsByEvent, to put back on the next main-queue
    /// turn after applyTextEdit closed an open typing group (per editor:
    /// each has its own undo manager).
    var pendingGroupsByEvent: Bool?
    private var cachedIndentation: (generation: Int, value: Indentation?)?
    /// Offsets of closers inserted by pairing; quote overtype only skips these.
    var autoClosers: [Int] = []
    private var loading = false
    private(set) var palette = EditorPalettes.light
    private var previewTimer: Timer?
    /// Cedric, in the corner (as on the Mac).
    let owlSprite = OwlSprite()
    /// His bubble (the hint bar) is showing the current hint.
    private(set) var bubbleOpen = false
    private var lastHintCount = 0
    private var autoOpenedHint: String?
    private var textWidth: NSLayoutConstraint!
    /// Selection, scroll and keyboard while the preview covers the text
    /// (an iPhone Duo folded shut with the preview on).
    private var continuity: EditorContinuity?
    /// Ask Cedric docked beside the text on wide screens.
    private var askPanel: UIViewController?
    /// Ask Cedric as a sheet (compact width).
    private weak var askSheet: UIViewController?
    private var askPanelWidth: NSLayoutConstraint?
    private var askModel: AskCedricModel?
    private var splitTrailing: NSLayoutConstraint!
    /// The split's bottom: on the status line, or (Focus Preview, the status
    /// line hidden) on the safe area's bottom.
    private var splitBottom: NSLayoutConstraint!
    private var splitBottomFocus: NSLayoutConstraint!
    /// Status line's bottom and height, offset from the view's bottom.
    private var statusBarBottomPin: NSLayoutConstraint!
    private var statusBarHeightPin: NSLayoutConstraint!
    /// A keyboard animation owns the pin; layout must not fight it.
    private var animatingStatusBar = false
    /// Focus Preview: the preview alone, editor, status line and owl hidden.
    private(set) var focusOn = false
    /// The preview was beside the text before Focus Preview (it comes back so).
    private var previewOnBeforeFocus = false
    /// The draggable handle between text and preview (wide screens).
    let divider = SplitDivider()
    /// Where the seam sits, kept per size class; a drag in progress.
    private(set) var splitPosition: SplitPosition = .fold
    private var dragFraction: Double?
    /// The preview's scroll share when the text was hidden: if it moved
    /// meanwhile, the text follows it when it comes back.
    private var previewFractionAtHide: Double?
    private var focusGestures: [UIGestureRecognizer] = []
    /// Undo and Redo in the bar, enabled from the text view's undo manager.
    private lazy var undoItem = barItem(String(localized: "Undo"), "arrow.uturn.backward", "editor.undo") { [weak self] in
        self?.textView.undoManager?.undo()
    }
    private lazy var redoItem = barItem(String(localized: "Redo"), "arrow.uturn.forward", "editor.redo") { [weak self] in
        self?.textView.undoManager?.redo()
    }
    /// Save, in the bar while "Save automatically" is off.
    private lazy var saveItem = barItem(String(localized: "Save"), "square.and.arrow.down", "editor.save") { [weak self] in
        self?.saveDocument()
    }
    /// Unsaved text from a crash, for this document.
    enum Recovery {
        /// Ask Restore / Discard when the editor appears.
        case offer(RecoveryRecord)
        /// Restore was chosen already (at launch).
        case restore(RecoveryRecord)
    }
    private var pendingRecovery: Recovery?
    private var recoveryWriter: RecoveryWriter!
    private var closing = false
    /// Why the text is read-only right now (nothing: editable).
    private(set) var editGate: EditGate
    /// An iCloud conflict is being dealt with (copied, then asked).
    private var conflictResolver: ConflictResolver?
    /// A save failed: shown until one succeeds.
    let saveErrorBanner = SaveErrorBanner()

    /// The window (scene session) the editor is in, for `OpenDocuments`.
    let windowID: String
    /// Edit / Done (read mode), or a disabled Read Only (a binary file).
    private lazy var editItem: UIBarButtonItem = {
        let i = UIBarButtonItem(title: String(localized: "Edit"), image: nil, primaryAction: UIAction { [weak self] _ in
            self?.toggleEditing()
        })
        i.style = .done
        i.accessibilityIdentifier = "editor.edit"
        return i
    }()

    /// `readModeOnOpen`: nil follows the "Open Files Read-Only" setting.
    init(document: TextDocument, recovery: Recovery? = nil, windowID: String = UUID().uuidString, readModeOnOpen: Bool? = nil) {
        self.document = document
        self.pendingRecovery = recovery
        self.windowID = windowID
        self.editGate = EditGate(readModeOnOpen: readModeOnOpen ?? AppSettings.openReadOnly, binary: document.openBinaryAnyway)
        super.init(nibName: nil, bundle: nil)
        _ = OpenDocuments.registry.register(path: document.recoveryPath, window: windowID)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpTextView()
        lastTextScrollOffsetY = textView.contentOffset.y
        setUpStatusBar()
        setUpLayout()
        setUpNavigation()
        colorizer = SyntaxColorizer(textView: textView, language: document.language.language)
        colorizer.lineIndex = { [weak self] in self?.lineIndex ?? LineIndex() }
        document.currentText = { [weak self] in self?.textView.text ?? "" }
        document.onReload = { [weak self] in self?.loadText() }
        document.onExternalChange = { [weak self] in self?.externalChange() }
        document.onSaveError = { [weak self] error in self?.saveFailed(error) }
        document.onEditingAllowed = { [weak self] allowed in self?.setEditLock(.documentLocked, !allowed) }
        document.onEditedChange = { [weak self] in self?.updateEdited() }
        recoveryWriter = RecoveryWriter(document: document) { [weak self] in self?.textView.text ?? "" }
        document.onSaved = { [weak self] in
            guard let self, !self.closing else { return }
            self.dailyWordsSaved()
            // Edits made while it saved keep their copy.
            if self.document.hasUnsavedChanges { self.recoveryWriter.textChanged() } else { self.recoveryWriter.clear() }
            self.saveErrorBanner.hide()
        }
        owl.onChange = { [weak self] in self?.showHint() }
        owl.onNote = { [weak self] note in self?.toast(note) }
        lastLineNumbersSetting = AppSettings.lineNumbers
        applySettings()
        loadText()
        applyEditGate()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(highlightContrastChanged),
                                               name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
        // As the Mac does: TextKit 2's content storage owns the storage's delegate.
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited),
                                               name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged),
                                               name: UIDocument.stateChangedNotification, object: document)
        for n in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                  .NSUndoManagerWillCloseUndoGroup] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoChanged(_:)), name: n, object: nil)
        }
        // With "Save automatically" off nothing saves on the way out: the
        // recovery copy is written now rather than up to 3 s later.
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        // A detached preview window of this document wants its text.
        NotificationCenter.default.addObserver(self, selector: #selector(detachedPreviewNeedsText(_:)),
                                               name: DetachedPreviews.needsText, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Opening or closing an iPhone Duo is a size-class change (compact
        // outside, regular inside; outer landscape is compact both ways).
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self,
                                 UITraitVerticalSizeClass.self]) { (self: Self, _: UITraitCollection) in
            self.splitPosition = self.splitStore.position(regularWidth: self.traitCollection.horizontalSizeClass == .regular,
                                                          regularHeight: self.traitCollection.verticalSizeClass == .regular)
            self.applySettings()
            self.layoutPreview()
            self.updateAskPanelForWidth()
            self.view.setNeedsLayout()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The window is nil until the editor is on screen, so the scene-level
        // title colour is applied again here.
        applyBarStyle()
        EditorBarStyle.renderNavigationBarIfRequested(navigationController?.navigationBar)
        updateEdited()
        colorizer.colorViewport()
        scheduleEditorHighlights(selectionChanged: false)
        if let r = pendingRecovery {
            pendingRecovery = nil
            switch r {
            case .restore(let rec): restoreRecovered(rec)
            case .offer(let rec): offerRecovered(rec)
            }
        }
    }

    // MARK: Setup

    private func setUpTextView() {
        textView.delegate = self
        invisiblesOverlay.textView = textView
        textView.invisiblesOverlay = invisiblesOverlay
        textView.addSubview(invisiblesOverlay)
        disableAutomaticSubstitutions(textView)
        textView.isFindInteractionEnabled = true
        textView.regexFind = regexFind
        textView.findInteraction?.optionsMenuProvider = { [weak self] defaults in
            guard let self else { return UIMenu(children: defaults) }
            let toggle = UIAction(title: String(localized: "Regex"), state: self.regexFind.enabled ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.regexFind.setEnabled(!self.regexFind.enabled)
            }
            toggle.accessibilityIdentifier = "find.regex"
            toggle.accessibilityLabel = String(localized: "Regex")
            toggle.accessibilityHint = String(localized: "Search with regular expressions")
            return UIMenu(children: defaults + [toggle, UIMenu(options: .displayInline, children: self.markActions())])
        }
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 10, left: editorTextInsetLeft, bottom: 80, right: 8)
        textView.accessibilityIdentifier = "editor.text"
        textView.allowsEditingTextAttributes = false
        textView.markdownKeysEnabled = { [weak self] in self?.markdownEditable ?? false }
        textView.onMarkdownTab = { [weak self] forward in self?.handleMarkdownTab(forward: forward) }
        textView.onMarkdownPaste = { [weak self] in self?.handleMarkdownPaste() ?? false }
        textView.onKeyboardCaretMove = { [weak self] in
            self?.scheduleWritingUpdate(center: true)
            self?.scheduleEditorHighlights(selectionChanged: false)
        }
        textView.onTypewriterScroll = { [weak self] in
            guard let self, self.writing.typewriter, self.writingLargeReason == nil else { return false }
            self.updateWriting(center: true)
            return true
        }
    }

    private func setUpStatusBar() {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "editor.status"
        wordsButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        wordsButton.titleLabel?.lineBreakMode = .byTruncatingTail
        wordsButton.clipsToBounds = true
        wordsButton.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        wordsButton.setContentHuggingPriority(.init(249), for: .horizontal)
        wordsButton.accessibilityIdentifier = "status.words"
        wordsButton.isHidden = true
        wordsButton.addAction(UIAction { [weak self] _ in self?.showStatistics() }, for: .primaryActionTriggered)
        for b in [languageButton, formatButton] {
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            b.showsMenuAsPrimaryAction = true
            b.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        }
        statusLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        languageButton.accessibilityIdentifier = "editor.language"
        formatButton.accessibilityIdentifier = "editor.format"
        hideKeyboardButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hideKeyboardButton.accessibilityLabel = String(localized: "Hide Keyboard")
        hideKeyboardButton.accessibilityIdentifier = "editor.hideKeyboard"
        hideKeyboardButton.isHidden = true
        hideKeyboardButton.addAction(UIAction { [weak self] _ in self?.hideKeyboard() }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            hideKeyboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            hideKeyboardButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = UIStackView(arrangedSubviews: [languageButton, formatButton, spacer, wordsButton, statusLabel, hideKeyboardButton])
        row.spacing = 10
        row.setCustomSpacing(0, after: spacer)
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(row)
        statusBar.backgroundColor = .secondarySystemBackground
        // Horizontal margins clear the corner curve; safe-area side insets
        // continue to apply in landscape.
        statusBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        statusBar.insetsLayoutMarginsFromSafeArea = true
        var guide: UILayoutGuide = statusBar.layoutMarginsGuide
        if #available(iOS 26.0, *) { guide = statusBar.layoutGuide(for: .margins(cornerAdaptation: .horizontal)) }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 20),
            // Centred in the full coloured band so a 34 pt bar does not leave
            // the labels sitting low; a 24 pt bar (keyboard or a small inset) is unchanged.
            row.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    private func setUpLayout() {
        split.axis = .horizontal
        split.distribution = .fill
        split.spacing = 1
        split.addArrangedSubview(textView)
        for v in [split, statusBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // Not an arranged subview, and not inside the text view: the numbers
        // stay on screen while the text scrolls.
        split.addSubview(lineNumberGutter)
        lineNumberGutter.onTapLine = { [weak self] line in self?.toggleBookmark(line: line - 1) }
        // Frame-based, placed in viewDidLayoutSubviews: the owl and his bubble.
        view.addSubview(owlSprite)
        view.addSubview(hintBar)
        hintBar.isHidden = true
        hintBar.onClose = { [weak self] in
            self?.bubbleOpen = false
            self?.owl.dismissCurrent()
            self?.showHint()
        }
        hintBar.onNext = { [weak self] in self?.owl.showNext() }
        hintBar.onFix = { [weak self] in self?.applyFix() }
        hintBar.onIgnore = { [weak self] in self?.ignoreStylePhrase() }
        setUpOwlSprite()
        setUpDivider()
        setUpSaveErrorBanner()
        setUpFocusGestures()
        let g = view.safeAreaLayoutGuide
        splitTrailing = split.trailingAnchor.constraint(equalTo: g.trailingAnchor)
        splitBottom = split.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        splitBottomFocus = split.bottomAnchor.constraint(equalTo: g.bottomAnchor)
        // The text pane's width when the preview is beside it (the seam on
        // the fold of an unfolded iPhone Duo): set in updateSplit().
        textWidth = textView.widthAnchor.constraint(equalToConstant: 100)
        textWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: g.topAnchor),
            // Inside the safe area: clear of a vertical bar at the side, the
            // camera and the rounded corners in landscape.
            split.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            splitTrailing,
            splitBottom,
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // The bar rests at the screen edge, filling the home-indicator zone;
        // a docked keyboard lifts its shorter strip onto the keyboard.
        statusBarBottomPin = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        statusBarHeightPin = statusBar.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([statusBarBottomPin, statusBarHeightPin])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateStatusBarPin()
        updateWordsVisibility()
        updateSplit()
        updateAskPanelWidth()
        layoutOwl()
        layoutDivider()
        layoutGutter()
        updateUnwrappedContentSize()
        updateWritingInset()
        if writingLayoutSize != textView.bounds.size {
            writingLayoutSize = textView.bounds.size
            scheduleWritingUpdate()
            scheduleEditorHighlights(selectionChanged: false)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    /// The window's safe area excludes the keyboard and its accessory.
    private func homeInsetForStatusBar() -> CGFloat {
        view.window?.safeAreaInsets.bottom ?? 0
    }

    /// Where the status line's bottom goes for a keyboard frame (the guide's,
    /// or a notification's end frame; both include the Context Bar, the
    /// text view's inputAccessoryView). A software keyboard is handled by
    /// EditorPanes. With a hardware keyboard the "keyboard" is only the bar
    /// (44 pt over the home inset), which EditorPanes ignores as too short to
    /// be a keyboard; while the bar is attached and the frame covers the
    /// bottom edge, the status line sits on the frame's top instead, so it
    /// is never under the bar. The frame comes first: the bar view's own
    /// position lags behind an animation's end frame.
    func statusBottom(keyboard: CGRect, homeInset: CGFloat) -> CGFloat {
        let height = view.bounds.height
        let bottom = EditorPanes.statusBarBottom(viewHeight: height, keyboardTop: keyboard.minY,
                                                  keyboardBottom: keyboard.maxY, homeInset: homeInset)
        guard bottom == height, textView.isFirstResponder, let bar = contextBar else { return bottom }
        if keyboard.height > 0, keyboard.maxY >= height - 1, keyboard.minY < height - homeInset - 1 {
            return max(keyboard.minY, 0)
        }
        // A frame that stops at the home inset (the bar not counted yet):
        // the bar's own frame, once it is on screen at the bottom.
        guard bar.window != nil, keyboard.intersects(view.bounds),
              keyboard.maxY >= height - homeInset - 1 else { return bottom }
        let frame = bar.convert(bar.bounds, to: view)
        guard frame.height > 0, frame.intersects(view.bounds),
              frame.maxY >= view.bounds.maxY - homeInset - 1 else { return bottom }
        return min(bottom, frame.minY)
    }

    /// The keyboard guide in this view's coordinates, or nil before the
    /// window exists.
    private func keyboardFrameInView() -> CGRect {
        view.keyboardLayoutGuide.layoutFrame
    }

    private func updateStatusBarPin() {
        guard !animatingStatusBar, let pin = statusBarBottomPin else { return }
        let g = keyboardFrameInView()
        let homeInset = homeInsetForStatusBar()
        let y = statusBottom(keyboard: g, homeInset: homeInset)
        statusBarHeightPin.constant = EditorPanes.statusBarHeight(homeInset: y < view.bounds.height ? 0 : homeInset)
        let constant = y - view.bounds.height
        guard abs(pin.constant - constant) > 0.5 else { return }
        pin.constant = constant
    }

    /// Show, hide, and interactive drag. The end frame is in screen
    /// coordinates; a duration of 0 is an interactive update, applied now
    /// so layout can keep following the guide.
    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard let raw = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let pin = statusBarBottomPin else { return }
        let frame = keyboardFrame(raw)
        let homeInset = homeInsetForStatusBar()
        let y = statusBottom(keyboard: frame, homeInset: homeInset)
        let barHeight = EditorPanes.statusBarHeight(homeInset: y < view.bounds.height ? 0 : homeInset)
        let constant = y - view.bounds.height
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        guard duration > 0.01 else {
            if abs(pin.constant - constant) > 0.5 { pin.constant = constant }
            statusBarHeightPin.constant = barHeight
            return
        }
        animatingStatusBar = true
        let options = UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            pin.constant = constant
            self.statusBarHeightPin.constant = barHeight
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.animatingStatusBar = false
            self.updateStatusBarPin()
        })
    }

    private func keyboardFrame(_ screen: CGRect) -> CGRect {
        guard let window = view.window else { return screen }
        let inWindow = window.convert(screen, from: window.screen.coordinateSpace)
        return view.convert(inWindow, from: window)
    }

    // MARK: Fold (iPhone Duo)

    /// The fold, as the system's "division" reserved regions (iOS 27.1+),
    /// in the view's coordinates: also while the phone is flat open
    /// (.includeInactive), since the crease is still there. None elsewhere.
    func folds() -> [CGRect] {
        if #available(iOS 27.1, *) {
            return view.reservedRegions(kind: .division, options: .includeInactive).map(\.frame)
        }
        return []
    }

    private var rightToLeft: Bool { view.effectiveUserInterfaceLayoutDirection == .rightToLeft }

    private var sideBySide: Bool { previewOn && !focusOn && !textView.isHidden && preview?.view.isHidden == false }

    /// The seam's position now: the drag in progress, else the kept one.
    private var effectiveSplit: SplitPosition { dragFraction.map { .fraction($0) } ?? splitPosition }

    /// Text and preview side by side: the seam where it was put (a drag
    /// snaps to 1/3, 1/2, 2/3 or the fold), by default on the fold when
    /// there is one (an unfolded iPhone Duo), else in the middle.
    private func updateSplit() {
        guard sideBySide else {
            if textWidth.isActive { textWidth.isActive = false }
            return
        }
        let s = PreviewSplit.panes(effectiveSplit, content: split.frame, folds: folds(), spacing: 1, rightToLeft: rightToLeft)
        if split.spacing != s.gap { split.spacing = s.gap }
        if textWidth.constant != s.leading { textWidth.constant = s.leading }
        if !textWidth.isActive { textWidth.isActive = true }
    }

    private func setUpNavigation() {
        navigationItem.title = document.displayName
        navigationItem.style = .editor
        navigationItem.backAction = UIAction { [weak self] _ in self?.closeDocument() }
        navigationItem.documentProperties = UIDocumentProperties(url: document.fileURL)
        navigationItem.largeTitleDisplayMode = .never
        updateBarButtons()
    }

    private func updateBarButtons() {
        let find = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in
            self?.textView.findInteraction?.presentFindNavigator(showingReplace: false)
        })
        find.accessibilityIdentifier = "editor.find"
        find.title = String(localized: "Find")
        // Cedric himself is the owl in the editor's corner (OwlSprite), not
        // a small bar icon; Ask Cedric is also in the overflow menu.
        var items = [find]
        updateUndoItems()
        if SavePolicy.showsSaveButton(saveAutomatically: AppSettings.saveAutomatically) { items.insert(saveItem, at: 0) }
        if hasEditorPreview {
            let p = UIBarButtonItem(image: UIImage(systemName: previewOn ? "eye.fill" : "eye"), primaryAction: UIAction { [weak self] _ in
                self?.togglePreview()
            })
            p.title = String(localized: "Preview")
            p.accessibilityIdentifier = "editor.preview"
            // Long-press (or a secondary click): the full-screen and
            // new-window ways in, which a tap on the eye doesn't reach.
            p.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
                done(self?.previewMenuItems() ?? [])
            }])
            items.append(p)
            let f = UIBarButtonItem(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), primaryAction: UIAction { [weak self] _ in
                self?.toggleFocusPreview()
            })
            f.title = String(localized: "Focus Preview")
            f.accessibilityLabel = String(localized: "Focus Preview")
            f.accessibilityIdentifier = "editor.focusPreview"
            items.append(f)
        }
        if focusOn {
            // Only the way back (and the overflow menu).
            let done = UIBarButtonItem(title: String(localized: "Edit"), image: nil, primaryAction: UIAction { [weak self] _ in
                self?.exitFocusPreview()
            })
            done.style = .done
            done.accessibilityHint = String(localized: "Leaves Focus Preview and shows the text.")
            done.accessibilityIdentifier = "editor.focusDone"
            if #available(iOS 27.0, *) { done.visibilityPriority = .high }
            navigationItem.rightBarButtonItems = [done]
            updateEdited()
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] done in
                done(self?.focusMenuItems() ?? [])
            }
            return
        }
        // Which stay when a vertical bar (iPhone Duo) runs out of room.
        if #available(iOS 27.0, *) {
            items.forEach { $0.visibilityPriority = .standard }
            for i in [find, undoItem, redoItem, saveItem, editItem] { i.visibilityPriority = .high }
        }
        // Undo and Redo first (leading), then Save, Find, Preview, and
        // Edit / Done at the trailing end.
        items.insert(contentsOf: [undoItem, redoItem], at: 0)
        if let edit = configuredEditItem() { items.append(edit) }
        navigationItem.rightBarButtonItems = items.reversed()
        updateEdited()
        // The rest in the system's own overflow menu (the ellipsis is
        // reserved for it), not an app-made "More" menu.
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.moreMenuItems() ?? [])
        }
    }

    func moreMenuItems() -> [UIMenuElement] {
        let save = UIAction(title: String(localized: "Save"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveDocument()
        }
        let revert = revertAction()
        let replace = UIAction(title: String(localized: "Find and Replace"), image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
            self?.textView.findInteraction?.presentFindNavigator(showingReplace: true)
        }
        let goTo = UIAction(title: String(localized: "Go to Line…"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
            self?.goToLine()
        }
        let quickly = UIAction(title: String(localized: "Open Quickly…"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.openQuickly()
        }
        let todos = UIAction(title: String(localized: "Find TODOs"), image: UIImage(systemName: "checklist")) { [weak self] _ in
            self?.findTodos()
        }
        todos.accessibilityIdentifier = "tools.menu.todos"
        if !canFindTodos { todos.attributes = .disabled }
        let statistics = UIAction(title: String(localized: "Statistics…"), image: UIImage(systemName: "chart.bar")) { [weak self] _ in
            self?.showStatistics()
        }
        statistics.accessibilityIdentifier = "stats.menu"
        quickly.accessibilityIdentifier = "editor.menu.quickOpen"
        let wrap = UIAction(title: String(localized: "Wrap Lines"), image: UIImage(systemName: "text.word.spacing")) { [weak self] _ in
            self?.toggleWrap()
        }
        wrap.state = AppSettings.wrap ? .on : .off
        wrap.accessibilityIdentifier = "editor.menu.wrapLines"
        let invisiblesTitle = AppSettings.showInvisibles ? String(localized: "Hide Invisibles") : String(localized: "Show Invisibles")
        let invisibles = UIAction(title: invisiblesTitle, state: AppSettings.showInvisibles ? .on : .off) { [weak self] _ in
            self?.toggleInvisibles()
        }
        invisibles.accessibilityIdentifier = "editor.menu.showInvisibles"
        invisibles.accessibilityLabel = invisiblesTitle
        let readable = UIAction(title: String(localized: "Readable Width"), image: UIImage(systemName: "text.aligncenter")) { [weak self] _ in
            self?.toggleReadableWidth()
        }
        readable.state = readableWidthOn ? .on : .off
        readable.attributes = AppSettings.wrap ? [] : .disabled
        readable.accessibilityIdentifier = "editor.menu.readableWidth"
        let check = UIAction(title: String(localized: "Check with Cedric"), image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.checkWithCedric()
        }
        let ask = UIAction(title: String(localized: "Ask Cedric"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [weak self] _ in
            self?.askCedric()
        }
        let settings = UIAction(title: String(localized: "Settings"), image: UIImage(systemName: "gear")) { [weak self] _ in
            self?.showSettings()
        }
        let print = UIAction(title: String(localized: "Print…"), image: UIImage(systemName: "printer")) { [weak self] _ in
            self?.printDocument()
        }
        print.accessibilityIdentifier = "editor.menu.print"
        let exportHTML = UIAction(title: String(localized: "Export as HTML…"), image: UIImage(systemName: "doc.text")) { [weak self] _ in
            self?.exportHTMLDocument()
        }
        exportHTML.accessibilityIdentifier = "editor.menu.exportHTML"
        let exportPDF = UIAction(title: String(localized: "Export as PDF…"), image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
            self?.exportPDFDocument()
        }
        exportPDF.accessibilityIdentifier = "editor.menu.exportPDF"
        if document.language.language != .markdown {
            exportHTML.attributes = .disabled
            exportPDF.attributes = .disabled
        }
        var first: [UIMenuElement] = [print, exportHTML, exportPDF, save, replace] + markActions() + [goTo, quickly, todos, statistics, wrap, invisibles, readable, ask, check]
        if let checkScript = checkScriptAction() { first.append(checkScript) }
        if hasEditorPreview {
            let focus = UIAction(title: String(localized: "Focus Preview"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.toggleFocusPreview()
            }
            focus.accessibilityIdentifier = "editor.menu.focusPreview"
            first.insert(focus, at: 0)
            // Stays in this menu whatever the bar has room for (the bar's
            // own Focus Preview button drops off a narrow iPhone bar).
            if let detach = detachPreviewAction() { first.insert(detach, at: 1) }
        }
        if UIApplication.shared.supportsMultipleScenes { first.append(Self.newWindowAction()) }
        return [UIMenu(options: .displayInline, children: first), UIMenu(options: .displayInline, children: [revert, previousVersionsMenu()]),
                writingModeMenu(), languageMenu(), indentationMenu(), bookmarksMenu(), formatMenu(),
                UIMenu(options: .displayInline, children: [settings])]
    }

    /// The preview button's long-press menu.
    private func previewMenuItems() -> [UIMenuElement] {
        let focus = UIAction(title: String(localized: "Focus Preview"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
            self?.toggleFocusPreview()
        }
        focus.accessibilityIdentifier = "editor.previewMenu.focus"
        return [focus] + [detachPreviewAction()].compactMap { $0 }
    }

    /// "Open Preview in New Window": iPad only (hidden on an iPhone).
    private func detachPreviewAction() -> UIAction? {
        guard document.language.language == .markdown, DetachedPreviews.available else { return nil }
        let a = UIAction(title: String(localized: "Open Preview in New Window"), image: UIImage(systemName: "macwindow.badge.plus")) { [weak self] _ in
            self?.openPreviewInNewWindow()
        }
        a.accessibilityIdentifier = "editor.menu.detachPreview"
        return a
    }

    /// The overflow menu in Focus Preview: back to the text, the text size.
    private func focusMenuItems() -> [UIMenuElement] {
        let back = UIAction(title: String(localized: "Exit Focus Preview"), image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
            self?.exitFocusPreview()
        }
        let bigger = UIAction(title: String(localized: "Bigger Text"), image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in
            self?.preview?.bigger()
        }
        let smaller = UIAction(title: String(localized: "Smaller Text"), image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in
            self?.preview?.smaller()
        }
        let actual = UIAction(title: String(localized: "Actual Size"), image: UIImage(systemName: "textformat.size")) { [weak self] _ in
            self?.preview?.actualSize()
        }
        return [UIMenu(options: .displayInline, children: [back]), UIMenu(options: .displayInline, children: [bigger, smaller, actual])]
    }

    // MARK: Text

    private func loadText() {
        clearEditorHighlights()
        loading = true
        let sel = textView.selectedRange
        textView.text = document.text
        invisiblesOverlay.textChanged()
        let font = AppSettings.font(for: document.language.language, traits: traitCollection)
        textView.font = font
        textView.textColor = UIColor(hex: palette.foreground)
        textView.typingAttributes = [.font: font, .foregroundColor: UIColor(hex: palette.foreground)]
        lineIndex = LineIndex(textView.textStorage.string as NSString)
        writingLargeReason = LargeDocument.reason(for: lineIndex)
        clearFocusRendering()
        updateWritingInset()
        applyProseChecking()
        markdownFenceIndex.invalidateAll()
        cachedIndentation = nil
        lineIndentation = nil
        let hadBookmarks = !bookmarks.isEmpty
        bookmarks = Bookmarks()
        applyTabStops()
        autoClosers = []
        if NSMaxRange(sel) <= (textView.text as NSString).length { textView.selectedRange = sel }
        loading = false
        // The text was replaced from disk: the old undo steps' ranges no
        // longer match it.
        textView.undoManager?.removeAllActions()
        colorizer.setLanguage(document.language.language)
        generation += 1
        regexFind.invalidate()
        dailyTimer?.invalidate()
        countDailyWords(baseline: true)
        scheduleWordCount()
        scheduleStatisticsUpdate()
        updateStatus()
        updateBarButtons()
        scheduleOwl()
        refreshPreview()
        askModel?.documentReplaced()
        scheduleMarkRecount()
        scheduleEditorHighlights()
        if hadBookmarks { bookmarksChanged() }
    }

    @objc private func storageEdited() {
        let textStorage = textView.textStorage
        let edited = textStorage.editedRange, delta = textStorage.changeInLength
        guard textStorage.editedMask.contains(.editedCharacters), !loading else { return }
        invisiblesOverlay.textChanged()
        clearEditorHighlights()
        editCount += 1
        // Marks follow the text: the stale paint is gone; find them again
        // in view after the pause, and recount.
        if hasMarks {
            scheduleMarkRecount()
            scheduleEditorHighlights(selectionChanged: false)
        }
        let oldRange = NSRange(location: edited.location, length: edited.length - delta)
        shiftAutoClosers(oldRange: oldRange, newLength: edited.length)
        let oldLines = lineIndex.lineCount
        // Bookmarks follow their lines, measured against the old text
        // (applyTextEdits then puts structured edits' own set in place).
        var bookmarkEdit: (first: Int, removed: Int, wholeLines: Bool)?
        if !bookmarks.isEmpty {
            let a = lineIndex.line(containing: oldRange.location), b = lineIndex.line(containing: NSMaxRange(oldRange))
            bookmarkEdit = (a, b - a, lineIndex.starts[a] == oldRange.location && lineIndex.starts[b] == NSMaxRange(oldRange))
        }
        let first = lineIndex.replace(oldRange, newLength: edited.length, in: textStorage.string as NSString)
        if let e = bookmarkEdit {
            bookmarks.adjust(firstLine: e.first, removed: e.removed, inserted: lineIndex.lineCount - oldLines + e.removed,
                             wholeLines: e.wholeLines)
            lineNumberGutter.bookmarked = Set(bookmarks.lines.map { $0 + 1 })
        }
        if writingLargeReason == nil,
           let reason = LargeDocument.reason(afterEditOf: first..<(lineIndex.line(containing: NSMaxRange(edited)) + 1), in: lineIndex) {
            writingLargeReason = reason
            clearFocusRendering()
            updateWritingInset()
            applyProseChecking()
            if !writing.isOff { showWritingPaused(reason) }
        }
        markdownFenceIndex.invalidate(fromLine: first)
        colorizer?.textDidChange(firstLine: first, lastLine: lineIndex.line(containing: NSMaxRange(edited)),
                                 lineDelta: lineIndex.lineCount - oldLines)
    }

    func textViewDidChange(_ textView: UITextView) {
        scheduleWritingUpdate()
        scheduleEditorHighlights(selectionChanged: false)
        generation += 1
        regexFind.invalidate()
        dailyTimer?.invalidate()
        let timer = Timer(timeInterval: dailyIdleInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitDailyWords() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
        scheduleWordCount()
        scheduleStatisticsUpdate()
        updateDocumentChangeCount()
        recoveryWriter.textChanged()
        updateUndoItems()
        updateStatus()
        scheduleOwl()
        askModel?.documentEdited()
        askModel?.scheduleScopeRefresh()
        // Also hides numbers shown only for bookmarks once the last one goes.
        // Not on this turn: the text may have just been replaced through the
        // storage, and finding the visible range mid-edit can make TextKit 2
        // spin forever.
        if showLineNumbers || !lineNumberGutter.isHidden { scheduleGutterLayout() } else { layoutTextInsets() }
        updateUnwrappedContentSize()
        if previewOn || DetachedPreviews.hasPreviews(forPath: document.recoveryPath) {
            previewTimer?.invalidate()
            let delay = document.language.language == .csv && LargeDocument.reason(for: lineIndex) != nil ? 0.8 : 0.3
            previewTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreview() }
            }
        }
        if textView.isFirstResponder { revealRange(textView.selectedRange) }
    }

    /// Lays out the gutter on the next main-queue turn, once for any number
    /// of edits in this one.
    private func scheduleGutterLayout() {
        guard !gutterLayoutScheduled else { return }
        gutterLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gutterLayoutScheduled = false
                self.scheduledGutterLayoutCount += 1
                self.layoutGutter()
            }
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        guard textView === self.textView, textView.isEditable, editGate.isEditable,
              textView.markedTextRange == nil else { return true }
        let text = textView.textStorage.string as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              NSMaxRange(range) <= text.length else { return true }
        let language = document.language.language

        if replacement == "\t", !self.textView.isPasting {
            let resolved = resolvedLineIndentation(text)
            if resolved.tabTypesSpaces {
                let start = lineIndex.starts[lineIndex.line(containing: range.location)]
                var column = 0
                for position in max(start, range.location - 4096)..<range.location {
                    column = text.character(at: position) == 9
                        ? (column / resolved.indentation.width + 1) * resolved.indentation.width : column + 1
                }
                let spaces = String(repeating: " ", count: resolved.indentation.width - column % resolved.indentation.width)
                return !applyTextEdit(TextEdit(range: range, replacement: spaces,
                                               selection: NSRange(location: range.location + spaces.utf16.count, length: 0)),
                                      actionName: String(localized: "Typing"))
            }
        }

        if replacement == "\n", !self.textView.isPasting {
            let singleLineSelection = range.length == 0
                || text.rangeOfCharacter(from: .newlines, options: [], range: range).location == NSNotFound
            if singleLineSelection {
                if language == .yaml,
                   let edit = MarkdownLists.newline(in: text, selection: range, language: .yaml,
                                                    tabWidth: currentLineIndentation(text).width,
                                                    useTabs: currentLineIndentation(text).usesTabs) {
                    return !applyTextEdit(edit, actionName: String(localized: "Typing"))
                }
                if language == .markdown, !isInMarkdownFence(at: range.location, in: text) {
                    if let edit = MarkdownTable.newline(in: text, selection: range) {
                        return !applyTextEdit(edit, actionName: String(localized: "Add Table Row"))
                    }
                    let indentation = markdownIndentation(for: text)
                    if let edit = MarkdownLists.newline(in: text, selection: range, language: .markdown,
                                                        tabWidth: indentation.width, useTabs: indentation.usesTabs) {
                        return !applyTextEdit(edit, actionName: String(localized: "Typing"))
                    }
                }
            }
            let line = lineIndex.line(containing: range.location)
            let edit = AutoEdit.newlineEdit(in: text, lineStart: lineIndex.starts[line], selection: range,
                                            language: language, unit: currentLineIndentation(text).unit)
            // Plain newline (no indent to keep): let the system insert it, as the Mac
            // falls back to insertNewline, so it stays in the current typing undo group.
            if edit.replacement == "\n", edit.selection == NSRange(location: range.location + 1, length: 0) {
                return true
            }
            return !applyTextEdit(edit, actionName: String(localized: "Typing"))
        }

        // Backspace only: UITextView reports the deleted character (caret-1, 1).
        // Forward delete is (caret, 1) and must not pair-delete, as on the Mac.
        if replacement.isEmpty, !self.textView.isPasting, range.length == 1, textView.selectedRange.length == 0,
           NSMaxRange(range) == textView.selectedRange.location,
           AppSettings.autoCloseBrackets, AutoEdit.pairs(in: language),
           AutoEdit.deletesPair(before: range.location < text.length ? text.character(at: range.location) : nil,
                                after: NSMaxRange(range) < text.length ? text.character(at: NSMaxRange(range)) : nil,
                                language: language) {
            let edit = TextEdit(range: NSRange(location: range.location, length: 2), replacement: "",
                                selection: NSRange(location: range.location, length: 0))
            return !applyTextEdit(edit, actionName: String(localized: "Typing"))
        }

        guard !self.textView.isPasting, replacement.utf16.count == 1, let raw = replacement.utf16.first else { return true }
        let typed = straightenedTyping(replacement) ?? replacement
        let character = typed.utf16.first ?? raw

        if typed == ":", language == .python,
           let edit = pythonClauseEdit(in: text, selection: range) {
            return !applyTextEdit(edit, actionName: String(localized: "Typing"))
        }

        if AppSettings.autoCloseBrackets, AutoEdit.pairs(in: language) {
            switch AutoEdit.typing(character, before: range.location > 0 ? text.character(at: range.location - 1) : nil,
                                   after: NSMaxRange(range) < text.length ? text.character(at: NSMaxRange(range)) : nil,
                                   hasSelection: range.length > 0, language: language,
                                   afterIsAutoClosed: autoClosers.contains(NSMaxRange(range))) {
            case .skip?:
                autoClosers.removeAll { $0 == range.location }
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                return false
            case .pair(let pair)?:
                let edit = TextEdit(range: range, replacement: pair,
                                    selection: NSRange(location: range.location + 1, length: 0))
                guard applyTextEdit(edit, actionName: String(localized: "Typing")) else { return true }
                autoClosers.append(range.location + 1)
                if autoClosers.count > 16 { autoClosers.removeFirst(autoClosers.count - 16) }
                return false
            case .wrap(let open, let close)?:
                let inner = text.substring(with: range)
                let edit = TextEdit(range: range, replacement: open + inner + close,
                                    selection: NSRange(location: range.location + 1, length: range.length))
                return !applyTextEdit(edit, actionName: String(localized: "Typing"))
            case nil:
                break
            }
        }
        // Quotes (and typographic dashes) are inserted exactly so UITextView
        // cannot rewrite them into typographic forms.
        if typed == "\"" || typed == "'" || typed != replacement {
            let edit = TextEdit(range: range, replacement: typed,
                                selection: NSRange(location: range.location + (typed as NSString).length, length: 0))
            return !applyTextEdit(edit, actionName: String(localized: "Typing"))
        }
        return true
    }

    /// Straight quotes and dashes for typed punctuation; nil if `replacement`
    /// needs no typography fix.
    private func straightenedTyping(_ replacement: String) -> String? {
        let map: [Character: Character] = [
            "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
            "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
            "\u{2013}": "-", "\u{2014}": "-",
        ]
        var changed = false
        let exact = String(replacement.map { ch in
            if let straight = map[ch] { changed = true; return straight }
            return ch
        })
        return changed ? exact : nil
    }

    func handleMarkdownTab(forward: Bool) {
        guard markdownEditable else { return }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= text.length else {
            return
        }
        let singleLine = selection.length == 0
            || text.rangeOfCharacter(from: .newlines, options: [], range: selection).location == NSNotFound
        if singleLine, !isInMarkdownFence(at: selection.location, in: text) {
            if let edit = MarkdownTable.tab(in: text, selection: selection, forward: forward),
               applyTextEdit(edit, actionName: String(localized: "Format Table")) { return }
            let indentation = markdownIndentation(for: text)
            if let edit = MarkdownLists.shiftItem(in: text, selection: selection, right: forward,
                                                  useTabs: indentation.usesTabs, tabWidth: indentation.width),
               applyTextEdit(edit, actionName: forward ? String(localized: "Indent") : String(localized: "Outdent")) { return }
        }
        if forward { textView.insertText("\t") }
    }

    func handleMarkdownPaste() -> Bool {
        guard markdownEditable else { return false }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.length > 0, !isInMarkdownFence(at: selection.location, in: text) else { return false }
        let pasteboard = markdownPasteboardReader()
        let pasted: String?
        if !pasteboard.urls.isEmpty {
            guard pasteboard.urls.count == 1 else { return false }
            let urls = pasteboard.urls
            pasted = urls[0].absoluteString
        } else if let string = pasteboard.string, MarkdownFormat.isURL(string) {
            pasted = string
        } else {
            return false
        }
        guard let pasted else { return false }
        return markdownLinkPaste(pasted)
    }

    func detectedIndentation(for text: NSString) -> Indentation? {
        if let cachedIndentation, cachedIndentation.generation == generation {
            return cachedIndentation.value
        }
        let value = Indentation.detect(text)
        cachedIndentation = (generation, value)
        return value
    }

    private func markdownIndentation(for text: NSString) -> Indentation {
        currentLineIndentation(text)
    }

    private func shiftAutoClosers(oldRange: NSRange, newLength: Int) {
        guard !autoClosers.isEmpty else { return }
        let end = NSMaxRange(oldRange)
        let delta = newLength - oldRange.length
        autoClosers = autoClosers.compactMap { offset in
            if offset >= end { return offset + delta }
            return offset < oldRange.location ? offset : nil
        }
    }

    private func pythonClauseEdit(in text: NSString, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let line = lineIndex.line(containing: selection.location)
        let start = lineIndex.starts[line]
        guard selection.location - start <= 512 else { return nil }
        let head = text.substring(with: NSRange(location: start, length: selection.location - start))
        var above: [String] = []
        var position = start
        while position > 0, above.count < 300 {
            let previous = lineIndex.line(containing: position - 1)
            let lineRange = lineIndex.contentRange(ofLine: previous)
            above.append(lineRange.length > 4096 ? "x" : text.substring(with: lineRange).trimmingCharacters(in: .newlines))
            position = lineRange.location
        }
        let width = currentLineIndentation(text).width
        guard let indent = LanguageIndent.pythonClauseIndent(head: head, above: above, tabWidth: width) else { return nil }
        let body = head.drop { $0 == " " || $0 == "\t" }
        let replacement = indent + body + ":"
        return TextEdit(range: NSRange(location: start, length: selection.location - start), replacement: replacement,
                        selection: NSRange(location: start + (replacement as NSString).length, length: 0))
    }

    /// A URL pasted over a selection in Markdown becomes [selection](url),
    /// one undo step (MarkdownPaste.linkPaste); false: paste as usual.
    func markdownLinkPaste(_ pasted: String) -> Bool {
        guard markdownEditable else { return false }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.length > 0, !isInMarkdownFence(at: selection.location, in: text),
              let edit = MarkdownPaste.linkPaste(in: text, selection: selection, pasted: pasted) else { return false }
        return applyTextEdit(edit, actionName: String(localized: "Paste"))
    }

    private func updateDocumentChangeCount() {
        let storage = textView.textStorage
        let matches = document.cleanCheckAllowed && DiskState.matchesDisk(textUTF16Length: storage.length, text: { storage.string },
                                            format: currentFormat,
                                            hasBOM: DiskState.includeBOM(encoding: document.encoding, onDisk: document.onDisk),
                                            onDisk: document.onDisk, onDiskUTF16Length: document.onDiskUTF16Length)
        if matches {
            if document.hasUnsavedChanges { document.updateChangeCount(.cleared) }
        } else {
            document.updateChangeCount(.done)
        }
    }

    private func disableAutomaticSubstitutions(_ textView: UITextView) {
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        applyProseChecking()
    }

    /// Whether the system may check spelling and grammar here: writing only
    /// (Markdown and plain text, not data files such as CSV or PEM), never
    /// code, and not while large-document mode pauses the extras (as on the Mac).
    var proseCheckingApplies: Bool {
        let language = document.language.language
        return writingLargeReason == nil && SpellScope.isProse(language)
            && SpellScope.checks(language: language, fileName: document.fileURL.lastPathComponent)
    }

    /// Spelling and grammar underlines from the system's checker, by the
    /// settings and `proseCheckingApplies`. Autocorrect and the smart
    /// substitutions stay off. UITextView marks the whole document: in
    /// Markdown that includes fenced code and markup (the Mac skips those).
    func applyProseChecking() {
        let on = proseCheckingApplies
        let spelling: UITextSpellCheckingType = on && AppSettings.checkSpellingWhileTyping ? .yes : .no
        var changed = textView.spellCheckingType != spelling
        textView.spellCheckingType = spelling
        if #available(iOS 27.0, *) {
            let grammar: UITextGrammarCheckingType = on && AppSettings.checkGrammarInProse ? .yes : .no
            changed = changed || textView.grammarCheckingType != grammar
            textView.grammarCheckingType = grammar
        }
        if changed, textView.isFirstResponder { textView.reloadInputViews() }
    }

    @objc func toggleCheckSpelling() { AppSettings.checkSpellingWhileTyping.toggle() }
    @objc func toggleCheckGrammar() { AppSettings.checkGrammarInProse.toggle() }

    func textViewDidBeginEditing(_ textView: UITextView) {
        disableAutomaticSubstitutions(textView)
        hideKeyboardButton.isHidden = false
        contextBar?.refreshStates()
    }
    func textViewDidEndEditing(_ textView: UITextView) { hideKeyboardButton.isHidden = true }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard textView === self.textView else { return UIMenu(children: suggestedActions) }
        var actions: [UIMenuElement] = []
        if document.language.language == .markdown {
            let html = UIAction(title: String(localized: "Copy as HTML")) { [weak self] _ in
                self?.copyMarkdown(rich: false, selection: range)
            }
            html.accessibilityIdentifier = "editor.copyHTML"
            let rich = UIAction(title: String(localized: "Copy as Rich Text")) { [weak self] _ in
                self?.copyMarkdown(rich: true, selection: range)
            }
            rich.accessibilityIdentifier = "editor.copyRichText"
            actions.append(contentsOf: [html, rich])
        }
        if canInlineAssist(.explain, selection: range) {
            let explain = UIAction(title: String(localized: "Explain Selection"), image: UIImage(systemName: "questionmark.bubble")) { [weak self] _ in
                self?.inlineAssist(.explain, selection: range)
            }
            explain.accessibilityIdentifier = "ask.explainSelection"
            actions.append(explain)
        }
        if canInlineAssist(.rewrite, selection: range) {
            let rewrite = UIAction(title: String(localized: "Rewrite Selection"), image: UIImage(systemName: "pencil.line")) { [weak self] _ in
                self?.inlineAssist(.rewrite, selection: range)
            }
            rewrite.accessibilityIdentifier = "ask.rewriteSelection"
            actions.append(rewrite)
        }
        let states = textToolStates(selection: range)
        if states.explain {
            let action = UIAction(title: String(localized: "Explain Regex")) { [weak self] _ in
                guard let self, self.textView.selectedRange == range else { return }
                self.explainRegex()
            }
            action.accessibilityIdentifier = "tools.explainRegex"
            actions.append(action)
        }
        if states.decode {
            let action = UIAction(title: String(localized: "Decode Selection")) { [weak self] _ in
                guard let self, self.textView.selectedRange == range else { return }
                self.decodeSelection()
            }
            action.accessibilityIdentifier = "tools.decode"
            actions.append(action)
        }
        if canFindTodos {
            let action = UIAction(title: String(localized: "Find TODOs")) { [weak self] _ in self?.findTodos() }
            action.accessibilityIdentifier = "tools.findTodos"
            actions.append(action)
        }
        var menus = suggestedActions
        menus.append(lineEditMenu())
        if !actions.isEmpty {
            menus.append(UIMenu(title: String(localized: "Cedric"), options: .displayInline, children: actions))
        }
        return UIMenu(children: menus)
    }

    /// The hide-keyboard button, Esc and ⌘. on a hardware keyboard (and
    /// still the interactive drag down).
    @objc func hideKeyboard() {
        textView.resignFirstResponder()
        hideKeyboardButton.isHidden = true
    }

    override var keyCommands: [UIKeyCommand]? {
        if focusOn {
            // Esc leaves Focus Preview (nothing else wants it there).
            let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(exitFocusPreview))
            esc.wantsPriorityOverSystemBehavior = true
            return [esc]
        }
        let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(hideKeyboard))
        let dot = UIKeyCommand(title: String(localized: "Hide Keyboard"), action: #selector(hideKeyboard), input: ".", modifierFlags: .command)
        let quickly = UIKeyCommand(title: String(localized: "Open Quickly…"), action: #selector(openQuickly), input: "o", modifierFlags: [.command, .alternate])
        // Esc stays with find and other system uses when they want it.
        esc.wantsPriorityOverSystemBehavior = false
        return [esc, dot, quickly]
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        scheduleWritingUpdate(center: false)
        scheduleEditorHighlights()
        contextBar?.refreshInlineSelectionStates()
        scheduleStatisticsUpdate()
        updateStatus()
        fadeOwlNearCaret()
        askModel?.scheduleScopeRefresh()
        // Find's Next moves the selection with the find bar up. That is the
        // "click next" jump: show the line number it landed on.
        guard textView.findInteraction?.isFindNavigatorVisible == true else { return }
        scheduleWritingUpdate(center: true)
        let line = lineIndex.line(containing: min(textView.selectedRange.location, lineIndex.length)) + 1
        jumpShowsLineNumbers = true
        markedLine = line
        layoutGutter()
        // Find's field has focus during Next/Previous. Skip this while the
        // person is dragging a selection or typing in the document.
        if !AppSettings.wrap, !textView.isFirstResponder { revealRange(textView.selectedRange) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        colorizer?.scheduleViewport()
        if scrollView === textView {
            invisiblesOverlay.refresh()
            if writing.focus { scheduleWritingUpdate(center: false) }
            scheduleEditorHighlights(selectionChanged: false)
        }
        fadeOwlNearCaret()
        if scrollView === textView {
            let offsetY = scrollView.contentOffset.y
            let movedVertically = lastTextScrollOffsetY.map { $0 != offsetY } ?? false
            lastTextScrollOffsetY = offsetY
            if movedVertically, askModel?.scope == .visible {
                askModel?.scheduleScopeRefresh()
            }
        }
        if scrollView === textView, showLineNumbers {
            // An edit's own scroll waits a turn; the user's drag does not.
            if isApplyingTextEdits { scheduleGutterLayout() } else { layoutGutter() }
        }
        // A detached preview window follows the text's place, roughly.
        if scrollView === textView, !textView.isHidden, DetachedPreviews.hasPreviews(forPath: document.recoveryPath) {
            DetachedPreviews.scroll(path: document.recoveryPath, fraction: textScrollFraction)
        }
    }

    private func updateStatus() {
        let sel = textView.selectedRange
        let line = lineIndex.line(containing: min(sel.location, lineIndex.length))
        let col = sel.location - lineIndex.starts[line] + 1
        var s = String(localized: "Ln \(line + 1), Col \(col)")
        if sel.length > 0 { s += " · " + String(localized: "\(sel.length) selected") }
        if let marks = markCount { s += " · " + String(localized: "\(marks) marked") }
        statusLabel.text = s
        languageButton.setTitle(document.language.displayTitle, for: .normal)
        languageButton.menu = languageMenu()
        // A file that mixes line endings keeps each line's own: say so.
        let ending = document.mixedLineEndings ? String(localized: "\(document.lineEnding.displayName) (mixed)") : document.lineEnding.displayName
        formatButton.setTitle("\(document.encoding.displayName) · \(ending)", for: .normal)
        formatButton.menu = formatMenu()
    }

    private func scheduleWordCount() {
        wordsTimer?.invalidate()
        guard textView.textStorage.length <= TextStats.maxCounted else {
            wordCount = nil
            wordsButton.isHidden = true
            return
        }

        wordsTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = Self.immutableCopy(self.textView.textStorage) as String
                let generation = self.generation
                Task { @MainActor [weak self] in
                    let count = await Task.detached(priority: .utility) {
                        let ns = text as NSString
                        return TextStats.count(ns, range: NSRange(location: 0, length: ns.length))
                    }.value
                    guard let self else { return }
                    guard self.generation == generation else {
                        self.scheduleWordCount()
                        return
                    }
                    self.wordCount = count?.words
                    self.wordCountGeneration = count == nil ? nil : generation
                    if let words = count?.words {
                        self.wordsButton.setTitle(localizedWordCount(words), for: .normal)
                    }
                    self.wordsButton.isHidden = count == nil
                    self.view.setNeedsLayout()
                }
            }
        }
    }

    func commitDailyWords() {
        dailyTimer?.invalidate()
        dailyTimer = nil
        countDailyWords(baseline: false)
    }

    func dailyWordsSaved() {
        commitDailyWords()
    }

    private func countDailyWords(baseline: Bool, dropAfter: Bool = false) {
        let key = dailyKey
        let storage = textView.textStorage
        if baseline {
            dailyBaselineArm &+= 1
            dailyBaselinePending = false
            dailyDropAfterBaseline = false
            dailyPendingWords = []
        }
        guard storage.length <= dailyWordCountLimit else {
            dailyBaselineArm &+= 1
            dailyBaselinePending = false
            dailyDropAfterBaseline = false
            dailyPendingWords = []
            wordCount = nil
            wordCountGeneration = nil
            dailyWords.drop(key)
            return
        }
        if wordCountGeneration == generation, let cached = wordCount {
            record(words: cached, baseline: baseline, dropAfter: dropAfter)
            return
        }
        if baseline && storage.length > Self.dailyImmediateLimit {
            // A long text is counted off the main thread, from a copy.
            dailyWords.drop(key)
            dailyBaselinePending = true
            let text = Self.immutableCopy(storage)
            let arm = dailyBaselineArm
            let counter = dailyWords
            dailyQueue.async { [self] in
                let words = TextStats.count(text, range: NSRange(location: 0, length: text.length))?.words
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.dailyBaselineArm == arm, counter === self.dailyWords else { return }
                        self.dailyBaselinePending = false
                        if let words { counter.rebaseOriginal(key: key, original: words) }
                        else { counter.drop(key) }
                        for words in self.dailyPendingWords.dropFirst() { counter.note(key: key, words: words) }
                        self.dailyPendingWords = []
                        if self.dailyDropAfterBaseline { counter.drop(key); self.dailyDropAfterBaseline = false }
                    }
                }
            }
            return
        }
        let words = TextStats.count(storage.string as NSString, range: NSRange(location: 0, length: storage.length))?.words
        record(words: words, baseline: baseline, dropAfter: dropAfter)
    }

    private func record(words: Int?, baseline: Bool, dropAfter: Bool) {
        if baseline { dailyWords.rebaseline(key: dailyKey, words: words) }
        else if dailyBaselinePending {
            if let words {
                if dailyPendingWords.isEmpty { dailyWords.note(key: dailyKey, words: words) }
                dailyPendingWords.append(words)
            } else {
                dailyWords.drop(dailyKey)
                dailyPendingWords = []
            }
        } else { dailyWords.note(key: dailyKey, words: words) }
        if dropAfter {
            if dailyBaselinePending { dailyDropAfterBaseline = true }
            else { dailyWords.drop(dailyKey) }
        }
    }

    func stopDailyWordTracking() {
        dailyTimer?.invalidate()
        dailyTimer = nil
        countDailyWords(baseline: false, dropAfter: true)
    }

    deinit {
        dailyTimer?.invalidate()
    }

    private func updateWordsVisibility() {
        let fits = wordCount != nil && wordsButton.bounds.width > 1
        wordsButton.alpha = fits ? 1 : 0
        wordsButton.accessibilityElementsHidden = !fits
        wordsButton.isUserInteractionEnabled = fits
    }

    func textToolStates(selection: NSRange) -> (explain: Bool, decode: Bool) {
        if let cache = toolStatesCache, cache.generation == generation, cache.selection == selection {
            return (cache.explain, cache.decode)
        }
        let states: (explain: Bool, decode: Bool)
        if let text = selectedTextForTools(selection) {
            states = (RegexExplain.looksLikeRegex(text), Decode.decode(text) != nil)
        } else {
            states = (false, false)
        }
        toolStatesCache = (generation, selection, states.explain, states.decode)
        return states
    }

    private func selectedTextForTools(_ range: NSRange) -> String? {
        let length = textView.textStorage.length
        guard range.location != NSNotFound, range.location >= 0, range.length > 0, range.length <= 64 * 1024,
              range.location <= length, range.length <= length - range.location else { return nil }
        return (textView.textStorage.string as NSString).substring(with: range)
    }

    private var canFindTodos: Bool { (1...4_000_000).contains(textView.textStorage.length) }

    @objc func explainRegex() {
        guard let text = selectedTextForTools(textView.selectedRange), RegexExplain.looksLikeRegex(text) else { return }
        presentTool(ToolResultViewController(title: String(localized: "Regex, explained"), body: RegexExplain.explain(text).text), bySelection: true)
    }

    @objc func decodeSelection() {
        guard let text = selectedTextForTools(textView.selectedRange), let result = Decode.decode(text) else { return }
        presentTool(ToolResultViewController(title: result.title, body: result.body), bySelection: true)
    }

    @objc func findTodos() {
        guard canFindTodos else { return }
        let text = textView.textStorage.string
        let language = document.language.language.rawValue
        let generation = generation
        Task { @MainActor [weak self] in
            let items = await Task.detached(priority: .userInitiated) { Todos.find(text, language: language) }.value
            guard let self, self.generation == generation else { return }
            self.presentTool(TodoListViewController(items: items) { [weak self] line in
                self?.revealLine(line)
            }, waitForPresentation: true, isValid: { [weak self] in
                self?.generation == generation
            })
        }
    }

    @objc func showStatistics() {
        commitDailyWords()
        let vc = StatisticsViewController(text: textView.textStorage.string, selection: textView.selectedRange,
                                          filePath: document.fileURL.path, documentLines: lineIndex.lineCount,
                                          dailyWords: dailyWords)
        presentTool(vc, anchor: wordsButton.isHidden || wordsButton.alpha == 0 ? nil : wordsButton)
    }

    private func scheduleStatisticsUpdate() {
        guard statisticsSheet != nil else { return }
        statisticsTimer?.invalidate()
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let statistics = self.statisticsSheet else { return }
                statistics.update(text: self.textView.textStorage.string, selection: self.textView.selectedRange,
                                  documentLines: self.lineIndex.lineCount)
            }
        }
    }

    private func presentTool(_ content: UIViewController, bySelection: Bool = false, anchor: UIView? = nil,
                             waitForPresentation: Bool = false, isValid: @escaping () -> Bool = { true }) {
        let nav = UINavigationController(rootViewController: content)
        nav.preferredContentSize = CGSize(width: 440, height: 420)
        if traitCollection.userInterfaceIdiom == .pad && traitCollection.horizontalSizeClass == .regular {
            nav.modalPresentationStyle = .popover
            if let popover = nav.popoverPresentationController {
                let source = anchor ?? textView
                popover.sourceView = source
                if bySelection, let range = textView.selectedTextRange {
                    let rect = textView.firstRect(for: range).intersection(textView.bounds)
                    popover.sourceRect = rect.isNull || rect.isEmpty ? textView.bounds : rect
                } else {
                    popover.sourceRect = source.bounds
                }
            }
        } else {
            nav.modalPresentationStyle = .pageSheet
            nav.sheetPresentationController?.detents = content is ToolResultViewController ? [.medium()] : [.medium(), .large()]
        }
        Task { @MainActor [weak self] in
            // Waiting behind another sheet (Settings, Ask Cedric) gives up
            // after about 5 s, so a late list doesn't pop up much later.
            var waits = 0
            while let self, isValid(), waits < 50,
                  self.viewIfLoaded?.window != nil || self.presentedViewController?.viewIfLoaded?.window != nil {
                if let presented = self.presentedViewController {
                    if presented.isBeingPresented || presented.isBeingDismissed {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if let previous = presented as? UINavigationController,
                       previous.viewControllers.first is ToolResultViewController ||
                       previous.viewControllers.first is TodoListViewController ||
                       previous.viewControllers.first is StatisticsViewController {
                        await withCheckedContinuation { continuation in
                            presented.dismiss(animated: true) { continuation.resume() }
                        }
                        continue
                    }
                    guard waitForPresentation else { return }
                    waits += 1
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                if let statistics = content as? StatisticsViewController {
                    statistics.update(text: self.textView.textStorage.string, selection: self.textView.selectedRange,
                                      documentLines: self.lineIndex.lineCount)
                    self.statisticsSheet = statistics
                }
                self.present(nav, animated: true)
                return
            }
        }
    }

    private func languageMenu() -> UIMenu {
        let current = document.language.language
        let items = Language.allCases.sorted { $0.displayName < $1.displayName }.map { l in
            UIAction(title: l.displayName, state: l == current ? .on : .off) { [weak self] _ in self?.setLanguage(l) }
        }
        return UIMenu(title: String(localized: "Language"), image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), children: items)
    }

    private func formatMenu() -> UIMenu {
        let enc = TextEncoding.allCases.map { e in
            UIAction(title: e.displayName, state: e == document.encoding ? .on : .off) { [weak self] _ in self?.setEncoding(e) }
        }
        let ends = LineEnding.allCases.map { le in
            UIAction(title: le.displayName, state: le == document.lineEnding ? .on : .off) { [weak self] _ in
                self?.setLineEnding(le)
            }
        }
        // They rewrite the whole file: not while it can't be edited.
        if !editGate.isEditable {
            for a in enc + ends where a.state != .on { a.attributes = .disabled }
        }
        return UIMenu(title: String(localized: "Encoding and Line Endings"), image: UIImage(systemName: "doc.text"), children: [
            UIMenu(title: String(localized: "Save As Encoding"), options: .displayInline, children: enc),
            UIMenu(title: String(localized: "Line Endings"), options: .displayInline, children: ends),
        ])
    }

    func setLanguage(_ l: Language) {
        let oldHasPreview = hasEditorPreview
        let newHasPreview = l == .markdown || l == .csv
        if l != document.language.language, previewOn, !(oldHasPreview && newHasPreview) {
            if focusOn { exitFocusPreview() }
            if previewOn { togglePreview() }
        }
        document.language.choose(l)
        colorizer.setLanguage(l)
        applySettings()
        updateStatus()
        updateBarButtons()
        updatePreviewHeader()
        if previewOn, hasEditorPreview {
            // Markdown <-> CSV/TSV keeps the preview open and swaps the renderer.
            refreshPreview()
            layoutPreview()
        }
        updateContextBar()
        scheduleOwl()
    }

    /// Asks first (it rewrites the whole file when saved); Undo puts it back.
    private func setEncoding(_ e: TextEncoding) {
        guard e != document.encoding, editGate.isEditable else { return }
        guard TextCodec.canEncode(textView.text, as: e) else {
            toast(String(localized: "Some characters can’t be saved as \(e.displayName)."))
            return
        }
        let change = FormatChange(from: currentFormat, to: .init(encoding: e, lineEnding: document.lineEnding,
                                                                 mixedLineEndings: document.mixedLineEndings))
        confirmFormatChange(change, title: String(localized: "Save \(document.displayName) as \(e.displayName)?"),
                            message: String(localized: "When it is saved, the whole file is rewritten in \(e.displayName). You can undo this with Undo."))
    }

    private func setLineEnding(_ le: LineEnding) {
        guard le != document.lineEnding || document.mixedLineEndings, editGate.isEditable else { return }
        let change = FormatChange(from: currentFormat, to: .init(encoding: document.encoding, lineEnding: le))
        let message = document.mixedLineEndings
            ? String(localized: "This file mixes line endings. When it is saved, every line ends with \(le.displayName). You can undo this with Undo.")
            : String(localized: "When it is saved, every line ending in the file is rewritten as \(le.displayName). You can undo this with Undo.")
        confirmFormatChange(change, title: String(localized: "Use \(le.displayName) line endings?"), message: message)
    }

    private var currentFormat: FormatChange.Format {
        .init(encoding: document.encoding, lineEnding: document.lineEnding, mixedLineEndings: document.mixedLineEndings)
    }

    private func confirmFormatChange(_ change: FormatChange, title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: String(localized: "Change"), style: .default) { [weak self] _ in
            self?.applyFormat(change, actionName: String(localized: "Change Encoding or Line Endings"))
        })
        present(a, animated: true)
    }

    /// Sets the encoding and line ending as one undoable step.
    func applyFormat(_ change: FormatChange, actionName: String) {
        document.encoding = change.to.encoding
        document.lineEnding = change.to.lineEnding
        document.mixedLineEndings = change.to.mixedLineEndings
        updateDocumentChangeCount()
        if let um = textView.undoManager {
            um.registerUndo(withTarget: self) { $0.applyFormat(change.undo, actionName: actionName) }
            um.setActionName(actionName)
        }
        updateStatus()
        updateUndoItems()
    }

    // MARK: Settings and theme

    @objc private func settingsChanged() {
        let lineNumbers = AppSettings.lineNumbers
        if lastLineNumbersSetting && !lineNumbers {
            jumpShowsLineNumbers = false
            markedLine = nil
        }
        lastLineNumbersSetting = lineNumbers
        applySettings()
        UIMenuSystem.main.setNeedsRebuild()
        updateBarButtons()
        scheduleOwl()
        showHint()
    }

    private func applySettings() {
        let dark = traitCollection.userInterfaceStyle == .dark
        palette = AppSettings.theme.palette(systemIsDark: dark)
        invisiblesOverlay.color = UIColor(hex: palette.invisibles)
        invisiblesOverlay.isHidden = !AppSettings.showInvisibles
        updateContextBar()
        contextBar?.applyPalette(palette)
        applyBarStyle()
        let bg = UIColor(hex: palette.background)
        textView.backgroundColor = bg
        view.backgroundColor = bg
        textView.tintColor = UIColor(hex: palette.caret)
        textView.keyboardAppearance = palette.isDark ? .dark : .light
        statusBar.backgroundColor = UIColor(hex: palette.statusBar)
        statusLabel.textColor = UIColor(hex: palette.gutterForeground)
        owlSprite.onDark = palette.isDark
        let font = AppSettings.font(for: document.language.language, traits: traitCollection)
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
        }
        textView.typingAttributes[.foregroundColor] = UIColor(hex: palette.foreground)
        applyTabStops()
        applyWrap()
        applyProseChecking()
        invisiblesOverlay.refresh()
        colorizer?.setPalette(palette)
        scheduleWritingUpdate()
        scheduleEditorHighlights()
        refreshPreview()
    }

    func writingModeMenu() -> UIMenu {
        let typewriter = UIAction(title: String(localized: "Typewriter Scrolling"), state: writing.typewriter ? .on : .off) { [weak self] _ in
            self?.toggleTypewriter()
        }
        let focus = UIAction(title: String(localized: "Focus"), state: writing.focus ? .on : .off) { [weak self] _ in
            self?.toggleWritingFocus()
        }
        let paragraph = UIAction(title: String(localized: "Focus on Paragraph"), state: AppSettings.focusUnit == .paragraph ? .on : .off) { _ in
            AppSettings.focusUnit = .paragraph
        }
        let sentence = UIAction(title: String(localized: "Focus on Sentence"), state: AppSettings.focusUnit == .sentence ? .on : .off) { _ in
            AppSettings.focusUnit = .sentence
        }
        return UIMenu(title: String(localized: "Writing Mode"), children: [typewriter, focus,
            UIMenu(options: .displayInline, children: [paragraph, sentence])])
    }

    @objc func toggleTypewriter() {
        writing.typewriter.toggle()
        updateWritingInset()
        scheduleWritingUpdate()
        if writing.typewriter, let reason = writingLargeReason { showWritingPaused(reason) }
    }

    @objc func toggleWritingFocus() {
        writing.focus.toggle()
        if !writing.focus { clearFocusRendering() }
        scheduleWritingUpdate()
        if writing.focus, let reason = writingLargeReason { showWritingPaused(reason) }
    }

    @objc func focusParagraph() { AppSettings.focusUnit = .paragraph }
    @objc func focusSentence() { AppSettings.focusUnit = .sentence }

    override func validate(_ command: UICommand) {
        super.validate(command)
        switch command.action {
        case #selector(toggleTypewriter): command.state = writing.typewriter ? .on : .off
        case #selector(toggleWritingFocus): command.state = writing.focus ? .on : .off
        case #selector(toggleInvisibles): command.state = AppSettings.showInvisibles ? .on : .off
        case #selector(toggleCheckSpelling): command.state = AppSettings.checkSpellingWhileTyping ? .on : .off
        case #selector(toggleCheckGrammar): command.state = AppSettings.checkGrammarInProse ? .on : .off
        case #selector(focusParagraph): command.state = AppSettings.focusUnit == .paragraph ? .on : .off
        case #selector(focusSentence): command.state = AppSettings.focusUnit == .sentence ? .on : .off
        case #selector(indentUsingSpaces(_:)), #selector(indentUsingTabs(_:)), #selector(tabWidthMenu(_:)):
            validateIndentationCommand(command)
        case #selector(toggleBookmarkMenu(_:)): command.title = bookmarkLineTitle
        default: break
        }
    }

    private func updateWritingInset() {
        let active = writing.typewriter && writingLargeReason == nil
        if writingBaseInset == nil {
            guard active else { return }
            writingBaseInset = textView.contentInset
        }
        guard let original = writingBaseInset else { return }
        let base = max(0, textView.adjustedContentInset.bottom - writingInset)
        let height = max(0, textView.bounds.height - textView.adjustedContentInset.top - base)
        let line = textView.font?.lineHeight ?? 20
        let extra = active ? CGFloat(Typewriter.bottomInset(visibleHeight: Double(height), lineHeight: Double(line))) : 0
        guard abs(extra - writingInset) > 0.5 else { return }
        var inset = original
        inset.bottom += extra
        writingInset = extra
        textView.contentInset = inset
        if extra == 0 { writingBaseInset = nil }
    }

    private func showWritingPaused(_ reason: LargeDocument.Reason) {
        switch reason {
        case .longLine: toast(String(localized: "Very long lines: colouring, spell check, the owl and Writing Mode are paused for speed."))
        case .size: toast(String(localized: "Large file: colouring, spell check, the owl and Writing Mode are paused for speed."))
        }
    }

    /// Re-checks the large-document pause after the whole text was replaced
    /// (the Mac leaves large mode only then, not while typing a long line shorter).
    private func reevaluateWritingLarge() {
        let reason = LargeDocument.reason(for: lineIndex)
        guard reason != writingLargeReason else { return }
        writingLargeReason = reason
        clearFocusRendering()
        updateWritingInset()
        applyProseChecking()
        if reason == nil { scheduleWritingUpdate() }
        else if !writing.isOff { showWritingPaused(reason!) }
    }

    /// Takes the dimming off the range painted last, and `current` if given
    /// (clamped to the text, so an edit that moved things cannot leave paint behind).
    private func clearFocusRendering(also current: NSRange? = nil) {
        defer { focusPaintedRange = nil; focusCache = nil; focusPalette = nil }
        guard let layout = textView.textLayoutManager, let manager = layout.textContentManager else { return }
        let length = textView.textStorage.length
        var spans = [focusPaintedRange, current].compactMap { $0 }
            .map { NSIntersectionRange($0, NSRange(location: 0, length: length)) }.filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        if spans.count == 2, NSMaxRange(spans[0]) >= spans[1].location {
            spans = [NSUnionRange(spans[0], spans[1])]
        }
        let origin = layout.documentRange.location
        for span in spans {
            if let a = manager.location(origin, offsetBy: span.location),
               let b = manager.location(a, offsetBy: span.length),
               let range = NSTextRange(location: a, end: b) {
                layout.removeRenderingAttribute(.foregroundColor, for: range)
            } else {
                layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
                break
            }
        }
    }

    private func scheduleWritingUpdate(center: Bool = true) {
        guard !writing.isOff, writingLargeReason == nil else { return }
        writingCenterPending = writingCenterPending || center
        guard !writingUpdatePending else { return }
        writingUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.writingUpdatePending = false
            let center = self.writingCenterPending
            self.writingCenterPending = false
            self.updateWriting(center: center)
        }
    }

    func updateWriting(center: Bool = true) {
        guard writingLargeReason == nil, textView.markedTextRange == nil else { return }
        if writing.typewriter && center {
            updateWritingInset()
            if !textView.isTracking, !textView.isDragging, let position = textView.selectedTextRange?.end {
                // Lay out up to the caret only when it is near the viewport:
                // a far-away caret would otherwise lay out everything between.
                if let layout = textView.textLayoutManager, let manager = layout.textContentManager,
                   let viewport = layout.textViewportLayoutController.viewportRange {
                    let start = manager.offset(from: layout.documentRange.location, to: viewport.location)
                    let viewportLength = manager.offset(from: viewport.location, to: viewport.endLocation)
                    let relative = NSMaxRange(textView.selectedRange) - start
                    if relative >= -3_000, relative <= viewportLength + 3_000,
                       let location = manager.location(viewport.location, offsetBy: relative) {
                        layout.ensureLayout(for: NSTextRange(location: location))
                    }
                    layout.textViewportLayoutController.layoutViewport()
                }
                let rect = textView.caretRect(for: position)
                let top = textView.adjustedContentInset.top
                let baseBottom = max(0, textView.adjustedContentInset.bottom - writingInset)
                let height = max(0, textView.bounds.height - top - baseBottom)
                if let target = Typewriter.scrollTarget(caretMidY: Double(rect.midY + top), visibleHeight: Double(height),
                    currentY: Double(textView.contentOffset.y + top), documentHeight: Double(textView.contentSize.height + top),
                    bottomInset: Double(writingInset)) {
                    let minY = -top
                    let maxY = max(minY, textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
                    textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: min(maxY, max(minY, CGFloat(target) - top))), animated: false)
                }
            }
        }
        guard writing.focus, let layout = textView.textLayoutManager,
              let manager = layout.textContentManager,
              let visible = editorVisibleRange() else { return }
        let text = textView.textStorage.string as NSString
        let focus = FocusRange.range(AppSettings.focusUnit, in: text, caret: textView.selectedRange.location)
        let contrast = UIAccessibility.isDarkerSystemColorsEnabled
        let key = [focus.location, focus.length, visible.location, visible.length, text.length, editCount, contrast ? 1 : 0]
        if focusCache == key, focusPalette == palette.foreground { return }
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let viewportStart = manager.offset(from: layout.documentRange.location, to: viewport.location)
        guard let start = manager.location(viewport.location, offsetBy: visible.location - viewportStart) else { return }
        clearFocusRendering(also: visible)
        // Increase Contrast dims less, so the unfocused text stays readable.
        let color = UIColor(hex: palette.foreground).withAlphaComponent(contrast ? 0.6 : 0.4)
        for range in FocusRange.dimmed(visible: visible, focus: focus) {
            guard let a = manager.location(start, offsetBy: range.location - visible.location),
                  let b = manager.location(a, offsetBy: range.length),
                  let textRange = NSTextRange(location: a, end: b) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
        focusPaintedRange = visible
        focusCache = key
        focusPalette = palette.foreground
    }

    func editorVisibleRange() -> NSRange? {
        guard let layout = textView.textLayoutManager, let manager = layout.textContentManager else { return nil }
        if let visible = SyntaxColorizer.visibleRange(textView), visible.length > 0 { return visible }
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return nil }
        let start = manager.offset(from: layout.documentRange.location, to: viewport.location)
        let length = manager.offset(from: viewport.location, to: viewport.endLocation)
        return NSRange(location: start, length: length)
    }

    @objc private func highlightContrastChanged() {
        highlightKey = nil
        focusCache = nil
        scheduleWritingUpdate(center: false)
        scheduleEditorHighlights(selectionChanged: false)
    }

    private func clearEditorHighlights() {
        if let layout = textView.textLayoutManager {
            for paint in highlightPainted {
                layout.removeRenderingAttribute(.backgroundColor, for: paint.textRange)
            }
        }
        highlightPainted = []
        highlightKey = nil
        highlightBracketKey = nil
        highlightBrackets = []
        highlightOccurrenceRanges = []
        highlightMarkRanges = []
    }

    private func scheduleEditorHighlights(selectionChanged: Bool = true) {
        highlightTimer?.invalidate()
        if selectionChanged { refreshEditorHighlights(includeOccurrences: false) }
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEditorHighlights() }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    // MARK: Mark All

    /// Mark counts are kept up to date while typing only up to this size
    /// (UTF-16 units, the Mac's `markRecountLimit`); a bigger document is
    /// counted when Mark All runs.
    static let markRecountLimit = 2_000_000

    var hasMarks: Bool { markNeedle != nil }

    /// The status line as shown (for tests and VoiceOver).
    var statusText: String { statusLabel.text ?? "" }

    /// Mark All: every occurrence of the selection, or of the word under
    /// the caret (Occurrences.needle: literal, whole word as highlighting
    /// does), until Clear Marks. Only the needle is kept; the visible text
    /// is searched again after edits. Nothing to mark: nothing happens.
    @objc func markAll() {
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length,
              let needle = Occurrences.needle(selection: selection, in: text) else { return }
        let had = hasMarks
        markCountTimer?.invalidate()
        markCountTimer = nil
        markNeedle = needle
        markCount = Occurrences.count(needle, in: text)
        refreshEditorHighlights()
        updateStatus()
        if !had { UIMenuSystem.main.setNeedsRebuild() }
    }

    @objc func clearMarks() {
        guard hasMarks else { return }
        markCountTimer?.invalidate()
        markCountTimer = nil
        markNeedle = nil
        markCount = nil
        refreshEditorHighlights()
        updateStatus()
        UIMenuSystem.main.setNeedsRebuild()
    }

    /// After an edit: count the marks again a moment later (documents up
    /// to `markRecountLimit`; a bigger one loses its count, not its marks).
    private func scheduleMarkRecount() {
        guard let needle = markNeedle else { return }
        markCountTimer?.invalidate()
        markCountTimer = nil
        guard textView.textStorage.length <= Self.markRecountLimit else {
            if markCount != nil {
                markCount = nil
                updateStatus()
            }
            return
        }
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.markNeedle == needle else { return }
                self.markCountTimer = nil
                self.markCount = Occurrences.count(needle, in: self.textView.textStorage.string as NSString)
                self.updateStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        markCountTimer = timer
    }

    private func markActions() -> [UIAction] {
        let mark = UIAction(title: String(localized: "Mark All"), image: UIImage(systemName: "highlighter")) { [weak self] _ in
            self?.markAll()
        }
        mark.accessibilityIdentifier = "editor.markAll"
        let clear = UIAction(title: String(localized: "Clear Marks"), image: UIImage(systemName: "eraser")) { [weak self] _ in
            self?.clearMarks()
        }
        clear.accessibilityIdentifier = "editor.clearMarks"
        if !hasMarks { clear.attributes = .disabled }
        return [mark, clear]
    }

    /// Paints Mark All's marks, the matching bracket pair (always, as on
    /// the Mac) and, with "Highlight occurrences" on, the other occurrences
    /// of the word or selection in view. `includeOccurrences: false` keeps the occurrences
    /// as they were (a selection change: the debounced pass catches up).
    func refreshEditorHighlights(includeOccurrences: Bool = true) {
        guard textView.markedTextRange == nil,
              let layout = textView.textLayoutManager, let manager = layout.textContentManager,
              let visible = editorVisibleRange(),
              let viewport = layout.textViewportLayoutController.viewportRange else { clearEditorHighlights(); return }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { clearEditorHighlights(); return }
        let wantOccurrences = AppSettings.highlightOccurrences
        let contrast = UIAccessibility.isDarkerSystemColorsEnabled
        let key = HighlightKey(values: [selection.location, selection.length, visible.location, visible.length, generation, editCount,
                                        wantOccurrences ? 1 : 0],
                               mark: markNeedle)
        let sameLook = highlightPalette == palette.findMatch && highlightCaretColor == palette.caret && highlightContrast == contrast
        if includeOccurrences, sameLook, highlightKey == key { return }
        let bracketKey = [selection.location, selection.length, generation]
        if highlightBracketKey != bracketKey {
            highlightBracketKey = bracketKey
            highlightBrackets = []
            if selection.length == 0, let (first, second) = AutoEdit.matchingBracket(in: text, caret: selection.location) {
                highlightBrackets = [first, second]
            }
        }
        var occurrences = highlightOccurrenceRanges
        var marks = highlightMarkRanges
        if includeOccurrences {
            occurrences = []
            marks = []
            let start = max(0, visible.location - 2_000)
            let end = min(text.length, NSMaxRange(visible) + 2_000)
            let searched = NSRange(location: start, length: end - start)
            if let markNeedle {
                marks = Occurrences.find(markNeedle, in: text, range: searched)
                    .map { NSIntersectionRange($0, visible) }.filter { $0.length > 0 }
            }
            if wantOccurrences, let needle = Occurrences.needle(selection: selection, in: text) {
                let found = Occurrences.find(needle, in: text, range: searched)
                let source = selection.length == 0 ? Occurrences.word(at: selection.location, in: text) : selection
                if found.count >= 2 || source.map({ !found.contains($0) }) == true {
                    occurrences = found.filter { $0 != selection }.map { NSIntersectionRange($0, visible) }.filter { $0.length > 0 }
                }
            }
            highlightOccurrenceRanges = occurrences
            highlightMarkRanges = marks
            highlightKey = key
        }
        if !wantOccurrences { occurrences = [] }
        if markNeedle == nil { marks = [] }
        // An occurrence that is also a mark keeps the mark's (full) colour,
        // as the Mac's half-alpha layer over a mark does.
        if !marks.isEmpty { occurrences = occurrences.filter { !marks.contains($0) } }
        let brackets = highlightBrackets.map { NSIntersectionRange($0, visible) }.filter { $0.length > 0 }
        let wanted = marks.map { ($0, HighlightKind.mark) } + occurrences.map { ($0, HighlightKind.occurrence) }
            + brackets.map { ($0, HighlightKind.bracket) }
        let unchanged = highlightPainted.count == wanted.count
            && zip(highlightPainted, wanted).allSatisfy { $0.range == $1.0 && $0.kind == $1.1 }
        let previousKey = highlightKey
        let canDiffBrackets = !includeOccurrences && sameLook && previousKey.map {
            Array($0.values[2...]) == Array(key.values[2...]) && $0.mark == key.mark
        } == true
        func color(_ kind: HighlightKind) -> UIColor {
            switch kind {
            // The theme's find colour is opaque: marks are already at full
            // strength, with or without Increase Contrast.
            case .mark: UIColor(hex: palette.findMatch)
            case .occurrence: UIColor(hex: palette.findMatch).withAlphaComponent(contrast ? 0.85 : 0.55)
            case .bracket: UIColor(hex: palette.caret).withAlphaComponent(contrast ? 0.65 : 0.3)
            }
        }
        if !unchanged && canDiffBrackets {
            let oldBrackets = highlightPainted.filter(\.bracket)
            let removed = oldBrackets.filter { !brackets.contains($0.range) }
            let added = brackets.filter { range in !oldBrackets.contains { $0.range == range } }
            let start = manager.offset(from: layout.documentRange.location, to: viewport.location)
            func paint(_ range: NSRange, kind: HighlightKind) -> HighlightPaint? {
                guard let a = manager.location(viewport.location, offsetBy: range.location - start),
                      let b = manager.location(a, offsetBy: range.length),
                      let r = NSTextRange(location: a, end: b) else { return nil }
                layout.addRenderingAttribute(.backgroundColor, value: color(kind), for: r)
                return HighlightPaint(range: range, textRange: r, kind: kind)
            }
            for old in removed {
                layout.removeRenderingAttribute(.backgroundColor, for: old.textRange)
                // Put back what the bracket covered, marks under occurrences.
                for (range, kind) in wanted where kind != .bracket {
                    let overlap = NSIntersectionRange(old.range, range)
                    if overlap.length > 0 { _ = paint(overlap, kind: kind) }
                }
            }
            highlightPainted.removeAll { paint in paint.bracket && removed.contains { $0.range == paint.range } }
            for range in added {
                if let painted = paint(range, kind: .bracket) { highlightPainted.append(painted) }
            }
        } else if !unchanged || !sameLook {
            // A handful of ranges: take all the paint off and put it back,
            // marks, then occurrences, then brackets, so a bracket on top
            // of one stays visible.
            for paint in highlightPainted { layout.removeRenderingAttribute(.backgroundColor, for: paint.textRange) }
            highlightPainted = []
            let start = manager.offset(from: layout.documentRange.location, to: viewport.location)
            for (range, kind) in wanted {
                guard let a = manager.location(viewport.location, offsetBy: range.location - start),
                      let b = manager.location(a, offsetBy: range.length),
                      let r = NSTextRange(location: a, end: b) else { continue }
                layout.addRenderingAttribute(.backgroundColor, value: color(kind), for: r)
                highlightPainted.append(HighlightPaint(range: range, textRange: r, kind: kind))
            }
        }
        highlightPalette = palette.findMatch
        highlightCaretColor = palette.caret
        highlightContrast = contrast
    }

    /// The window the theme overrode, so dismissing the editor can put the
    /// document browser back on the phone's appearance. `view.window` is
    /// already nil by the time the editor has disappeared.
    private weak var themedWindow: UIWindow?

    /// Title and bar tint follow the theme. A fixed theme also sets this
    /// window's interface style; System leaves it unspecified so it tracks
    /// the phone, and never replaces the accent tint. See `EditorBarStyle`.
    private func applyBarStyle() {
        let style = EditorBarStyle.interfaceStyle(theme: AppSettings.theme, isDark: palette.isDark)
        if let window = view.window { themedWindow = window }
        EditorBarStyle.apply(navigationController: navigationController,
                             item: navigationItem,
                             window: view.window,
                             foreground: UIColor(hex: palette.foreground),
                             interfaceStyle: style)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyBarStyle()
        view.setNeedsLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if owlInRail { setOwlFrame(owlFrame, inRail: false) }
    }

    override func willMove(toParent parent: UIViewController?) {
        if parent == nil, owlInRail { setOwlFrame(owlFrame, inRail: false) }
        super.willMove(toParent: parent)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        highlightTimer?.invalidate()
        highlightTimer = nil
        clearEditorHighlights()
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            EditorBarStyle.restore(window: themedWindow)
            themedWindow = nil
        }
    }

    private func applyWrap() {
        preserveTextViewportDuringLayout {
            applyWrapWithoutMovingTextViewport()
        }
        view.setNeedsLayout()
    }

    private func applyWrapWithoutMovingTextViewport() {
        let c = textView.textContainer
        if AppSettings.wrap {
            if !c.widthTracksTextView {
                c.size = CGSize(width: max(0, textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right),
                                height: CGFloat.greatestFiniteMagnitude)
                textView.setContentOffset(CGPoint(x: -textView.adjustedContentInset.left, y: textView.contentOffset.y), animated: false)
            }
            c.widthTracksTextView = true
            textView.showsHorizontalScrollIndicator = false
            textView.alwaysBounceHorizontal = false
            textView.minimumContentWidth = 0
        } else {
            c.widthTracksTextView = false
            c.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.showsHorizontalScrollIndicator = true
            textView.alwaysBounceHorizontal = true
        }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        if showLineNumbers { layoutGutter() } else { layoutTextInsets() }
        updateUnwrappedContentSize()
    }

    /// TextKit 2 keeps a UITextView's contentSize.width at the viewport even
    /// when unwrapped fragments are much wider. Grow the scroller from the
    /// laid-out text and from a font estimate of the longest line.
    private func updateUnwrappedContentSize() {
        guard !AppSettings.wrap else { return }
        preserveTextViewportDuringLayout {
            updateUnwrappedContentSizeWithoutViewportChange()
        }
    }

    private func updateUnwrappedContentSizeWithoutViewportChange() {
        let insets = textView.textContainerInset
        var width = textView.bounds.width
        if let used = textView.textLayoutManager?.usageBoundsForTextContainer, used.width.isFinite {
            width = max(width, ceil(used.maxX + insets.left + insets.right))
        }
        let font = textView.font ?? AppSettings.font(for: document.language.language, traits: traitCollection)
        let zeroWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let alphabetWidth = ("abcdefghijklmnopqrstuvwxyz" as NSString).size(withAttributes: [.font: font]).width
        let fixedPitch = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        let charWidth = max(CGFloat(ProseFont.characterWidth(
            fixedPitch: fixedPitch,
            zeroWidth: Double(zeroWidth),
            lowercaseAlphabetWidth: Double(alphabetWidth)
        )), 1)
        // longestLine includes the newline; a little slack covers tabs.
        width = max(width, ceil(CGFloat(max(0, lineIndex.longestLine)) * charWidth + insets.left + insets.right + 8))
        textView.minimumContentWidth = width
        // UITextView/TextKit 2 replaces an infinite container width with the
        // viewport width, which wraps the line again. Pin a finite width.
        let containerWidth = max(textView.bounds.width - insets.left - insets.right, width - insets.left - insets.right)
        let c = textView.textContainer
        if abs(c.size.width - containerWidth) > 1 {
            c.size = CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        if textView.contentSize.width + 0.5 < width {
            textView.contentSize = CGSize(width: width, height: textView.contentSize.height)
        }
    }

    private func preserveTextViewportDuringLayout(_ update: () -> Void) {
        let offsetY = textView.contentOffset.y
        update()
        let inset = textView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, textView.contentSize.height + inset.bottom - textView.bounds.height)
        let y = min(max(offsetY, minY), maxY)
        guard abs(textView.contentOffset.y - y) > 0.5 else { return }
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
    }

    // MARK: Owl

    private func scheduleOwl() {
        owl.schedule { [weak self] in self?.owlSnapshot() ?? EditorOwl.Snapshot(text: "", visible: NSRange(), selection: NSRange(),
                                                                                   fileName: nil, language: .plain, generation: 0,
                                                                                   facts: OwlDocumentFacts()) }
    }

    private func owlSnapshot() -> EditorOwl.Snapshot {
        let text = (textView.textStorage.string as NSString).copy() as! NSString
        return EditorOwl.Snapshot(text: text, visible: SyntaxColorizer.visibleRange(textView) ?? NSRange(location: 0, length: text.length),
                                  selection: textView.selectedRange, fileName: document.displayName,
                                  language: document.language.language, generation: generation,
                                  facts: OwlDocumentFacts(isWholeDocument: text.length <= OwlContextWindow.byteCap,
                                                          unsavedSince: document.firstUnsavedEdit, lineEnding: document.lineEnding,
                                                          mixedLineEndings: document.mixedLineEndings,
                                                          languageIsManual: document.language.isManual,
                                                          styleCheck: AppSettings.styleCheckSettings))
    }

    /// The hints he may show: the offline ones only with the setting on;
    /// ones asked for (Check with Cedric) always.
    private var shownHints: [EditorOwl.Shown] {
        owl.hints.filter { AppSettings.owlHints || $0.hint.source != "rules" }
    }

    /// The hints changed: his badge and pose; the bubble if it is open
    /// (rules hints wait for a tap; a check you asked for opens it).
    private func showHint() {
        // A check you asked for opens his bubble, once per hint.
        if let v = owl.visible, v.hint.source != "rules", v.hint.id != autoOpenedHint {
            autoOpenedHint = v.hint.id
            bubbleOpen = true
        }
        updateOwlBadge()
        guard bubbleOpen, let shown = owl.visible, AppSettings.owlHints || shown.hint.source != "rules" else {
            bubbleOpen = false
            updateOwlBadge()
            guard !hintBar.isHidden else { return }
            UIView.animate(withDuration: 0.2) { self.hintBar.alpha = 0 } completion: { _ in
                if !self.bubbleOpen { self.hintBar.isHidden = true }
            }
            return
        }
        var fixTitle: String?
        var ignoreTitle: String?
        if shown.hint.replacement != nil, shown.hint.range != nil { fixTitle = String(localized: "Fix it") }
        if StyleCheck.isStyleHint(shown.hint.id) {
            ignoreTitle = String(localized: "Ignore")
            if shown.hint.replacement == nil { fixTitle = String(localized: "Show Me") }
        }
        if let l = RulesHintProvider.guessedLanguage(shown.hint) { fixTitle = String(localized: "Use \(l.displayName)") }
        if shown.hint.id == RulesHintProvider.saveCopyID { fixTitle = String(localized: "Save") }
        hintBar.show(shown.hint, fixTitle: fixTitle, ignoreTitle: ignoreTitle, more: shownHints.count > 1)
        if hintBar.isHidden {
            hintBar.alpha = 0
            hintBar.isHidden = false
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { self.hintBar.alpha = 1 }
    }

    /// Tap on the owl with a hint waiting: his bubble shows it.
    func openHint() {
        guard owl.visible != nil, !focusOn else { return }
        bubbleOpen = true
        showHint()
    }

    func closeHint() {
        bubbleOpen = false
        showHint()
    }

    // MARK: The owl in the corner

    private var owlInRail = false

    /// Owl coordinates everywhere else in this controller are in `view`.
    private var owlFrame: CGRect {
        owlSprite.superview?.convert(owlSprite.frame, to: view) ?? owlSprite.frame
    }

    func setOwlFrame(_ frame: CGRect, inRail: Bool) {
        let parent = inRail ? (navigationController?.view ?? view!) : view!
        if owlSprite.superview !== parent {
            let old = owlFrame
            parent.addSubview(owlSprite)
            owlSprite.frame = view.convert(old, to: parent)
        }
        if inRail { parent.bringSubviewToFront(owlSprite) }
        owlInRail = inRail
        owlSprite.frame = view.convert(frame, to: parent)
    }

    var owlPlacement: OwlPlacement {
        get {
            guard let d = AppSettings.defaults.data(forKey: AppSettings.Key.owlPlacement),
                  let p = try? JSONDecoder().decode(OwlPlacement.self, from: d) else { return .default }
            return p
        }
        set { AppSettings.defaults.set(try? JSONEncoder().encode(newValue), forKey: AppSettings.Key.owlPlacement) }
    }

    private func setUpOwlSprite() {
        owlSprite.onTap = { [weak self] in
            guard let self else { return }
            if self.bubbleOpen { self.closeHint() }
            else if self.owl.visible != nil, !self.shownHints.isEmpty { self.openHint() }
            else { self.askCedric() }
        }
        owlSprite.onDoubleTap = { [weak self] in self?.moveOwl(to: .default) }
        owlSprite.onDragBegan = { [weak self] in self?.closeHint() }
        owlSprite.dragArea = { [weak self] in
            guard let self, let parent = self.owlSprite.superview else { return .zero }
            return self.view.convert(self.owlArea(), to: parent)
        }
        owlSprite.onDragEnded = { [weak self] frame in
            guard let self, let parent = self.owlSprite.superview else { return }
            let inView = parent.convert(frame, to: self.view)
            self.moveOwl(to: OwlPlacement.snapped(frameYDown: inView, in: self.owlArea()), fromDrag: true)
        }
        owlSprite.menuProvider = { [weak self] in self?.owlMenu() ?? UIMenu(children: []) }
        owlSprite.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Ask Cedric")) { [weak self] _ in self?.askCedric(); return true },
            UIAccessibilityCustomAction(name: String(localized: "Reset Position")) { [weak self] _ in self?.moveOwl(to: .default); return true },
        ]
    }

    /// His long-press menu (the Mac's popover).
    private func owlMenu() -> UIMenu {
        let ask = UIAction(title: String(localized: "Ask Cedric"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [weak self] _ in
            self?.askCedric()
        }
        let check = UIAction(title: String(localized: "Check with Cedric"), image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.checkWithCedric()
        }
        let hints = UIAction(title: String(localized: "Offline Hints"), image: UIImage(systemName: "lightbulb"),
                             state: AppSettings.owlHints ? .on : .off) { _ in AppSettings.owlHints.toggle() }
        let reset = UIAction(title: String(localized: "Reset Position"), image: UIImage(systemName: "arrow.down.right.square")) { [weak self] _ in
            self?.moveOwl(to: .default)
        }
        let top: [UIMenuElement] = [ask, check] + (checkScriptAction().map { [$0] } ?? [])
        return UIMenu(children: top + [UIMenu(options: .displayInline, children: [hints, reset])])
    }

    /// "Check Script for Risks…", only for a script (the overflow menu and the owl's).
    private func checkScriptAction() -> UIAction? {
        guard canCheckScript else { return nil }
        let action = UIAction(title: String(localized: "Check Script for Risks…"), image: UIImage(systemName: "exclamationmark.shield")) { [weak self] _ in
            self?.checkScriptForRisks()
        }
        action.accessibilityIdentifier = "editor.checkScript"
        return action
    }

    /// Where he may sit: the text pane (inside the safe area, above the
    /// status line, which rides on the keyboard), a little in from its edges.
    func owlArea() -> CGRect {
        var area = view.safeAreaLayoutGuide.layoutFrame
        area.size.height = max(0, statusBar.frame.minY - area.minY)
        if !textView.isHidden { area = area.intersection(textView.frame.offsetBy(dx: split.frame.minX, dy: split.frame.minY)) }
        // Never over Ask Cedric's panel (he sat on its Send button).
        area = EditorPanes.owlArea(textPane: area, chat: askPanel?.view.frame)
        // Before the first real layout the area can be empty: insetting an
        // empty rect gives CGRect.null (infinite origin), and a frame from
        // that crashes CALayer (seen on the iPhone Duo simulator).
        guard !area.isNull, !area.isInfinite, area.width > 8, area.height > 8 else { return .zero }
        return area.insetBy(dx: 4, dy: 4)
    }

    /// Only the default placement follows the rail; a dragged position stays
    /// in the pane. UIKit exposes the rail's safe inset, not its controls.
    private func railOwlFrame() -> CGRect? {
        guard !traitCollection.preferredContentSizeCategory.isAccessibilityCategory,
              let nav = navigationController, nav.topViewController === self,
              let window = view.window, !nav.isNavigationBarHidden else { return nil }
        let bar = nav.navigationBar
        let screen = window.convert(window.bounds, to: view)
        let safe = window.convert(window.bounds.inset(by: window.safeAreaInsets), to: view)
        let barFrame = bar.convert(bar.bounds, to: view)
        let statusTop = statusBar.convert(statusBar.bounds, to: view).minY
        let statusBarShown = window.windowScene?.statusBarManager?.isStatusBarHidden != true
        let size = CGSize(width: OwlSprite.size, height: OwlSprite.size)
        return OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: barFrame,
                                              statusTop: statusTop, statusBarShown: statusBarShown, size: size)
    }

    private func layoutOwl() {
        // The panes' own frames first: the split lays out its panes after
        // this view, so a panel just opened still had the old text width
        // and he stayed where he was, on the panel.
        split.layoutIfNeeded()
        let railSlot = owlPlacement == .default
            && !AppSettings.defaults.bool(forKey: AppSettings.Key.owlManualPlacement)
            ? railOwlFrame() : nil
        if !owlSprite.isDragging, let railSlot {
            setOwlFrame(railSlot, inRail: true)
        } else if !owlSprite.isDragging, owlInRail {
            setOwlFrame(owlFrame, inRail: false)
        }
        let area = owlArea()
        guard area.width >= OwlSprite.size, area.height >= OwlSprite.size else {
            if askPanel != nil { owlSprite.isHidden = true }
            return
        }
        let size = CGSize(width: OwlSprite.size, height: OwlSprite.size)
        if !owlSprite.isDragging, railSlot == nil {
            let f = owlPlacement.frameYDown(in: area, size: size)
            setOwlFrame(OwlPlacement.avoidingFolds(f, folds: folds(), in: area), inRail: false)
        }
        applyOwlHidden()
        layoutBubble(area: area)
        fadeOwlNearCaret()
    }

    private func layoutBubble(area: CGRect) {
        guard bubbleOpen, !hintBar.isHidden else { return }
        // On his side of the fold.
        let o = owlFrame
        let fold = FoldLayout.crossingFolds(folds(), content: area).first
        let lane = FoldLayout.lane(in: area, folds: folds(), trailing: fold.map { o.midX > $0.midX } ?? true)
        guard lane.width > 60, lane.height > 40 else { return }
        let size = hintBar.fit(width: lane.width - 8)
        let b = OwlPlacement.bubbleYDown(owl: o, size: size, in: lane, avoid: hintedRect())
        hintBar.tailOnTop = b.tailOnTop
        hintBar.tailAtLeft = b.tailAtLeft
        hintBar.frame = b.frame
    }

    /// The lines the shown hint is about, across the view (nil if none or off screen).
    private func hintedRect() -> CGRect? {
        guard let v = owl.visible, let r = v.hint.range,
              let start = textView.position(from: textView.beginningOfDocument, offset: r.location + v.offset),
              let end = textView.position(from: start, offset: r.length),
              let range = textView.textRange(from: start, to: end) else { return nil }
        let rect = textView.firstRect(for: range)
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let inView = textView.convert(rect, to: view)
        return CGRect(x: view.bounds.minX, y: inView.minY, width: view.bounds.width, height: max(inView.height, 12))
    }

    /// Saves where he goes and slides him there (0.16 s, as on the Mac).
    func moveOwl(to place: OwlPlacement, fromDrag: Bool = false) {
        owlPlacement = place
        AppSettings.defaults.set(fromDrag, forKey: AppSettings.Key.owlManualPlacement)
        let area = owlArea()
        guard area.width >= OwlSprite.size, area.height >= OwlSprite.size else { return }
        let slot = place == .default && !fromDrag ? railOwlFrame() : nil
        let f = slot ?? OwlPlacement.avoidingFolds(place.frameYDown(in: area, size: owlSprite.bounds.size), folds: folds(), in: area)
        let old = owlFrame
        setOwlFrame(old, inRail: slot != nil)
        if UIAccessibility.isReduceMotionEnabled {
            setOwlFrame(f, inRail: slot != nil)
        } else {
            UIView.animate(withDuration: 0.16) { self.setOwlFrame(f, inRail: slot != nil) }
        }
        layoutBubble(area: area)
        fadeOwlNearCaret()
    }

    /// He fades while the caret is near him (so he never sits on what you type).
    private func fadeOwlNearCaret() {
        if owlInRail { owlSprite.setFaded(false); return }
        guard !textView.isHidden, let sel = textView.selectedTextRange else { owlSprite.setFaded(false); return }
        let caret = textView.convert(textView.caretRect(for: sel.end), to: view)
        owlSprite.setFaded(caret.insetBy(dx: -28, dy: -18).intersects(owlFrame))
    }

    private var owlBadgeHidden = false

    /// Hidden by his badge state, in Focus Preview, or if he'd touch the chat.
    private func applyOwlHidden() {
        let hide = owlBadgeHidden || EditorPanes.owlHidden(layout: paneLayout, owlFrame: owlFrame, chat: askPanel?.view.frame)
        if owlSprite.isHidden != hide { owlSprite.isHidden = hide }
    }

    private func updateOwlBadge() {
        let count = shownHints.count
        let large = LargeDocument.reason(for: lineIndex) != nil
        let state = OwlBadge.make(hints: count, previous: lastHintCount, bubbleOpen: bubbleOpen,
                                  hintsOn: AppSettings.owlHints || count > 0, largeDocument: large,
                                  reduceMotion: UIAccessibility.isReduceMotionEnabled)
        lastHintCount = count
        owlBadgeHidden = state.hidden
        applyOwlHidden()
        owlSprite.apply(state)
        owlSprite.pose = count > 0 || bubbleOpen ? .talking : .idle
    }

    func applyFix() {
        guard let shown = owl.visible else { return }
        if let l = RulesHintProvider.guessedLanguage(shown.hint) {
            setLanguage(l)
            owl.dismissCurrent()
            return
        }
        if shown.hint.id == RulesHintProvider.saveCopyID {
            saveDocument()
            owl.dismissCurrent()
            return
        }
        if shown.hint.replacement == nil, StyleCheck.isStyleHint(shown.hint.id) {
            showHintRange(shown)
            return
        }
        guard editableOrSay() else { return }
        guard let fix = owl.fix(in: textView.textStorage.string as NSString),
              let start = textView.position(from: textView.beginningOfDocument, offset: fix.range.location),
              let end = textView.position(from: start, offset: fix.range.length),
              let range = textView.textRange(from: start, to: end) else {
            toast(String(localized: "The text changed since Cedric looked. Try again in a moment."))
            owl.dismissCurrent()
            return
        }
        // Through UITextInput, so it is one undoable edit.
        textView.replace(range, withText: fix.replacement)
        bubbleOpen = false
        owl.dismissCurrent()
    }

    /// Selects the phrase Style Check pointed at (a cliché has no fix).
    private func showHintRange(_ shown: EditorOwl.Shown) {
        guard let r = shown.hint.range else { return }
        let abs = NSRange(location: r.location + shown.offset, length: r.length)
        guard NSMaxRange(abs) <= (textView.text as NSString).length else { return }
        textView.selectedRange = abs
        jumpShowsLineNumbers = true
        layoutGutter()
        revealRange(abs)
    }

    /// "Ignore this word": the phrase joins Style Check's exceptions.
    private func ignoreStylePhrase() {
        guard let id = owl.visible?.hint.id, let phrase = StyleCheck.phrase(fromHintID: id) else { return }
        if !AppSettings.styleCheckExceptions.contains(phrase) {
            AppSettings.styleCheckExceptions.append(phrase)
        }
        bubbleOpen = false
        owl.dismissCurrent()
    }

    @objc func checkWithCedric() {
        owl.askAI { [weak self] in self!.owlSnapshot() }
        toast(String(localized: "Cedric is looking…"))
    }

    // MARK: Ask Cedric

    /// Check Script for Risks…: shell, PowerShell, batch, .reg, Python, Ruby.
    var canCheckScript: Bool { ScriptSafety.isScript(document.language.language) }

    /// Opens Ask Cedric and starts the check: the offline scan (the script
    /// is never run, nothing is sent for it), then the model's review when
    /// an engine is ready.
    @objc func checkScriptForRisks() {
        guard canCheckScript else { return }
        if askPanel == nil && askSheet == nil { askCedric() }
        askModel?.checkScriptSafety()
    }

    private static let inlineToolGate = OwlToolGate.bundled()

    func inlineAssistStates(selection: NSRange) -> (explain: Bool, rewrite: Bool) {
        let length = textView.textStorage.length
        let hasSelection = selection.location != NSNotFound && selection.length > 0
            && selection.location <= length && selection.length <= length - selection.location
        guard hasSelection else { return (false, false) }
        let large = LargeDocument.reason(for: lineIndex) != nil
        let settings = AskCedricModel.chatSettings()
        let enabled = !large && askModel?.running != true
        let allowsTools = settings.flatMap { OwlChatEngines.configuredScoreKey(settings: $0) }
            .map { Self.inlineToolGate.allowsTools($0) } ?? false
        let readOnly = OwlEditAccess.readOnly(editable: editGate.isEditable, following: false, largeDocument: large, extrasPaused: false)
        return (OwlInlineAssist.canExplain(askEnabled: enabled, engineReady: settings != nil, hasSelection: hasSelection),
                OwlInlineAssist.canRewrite(askEnabled: enabled && !readOnly, engineReady: settings != nil,
                                           hasSelection: hasSelection, allowsTools: allowsTools))
    }

    func canInlineAssist(_ action: OwlQuickAction, selection: NSRange) -> Bool {
        let states = inlineAssistStates(selection: selection)
        return action == .rewrite ? states.rewrite : states.explain
    }

    @objc func explainSelection() { inlineAssist(.explain, selection: textView.selectedRange) }
    @objc func rewriteSelection() { inlineAssist(.rewrite, selection: textView.selectedRange) }

    private func inlineAssist(_ action: OwlQuickAction, selection: NSRange) {
        guard selection == textView.selectedRange, canInlineAssist(action, selection: selection) else { return }
        if askPanel == nil && askSheet == nil { askCedric() }
        let title = action == .explain ? String(localized: "Explain Selection") : String(localized: "Rewrite Selection")
        askModel?.ask(title, action: action, inlineSelection: selection)
    }

    @objc func askCedric() {
        // Ask is about the text: Focus Preview ends.
        if focusOn { exitFocusPreview() }
        let model = AskCedricModel(fileName: document.displayName, language: document.language.language)
        model.apply = { [weak self] proposal in self?.apply(proposal) ?? .refused }
        model.documentNow = { [weak self] in self?.currentDocument() ?? AskCedricModel.DocumentNow(text: "", generation: 0, readOnly: true, large: false, lines: LineIndex()) }
        model.makeSnapshot = { [weak self] in self?.askSnapshot() ?? OwlDocumentSnapshot(text: "", generation: 0) }
        model.refreshScope()
        model.askIsVisible = { [weak self] in self?.askPanel != nil || self?.askSheet != nil }
        model.openSettings = { [weak self] in
            guard let self else { return }
            if self.askPanel != nil { self.closeAskPanel(); self.showSettings() }
            else { self.dismiss(animated: true) { self.showSettings() } }
        }
        askModel = model
        // An iPad at regular width docks Cedric beside the text. A phone
        // always gets the sheet, including landscape, where the width is
        // regular but a side panel is too narrow to read. An iPad panel can
        // still be popped out into that sheet.
        closeHint()
        if askUsesPanel {
            openAskPanel(model)
            return
        }
        presentAskSheet(model)
    }

    /// Side panel only on an iPad that has room. A phone, and an iPad in a
    /// narrow split, use the sheet.
    private var askUsesPanel: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && traitCollection.horizontalSizeClass == .regular
    }

    /// The sheet and the side panel share the jump-to-line hook.
    private func askRoot(_ model: AskCedricModel) -> AskCedricView {
        var root = AskCedricView(model: model)
        root.onJumpToLine = { [weak self] line in self?.revealLine(line) }
        return root
    }

    private func presentAskSheet(_ model: AskCedricModel) {
        let host = UIHostingController(rootView: askRoot(model))
        // Default sizing uses the SwiftUI ideal size. A ScrollView's ideal
        // size is its whole transcript, so the sheet clipped long answers
        // instead of scrolling them.
        host.sizingOptions = []
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.selectedDetentIdentifier = .medium
            // Medium leaves the editor visible and undimmed behind the sheet.
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            // Compact height (iPhone landscape): stay attached to the bottom
            // edge. The default there is a floating card.
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.delegate = self
        }
        askSheet = host
        present(host, animated: true)
    }

    private func openAskPanel(_ model: AskCedricModel) {
        // Drop a previous panel without stopping: `askModel` is already the
        // conversation we're about to show.
        detachAskPanel()
        var root = askRoot(model)
        root.onDone = { [weak self] in self?.closeAskPanel() }
        root.onPopOut = { [weak self] in self?.popOutAskPanel() }
        let host = UIHostingController(rootView: root)
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.accessibilityIdentifier = "ask.panel"
        view.insertSubview(host.view, belowSubview: owlSprite)
        let g = view.safeAreaLayoutGuide
        let width = host.view.widthAnchor.constraint(equalToConstant: 360)
        splitTrailing.isActive = false
        splitTrailing = split.trailingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: -1)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: g.topAnchor),
            host.view.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            width, splitTrailing,
        ])
        host.didMove(toParent: self)
        askPanel = host
        askPanelWidth = width
        updateAskPanelWidth()
        // The panel takes the preview's place (never three columns).
        layoutPreview()
        view.setNeedsLayout()
    }

    func closeAskPanel() {
        askModel?.stop()
        detachAskPanel()
    }

    /// The iPad side panel becomes the sheet, same conversation still running.
    private func popOutAskPanel() {
        guard let model = askModel else { return }
        detachAskPanel()
        presentAskSheet(model)
    }

    /// Takes the side panel out of the editor. Does not stop the conversation.
    private func detachAskPanel() {
        guard let host = askPanel else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        askPanel = nil
        askPanelWidth = nil
        splitTrailing.isActive = false
        splitTrailing = split.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        splitTrailing.isActive = true
        // The preview comes back.
        layoutPreview()
        view.setNeedsLayout()
    }

    /// The panel takes the trailing side of the fold when there is one,
    /// else 40% of the width (at least 340 pt).
    private func updateAskPanelWidth() {
        guard let w = askPanelWidth else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let lane = FoldLayout.lane(in: safe, folds: folds(), trailing: true, rightToLeft: rightToLeft, gap: 0)
        let width = lane.width < safe.width ? lane.width : max(340, safe.width * 0.4)
        let clamped = min(width, max(0, safe.width - 280))
        if w.constant != clamped { w.constant = clamped }
    }

    /// An iPad losing regular width (Split View) turns the panel into the
    /// sheet, same conversation; gaining it docks the sheet again. A phone
    /// stays a sheet in landscape, where the width class is regular.
    private func updateAskPanelForWidth() {
        let current: EditorPanes.Ask = askPanel != nil ? .panel : askSheet != nil ? .sheet : .none
        let want: EditorPanes.Ask = askUsesPanel ? .panel : .sheet
        guard current != .none, current != want, let model = askModel else { return }
        if want == .panel {
            guard let sheet = askSheet else { return }
            askSheet = nil
            sheet.dismiss(animated: false) { [weak self] in self?.openAskPanel(model) }
            return
        }
        detachAskPanel()
        presentAskSheet(model)
    }

    /// The document as it is now, for an edit card's Apply.
    private func currentDocument() -> AskCedricModel.DocumentNow {
        let large = LargeDocument.reason(for: lineIndex) != nil
        let readOnly = OwlEditAccess.readOnly(editable: editGate.isEditable, following: false,
                                              largeDocument: large, extrasPaused: false)
        return AskCedricModel.DocumentNow(text: textView.text as NSString, generation: generation,
                                          readOnly: readOnly, large: large, lines: lineIndex)
    }

    /// Frozen for one question, including the facts check_document reads.
    private func askSnapshot() -> OwlDocumentSnapshot {
        let s = owlSnapshot()
        return OwlDocumentSnapshot(text: s.text as String, generation: s.generation, selection: s.selection,
                                   visible: s.visible, fileName: s.fileName, language: s.language.rawValue, facts: s.facts)
    }

    /// Applies an Ask Cedric edit where it matches the live document, as one undo step.
    /// `.stale`: the text no longer matches. `.refused`: it matches, but this
    /// text view could not turn the range into a position.
    private func apply(_ p: OwlEditProposal) -> AskCedricModel.ApplyResult {
        let now = currentDocument()
        guard case .ready(let range) = p.state(text: now.text, generation: now.generation, readOnly: now.readOnly) else { return .stale }
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let r = textView.textRange(from: start, to: end) else { return .refused }
        let um = textView.undoManager
        um?.beginUndoGrouping()
        textView.replace(r, withText: p.replacement)
        um?.setActionName(String(localized: "Cedric’s Edit"))
        um?.endUndoGrouping()
        let placed = NSRange(location: range.location, length: (p.replacement as NSString).length)
        textView.selectedRange = placed
        revealRange(placed)
        return .applied
    }

    // MARK: Preview

    private var hasEditorPreview: Bool {
        document.language.language == .markdown || document.language.language == .csv
    }

    @objc func togglePreview() {
        guard hasEditorPreview else { return }
        // ⇧⌘P in Focus Preview: back to the text.
        if focusOn { exitFocusPreview(); return }
        previewOn.toggle()
        if previewOn { makePreview() }
        if document.language.language == .csv {
            refreshPreview()
            layoutPreview()
        } else {
            layoutPreview()
            refreshPreview()
        }
        updateBarButtons()
        contextBar?.refreshStates()
    }

    private func makePreview() {
        guard preview == nil else { return }
        let p = PreviewController()
        addChild(p)
        p.didMove(toParent: self)
        p.onZoom = { [weak self] (z: Double) in
            let pct = Int((z * 100).rounded())
            self?.zoomNote(String(localized: "Text \(pct)%"))
        }
        p.onOpenFile = { [weak self] url in self?.openLinked(url) }
        preview = p
        updatePreviewHeader()
    }

    /// The preview's own corner controls: Focus Preview in and out, and on
    /// iPad Open Preview in New Window (also dragged out to make one).
    private func updatePreviewHeader() {
        guard let p = preview else { return }
        let detach = document.language.language == .markdown && DetachedPreviews.available
        p.configureHeader(focusOn: focusOn,
                          onFocus: { [weak self] in self?.toggleFocusPreview() },
                          onDetach: detach ? { [weak self] in self?.openPreviewInNewWindow() } : nil,
                          detachActivity: detach ? { [weak self] in self?.detachedPreviewActivity() } : nil)
    }

    // MARK: Detached preview (iPad)

    private var detachedTarget: PreviewWindows.Target {
        PreviewWindows.Target(documentPath: document.recoveryPath, editorWindow: windowID, title: document.displayName)
    }

    private var detachedSnapshot: DetachedPreviews.Snapshot {
        DetachedPreviews.Snapshot(url: document.fileURL, markdown: textView.text, palette: palette)
    }

    private func detachedPreviewActivity() -> NSUserActivity {
        DetachedPreviews.activity(for: detachedTarget, snapshot: detachedSnapshot)
    }

    /// A window with the preview alone, following this text live. It never
    /// writes the document (it has none of its own).
    @objc func openPreviewInNewWindow() {
        guard document.language.language == .markdown, DetachedPreviews.available else { return }
        DetachedPreviews.open(detachedTarget, snapshot: detachedSnapshot, from: view.window?.windowScene) { [weak self] error in
            self?.toast(String(localized: "Couldn’t open a new window: \(error.localizedDescription)"))
        }
    }

    @objc private func detachedPreviewNeedsText(_ n: Notification) {
        guard let path = n.userInfo?["path"] as? String,
              OpenDocumentRegistry.key(forPath: path) == OpenDocumentRegistry.key(forPath: document.recoveryPath), !closing else { return }
        DetachedPreviews.publish(path: document.recoveryPath, snapshot: detachedSnapshot)
        if !textView.isHidden { DetachedPreviews.scroll(path: document.recoveryPath, fraction: textScrollFraction) }
    }

    /// iPad (regular width): side by side. iPhone: the preview replaces the
    /// text. Focus Preview: the preview alone, everywhere.
    /// Never three columns: Ask Cedric's panel takes the preview's place on
    /// a wide screen (EditorPanes).
    var paneLayout: EditorPanes.Layout {
        // Only the docked panel takes a column. The sheet floats over the
        // editor, so a phone in landscape keeps text and preview side by side.
        EditorPanes.layout(previewOn: previewOn, askOpen: askPanel != nil, focus: focusOn,
                           regularWidth: traitCollection.horizontalSizeClass == .regular)
    }

    private func layoutPreview() {
        guard let p = preview else { return }
        let l = paneLayout
        if l.preview {
            let wasShowing = p.view.superview === split && !p.view.isHidden
            if p.view.superview !== split { split.addArrangedSubview(p.view) }
            p.view.isHidden = false
            if !l.text, !textView.isHidden { hideTextKeepingState(previewWasShowing: wasShowing) }
            if l.text, textView.isHidden { showTextRestoringState() }
        } else {
            p.view.isHidden = true
            if textView.isHidden { showTextRestoringState() }
        }
        view.setNeedsLayout()
    }

    /// The text's scroll share (0 top, 1 bottom).
    private var textScrollFraction: Double {
        let i = textView.adjustedContentInset
        return ScrollSync.fraction(offset: textView.contentOffset.y, contentHeight: textView.contentSize.height,
                                   visibleHeight: textView.bounds.height, insetTop: i.top, insetBottom: i.bottom)
    }

    /// The preview takes the whole screen (Focus Preview, or an iPhone Duo
    /// folded shut with the preview on): remember the caret, selection,
    /// scroll and keyboard. A preview that wasn't showing opens at the
    /// text's place.
    private func hideTextKeepingState(previewWasShowing: Bool) {
        continuity = EditorContinuity(selection: textView.selectedRange, contentOffset: textView.contentOffset,
                                      wasEditing: textView.isFirstResponder)
        if let p = preview {
            if !previewWasShowing { p.scrollFraction = textScrollFraction }
            previewFractionAtHide = p.scrollFraction
        }
        textView.resignFirstResponder()
        textView.isHidden = true
    }

    /// The text is back (opened again, the preview turned off, Focus
    /// Preview left): as it was, or, if the preview was scrolled meanwhile,
    /// at the preview's place (the keyboard then stays down, so the caret
    /// doesn't pull the text back).
    private func showTextRestoringState() {
        textView.isHidden = false
        let moved: Double? = {
            guard let at = previewFractionAtHide, let now = preview?.scrollFraction, abs(now - at) > 0.02 else { return nil }
            return now
        }()
        previewFractionAtHide = nil
        guard let c = continuity else { return }
        continuity = nil
        textView.selectedRange = c.restoredSelection(length: (textView.text as NSString).length)
        view.layoutIfNeeded()
        let maxOffset = CGPoint(x: textView.contentSize.width + textView.adjustedContentInset.right - textView.bounds.width,
                                y: textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        if let f = moved {
            let i = textView.adjustedContentInset
            let y = ScrollSync.offset(fraction: f, contentHeight: textView.contentSize.height, visibleHeight: textView.bounds.height,
                                      insetTop: i.top, insetBottom: i.bottom)
            textView.setContentOffset(CGPoint(x: c.restoredOffset(maxOffset: maxOffset).x, y: y), animated: false)
            return
        }
        textView.setContentOffset(c.restoredOffset(maxOffset: maxOffset), animated: false)
        if c.wasEditing { textView.becomeFirstResponder() }
    }

    // MARK: Focus Preview

    /// One tap: the preview alone (turned on if it was off), on any screen.
    @objc func toggleFocusPreview() {
        guard hasEditorPreview else { return }
        if focusOn { exitFocusPreview(); return }
        // The preview alone: a docked Ask Cedric panel closes.
        closeAskPanel()
        previewOnBeforeFocus = previewOn
        focusOn = true
        previewOn = true
        makePreview()
        closeHint()
        setFocusChrome(true)
        updatePreviewHeader()
        if document.language.language == .csv {
            refreshPreview()
            layoutPreview()
        } else {
            layoutPreview()
            refreshPreview()
        }
        updateBarButtons()
        updateOwlBadge()
        UIAccessibility.post(notification: .screenChanged, argument: String(localized: "Focus Preview. Edit returns to the text."))
    }

    /// Back to the text: side by side again on a wide screen if the preview
    /// was beside it before; on a phone-sized screen, the text.
    @objc func exitFocusPreview() {
        guard focusOn else { return }
        focusOn = false
        let regular = traitCollection.horizontalSizeClass == .regular
        previewOn = regular && previewOnBeforeFocus
        setFocusChrome(false)
        updatePreviewHeader()
        layoutPreview()
        updateBarButtons()
        updateOwlBadge()
        UIAccessibility.post(notification: .screenChanged, argument: textView)
    }

    /// The status line goes in Focus Preview (the preview runs to the bottom).
    private func setFocusChrome(_ focus: Bool) {
        statusBar.isHidden = focus
        if focus {
            splitBottom.isActive = false
            splitBottomFocus.isActive = true
        } else {
            splitBottomFocus.isActive = false
            splitBottom.isActive = true
        }
        if focus { hintBar.isHidden = true }
        focusGestures.forEach { $0.isEnabled = focus }
        divider.isHidden = true
        view.setNeedsLayout()
        // The status bar and home indicator step aside where the system
        // lets them (not while a hardware status bar is forced, or in a
        // Split View / Stage Manager window).
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    override var prefersStatusBarHidden: Bool { focusOn }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var prefersHomeIndicatorAutoHidden: Bool { focusOn }

    /// Ways back besides Edit and Esc: a swipe down with the preview at its
    /// top, and a swipe in from the leading edge.
    private func setUpFocusGestures() {
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDownInFocus))
        down.direction = .down
        down.delegate = self
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwipedInFocus(_:)))
        edge.edges = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        for g in [down, edge] as [UIGestureRecognizer] {
            g.isEnabled = false
            view.addGestureRecognizer(g)
        }
        focusGestures = [down, edge]
    }

    @objc private func swipedDownInFocus() { exitFocusPreview() }

    @objc private func edgeSwipedInFocus(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .ended, abs(g.translation(in: view).x) > 60 else { return }
        exitFocusPreview()
    }

    /// A short note for the preview's text size (one at a time).
    private weak var zoomLabel: UILabel?
    private func zoomNote(_ text: String) {
        zoomLabel?.removeFromSuperview()
        toast(text)
        zoomLabel = view.subviews.last { $0.accessibilityIdentifier == "editor.toast" } as? UILabel
    }

    // MARK: Resizable split

    private var splitStore: PreviewSplitStore { PreviewSplitStore(defaults: AppSettings.defaults) }

    private func setUpDivider() {
        view.insertSubview(divider, aboveSubview: split)
        divider.isHidden = true
        splitPosition = splitStore.position(regularWidth: traitCollection.horizontalSizeClass == .regular,
                                            regularHeight: traitCollection.verticalSizeClass == .regular)
        divider.onDrag = { [weak self] (x: CGFloat, ended: Bool) in self?.dividerDragged(to: x, ended: ended) }
        divider.onReset = { [weak self] in self?.setSplit(.fold) }
        divider.onStep = { [weak self] (direction: Int) in
            guard let self else { return }
            // Increment gives the preview (the trailing pane) more room.
            self.setSplit(PreviewSplit.step(self.splitPosition, by: -direction, content: self.split.frame, folds: self.folds(),
                                            rightToLeft: self.rightToLeft))
        }
        divider.value = { [weak self] in self?.dividerValue() ?? "" }
    }

    private func dividerValue() -> String {
        let pct = PreviewSplit.previewPercent(splitPosition, content: split.frame, folds: folds(), rightToLeft: rightToLeft)
        if splitPosition == .fold, PreviewSplit.foldFraction(content: split.frame, folds: folds()) != nil {
            return String(localized: "At the fold, preview \(pct)%")
        }
        return String(localized: "Preview \(pct)%")
    }

    private func layoutDivider() {
        guard sideBySide, split.frame.width > 0 else {
            if !divider.isHidden { divider.isHidden = true }
            return
        }
        divider.isHidden = false
        let x = PreviewSplit.seamX(effectiveSplit, content: split.frame, folds: folds(), spacing: 1, rightToLeft: rightToLeft)
        divider.frame = CGRect(x: x - SplitDivider.hitWidth / 2, y: split.frame.minY,
                               width: SplitDivider.hitWidth, height: split.frame.height)
    }

    private func dividerDragged(to x: CGFloat, ended: Bool) {
        let f = PreviewSplit.fraction(seamAt: x, content: split.frame, rightToLeft: rightToLeft)
        guard ended else {
            dragFraction = f
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return
        }
        dragFraction = nil
        setSplit(PreviewSplit.snap(f, content: split.frame, folds: folds(), rightToLeft: rightToLeft))
    }

    /// Moves the seam to `p` (snapped, animated) and keeps it for this size class.
    private func setSplit(_ p: SplitPosition) {
        let changed = p != splitPosition
        splitPosition = p
        splitStore.set(p, regularWidth: traitCollection.horizontalSizeClass == .regular,
                       regularHeight: traitCollection.verticalSizeClass == .regular)
        if changed { UISelectionFeedbackGenerator().selectionChanged() }
        view.setNeedsLayout()
        if UIAccessibility.isReduceMotionEnabled {
            view.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { self.view.layoutIfNeeded() }
        }
        UIAccessibility.post(notification: .layoutChanged, argument: divider)
    }

    private func refreshPreview() {
        if DetachedPreviews.hasPreviews(forPath: document.recoveryPath) {
            DetachedPreviews.publish(path: document.recoveryPath, snapshot: detachedSnapshot)
        }
        guard previewOn, let p = preview else { return }
        p.documentURL = document.fileURL
        if document.language.language == .csv {
            let snapshot = textView.textStorage.string as NSString
            let oldFraction = p.scrollFraction
            let sourceGeneration = generation
            p.showCSV(text: snapshot, fileName: document.fileURL.lastPathComponent,
                      large: LargeDocument.reason(for: lineIndex) != nil, sourceGeneration: sourceGeneration,
                      palette: palette, scrollFraction: oldFraction,
                      isSourceCurrent: { [weak self] in self?.generation == sourceGeneration }) { [weak self] offset, sourceGeneration in
                guard let self, self.generation == sourceGeneration else { return }
                if self.focusOn { self.exitFocusPreview() }
                if self.textView.isHidden { self.togglePreview() }
                let selection = NSRange(location: min(offset, self.textView.textStorage.length), length: 0)
                self.textView.selectedRange = selection
                self.revealRange(selection)
                if self.textView.isEditable { self.textView.becomeFirstResponder() }
            }
        } else {
            p.show(markdown: textView.text, palette: palette)
        }
    }

    /// Opens a note a preview link names: this document closes the usual
    /// way (saved, or asked about), then the browser opens the note.
    private var afterClose: (() -> Void)?

    private func openLinked(_ url: URL) {
        guard url.standardizedFileURL != document.fileURL.standardizedFileURL else { return }
        let browser = navigationController?.presentingViewController as? DocumentBrowserViewController
        afterClose = { [weak browser] in browser?.presentDocument(at: url) }
        closeDocument()
    }

    // MARK: Commands

    func findError(_ message: String, announce: Bool = true) {
        toast(message)
        if announce { announceAccessibility(message) }
    }

    @discardableResult
    func applyFindReplacement(range: NSRange, replacement: String, name: String) -> Bool {
        applyFindReplacements([(range, replacement)], name: name)
    }

    /// Find's replacements (ascending, not overlapping) as one undo step.
    @discardableResult
    func applyFindReplacements(_ edits: [(range: NSRange, replacement: String)], name: String) -> Bool {
        guard textView.isEditable, editGate.isEditable, textView.markedTextRange == nil, let last = edits.last else { return false }
        // The caret goes after the last replacement, in the new text.
        let caret = last.range.location + (edits.dropLast().reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }) + (last.replacement as NSString).length
        return applyTextEdits(edits, selection: NSRange(location: caret, length: 0), actionName: name)
    }

    @objc func copyAsHTML() {
        copyMarkdown(rich: false, selection: textView.selectedRange)
    }

    @objc func copyAsRichText() {
        copyMarkdown(rich: true, selection: textView.selectedRange)
    }

    func copyMarkdown(rich: Bool, selection: NSRange, done: (@MainActor () -> Void)? = nil) {
        guard document.language.language == .markdown else { done?(); return }
        let text = textView.textStorage.string as NSString
        guard selection.location != NSNotFound, selection.location <= text.length,
              selection.length <= text.length - selection.location else { done?(); return }
        let markdown = selection.length > 0 ? text.substring(with: selection) : text as String
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            findError(String(localized: "Nothing to copy."))
            done?()
            return
        }
        // The HTML importer runs on the main thread: a very long text would freeze the editor.
        if rich && (markdown as NSString).length > Self.richTextCopyLimit {
            findError(String(localized: "That’s too much to copy as rich text. Select less."))
            done?()
            return
        }
        let pasteboard = copyPasteboard
        let write = PasteboardWrite(changeCount: pasteboard.changeCount)
        let folder = document.fileURL.deletingLastPathComponent()
        let current: () -> Bool = { [weak self] in
            guard let self else { return false }
            return write.allowsWrite(changeCount: pasteboard.changeCount,
                                     documentIsActive: !self.closing && self.view.window != nil &&
                                     (self.navigationController == nil || self.navigationController?.topViewController === self))
        }
        if !rich {
            MarkdownExportIOS.renderFragment(markdown: markdown, folder: folder) { html in
                defer { done?() }
                guard current() else { return }
                // The HTML source as text, as on the Mac. Copy as Rich Text puts the markup itself.
                pasteboard.write([UTType.utf8PlainText.identifier: html])
            }
            return
        }
        MarkdownExportIOS.renderPage(markdown: markdown, title: MarkdownExport.baseName(displayName: document.displayName),
                                     folder: folder) { [weak self] page, _, _ in
            defer { done?() }
            guard let self, current() else { return }
            let html = HTMLScrub.noScriptNoRemote(page)
            do {
                let attributed = try NSAttributedString(data: Data(html.utf8),
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
                let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                guard current() else { return }
                pasteboard.write([UTType.html.identifier: Data(html.utf8),
                                  UTType.rtf.identifier: rtf,
                                  UTType.utf8PlainText.identifier: attributed.string])
            } catch {
                self.showCopyError(error)
            }
        }
    }

    static let richTextCopyLimit = 300_000

    private func showCopyError(_ error: Error) {
        let alert = UIAlertController(title: String(localized: "Couldn’t copy"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    @objc func printDocument() {
        if document.language.language == .markdown {
            let folder = document.fileURL.deletingLastPathComponent()
            MarkdownExportIOS.renderPage(
                markdown: textView.text,
                title: MarkdownExport.baseName(displayName: document.displayName),
                folder: folder,
                remote: false
            ) { [weak self] html, openedRoot, vaultRoot in
                guard let self else { return }
                MarkdownExportIOS.makePDF(html: html, folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot) { [weak self] result in
                    switch result {
                    case .success(let data): self?.presentPrint(item: data)
                    case .failure(let error): self?.showExportError(error)
                    }
                }
            }
        } else {
            let formatter = UISimpleTextPrintFormatter(text: textView.text)
            formatter.font = textView.font ?? AppSettings.font(for: document.language.language, traits: traitCollection)
            presentPrint(formatter: formatter)
        }
    }

    @objc func exportHTMLDocument() {
        guard document.language.language == .markdown else { return }
        MarkdownExportIOS.renderPage(
            markdown: textView.text,
            title: MarkdownExport.baseName(displayName: document.displayName),
            folder: document.fileURL.deletingLastPathComponent()
        ) { [weak self] html, _, _ in
            self?.shareExport(Data(html.utf8), ext: "html")
        }
    }

    @objc func exportPDFDocument() {
        guard document.language.language == .markdown else { return }
        MarkdownExportIOS.renderPage(
            markdown: textView.text,
            title: MarkdownExport.baseName(displayName: document.displayName),
            folder: document.fileURL.deletingLastPathComponent(),
            remote: false
        ) { [weak self] html, openedRoot, vaultRoot in
            guard let self else { return }
            MarkdownExportIOS.makePDF(html: html, folder: self.document.fileURL.deletingLastPathComponent(),
                                       openedRoot: openedRoot, vaultRoot: vaultRoot) { [weak self] result in
                switch result {
                case .success(let data): self?.shareExport(data, ext: "pdf")
                case .failure(let error): self?.showExportError(error)
                }
            }
        }
    }

    private func presentPrint(formatter: UIPrintFormatter? = nil, item: Any? = nil) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = document.displayName
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.printingItem = item
        if UIDevice.current.userInterfaceIdiom == .pad {
            let rect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            guard controller.present(from: rect, in: view, animated: true) else {
                showExportError(CocoaError(.fileWriteUnknown))
                return
            }
        } else if !controller.present(animated: true) {
            showExportError(CocoaError(.fileWriteUnknown))
        }
    }

    private func shareExport(_ data: Data, ext: String) {
        let manager = FileManager.default
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            showExportError(CocoaError(.fileNoSuchFile))
            return
        }
        let directory = caches.appendingPathComponent("MarkdownExport-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(MarkdownExport.fileName(displayName: document.displayName, ext: ext))
            try data.write(to: url, options: .atomic)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in try? manager.removeItem(at: directory) }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            present(activity, animated: true)
        } catch {
            try? manager.removeItem(at: directory)
            showExportError(error)
        }
    }

    private func showExportError(_ error: Error) {
        let alert = UIAlertController(title: String(localized: "Couldn’t export"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    @objc func saveDocument() {
        document.save(to: document.fileURL, for: .forOverwriting) { [weak self] ok in
            if !ok { self?.saveFailed(nil) }
        }
    }

    /// With "Save automatically" off and unsaved changes: Save / Don't
    /// Save / Cancel. Otherwise it closes (autosave saves first when on).
    @objc func closeDocument() {
        guard !closing else { return }
        // The last save failed and the text is still unsaved: say so first.
        if !saveErrorBanner.isHidden, document.hasUnsavedChanges {
            let a = UIAlertController(title: String(localized: "\(document.displayName) isn’t saved"),
                                      message: (saveErrorBanner.message ?? "") + "\n\n" + String(localized: "If you close it, the text is kept as a recovery copy and offered when you open the file again."),
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: String(localized: "Keep Editing"), style: .cancel) { [weak self] _ in self?.afterClose = nil })
            a.addAction(UIAlertAction(title: String(localized: "Close"), style: .destructive) { [weak self] _ in
                self?.finishClose(saveFirst: false)
            })
            present(a, animated: true)
            return
        }
        switch SavePolicy.onClose(saveAutomatically: AppSettings.saveAutomatically, hasUnsavedChanges: document.hasUnsavedChanges) {
        case .close:
            finishClose(saveFirst: false)
        case .ask:
            let a = UIAlertController(title: String(localized: "Save the changes to \(document.displayName)?"),
                                      message: String(localized: "If you don’t save, your changes are lost."), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self] _ in self?.finishClose(saveFirst: true) })
            a.addAction(UIAlertAction(title: String(localized: "Don’t Save"), style: .destructive) { [weak self] _ in
                self?.finishClose(saveFirst: false, discarding: true)
            })
            a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in self?.afterClose = nil })
            a.preferredAction = a.actions.first
            present(a, animated: true)
        }
    }

    private func finishClose(saveFirst: Bool, discarding: Bool = false) {
        if saveFirst {
            document.save(to: document.fileURL, for: .forOverwriting) { [weak self] ok in
                guard let self else { return }
                if ok { self.finishClose(saveFirst: false) } else { self.saveFailed(nil) }
            }
            return
        }
        closing = true
        stopDailyWordTracking()
        owl.cancel()
        textView.resignFirstResponder()
        document.close { [weak self] _ in
            guard let self else { return }
            // A clean close: the opened copy goes, and the recovery copy
            // unless the changes are still unsaved (a save that failed).
            self.recoveryWriter.stop(keepingCopy: !discarding && self.document.hasUnsavedChanges)
            self.document.discardOpenedCopy()
            OpenDocuments.registry.unregister(path: self.document.recoveryPath, window: self.windowID)
            // Closed on purpose: the next launch starts at the browser.
            LastOpenDocument.shared.forget(self.document.fileURL)
            // Its detached preview windows close with it.
            DetachedPreviews.documentClosed(path: self.document.recoveryPath)
            let after = self.afterClose
            self.afterClose = nil
            self.dismiss(animated: true) { after?() }
        }
    }

    // ⌘+, ⌘− and ⌘0 size the preview's text in Focus Preview, the editor's otherwise.
    @objc func biggerFont() { if focusOn { preview?.bigger() } else { AppSettings.fontSize += 1 } }
    @objc func smallerFont() { if focusOn { preview?.smaller() } else { AppSettings.fontSize -= 1 } }
    @objc func actualSizeFont() { if focusOn { preview?.actualSize() } else { AppSettings.resetFontSize() } }
    @objc func toggleWrap() { AppSettings.wrap.toggle() }
    @objc func toggleInvisibles() { AppSettings.showInvisibles.toggle() }

    /// The document menu's switch for this file. Lines must wrap.
    @objc func toggleReadableWidth() {
        guard AppSettings.wrap else { return }
        readableWidthChoice = !readableWidthOn
        view.setNeedsLayout()
    }

    @objc func showSettings() {
        let host = UIHostingController(rootView: SettingsView())
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    @objc func newWindow() {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
    }

    /// New Window as the system's scene activation action: the system
    /// hides or refuses it where a new window can't open (an iPhone Duo's
    /// outer display) instead of the request failing silently.
    static func newWindowAction() -> UIAction {
        UIWindowScene.ActivationAction(title: String(localized: "New Window"), image: UIImage(systemName: "macwindow.badge.plus"),
                                      identifier: nil, alternate: nil) { _ in
            UIWindowScene.ActivationConfiguration(userActivity: NSUserActivity(activityType: "app.owlink.ios.newWindow"))
        }
    }

    /// Headings of the open Markdown file, and files under a folder this
    /// app can list (the document's folder, or a folder the preview was
    /// granted). The sheet closes before a file is opened.
    @objc func openQuickly() {
        let headings = document.language.language == .markdown ? MarkdownOutline.headings(in: textView.text) : []
        let root = quickOpenRoot()
        var host: UIHostingController<QuickOpenView>!
        let rootView = QuickOpenView(headings: headings, root: root, onHeading: { [weak self] heading in
            host.dismiss(animated: true) { self?.revealLine(heading.line + 1) }
        }, onFile: { [weak self] url in
            host.dismiss(animated: true) {
                // A symlink out of the folder is listed nowhere, and is
                // refused again here: the resolved path has to stay under root.
                guard let self, let root, QuickOpen.containedFile(url, under: root) != nil else { return }
                self.openLinked(url)
            }
        })
        host = UIHostingController(rootView: rootView)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    /// The document's own folder when a file in it can actually be opened,
    /// else the nearest folder the preview was granted (its security scope
    /// started once). A listing on its own is not access: Files often lists
    /// a parent the app was not granted, and those siblings then fail to open.
    private func quickOpenRoot() -> URL? {
        let folder = document.fileURL.deletingLastPathComponent()
        let granted = PreviewFolderGrants.shared.root(for: folder)
        let readable = PreviewFolderAccess.canRead(PreviewFolderAccess.facts(folder: folder, document: document.fileURL))
        return QuickOpen.folderRoot(documentFolder: folder, readable: readable, granted: granted)
    }

    @objc func goToLine() {
        let alert = GoToLineAlertController(title: String(localized: "Go to Line"), message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.keyboardType = .numberPad
            $0.placeholder = "1–\(self.lineIndex.lineCount)"
            $0.backgroundColor = .systemBackground
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Go"), style: .default) { [weak self, weak alert] _ in
            guard let self, let n = Int(alert?.textFields?.first?.text ?? ""), n >= 1 else { return }
            self.revealLine(n)
            // Go to Line puts the caret there. A citation jump does not: it
            // only moves the selection, so a read-only document stays read-only.
            if self.textView.isEditable { self.textView.becomeFirstResponder() }
        })
        present(alert, animated: true)
    }

    /// Moves the caret to a 1-based line and turns line numbers on for this
    /// tab. Does not change the text and does not start editing.
    func revealLine(_ line: Int) {
        guard line >= 1, lineIndex.lineCount > 0 else { return }
        if focusOn { exitFocusPreview() }
        if textView.isHidden {
            previewOn = false
            layoutPreview()
        }
        jumpShowsLineNumbers = true
        let index = min(line, lineIndex.lineCount) - 1
        markedLine = index + 1
        let r = NSRange(location: lineIndex.starts[index], length: 0)
        textView.selectedRange = r
        layoutGutter()
        revealRange(r)
        scheduleWritingUpdate(center: true)
        if let sheet = askSheet?.sheetPresentationController, sheet.selectedDetentIdentifier == .large {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        }
        layoutGutter()
    }

    /// Reveal a selection, including its column when unwrapped. TextKit 2's
    /// UITextView often leaves the caret off-screen after the system
    /// helpers; fall back to an explicit offset when that happens.
    func revealRange(_ range: NSRange) {
        guard range.location != NSNotFound, range.location <= textView.textStorage.length,
              let position = textView.position(from: textView.beginningOfDocument, offset: range.location) else {
            textView.scrollRangeToVisible(range)
            return
        }
        layoutTextInsets()
        updateUnwrappedContentSize()
        textView.scrollRangeToVisible(range)
        var rect = textView.caretRect(for: position)
        if rect.isNull || rect.isInfinite { return }
        let gutter: CGFloat = (!AppSettings.wrap && showLineNumbers) ? lineNumberGutter.bounds.width : 0
        if gutter > 0 {
            rect.size.width += gutter
            rect.origin.x -= gutter
        }
        textView.scrollRectToVisible(rect, animated: false)
        let inset = textView.adjustedContentInset
        var visible = textView.bounds.inset(by: inset)
        if gutter > 0 {
            visible.origin.x += gutter
            visible.size.width = max(0, visible.size.width - gutter)
        }
        let target = CGPoint(x: rect.midX, y: rect.midY)
        if visible.insetBy(dx: -2, dy: -2).contains(target) { return }
        let minX = -inset.left, minY = -inset.top
        let maxX = max(minX, textView.contentSize.width + inset.right - textView.bounds.width)
        let maxY = max(minY, textView.contentSize.height + inset.bottom - textView.bounds.height)
        let x = AppSettings.wrap ? min(max(textView.contentOffset.x, minX), maxX) : min(max(rect.minX - gutter - 8, minX), maxX)
        let y = min(max(rect.midY - textView.bounds.height / 3, minY), maxY)
        textView.setContentOffset(CGPoint(x: x, y: y), animated: false)
    }

    /// Horizontal insets for the text. Off, the gutter consumes the left
    /// inset as before. On, the column is centred; the gutter sits in the
    /// left margin when that margin is wide enough, otherwise it consumes
    /// width and the column centres in what remains.
    private func textInsets(gutterWidth: CGFloat) -> (left: CGFloat, right: CGFloat, gutterX: CGFloat) {
        let plain = (left: editorTextInsetLeft + gutterWidth, right: CGFloat(8), gutterX: CGFloat(0))
        guard readableWidthOn, AppSettings.wrap, textView.bounds.width > 1 else { return plain }
        let font = textView.font ?? AppSettings.font(for: document.language.language, traits: traitCollection)
        let zeroWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let alphabetWidth = ("abcdefghijklmnopqrstuvwxyz" as NSString).size(withAttributes: [.font: font]).width
        let fixedPitch = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        let charWidth = CGFloat(ProseFont.characterWidth(
            fixedPitch: fixedPitch,
            zeroWidth: Double(zeroWidth),
            lowercaseAlphabetWidth: Double(alphabetWidth)
        ))
        let padding = textView.textContainer.lineFragmentPadding
        let column = ReadableWidth.columnWidth(columns: AppSettings.readableColumns,
                                               charWidth: Double(max(charWidth, 1)), padding: Double(padding))
        let full = Double(textView.bounds.width)
        let insetFull = ReadableWidth.inset(viewWidth: full, column: column)
        if gutterWidth == 0 || ReadableWidth.overlaidGutterMinX(textMinX: insetFull, gutterWidth: Double(gutterWidth), sidebarWidth: 0) != nil {
            return (CGFloat(insetFull), CGFloat(insetFull), CGFloat(insetFull) - gutterWidth)
        }
        let content = max(0, full - Double(gutterWidth))
        let inset = ReadableWidth.inset(viewWidth: content, column: column)
        return (gutterWidth + CGFloat(inset), CGFloat(inset), 0)
    }

    /// Places the gutter over the text's left inset and fills it with the
    /// visible line numbers. Hidden while the text itself is hidden.
    /// Readable Width, when this file has it on and lines wrap, centres a
    /// column and draws the gutter in that margin when it fits.
    func layoutGutter() {
        let font = UIFont.monospacedSystemFont(ofSize: max(10, (textView.font?.pointSize ?? 13) * 0.85), weight: .regular)
        let (width, insets) = layoutTextInsets()
        guard showLineNumbers else {
            lineNumberGutter.isHidden = true
            return
        }
        lineNumberGutter.isHidden = textView.isHidden || textView.superview == nil
        guard !lineNumberGutter.isHidden else { return }
        let frame = textView.convert(textView.bounds, to: split)
        let next = CGRect(x: frame.minX + insets.gutterX, y: frame.minY, width: width, height: frame.height)
        if lineNumberGutter.frame != next { lineNumberGutter.frame = next }
        lineNumberGutter.font = font
        lineNumberGutter.numberColor = UIColor(hex: palette.gutterForeground)
        lineNumberGutter.backgroundColor = UIColor(hex: palette.gutterBackground)
        lineNumberGutter.highlightColor = UIColor(hex: palette.foreground)
        lineNumberGutter.bandColor = UIColor(hex: palette.currentLine)
        lineNumberGutter.highlight = markedLine
        lineNumberGutter.bookmarked = Set(bookmarks.lines.map { $0 + 1 })
        lineNumberGutter.bookmarkColor = UIColor(hex: palette.caret)
        guard let vr = SyntaxColorizer.visibleRange(textView), lineIndex.length == textView.textStorage.length else {
            lineNumberGutter.rows = []
            lineNumberGutter.setNeedsDisplay()
            return
        }
        let first = lineIndex.line(containing: vr.location)
        let last = lineIndex.line(containing: min(lineIndex.length, NSMaxRange(vr)))
        var rows: [LineNumberGutter.Row] = []
        rows.reserveCapacity(last - first + 1)
        for i in first...last {
            guard let pos = textView.position(from: textView.beginningOfDocument, offset: lineIndex.starts[i]) else { continue }
            let y = textView.caretRect(for: pos).midY - textView.bounds.minY
            guard y >= 0, y <= textView.bounds.height else { continue }
            rows.append(LineNumberGutter.Row(line: i + 1, midY: y))
        }
        lineNumberGutter.rows = rows
        lineNumberGutter.setNeedsDisplay()
    }

    /// The text's side insets for the gutter and Readable Width; set before
    /// anything reads textContainerInset (the unwrapped content width).
    @discardableResult
    private func layoutTextInsets() -> (CGFloat, (left: CGFloat, right: CGFloat, gutterX: CGFloat)) {
        let font = UIFont.monospacedSystemFont(ofSize: max(10, (textView.font?.pointSize ?? 13) * 0.85), weight: .regular)
        let width = showLineNumbers ? LineNumberGutter.width(lineCount: lineIndex.lineCount, font: font) : 0
        let insets = textInsets(gutterWidth: width)
        var edge = textView.textContainerInset
        if abs(edge.left - insets.left) > 0.5 || abs(edge.right - insets.right) > 0.5 {
            edge.left = insets.left
            edge.right = insets.right
            preserveTextViewportDuringLayout {
                textView.textContainerInset = edge
            }
        }
        return (width, insets)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(printDocument) { return true }
        if action == #selector(exportHTMLDocument) || action == #selector(exportPDFDocument) {
            return document.language.language == .markdown
        }
        if action == #selector(copyAsHTML) || action == #selector(copyAsRichText) {
            return document.language.language == .markdown && textView.window != nil
        }
        if Self.markdownActions.contains(action) { return markdownEditable }
        if action == #selector(commentSelection(_:)) { return lineEditable && document.language.language.commentSyntax != nil }
        if Self.lineActions.contains(action) { return lineEditable }
        if Self.indentationModeActions.contains(action) { return true }
        if action == #selector(explainRegex) { return textToolStates(selection: textView.selectedRange).explain }
        if action == #selector(decodeSelection) { return textToolStates(selection: textView.selectedRange).decode }
        if action == #selector(findTodos) { return canFindTodos }
        if action == #selector(markAll) { return textView.window != nil }
        if action == #selector(clearMarks) { return hasMarks }
        if action == #selector(toggleBookmarkMenu(_:)) { return true }
        if action == #selector(nextBookmarkMenu(_:)) || action == #selector(previousBookmarkMenu(_:))
            || action == #selector(clearBookmarksMenu(_:)) { return !bookmarks.isEmpty }
        if action == #selector(showStatistics) { return true }
        if action == #selector(toggleCheckSpelling) || action == #selector(toggleCheckGrammar) { return true }
        if action == #selector(checkScriptForRisks) { return canCheckScript }
        if action == #selector(explainSelection) || action == #selector(rewriteSelection) {
            return canInlineAssist(action == #selector(explainSelection) ? .explain : .rewrite, selection: textView.selectedRange)
        }
        if action == #selector(togglePreview) || action == #selector(toggleFocusPreview) {
            return hasEditorPreview
        }
        if action == #selector(openPreviewInNewWindow) {
            return document.language.language == .markdown && DetachedPreviews.available
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Data safety

    private func barItem(_ title: String, _ symbol: String, _ id: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
        let i = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
        i.title = title
        i.accessibilityLabel = title
        i.accessibilityIdentifier = id
        return i
    }

    @objc private func undoChanged(_ note: Notification) {
        guard let um = note.object as? UndoManager, um === textView.undoManager else { return }
        if note.name == .NSUndoManagerDidUndoChange || note.name == .NSUndoManagerDidRedoChange {
            scheduleWritingUpdate(center: true)
        }
        // After the group is closed (WillClose comes before it is counted).
        DispatchQueue.main.async { [weak self] in self?.updateUndoItems() }
    }

    func updateUndoItems() {
        let um = textView.undoManager
        undoItem.isEnabled = editGate.isEditable && um?.canUndo ?? false
        redoItem.isEnabled = editGate.isEditable && um?.canRedo ?? false
    }

    /// Sets one reason the text is read-only, and the text view to match.
    func setEditLock(_ reason: EditGate.Reason, _ on: Bool) {
        editGate.set(reason, on)
        applyEditGate()
    }

    private func applyEditGate() {
        let editable = editGate.isEditable
        if textView.isEditable != editable {
            if !editable { textView.resignFirstResponder() }
            textView.isEditable = editable
        }
        updateUndoItems()
        _ = configuredEditItem()
        if isViewLoaded { updateStatus() }
        askModel?.documentEdited()
        contextBar?.refreshStates()
    }

    /// Edit / Done / Read Only for the bar (nil: read mode not in use).
    private func configuredEditItem() -> UIBarButtonItem? {
        switch editGate.button {
        case .none:
            return nil
        case .edit:
            editItem.title = String(localized: "Edit")
            editItem.isEnabled = true
            editItem.accessibilityHint = String(localized: "Lets you change the text.")
        case .done:
            editItem.title = String(localized: "Done")
            editItem.isEnabled = true
            editItem.accessibilityHint = String(localized: "Back to reading: the text can’t be changed until you tap Edit.")
        case .readOnly:
            editItem.title = String(localized: "Read Only")
            editItem.isEnabled = false
            editItem.accessibilityHint = String(localized: "This file looks binary, so Owlink opened it read-only.")
        }
        return editItem
    }

    /// The Edit / Done button.
    @objc func toggleEditing() {
        switch editGate.button {
        case .edit: startEditing()
        case .done: stopEditing()
        case .none, .readOnly: break
        }
    }

    /// Edit: leaves read mode and puts the caret in the text.
    func startEditing() {
        let editable = editGate.beginEditing()
        applyEditGate()
        if editable { textView.becomeFirstResponder() }
    }

    /// Done: back to read mode.
    func stopEditing() {
        editGate.endEditing()
        applyEditGate()
    }

    /// For changes that come from a command rather than typing (Fix it, an
    /// Ask Cedric edit): only while the text is editable.
    private func editableOrSay() -> Bool {
        if editGate.isEditable { return true }
        switch editGate.button {
        case .edit: toast(String(localized: "Tap Edit to change the text."))
        case .readOnly: toast(String(localized: "This file is open read-only."))
        default: toast(String(localized: "The text can’t be changed right now."))
        }
        return false
    }

    /// For a confirmed change to the whole text (Revert, Restore): leaves
    /// read mode, but not while the file is binary, locked or in conflict.
    private func explicitChangeAllowed() -> Bool {
        if editGate.allowExplicitChange() {
            applyEditGate()
            return true
        }
        return editableOrSay()
    }

    /// "Edited" as soon as there are unsaved changes, gone once saved:
    /// UIDocument's own hasUnsavedChanges, no separate flag.
    func updateEdited() {
        let edited = document.hasUnsavedChanges
        let name = document.displayName
        if #available(iOS 26.0, *) {
            navigationItem.title = name
            navigationItem.subtitle = edited ? String(localized: "Edited") : nil
        } else {
            navigationItem.title = edited ? String(localized: "\(name) — Edited") : name
        }
        view.window?.windowScene?.title = edited ? String(localized: "\(name) — Edited") : name
        // Setting `title` drops an attributed title. Colour it again.
        applyBarStyle()
        saveItem.isEnabled = edited
    }

    var undoBarItem: UIBarButtonItem { undoItem }
    var editBarItem: UIBarButtonItem { editItem }
    var redoBarItem: UIBarButtonItem { redoItem }
    var saveBarItem: UIBarButtonItem { saveItem }
    /// The Edited mark is showing (the subtitle, or the title before iOS 26).
    var editedShown: Bool {
        let edited = String(localized: "Edited")
        if #available(iOS 26.0, *), navigationItem.subtitle == edited { return true }
        return navigationItem.title?.hasSuffix(edited) == true
    }

    @objc private func enteredBackground() {
        commitDailyWords()
        recoveryWriter.writeNow()
    }

    /// iOS may end a suspended app: today's count is kept before that.
    @objc private func resignedActive() {
        commitDailyWords()
    }

    /// Replaces the whole text as one undoable edit (Undo brings it back).
    func replaceAllText(with text: String) {
        guard let all = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) else { return }
        let g = generation
        textView.replace(all, withText: text)
        if generation == g { textViewDidChange(textView) }
        // A whole-text replacement is the one edit that can leave large mode (as on the Mac).
        reevaluateWritingLarge()
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    private func revertAction() -> UIAction {
        let a = UIAction(title: String(localized: "Revert to Opened Version…"), image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
            self?.confirmRevert()
        }
        a.accessibilityIdentifier = "editor.revert"
        if editGate.button == .readOnly { a.attributes = .disabled; return a }
        switch document.openedCopy {
        case .kept?:
            break
        case .tooLarge?:
            a.attributes = .disabled
            a.subtitle = String(localized: "Not available for files over 20 MB")
        case .failed?, nil:
            a.attributes = .disabled
            a.subtitle = String(localized: "No copy of the opened version")
        }
        return a
    }

    /// Restore Previous Version: the safety copies of this file (before
    /// Owlink saves, conflict versions, text kept before a reload),
    /// newest first, kept up to 7 days.
    private func previousVersionsMenu() -> UIMenuElement {
        let copies = SaveSafetyStores.copies.copies(forDocumentPath: document.recoveryPath)
        let title = String(localized: "Restore Previous Version…")
        let image = UIImage(systemName: "archivebox")
        guard !copies.isEmpty, editGate.button != .readOnly else {
            let a = UIAction(title: title, image: image, attributes: .disabled) { _ in }
            a.subtitle = String(localized: "No previous versions kept")
            a.accessibilityIdentifier = "editor.previousVersions"
            return a
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        let items = copies.map { c in
            UIAction(title: f.string(from: c.sourceDate ?? c.savedAt), subtitle: c.kindTitle) { [weak self] _ in
                self?.confirmRestore(c)
            }
        }
        let m = UIMenu(title: title, image: image, children: items)
        m.accessibilityIdentifier = "editor.previousVersions"
        return m
    }

    private func confirmRestore(_ c: SafetyCopy) {
        let a = UIAlertController(title: String(localized: "Restore this version?"),
                                  message: String(localized: "The text is replaced with \(c.kindTitle.lowercased()) (\(c.byteCount) bytes). You can undo this with Undo."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: String(localized: "Restore"), style: .destructive) { [weak self] _ in self?.restore(c) })
        present(a, animated: true)
    }

    func restore(_ c: SafetyCopy) {
        guard explicitChangeAllowed() else { return }
        guard let data = SaveSafetyStores.copies.data(for: c), let decoded = c.decode(data) else {
            toast(String(localized: "Couldn’t read that version."))
            return
        }
        replaceAllText(with: decoded.text)
        let change = FormatChange(from: currentFormat, to: .init(encoding: decoded.encoding, lineEnding: decoded.lineEnding,
                                                                 mixedLineEndings: decoded.mixedLineEndings))
        if change.changesEverything { applyFormat(change, actionName: String(localized: "Restore")) }
        toast(String(localized: "Restored the previous version. Undo brings back the text before it."))
    }

    private func confirmRevert() {
        let a = UIAlertController(title: String(localized: "Revert to the version you opened?"),
                                  message: String(localized: "The text goes back to how \(document.displayName) was when you opened it. You can undo this with Undo."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: String(localized: "Revert"), style: .destructive) { [weak self] _ in self?.revertToOpened() })
        present(a, animated: true)
    }

    func revertToOpened() {
        guard explicitChangeAllowed() else { return }
        guard let data = document.openedBytes(), let decoded = TextCodec.decode(data) else {
            toast(String(localized: "Couldn’t read the opened version."))
            return
        }
        replaceAllText(with: decoded.text)
        let change = FormatChange(from: currentFormat, to: .init(encoding: decoded.encoding, lineEnding: decoded.lineEnding,
                                                                 mixedLineEndings: decoded.mixedLineEndings))
        // In the same undo group as the text: one Undo brings both back.
        if change.changesEverything { applyFormat(change, actionName: String(localized: "Revert")) }
        toast(String(localized: "Reverted to the opened version."))
    }

    private func offerRecovered(_ r: RecoveryRecord) {
        let a = RecoveryOffer.alert(for: r) { [weak self] restore in
            if restore { self?.restoreRecovered(r) } else { SaveSafetyStores.recovery.clear(documentPath: r.documentPath) }
        }
        present(a, animated: true)
    }

    /// The unsaved text comes back as an edit (Undo shows the file's text).
    private func restoreRecovered(_ r: RecoveryRecord) {
        // Kept for later if the file can't be changed now (it stays offered).
        guard explicitChangeAllowed() else { return }
        replaceAllText(with: r.text)
        let change = FormatChange(from: currentFormat, to: .init(encoding: r.encoding, lineEnding: r.lineEnding,
                                                                 mixedLineEndings: document.mixedLineEndings))
        if change.changesEverything { applyFormat(change, actionName: String(localized: "Restore")) }
        recoveryWriter.writeNow()
        toast(String(localized: "Restored the unsaved changes."))
    }

    @objc private func documentStateChanged() {
        let state = document.documentState
        setEditLock(.documentLocked, state.contains(.editingDisabled))
        if state.contains(.savingError), saveErrorBanner.isHidden { saveFailed(nil) }
        if state.contains(.inConflict), conflictResolver == nil, !closing { beginConflict() }
    }

    // MARK: Failed saves

    private func setUpSaveErrorBanner() {
        saveErrorBanner.isHidden = true
        saveErrorBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(saveErrorBanner)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            saveErrorBanner.topAnchor.constraint(equalTo: g.topAnchor, constant: 6),
            saveErrorBanner.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 10),
            saveErrorBanner.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
        ])
    }

    /// A save failed: the text stays here, unsaved (and in the recovery
    /// copy), and a strip says why until a save succeeds. Not an alert:
    /// typing goes on.
    func saveFailed(_ error: Error?) {
        guard !closing else { return }
        let name = document.displayName
        recoveryWriter.writeNow()
        if let error, case TextDocument.OpenError.unencodable(let enc) = error {
            saveErrorBanner.show(String(localized: "\(name) isn’t saved: some characters can’t be saved as \(enc.displayName). Your text is kept here."),
                                 actionTitle: String(localized: "Save as UTF-8")) { [weak self] in
                self?.saveAsUTF8()
            }
            return
        }
        let why = error.map { " " + $0.localizedDescription } ?? ""
        saveErrorBanner.show(String(localized: "Couldn’t save \(name).\(why) Your text is kept here, unsaved."))
    }

    private func saveAsUTF8() {
        applyFormat(FormatChange(from: currentFormat, to: .init(encoding: .utf8, lineEnding: document.lineEnding,
                                                                mixedLineEndings: document.mixedLineEndings)),
                    actionName: String(localized: "Save as UTF-8"))
        saveDocument()
    }

    // MARK: iCloud conflicts

    /// Copies every version (and any unsaved text) first, then asks which
    /// to keep. Editing is off until it is resolved.
    private func beginConflict() {
        let resolver = ConflictResolver(document: document)
        conflictResolver = resolver
        setEditLock(.conflict, true)
        let v = resolver.versions()
        guard !v.others.isEmpty else { endConflict(); return }
        resolver.backUp(v, unsavedText: document.hasUnsavedChanges ? textView.text : nil) { [weak self] failure in
            guard let self else { return }
            if let failure {
                // Nothing resolved and nothing removed: the conflict stays
                // (iCloud keeps every version), and so does the lock.
                self.showAlert(String(localized: "This file has a conflict"), failure.localizedDescription)
                return
            }
            self.askConflict(resolver, v)
        }
    }

    private func askConflict(_ resolver: ConflictResolver, _ v: ConflictResolver.Versions, note: String? = nil) {
        let a = ConflictResolver.chooser(name: document.displayName, v, note: note) { [weak self] choice in
            self?.resolveConflict(choice, resolver, v)
        }
        present(a, animated: true)
    }

    private func resolveConflict(_ choice: ConflictResolution.Choice, _ resolver: ConflictResolver, _ v: ConflictResolver.Versions) {
        resolver.resolve(choice, v) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let f):
                // Ask again: every version is still there (or copied).
                self.askConflict(resolver, v, note: f.localizedDescription)
            case .success(let savedName):
                switch choice {
                case .keepThis:
                    self.toast(String(localized: "Kept this version. The other is in Restore Previous Version for 7 days."))
                    self.document.markDiskStateStale()
                    self.endConflict()
                case .keepBoth:
                    self.toast(String(localized: "Kept this version and saved the other as “\(savedName ?? "")”."))
                    self.document.markDiskStateStale()
                    self.endConflict()
                case .keepOther:
                    // The other version is the file now: read it. The text
                    // shown here (saved or not) is copied already.
                    self.recoveryWriter.clear()
                    self.document.revertAfterChoice { [weak self] _ in
                        self?.toast(String(localized: "Kept the other version. This one is in Restore Previous Version for 7 days."))
                        self?.endConflict()
                    }
                }
            }
        }
    }

    // MARK: Changed elsewhere with unsaved edits

    /// The file changed on disk while the text here had unsaved edits: the
    /// document did not reload. The text here goes to the recovery store
    /// and both sides to the safety copies, then Keep Mine / Use Theirs.
    private func externalChange() {
        guard !closing, document.externalChangePending else { return }
        setEditLock(.externalChange, true)
        recoveryWriter.writeNow()
        DocumentCopies.keepUnsaved(textView.text, of: document)
        DocumentCopies.keepDisk(of: document, kind: .externalVersion) { [weak self] _ in
            self?.askExternalChange()
        }
    }

    private func askExternalChange() {
        guard !closing else { return }
        let a = UIAlertController(title: String(localized: "\(document.displayName) was changed somewhere else"),
                                  message: String(localized: "You have unsaved changes here. Keep Mine saves your version over the other one; Use Theirs shows the other one. Both are kept in Restore Previous Version for 7 days."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Keep Mine"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.document.keepMineAfterExternalChange()
            self.setEditLock(.externalChange, false)
            self.toast(String(localized: "Kept your version."))
        })
        a.addAction(UIAlertAction(title: String(localized: "Use Theirs"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.recoveryWriter.clear()
            self.document.revertAfterChoice { [weak self] _ in
                self?.setEditLock(.externalChange, false)
                self?.toast(String(localized: "Showing the other version. Your text is in Restore Previous Version for 7 days."))
            }
        })
        present(a, animated: true)
    }

    private func endConflict() {
        conflictResolver = nil
        setEditLock(.conflict, false)
        // Another conflict may have come in meanwhile.
        if document.documentState.contains(.inConflict),
           NSFileVersion.unresolvedConflictVersionsOfItem(at: document.fileURL)?.isEmpty == false {
            beginConflict()
        }
    }

    private func showAlert(_ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }

    // MARK: Toast

    func toast(_ text: String) {
        let label = PaddingLabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .label
        // tertiarySystemBackground is white in light mode, the same as the
        // editor, so the toast read as loose text over the code. Use a
        // contrasting fill and a hairline border so it stands out as a pill.
        label.backgroundColor = .secondarySystemBackground
        label.layer.borderWidth = 1
        label.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "editor.toast"
        view.addSubview(label)
        // Inside the safe area, and on one side of an iPhone Duo's fold.
        let lane = FoldLayout.lane(in: view.safeAreaLayoutGuide.layoutFrame, folds: folds(), trailing: true,
                                   rightToLeft: rightToLeft)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.leftAnchor, constant: lane.midX),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: max(120, lane.width - 40)),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.3) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
        }
    }
}

extension EditorViewController: UISheetPresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === askSheet { askSheet = nil }
    }
}

extension EditorViewController {
    /// The swipe down in Focus Preview only with the preview at its top
    /// (otherwise it is a scroll), and alongside the page's own gestures.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let swipe = g as? UISwipeGestureRecognizer, swipe.direction == .down else { return true }
        guard focusOn, let s = preview?.activeScrollView else { return false }
        return s.contentOffset.y <= -s.adjustedContentInset.top + 1
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        focusGestures.contains(g)
    }
}

final class PaddingLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 12, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 24, height: s.height + 16)
    }
}

/// TextKit 2's UITextView reports a viewport-wide contentSize when wrapping
/// is off. Keep the width we measured so later layout passes cannot shrink it.
final class EditorDocumentTextView: UITextView {
    weak var invisiblesOverlay: InvisiblesOverlay?
    override func layoutSubviews() {
        super.layoutSubviews()
        invisiblesOverlay?.refresh()
    }
    weak var regexFind: RegexFind?
    override func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        guard let regexFind else { return super.findInteraction(interaction, sessionFor: view) }
        let session = UITextSearchingFindSession(searchableObject: regexFind)
        regexFind.session = session
        return session
    }
    override func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        regexFind?.endSession()
        super.findInteraction(interaction, didEnd: session)
    }
    var minimumContentWidth: CGFloat = 0
    var markdownKeysEnabled: (() -> Bool)?
    var onMarkdownTab: ((Bool) -> Void)?
    var onMarkdownPaste: (() -> Bool)?
    var onKeyboardCaretMove: (() -> Void)?
    var onTypewriterScroll: (() -> Bool)?
    private var keyboardEdit = false
    private(set) var isPasting = false

    override var keyCommands: [UIKeyCommand]? {
        guard markdownKeysEnabled?() == true else { return super.keyCommands }
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(markdownTab))
        let backtab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(markdownBacktab))
        tab.wantsPriorityOverSystemBehavior = true
        backtab.wantsPriorityOverSystemBehavior = true
        return [tab, backtab] + (super.keyCommands ?? [])
    }

    @objc private func markdownTab() { onMarkdownTab?(true) }
    @objc private func markdownBacktab() { onMarkdownTab?(false) }

    override func paste(_ sender: Any?) {
        if onMarkdownPaste?() == true { onKeyboardCaretMove?(); return }
        isPasting = true
        defer { isPasting = false; onKeyboardCaretMove?() }
        super.paste(sender)
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
        onKeyboardCaretMove?()
    }

    override func replace(_ range: UITextRange, withText text: String) {
        super.replace(range, withText: text)
        onKeyboardCaretMove?()
    }

    /// An IME's composition is committed.
    override func unmarkText() {
        let hadMarked = markedTextRange != nil
        super.unmarkText()
        if hadMarked { onKeyboardCaretMove?() }
    }

    override func insertText(_ text: String) {
        keyboardEdit = true
        defer { keyboardEdit = false }
        super.insertText(text)
    }

    override func deleteBackward() {
        keyboardEdit = true
        defer { keyboardEdit = false }
        super.deleteBackward()
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        if keyboardEdit, onTypewriterScroll?() == true { return }
        super.scrollRangeToVisible(range)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.contains(where: { press in
            guard let key = press.key else { return false }
            return [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow, .keyboardDeleteForward].contains(key.keyCode)
        }) { onKeyboardCaretMove?() }
    }

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            super.contentSize = CGSize(width: max(newValue.width, minimumContentWidth), height: newValue.height)
        }
    }
}

