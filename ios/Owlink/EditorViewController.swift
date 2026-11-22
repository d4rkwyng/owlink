import UIKit
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
    let textView = UITextView(usingTextLayoutManager: true)
    private(set) var lineIndex = LineIndex()
    /// Left inset of the text before line numbers claim any of it.
    private let editorTextInsetLeft: CGFloat = 8
    /// This file's Readable Width choice. Nil follows Settings, which is off.
    private var readableWidthChoice: Bool?
    private var readableWidthOn: Bool { readableWidthChoice ?? AppSettings.readableWidthDefault }
    /// A jump forces numbers on for this tab without changing the setting.
    private var jumpShowsLineNumbers = false
    private var lastLineNumbersSetting = AppSettings.lineNumbers
    private var showLineNumbers: Bool { AppSettings.lineNumbers || jumpShowsLineNumbers }
    /// 1-based line drawn stronger in the gutter, the one just jumped to.
    private var markedLine: Int?
    private let lineNumberGutter = LineNumberGutter()
    private var colorizer: SyntaxColorizer!
    let owl = EditorOwl()
    let hintBar = OwlHintBar()
    private let statusBar = UIView()
    private let statusLabel = UILabel()
    private let languageButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    /// In the bar that rides on the keyboard, only while it is up.
    let hideKeyboardButton = UIButton(type: .system)
    private let split = UIStackView()
    private(set) var preview: PreviewController?
    private(set) var previewOn = false
    private var generation = 0
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
    /// Home-indicator inset last seen while the keyboard was down. A docked
    /// keyboard can inflate the safe area; that must not look like a tall
    /// home indicator and pin the bar under the keys.
    private var restingHomeInset: CGFloat = 0
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
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 10, left: editorTextInsetLeft, bottom: 80, right: 8)
        textView.accessibilityIdentifier = "editor.text"
        textView.allowsEditingTextAttributes = false
    }

    private func setUpStatusBar() {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "editor.status"
        for b in [languageButton, formatButton] {
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            b.showsMenuAsPrimaryAction = true
        }
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
        let row = UIStackView(arrangedSubviews: [languageButton, formatButton, UIView(), statusLabel, hideKeyboardButton])
        row.spacing = 14
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
        updateSplit()
        updateAskPanelWidth()
        layoutOwl()
        layoutDivider()
        layoutGutter()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    /// Home-indicator inset, ignoring a keyboard that has been added to the
    /// safe area (those are well over 80 pt; the indicator is not).
    private func homeInsetForStatusBar() -> CGFloat {
        let inset = view.safeAreaInsets.bottom
        if inset <= 80 { restingHomeInset = inset }
        return restingHomeInset
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
        let y = EditorPanes.statusBarBottom(viewHeight: view.bounds.height, keyboardTop: g.minY, keyboardBottom: g.maxY,
                                            homeInset: homeInset)
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
        let y = EditorPanes.statusBarBottom(viewHeight: view.bounds.height, keyboardTop: frame.minY, keyboardBottom: frame.maxY,
                                            homeInset: homeInset)
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
        if document.language.language == .markdown {
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

    private func moreMenuItems() -> [UIMenuElement] {
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
        quickly.accessibilityIdentifier = "editor.menu.quickOpen"
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
        var first: [UIMenuElement] = [save, replace, goTo, quickly, readable, ask, check]
        if document.language.language == .markdown {
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
                languageMenu(), formatMenu(),
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
        loading = true
        let sel = textView.selectedRange
        textView.text = document.text
        textView.font = AppSettings.font(for: traitCollection)
        textView.textColor = UIColor(hex: palette.foreground)
        textView.typingAttributes = [.font: AppSettings.font(for: traitCollection), .foregroundColor: UIColor(hex: palette.foreground)]
        lineIndex = LineIndex(textView.textStorage.string as NSString)
        if NSMaxRange(sel) <= (textView.text as NSString).length { textView.selectedRange = sel }
        loading = false
        // The text was replaced from disk: the old undo steps' ranges no
        // longer match it.
        textView.undoManager?.removeAllActions()
        colorizer.setLanguage(document.language.language)
        generation += 1
        updateStatus()
        updateBarButtons()
        scheduleOwl()
        refreshPreview()
        askModel?.documentReplaced()
    }

    @objc private func storageEdited() {
        let textStorage = textView.textStorage
        let edited = textStorage.editedRange, delta = textStorage.changeInLength
        guard textStorage.editedMask.contains(.editedCharacters), !loading else { return }
        let oldRange = NSRange(location: edited.location, length: edited.length - delta)
        let oldLines = lineIndex.lineCount
        let first = lineIndex.replace(oldRange, newLength: edited.length, in: textStorage.string as NSString)
        colorizer?.textDidChange(firstLine: first, lastLine: lineIndex.line(containing: NSMaxRange(edited)),
                                 lineDelta: lineIndex.lineCount - oldLines)
    }

    func textViewDidChange(_ textView: UITextView) {
        generation += 1
        updateDocumentChangeCount()
        recoveryWriter.textChanged()
        updateUndoItems()
        updateStatus()
        scheduleOwl()
        askModel?.documentEdited()
        if showLineNumbers { layoutGutter() }
        if previewOn || DetachedPreviews.hasPreviews(forPath: document.recoveryPath) {
            previewTimer?.invalidate()
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreview() }
            }
        }
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

    func textViewDidBeginEditing(_ textView: UITextView) { hideKeyboardButton.isHidden = false }
    func textViewDidEndEditing(_ textView: UITextView) { hideKeyboardButton.isHidden = true }

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
        updateStatus()
        fadeOwlNearCaret()
        // Find's Next moves the selection with the find bar up. That is the
        // "click next" jump: show the line number it landed on.
        guard textView.findInteraction?.isFindNavigatorVisible == true else { return }
        let line = lineIndex.line(containing: min(textView.selectedRange.location, lineIndex.length)) + 1
        jumpShowsLineNumbers = true
        markedLine = line
        layoutGutter()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        colorizer?.scheduleViewport()
        fadeOwlNearCaret()
        if scrollView === textView, showLineNumbers { layoutGutter() }
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
        statusLabel.text = s
        languageButton.setTitle(document.language.displayTitle, for: .normal)
        languageButton.menu = languageMenu()
        // A file that mixes line endings keeps each line's own: say so.
        let ending = document.mixedLineEndings ? String(localized: "\(document.lineEnding.displayName) (mixed)") : document.lineEnding.displayName
        formatButton.setTitle("\(document.encoding.displayName) · \(ending)", for: .normal)
        formatButton.menu = formatMenu()
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
        document.language.choose(l)
        colorizer.setLanguage(l)
        updateStatus()
        updateBarButtons()
        if l != .markdown, previewOn { togglePreview() }
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
        updateBarButtons()
        scheduleOwl()
        showHint()
    }

    private func applySettings() {
        let dark = traitCollection.userInterfaceStyle == .dark
        palette = AppSettings.theme.palette(systemIsDark: dark)
        applyBarStyle()
        let bg = UIColor(hex: palette.background)
        textView.backgroundColor = bg
        view.backgroundColor = bg
        textView.tintColor = UIColor(hex: palette.caret)
        textView.keyboardAppearance = palette.isDark ? .dark : .light
        statusBar.backgroundColor = UIColor(hex: palette.statusBar)
        statusLabel.textColor = UIColor(hex: palette.gutterForeground)
        owlSprite.onDark = palette.isDark
        let font = AppSettings.font(for: traitCollection)
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
        }
        textView.typingAttributes[.foregroundColor] = UIColor(hex: palette.foreground)
        applyWrap()
        colorizer?.setPalette(palette)
        refreshPreview()
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
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            EditorBarStyle.restore(window: themedWindow)
            themedWindow = nil
        }
    }

    private func applyWrap() {
        let c = textView.textContainer
        if AppSettings.wrap {
            c.widthTracksTextView = true
        } else {
            c.widthTracksTextView = false
            c.size = CGSize(width: 20_000, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        view.setNeedsLayout()
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
        return UIMenu(children: [ask, check, UIMenu(options: .displayInline, children: [hints, reset])])
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
        guard traitCollection.userInterfaceIdiom == .phone,
              !traitCollection.preferredContentSizeCategory.isAccessibilityCategory,
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
        let area = owlArea()
        guard area.width >= OwlSprite.size, area.height >= OwlSprite.size else {
            if owlInRail, !owlSprite.isDragging { setOwlFrame(owlFrame, inRail: false) }
            if askPanel != nil { owlSprite.isHidden = true }
            return
        }
        let size = CGSize(width: OwlSprite.size, height: OwlSprite.size)
        if !owlSprite.isDragging {
            if owlPlacement == .default, !AppSettings.defaults.bool(forKey: AppSettings.Key.owlManualPlacement), let slot = railOwlFrame() {
                setOwlFrame(slot, inRail: true)
            } else {
                let f = owlPlacement.frameYDown(in: area, size: size)
                setOwlFrame(OwlPlacement.avoidingFolds(f, folds: folds(), in: area), inRail: false)
            }
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
        textView.scrollRangeToVisible(abs)
        jumpShowsLineNumbers = true
        layoutGutter()
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

    @objc func askCedric() {
        // Ask is about the text: Focus Preview ends.
        if focusOn { exitFocusPreview() }
        let model = AskCedricModel(fileName: document.displayName, language: document.language.language)
        model.apply = { [weak self] proposal in self?.apply(proposal) ?? .refused }
        model.documentNow = { [weak self] in self?.currentDocument() ?? AskCedricModel.DocumentNow(text: "", generation: 0, readOnly: true, large: false, lines: LineIndex()) }
        model.makeSnapshot = { [weak self] in self?.askSnapshot() ?? OwlDocumentSnapshot(text: "", generation: 0) }
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
        textView.scrollRangeToVisible(placed)
        return .applied
    }

    // MARK: Preview

    @objc func togglePreview() {
        guard document.language.language == .markdown else { return }
        // ⇧⌘P in Focus Preview: back to the text.
        if focusOn { exitFocusPreview(); return }
        previewOn.toggle()
        if previewOn { makePreview() }
        layoutPreview()
        refreshPreview()
        updateBarButtons()
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
        guard document.language.language == .markdown else { return }
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
        layoutPreview()
        refreshPreview()
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
        p.show(markdown: textView.text, palette: palette)
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
        owl.cancel()
        textView.resignFirstResponder()
        document.close { [weak self] _ in
            guard let self else { return }
            // A clean close: the opened copy goes, and the recovery copy
            // unless the changes are still unsaved (a save that failed).
            self.recoveryWriter.stop(keepingCopy: !discarding && self.document.hasUnsavedChanges)
            self.document.discardOpenedCopy()
            OpenDocuments.registry.unregister(path: self.document.recoveryPath, window: self.windowID)
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
        textView.scrollRangeToVisible(r)
        if let sheet = askSheet?.sheetPresentationController, sheet.selectedDetentIdentifier == .large {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        }
        layoutGutter()
    }

    /// Horizontal insets for the text. Off, the gutter consumes the left
    /// inset as before. On, the column is centred; the gutter sits in the
    /// left margin when that margin is wide enough, otherwise it consumes
    /// width and the column centres in what remains.
    private func textInsets(gutterWidth: CGFloat) -> (left: CGFloat, right: CGFloat, gutterX: CGFloat) {
        let plain = (left: editorTextInsetLeft + gutterWidth, right: CGFloat(8), gutterX: CGFloat(0))
        guard readableWidthOn, AppSettings.wrap, textView.bounds.width > 1 else { return plain }
        let font = textView.font ?? AppSettings.font(for: traitCollection)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
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
    private func layoutGutter() {
        let font = (textView.font ?? AppSettings.font(for: traitCollection)).withSize(
            max(10, (textView.font?.pointSize ?? 13) * 0.85))
        let width = showLineNumbers ? LineNumberGutter.width(lineCount: lineIndex.lineCount, font: font) : 0
        let insets = textInsets(gutterWidth: width)
        var edge = textView.textContainerInset
        if abs(edge.left - insets.left) > 0.5 || abs(edge.right - insets.right) > 0.5 {
            edge.left = insets.left
            edge.right = insets.right
            textView.textContainerInset = edge
        }
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

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(togglePreview) || action == #selector(toggleFocusPreview) {
            return document.language.language == .markdown
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
        // After the group is closed (WillClose comes before it is counted).
        DispatchQueue.main.async { [weak self] in self?.updateUndoItems() }
    }

    private func updateUndoItems() {
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
        recoveryWriter.writeNow()
    }

    /// Replaces the whole text as one undoable edit (Undo brings it back).
    private func replaceAllText(with text: String) {
        guard let all = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) else { return }
        let g = generation
        textView.replace(all, withText: text)
        if generation == g { textViewDidChange(textView) }
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

    private func toast(_ text: String) {
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
        guard focusOn, let s = preview?.web.scrollView else { return false }
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
