import AppKit
import CedricCore
import CedricAI

/// Ask Cedric: a small floating panel per window, opened from the owl's
/// popover or Cedric › Ask Cedric… (⌥⌘/). Created on first use, so it costs
/// nothing at launch. Questions go to the AI engine chosen in Cedric AI
/// Settings (local or LAN only); answers stream in; an edit comes back as
/// proposed diff cards (up to five per answer) with Apply / Skip, each
/// applied as one undo step only while its text is still in the document
/// exactly once (a quick action's block: while the document is unchanged
/// since asking). A large document, and a tab whose extras are paused,
/// is treated as read-only. History is per document, in memory only.
@MainActor
final class OwlChatStore {
    static let shared = OwlChatStore()
    private(set) var histories: [UUID: [OwlChatEntry]] = [:]
    private var cached: (settings: LocalAISettings, engine: any OwlChatEngine)?
    private var scoreKeyCache: (settings: LocalAISettings, key: String?)?
    /// The last engine's context budget, for the scopes offered before the
    /// engine is made; till then the smallest (Apple Intelligence's).
    private(set) var contextBudget = 5_000
    private(set) var engineTitle: String?
    private var engineTitleSettings: LocalAISettings?
    let gate = OwlToolGate.bundled()

    func history(_ id: UUID) -> [OwlChatEntry] { histories[id] ?? [] }
    func displayTitle(settings: LocalAISettings) -> String {
        if engineTitleSettings == settings, let engineTitle { return engineTitle }
        return OwlChatEngines.displayTitle(settings: settings)
    }
    func append(_ e: OwlChatEntry, to id: UUID) { histories[id, default: []].append(e) }
    func replaceLast(_ e: OwlChatEntry, in id: UUID) {
        guard var h = histories[id], !h.isEmpty else { return }
        h[h.count - 1] = e
        histories[id] = h
    }
    func insertBeforeLast(_ e: OwlChatEntry, in id: UUID) {
        guard var h = histories[id], !h.isEmpty else { append(e, to: id); return }
        h.insert(e, at: h.count - 1)
        histories[id] = h
    }
    func clear(_ id: UUID) { histories[id] = nil }
    func closed(_ id: UUID) { histories[id] = nil }

    /// The engine for the saved AI settings (the fake under CEDRIC_AI_FAKE).
    func engine() async -> (any OwlChatEngine)? {
        if let d = AskCedricEngine.fakeDelay {
            let piece = DevEnvironment.values["CEDRIC_OWL_CHAT_FAKE_DELAY"].flatMap(Double.init) ?? min(0.08, max(0.01, d / 10))
            let e = FakeChatEngine(delay: piece)
            contextBudget = e.contextBudget
            engineTitle = e.title
            engineTitleSettings = nil
            return e
        }
        guard let s = AskCedricEngine.settings() else { return nil }
        if let c = cached, c.settings == s {
            contextBudget = c.engine.contextBudget
            engineTitle = c.engine.title
            engineTitleSettings = s
            return c.engine
        }
        guard let e = await OwlChatEngines.make(settings: s) else { return nil }
        cached = (s, e)
        contextBudget = e.contextBudget
        engineTitle = e.title
        engineTitleSettings = s
        return e
    }

    /// Tools for this engine's model: it scored ≥ 80% on the tool set
    /// (CEDRIC_OWL_TOOLS=0/1 overrides for one run).
    func useTools(_ engine: any OwlChatEngine) -> Bool {
        if let v = DevEnvironment.values["CEDRIC_OWL_TOOLS"] { return v == "1" }
        return gate.allowsTools(engine.scoreKey)
    }

    func invalidateScoreKey() { scoreKeyCache = nil }

    var previewUsesTools: Bool {
        if let v = DevEnvironment.values["CEDRIC_OWL_TOOLS"] { return v == "1" }
        if AskCedricEngine.fakeDelay != nil { return gate.allowsTools(FakeChatEngine(delay: 0).scoreKey) }
        guard let settings = AskCedricEngine.settings() else { return false }
        if let cached, cached.settings == settings { return gate.allowsTools(cached.engine.scoreKey) }
        if scoreKeyCache?.settings != settings {
            scoreKeyCache = (settings, OwlChatEngines.configuredScoreKey(settings: settings))
        }
        return scoreKeyCache?.key.map { gate.allowsTools($0) } ?? false
    }

    var inlineAllowsTools: Bool {
        if AskCedricEngine.fakeDelay != nil { return gate.allowsTools(FakeChatEngine(delay: 0).scoreKey) }
        guard let settings = AskCedricEngine.settings() else { return false }
        if let cached, cached.settings == settings { return gate.allowsTools(cached.engine.scoreKey) && useTools(cached.engine) }
        if scoreKeyCache?.settings != settings {
            scoreKeyCache = (settings, OwlChatEngines.configuredScoreKey(settings: settings))
        }
        guard let key = scoreKeyCache?.key, gate.allowsTools(key) else { return false }
        return DevEnvironment.values["CEDRIC_OWL_TOOLS"] != "0"
    }
}

/// Is a local engine ready for Ask Cedric (`OwlChatSetup`)? Never on the
/// launch path: asked when a menu, the owl or a grammar pass needs it, and
/// kept for 30 s (a model download or an AI settings change resets it).
/// Debug builds only (the checks): CEDRIC_ASK_ENGINE=0/1 overrides it
/// for one run, and the fake engine (a numeric CEDRIC_AI_FAKE) counts as
/// ready. A release build ignores both, so nothing in the environment
/// can turn AI on past the user's opt-in.
@MainActor
enum AskCedricEngine {
    private static var cache: (at: Date, settings: LocalAISettings?)?

    /// The fake engine's delay (CEDRIC_AI_FAKE=0.3); always nil in a release build.
    static var fakeDelay: Double? {
        #if DEBUG
        return DevEnvironment.values["CEDRIC_AI_FAKE"].flatMap(Double.init)
        #else
        return nil
        #endif
    }

    static func settings() -> LocalAISettings? {
        #if DEBUG
        let env = DevEnvironment.values
        if env["CEDRIC_ASK_ENGINE"] == "0" { return nil }
        if fakeDelay != nil || env["CEDRIC_ASK_ENGINE"] == "1" {
            var s = AIStore.load()
            s.enabled = true
            return s
        }
        #endif
        if let c = cache, Date().timeIntervalSince(c.at) < 30 { return c.settings }
        let built = BuiltInEngine()
        let s = OwlChatSetup.chatSettings(AIStore.load(), appleAvailable: AppleChatEngine.isAvailable,
                                          builtInInstalled: !built.installedModels.isEmpty)
        cache = (Date(), s)
        return s
    }

    static var isAvailable: Bool { settings() != nil }

    /// Where Ask Cedric's text goes, for the wording that says so.
    static func privacy(autoGrammar: Bool) -> AIPrivacyWording {
        let engine: AIPrivacyWording.Engine
        if let s = settings() {
            engine = s.backend.usesServer && fakeDelay == nil ? .server(host: s.baseURL.host) : .local
        } else {
            engine = .none
        }
        return AIPrivacyWording(engine: engine, autoGrammar: autoGrammar)
    }

    static func invalidate() {
        cache = nil
        OwlChatStore.shared.invalidateScoreKey()
    }
}

@MainActor
final class OwlChatPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private weak var tab: EditorWindowController?
    let panel: NSPanel
    let scopePopup = NSPopUpButton()
    let transcript = NSTextView()
    let input = NSTextField()
    private(set) var sendButton: NSButton!
    private(set) var stopButton: NSButton!
    private(set) var actionButtons: [OwlQuickAction: NSButton] = [:]
    let footer = NSTextField(labelWithString: "")
    // The proposed edits: a card each, in a scroll view under the transcript.
    let cardsStack = NSStackView()
    let cardsScroll = NSScrollView()
    private var cardsHeight: NSLayoutConstraint!
    private(set) var cards: [OwlEditCard] = []

    private var task: Task<Void, Never>?
    private(set) var running = false
    private var chunkedReviewRunning = false
    private var footerBeforeReview: String?
    private var reviewProgress: String?
    private var reviewScopeLabel: String?
    /// The first card's proposal (checks).
    var pending: OwlEditProposal? { cards.first?.proposal }
    var hasProposals: Bool { !cards.isEmpty }
    private var lastRequest: (question: String, action: OwlQuickAction?, inline: Bool, selection: NSRange?, selectionText: String?)?
    /// Streamed text not yet shown (flushed at ~30 Hz).
    private var pendingText = ""
    private var flushTimer: Timer?
    private var streamed = ""
    private var typingTimer: Timer?
    private var typingDots = "."
    private var typingIndicatorActive = false
    private var pendingInlineNote: String?
    private var scopes: [OwlChatScope] = []
    /// Requests asked (checks).
    private(set) var asks = 0
    private(set) var lastOutcome: OwlChatOutcome?
    /// The last request used tools (checks).
    private(set) var lastUsedTools = false
    var onFinish: ((OwlChatOutcome?) -> Void)?

    init(tab: EditorWindowController) {
        self.tab = tab
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.tabbingMode = .disallowed
        super.init()
        build()
    }

    var docID: UUID? { tab?.doc.id }

    // MARK: Building

    private func small(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.bezelStyle = .rounded
        return b
    }

    private func build() {
        panel.title = String(localized: "Ask Cedric")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 340, height: 320)
        panel.delegate = self

        let about = NSTextField(labelWithString: String(localized: "Asking about:"))
        about.font = .systemFont(ofSize: 11)
        about.textColor = .secondaryLabelColor
        scopePopup.setAccessibilityLabel(String(localized: "Asking about"))
        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        // No owl in here: the editor's own owl, wherever he sits, reacts
        // to the conversation (OwlController.chatCue).
        let head = NSStackView(views: [about, scopePopup, NSView()])
        head.spacing = 6
        head.alignment = .centerY

        // Two rows: what it does (and the script check), then the rest.
        let firstRow = NSStackView()
        let secondRow = NSStackView()
        for row in [firstRow, secondRow] { row.spacing = 4 }
        for a in OwlQuickAction.allCases {
            let b = small(a.title(prose: false), #selector(quickAction(_:)))
            b.tag = OwlQuickAction.allCases.firstIndex(of: a)!
            actionButtons[a] = b
            ([.explain, .explainLine, .scriptSafety].contains(a) ? firstRow : secondRow).addArrangedSubview(b)
        }
        let actions = NSStackView(views: [firstRow, secondRow])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 4

        transcript.isEditable = false
        transcript.isRichText = true
        transcript.font = .systemFont(ofSize: 12)
        transcript.textContainerInset = NSSize(width: 4, height: 6)
        transcript.drawsBackground = true
        transcript.backgroundColor = .textBackgroundColor
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityLabel(String(localized: "Conversation"))
        let tScroll = NSScrollView()
        tScroll.documentView = transcript
        tScroll.hasVerticalScroller = true
        tScroll.borderType = .bezelBorder
        tScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        tScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        // Proposed edits.
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 6
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        let flipped = CardsDocumentView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(cardsStack)
        NSLayoutConstraint.activate([
            cardsStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        cardsScroll.documentView = flipped
        cardsScroll.hasVerticalScroller = true
        cardsScroll.drawsBackground = false
        flipped.widthAnchor.constraint(equalTo: cardsScroll.contentView.widthAnchor).isActive = true
        cardsHeight = cardsScroll.heightAnchor.constraint(equalToConstant: 0)
        cardsHeight.isActive = true
        cardsScroll.setAccessibilityLabel(String(localized: "Proposed changes"))
        cardsScroll.isHidden = true

        input.placeholderString = String(localized: "Ask about this text…")
        input.setAccessibilityLabel(String(localized: "Question for Cedric"))
        input.font = .systemFont(ofSize: 12)
        input.target = self
        input.action = #selector(send(_:))
        input.delegate = self
        sendButton = small(String(localized: "Ask"), #selector(send(_:)))
        stopButton = small(String(localized: "Stop"), #selector(stop(_:)))
        stopButton.isHidden = true
        let inputRow = NSStackView(views: [input, sendButton, stopButton])
        inputRow.spacing = 6
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = small(String(localized: "Copy as Markdown"), #selector(copyMarkdown(_:)))
        let clear = small(String(localized: "Clear"), #selector(clearHistory(_:)))
        let foot = NSStackView(views: [footer, NSView(), clear, copy])
        foot.spacing = 6

        let stack = NSStackView(views: [head, actions, tScroll, cardsScroll, inputRow, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for v in [head, tScroll, cardsScroll, inputRow, foot, actions] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 10).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -10).isActive = true
        }
        panel.contentView = stack
    }

    // MARK: Showing

    /// A floating panel of its own, not a child window of the tab (0.2.1):
    /// dragged as a child window it trailed the cursor by one mouse event
    /// all the way (measured in a macOS 26 VM with real CGEvent drags: 5 pt
    /// behind at every 16 ms step; as its own panel, 0), which Derek saw as
    /// stutter. It hides with
    /// its tab (another tab selected, the window minimized or closed) and
    /// comes back with it; it no longer follows the window around.
    /// Where it opens: `place(in:)`.
    func show() {
        guard let tab, let w = tab.window else { return }
        follow(w)
        let opening = !panel.isVisible
        if opening { place(in: w) }
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        if opening { tab.owl?.chatOpened(panel, engineReady: AskCedricEngine.isAvailable) }
    }

    /// The user moved the panel since it last opened by itself: from then
    /// on (this tab, this run of the app) it opens where they left it.
    private(set) var movedByUser = false
    /// Where it opened next to the owl (checks: nil when it didn't).
    private(set) var openedBesideOwl: NSRect?
    private var placedOrigin: NSPoint?
    private var placing = false

    /// Where it opens, every time it opens (`OwlChatPlacement`):
    /// 1. moved by the user this session: where they left it (if that is
    ///    still on a screen);
    /// 2. the owl on screen: beside him, wherever he sits, on the side
    ///    with room, inside the screen's visible frame;
    /// 3. no owl (Hide Cedric, or none in this tab): the window's
    ///    bottom-right corner, as before. The owl isn't shown for it.
    private func place(in w: NSWindow) {
        openedBesideOwl = nil
        if movedByUser, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { return }
        if let owl = tab?.owl?.screenFrame {
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: owl.midX, y: owl.midY)) } ?? w.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                setOrigin(OwlChatPlacement.panelOrigin(owl: owl, panel: panel.frame.size, screen: visible))
                openedBesideOwl = owl
                return
            }
        }
        position(in: w)
    }

    private func setOrigin(_ o: NSPoint) {
        placing = true
        panel.setFrameOrigin(o)
        placing = false
        placedOrigin = panel.frame.origin
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing, panel.isVisible, let placedOrigin, panel.frame.origin != placedOrigin else { return }
        movedByUser = true
    }

    private weak var followed: NSWindow?
    private var followers: [NSObjectProtocol] = []
    /// Hidden because its tab's window isn't on screen, to come back with it.
    private var hiddenWithTab = false

    private func follow(_ w: NSWindow) {
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .fullScreenDisallowsTiling]
        guard followed !== w else { return }
        unfollow()
        followed = w
        let nc = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.tabWindowChanged() } }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification] {
            followers.append(nc.addObserver(forName: name, object: w, queue: .main, using: update))
        }
        followers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    /// Still watching a tab window (the checks: false once closed).
    var followsTabWindow: Bool { followed != nil || !followers.isEmpty }

    private func unfollow() {
        followers.forEach { NotificationCenter.default.removeObserver($0) }
        followers = []
        followed = nil
    }

    /// Its tab went away (another tab selected, minimized) or came back.
    private func tabWindowChanged() {
        guard let w = followed else { return }
        let onScreen = w.isVisible && !w.isMiniaturized && (w.tabGroup?.selectedWindow ?? w) === w
        if !onScreen, panel.isVisible {
            hiddenWithTab = true
            panel.orderOut(nil)
        } else if onScreen, hiddenWithTab, NSApp.isActive {
            hiddenWithTab = false
            panel.orderFront(nil)
        }
    }

    /// The default place, with no owl to sit beside: the window's
    /// bottom-right corner, inside the screen.
    private func position(in w: NSWindow) {
        let size = panel.frame.size
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
        var o = NSPoint(x: w.frame.maxX - size.width - 24, y: w.frame.minY + 100)
        o.x = min(max(o.x, screen.minX + 4), screen.maxX - size.width - 4)
        o.y = min(max(o.y, screen.minY + 4), screen.maxY - size.height - 4)
        setOrigin(o)
    }

    var isShown: Bool { panel.isVisible }

    func close() {
        stopTypingIndicator(renderAfter: false)
        stop(nil)
        hiddenWithTab = false
        unfollow()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        tab?.owl?.chatClosed()
    }

    func windowWillClose(_ notification: Notification) {
        stopTypingIndicator(renderAfter: false)
        stop(nil)
        hiddenWithTab = false
        // Closed by its own close button or Escape (not `close()`): stop
        // watching the tab's window too.
        unfollow()
        panel.parent?.removeChildWindow(panel)
        tab?.owl?.chatClosed()
    }

    /// The scope chip, the action titles (prose or code), the footer and the transcript.
    func refresh() {
        guard let tab else { return }
        let s = snapshot()
        let history = docID.map { OwlChatStore.shared.history($0) } ?? []
        let tools = OwlChatStore.shared.previewUsesTools
        let server = AskCedricEngine.fakeDelay == nil && (AskCedricEngine.settings()?.backend.usesServer ?? false)
        let picture = OwlPicture.isPicture(fileName: s.fileName)
            ? SVGPictureSource(text: s.text, folder: tab.doc.fileURL?.deletingLastPathComponent()) : nil
        let budget = OwlInlineAssist.documentBudget(engineBudget: OwlChatStore.shared.contextBudget, instructionWrapper: "",
                                                    systemPrompt: OwlPrompts.chatSystem(toolsOn: tools, server: server),
                                                    history: history)
        scopes = OwlChatContext.scopes(for: s, budget: budget)
        // The user's own pick stays while it's offered; else the default
        // is worked out again each time.
        let current = pickedScope.flatMap { scopes.contains($0) ? $0 : nil }
        scopePopup.removeAllItems()
        for sc in scopes {
            let label = (chunkedReviewRunning && sc == .wholeDocument ? reviewScopeLabel : nil)
                ?? OwlChatRequest.documentContext(s, scope: sc, engineBudget: OwlChatStore.shared.contextBudget,
                                                       history: history, question: "", action: nil, tools: tools,
                                                       server: server, prose: isProse, imageSource: picture,
                                                       preview: true)?.label ?? sc.title
            scopePopup.addItem(withTitle: label)
            scopePopup.lastItem?.representedObject = sc.rawValue
        }
        let pick = current ?? OwlChatContext.defaultScope(for: s, budget: budget)
        if let i = scopes.firstIndex(of: pick) { scopePopup.selectItem(at: i) }
        let prose = isProse
        let script = !prose && ScriptSafety.isScript(tab.doc.language)
        for (a, b) in actionButtons {
            b.title = a.title(prose: prose)
            b.isHidden = !a.isOffered(prose: prose, language: tab.doc.language)
        }
        if script { actionButtons[.explain]?.title = String(localized: "What Does It Do?") }
        if tab.textView.selectedRange().length > 0 { actionButtons[.explainLine]?.title = String(localized: "Explain Selection") }
        if AskCedricEngine.fakeDelay != nil {
            footer.stringValue = String(localized: "On this Mac · test engine")
        } else if let chat = AskCedricEngine.settings() {
            let place = chat.backend.usesServer ? (chat.baseURL.host ?? "this Mac") : String(localized: "this Mac")
            footer.stringValue = String(localized: "On \(place) · \(OwlChatStore.shared.displayTitle(settings: chat))")
        } else {
            footer.stringValue = String(localized: "No AI engine yet: set one up in Cedric AI Settings.")
        }
        if chunkedReviewRunning, let reviewProgress {
            footerBeforeReview = footer.stringValue
            footer.stringValue = reviewProgress
        }
        panel.title = String(localized: "Ask Cedric — \(tab.doc.displayName)")
        render()
        updateButtons()
        // Opening (or a check refreshing the panel) catches cards up. Typing
        // does not come through here.
        refreshCards()
    }

    /// Keep the footer on the resolved engine, including an auto-picked server model.
    private func showEngineTitle(_ engine: any OwlChatEngine) {
        if AskCedricEngine.fakeDelay != nil {
            footer.stringValue = String(localized: "On this Mac · test engine")
        } else {
            let place = engine.usesServer ? (AskCedricEngine.settings()?.baseURL.host ?? String(localized: "this Mac")) : String(localized: "this Mac")
            footer.stringValue = String(localized: "On \(place) · \(engine.title)")
        }
        if chunkedReviewRunning, let reviewProgress {
            footerBeforeReview = footer.stringValue
            footer.stringValue = reviewProgress
        }
    }

    private var isProse: Bool {
        guard let tab else { return false }
        if let p = tab.grammar.lastSawProse { return p }
        return tab.doc.language == .plain || tab.doc.language == .markdown
    }

    private func updateButtons() {
        sendButton.isHidden = running
        stopButton.isHidden = !running
        for b in actionButtons.values { b.isEnabled = !running }
        input.isEnabled = !running
    }

    var selectedScope: OwlChatScope {
        (scopePopup.selectedItem?.representedObject as? String).flatMap(OwlChatScope.init(rawValue:)) ?? .wholeDocument
    }

    func selectScope(_ s: OwlChatScope) {
        if let i = scopes.firstIndex(of: s) { scopePopup.selectItem(at: i); pickedScope = s }
    }

    /// The scope the user picked from the menu (nil: the default).
    private var pickedScope: OwlChatScope?

    @objc private func scopeChanged(_ sender: Any?) { pickedScope = selectedScope }

    // MARK: Transcript

    private func attributed(_ e: OwlChatEntry) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        switch e.role {
        case .user:
            out.append(NSAttributedString(string: String(localized: "You") + "\n", attributes: label))
            out.append(NSAttributedString(string: e.text + "\n\n", attributes: body))
        case .owl:
            out.append(NSAttributedString(string: String(localized: "Cedric") + "\n", attributes: label))
            out.append(NSAttributedString(string: e.text, attributes: body))
            out.append(NSAttributedString(string: "\n\n", attributes: body))
        case .tool, .note:
            out.append(NSAttributedString(string: e.text + "\n", attributes: quiet))
        case .scan:
            out.append(NSAttributedString(string: String(localized: "Offline scan (no AI)") + "\n", attributes: label))
            let mono: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
            out.append(NSAttributedString(string: e.text + "\n\n", attributes: mono))
        }
        return out
    }

    private func render() {
        guard let id = docID, let storage = transcript.textStorage else { return }
        let all = NSMutableAttributedString()
        let h = OwlChatStore.shared.history(id)
        if h.isEmpty {
            all.append(NSAttributedString(string: String(localized: "Ask a question, or pick a quick action. Cedric sees only what the chip above says, and nothing leaves this Mac or your network.") + "\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for (index, entry) in h.enumerated() {
            if index == h.count - 1, entry.role == .owl, entry.text.isEmpty, running, typingIndicatorActive {
                all.append(attributed(OwlChatEntry(role: .owl, text: typingDots)))
            } else {
                all.append(attributed(entry))
            }
        }
        transcript.setAccessibilityLabel(typingIndicatorActive
            ? String(localized: "Cedric is writing")
            : String(localized: "Conversation"))
        storage.setAttributedString(all)
        transcript.scrollToEndOfDocument(nil)
    }

    /// The transcript's text (checks).
    var transcriptText: String { transcript.string }

    // MARK: Asking

    @objc func quickAction(_ sender: NSButton) {
        guard sender.tag < OwlQuickAction.allCases.count else { return }
        let a = OwlQuickAction.allCases[sender.tag]
        switch a {
        case .scriptSafety: checkScriptSafety()
        case .explainLine: explainLine()
        default: ask(question: sender.title, action: a)
        }
    }

    /// Explain Line: the selection, or the caret's whole line.
    func explainLine() {
        guard let tab else { return }
        let tv = tab.textView
        var sel = tv.selectedRange()
        let ns = tv.string as NSString
        if sel.length == 0 {
            let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            var len = line.length
            while len > 0, [10, 13].contains(Int(ns.character(at: line.location + len - 1))) { len -= 1 }
            guard len > 0 else { NSSound.beep(); return }
            sel = NSRange(location: line.location, length: len)
        }
        let title = actionButtons[.explainLine]?.title ?? OwlQuickAction.explainLine.title(prose: false)
        ask(question: title, action: .explainLine, selection: sel, scope: .selection)
    }

    /// The offline findings of the last script check (checks).
    private(set) var lastScan: [ScriptSafety.Finding]?
    /// The last script check's scan stopped at `ScriptSafety.maxLines` (checks).
    private(set) var lastScanTruncated = false
    /// The running script check's forced verdict, for an answer cut short.
    private var forcedVerdict: ScriptVerdict.Reason?
    /// The running script check's answer, clamped as it streams in.
    private var verdictStream: ScriptVerdictStream?
    /// This answer is about a script: "safe" claims are rewritten (`OwlChatRequest.safeClaimGuard`).
    private var safeClaimGuard: ScriptVerdict.Guard?
    /// What of the streamed answer the transcript shows now (script check).
    private var shownAnswer = ""
    /// Every text the script check's answer showed while streaming (checks).
    private(set) var streamedRenders: [String] = []

    /// Check for Risks: the offline scan first (no AI; works on any Mac),
    /// then, with Ask Cedric on and an engine ready, the model's review of
    /// the whole script (or a centred window) with the findings attached.
    /// The verdict is never "safe" (`ScriptVerdict`), and is "Don't run
    /// it" after a high finding or a partial review.
    func checkScriptSafety() {
        guard !running, let tab, docID != nil else { return }
        // Over the auto-review cap: only once the user confirmed.
        guard !tab.autoReviewCapped || tab.autoReviewAskConfirmed else {
            tab.confirmAskingCedric(over: panel) { [weak self] in self?.checkScriptSafety() }
            return
        }
        guard let id = docID else { return }
        let text = tab.textView.string
        let language = tab.doc.language
        discardProposal(nil)
        let question = String(localized: "Check this script for risks.")
        OwlChatStore.shared.append(OwlChatEntry(role: .user, text: question), to: id)
        render()
        running = true
        updateButtons()
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .userInitiated) { ScriptSafety.check(text, language: language) }.value
            guard let self, let id = self.docID else { return }
            self.running = false
            self.lastScan = report.findings
            self.lastScanTruncated = report.truncated
            let summary = ScriptSafety.summary(report)
            OwlChatStore.shared.append(OwlChatEntry(role: .scan, text: summary), to: id)
            if Settings.shared.owlChat, AskCedricEngine.isAvailable {
                self.selectScope(.wholeDocument)
                self.ask(question: question, action: .scriptSafety, scope: .wholeDocument,
                         scan: report.findings.isEmpty && !report.truncated ? nil : summary,
                         scanHasHigh: report.hasHigh, scanTruncated: report.truncated, showQuestion: false)
            } else {
                var note = String(localized: "No AI engine is set up, so this is the offline scan only: it flags risky patterns, it can’t prove a script is harmless.")
                if let reason = ScriptVerdict.forcedReason(scanHasHigh: report.hasHigh, truncated: report.truncated) {
                    note += "\n" + reason.note + "\nVerdict: " + ScriptVerdict.forcedDontRun + "."
                }
                OwlChatStore.shared.append(OwlChatEntry(role: .note, text: note), to: id)
                self.render()
                self.updateButtons()
                self.onFinish?(nil)
            }
        }
    }

    @objc func send(_ sender: Any?) {
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        input.stringValue = ""
        ask(question: q, action: nil)
    }

    func snapshot() -> OwlDocumentSnapshot {
        guard let tab else { return OwlDocumentSnapshot(text: "", generation: 0) }
        let tv = tab.textView
        return OwlDocumentSnapshot(text: tv.string, generation: tab.doc.changeCount, selection: tv.selectedRange(),
                                   visible: tv.visibleCharacterRange, fileName: tab.doc.fileURL?.lastPathComponent,
                                   language: tab.doc.language.rawValue,
                                   // For check_document: the owl's facts and the grammar checker's findings now.
                                   facts: tab.owlFacts(wholeDocument: true), grammar: tab.grammar.issues)
    }

    /// `selection` and `scope` override the document's and the chip's;
    /// `scan` is the script check's findings.
    func ask(question: String, action: OwlQuickAction?, selection: NSRange? = nil, scope forced: OwlChatScope? = nil,
             scan: String? = nil, scanHasHigh: Bool = false, scanTruncated: Bool = false, showQuestion: Bool = true,
             inline: Bool = false) {
        guard !running, let tab, let id = docID else { return }
        // Over the auto-review cap: asked for, so it may run, once the
        // user has confirmed (the size, and that auto-review is off). The
        // whole-file chunked review starts only from here.
        guard !tab.autoReviewCapped || tab.autoReviewAskConfirmed else {
            tab.confirmAskingCedric(over: panel) { [weak self] in
                self?.ask(question: question, action: action, selection: selection, scope: forced, scan: scan,
                          scanHasHigh: scanHasHigh, scanTruncated: scanTruncated, showQuestion: showQuestion, inline: inline)
            }
            return
        }
        discardProposal(nil)
        forcedVerdict = nil
        verdictStream = nil
        safeClaimGuard = nil
        shownAnswer = ""
        streamedRenders = []
        pendingInlineNote = nil
        chunkedReviewRunning = false
        footerBeforeReview = nil
        reviewProgress = nil
        reviewScopeLabel = nil
        var snap = snapshot()
        if let selection {
            snap = OwlDocumentSnapshot(text: snap.text, generation: snap.generation, selection: selection, visible: snap.visible,
                                       fileName: snap.fileName, language: snap.language, facts: snap.facts, grammar: snap.grammar)
        }
        let originalSelection = inline ? snap.selection : nil
        let originalSelectionText = originalSelection.map(snap.substring)
        lastRequest = (question, action, inline, originalSelection, originalSelectionText)
        let scope = forced ?? selectedScope
        let prose = isProse
        var history = OwlChatStore.shared.history(id)
        if !showQuestion, history.last?.role == .scan { history.removeLast() }
        if !showQuestion, history.last?.role == .user { history.removeLast() }
        if showQuestion { OwlChatStore.shared.append(OwlChatEntry(role: .user, text: question), to: id) }
        OwlChatStore.shared.append(OwlChatEntry(role: .owl, text: ""), to: id)
        running = true
        startTypingIndicator()
        render()
        tab.contextBar?.refreshStates()
        asks += 1
        streamed = ""
        flushes = 0
        updateButtons()
        tab.owl?.chatCue(.asked)
        // The user asked: this request may load the built-in model
        // (BuiltInLoadIntent). Everything it starts inherits that.
        task = BuiltInLoad.$intent.withValue(.userAsked) { Task { @MainActor [weak self] in
            guard let self else { return }
            guard let engine = await OwlChatStore.shared.engine() else {
                self.finish(nil, error: String(localized: "No AI engine is ready. Set one up in Cedric › Cedric AI Settings…"))
                return
            }
            self.showEngineTitle(engine)
            let tools = OwlChatStore.shared.useTools(engine)
            if inline, action == .rewrite, (!tools || !OwlChatStore.shared.gate.allowsTools(engine.scoreKey)) {
                self.finish(nil, error: String(localized: "This model is not enabled for proposed edits."))
                return
            }
            var requestSnapshot = snap
            var inlineClip: OwlInlineAssist.SelectionClip?
            // An SVG may offer describe_image even when the selected action
            // otherwise has no tools.
            let picture = OwlPicture.isPicture(fileName: snap.fileName)
                ? SVGPictureSource(text: snap.text, folder: tab.doc.fileURL?.deletingLastPathComponent()) : nil
            func context(for scope: OwlChatScope) -> OwlChatContext? {
                OwlChatRequest.documentContext(snap, scope: scope, engineBudget: engine.contextBudget,
                                               history: history, question: question, action: action,
                                               tools: tools, server: engine.usesServer, prose: prose,
                                               imageSource: picture, scan: scan, inline: inline)
            }
            // The chip can still say Selection after the user has clicked away.
            var usedScope = scope
            var ctx = context(for: usedScope)
            if ctx == nil, usedScope == .selection, !snap.hasSelection, !inline {
                usedScope = .wholeDocument
                ctx = context(for: usedScope)
            }
            guard let ctx else {
                self.finish(nil, error: String(localized: "The selected text is no longer available."))
                return
            }
            if let index = self.scopes.firstIndex(of: usedScope) {
                self.scopePopup.item(at: index)?.title = ctx.label
                self.scopePopup.selectItem(at: index)
            }
            if inline, let action {
                let budgetRequest = OwlChatRequest(question: question, action: action, context: ctx, snapshot: snap,
                                                   history: history, useTools: tools, prose: prose, scan: scan,
                                                   scanHasHigh: scanHasHigh, scanTruncated: scanTruncated, imageSource: picture)
                let additions = budgetRequest.contextAdditions(engineBudget: engine.contextBudget)
                let promptTools = !OwlTools.specs(budgetRequest.tools).isEmpty
                let system = OwlPrompts.chatSystem(toolsOn: promptTools, server: engine.usesServer,
                                                   digest: additions.digest != nil, checks: additions.checks != nil,
                                                   canEdit: budgetRequest.tools.contains(.proposeEdit),
                                                   partial: budgetRequest.contextIsPartial)
                let wrapper = OwlInlineAssist.instruction(action: action, selection: "", prose: prose,
                                                          toolsOn: tools, context: ctx)
                let room = OwlInlineAssist.remainingBudget(engineBudget: engine.contextBudget,
                                                           numberedContext: ctx.numbered, instructionWrapper: wrapper,
                                                           systemPrompt: system, history: history,
                                                           digestReservation: additions.digestReservation)
                let clip = OwlInlineAssist.clip(snap.substring(snap.selection), budget: room)
                inlineClip = clip
                pendingInlineNote = clip.note
                requestSnapshot = OwlDocumentSnapshot(text: snap.text, generation: snap.generation,
                                                      selection: NSRange(location: snap.selection.location,
                                                                         length: (clip.text as NSString).length),
                                                      visible: snap.visible, fileName: snap.fileName, language: snap.language,
                                                      facts: snap.facts, grammar: snap.grammar)
                if clip.text.isEmpty {
                    self.finish(nil, error: String(localized: "There isn’t enough room in this model’s context for the selected text."))
                    return
                }
            }
            self.lastUsedTools = tools
            var req = OwlChatRequest(question: question, action: action, context: ctx, snapshot: requestSnapshot,
                                     history: history, useTools: tools, prose: prose, scan: scan,
                                     scanHasHigh: scanHasHigh, scanTruncated: scanTruncated, imageSource: picture,
                                     inlineSelection: inline ? inlineClip?.text : nil,
                                     inlineSelectionNote: inlineClip?.note)
            if action == .scriptSafety { req.scanFindings = self.lastScan }
            if let plan = OwlChunkedReviewRunner.plan(req, engine: engine) {
                guard self.running, !Task.isCancelled else { return }
                self.chunkedReviewRunning = true
                self.footerBeforeReview = self.footer.stringValue
                if let index = self.scopes.firstIndex(of: usedScope), let first = plan.parts.first, let last = plan.parts.last {
                    let label = plan.isComplete
                        ? String(localized: "Whole document (\(plan.totalLines) lines)")
                        : String(localized: "Lines \(first.first)–\(last.last) of \(plan.totalLines) (rest not reviewed)")
                    self.reviewScopeLabel = label
                    self.scopePopup.item(at: index)?.title = label
                }
                let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine, model: engine.scoreKey,
                                                              describeError: Self.describe) { [weak self] _, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        guard let self, self.running, self.chunkedReviewRunning else { return }
                        let progress = String(localized: "Reviewing…")
                        self.reviewProgress = progress
                        self.footer.stringValue = progress
                    } }
                }
                self.finish(result.outcome, error: nil, stopped: result.stopped, failed: result.error != nil)
                return
            }
            if OwlChunkedReviewRunner.eligible(req) { req = OwlChunkedReviewRunner.wholeRequest(req) }
            self.forcedVerdict = req.forcedVerdict
            // Any answer about a script: clamped before it shows (ScriptVerdictStream).
            self.safeClaimGuard = req.safeClaimGuard
            if let mode = req.safeClaimGuard { self.verdictStream = ScriptVerdictStream(forced: req.forcedVerdict, guard: mode) }
            do {
                let outcome = try await OwlChatRunner.run(req, engine: engine, model: engine.scoreKey) { [weak self] ev in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(ev) } }
                }
                // Events queued before this point are delivered first.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(outcome, error: nil) } }
            } catch is CancellationError {
                self.finish(nil, error: String(localized: "Stopped."))
            } catch LocalAIError.cancelled {
                self.finish(nil, error: String(localized: "Stopped."))
            } catch BuiltInError.cancelled {
                self.finish(nil, error: String(localized: "Stopped."))
            } catch {
                self.finish(nil, error: Self.describe(error))
            }
        } }
    }

    nonisolated static func describe(_ e: Error) -> String {
        switch e {
        case LocalAIError.timedOut: return String(localized: "The model took too long to answer.")
        case LocalAIError.endpointNotLocal: return String(localized: "The AI address isn’t on this Mac or the local network.")
        case LocalAIError.http(let c): return String(localized: "The AI server answered with an error (\(c)).")
        case BuiltInError.promptTooLong: return String(localized: "Too much text for this model: select less and ask again.")
        case BuiltInError.notInstalled: return String(localized: "No model downloaded yet: download one in Settings › Cedric.")
        case BuiltInError.loadTimedOut: return String(localized: "The built-in model didn’t finish loading. Automatic AI is off for now; ask again to retry once, or restart Owlink.")
        case BuiltInError.unhealthy: return String(localized: "The built-in model didn’t finish loading earlier. Restart Owlink to try it again.")
        case BuiltInError.automaticLoadNotAllowed: return String(localized: "The built-in model isn’t loaded yet: ask again.")
        default: return String(localized: "Something went wrong: \(String(String(describing: e).prefix(160)))")
        }
    }

    private func handle(_ ev: OwlChatEvent) {
        guard running, let id = docID else { return }
        switch ev {
        case .text(let t):
            tab?.owl?.chatCue(.streaming)
            let firstText = typingIndicatorActive && !t.isEmpty
            if firstText { stopTypingIndicator() }
            pendingText += t
            if firstText {
                flush()
                return
            }
            if flushTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.flush() }
                }
                RunLoop.main.add(timer, forMode: .common)
                flushTimer = timer
            }
        case .tool(let name, let summary):
            flush()
            // Above the answer being written.
            OwlChatStore.shared.insertBeforeLast(OwlChatEntry(role: .tool, text: "· " + summary), in: id)
            render()
            if name == .searchDocument { tab?.owl?.chatCue(.searching) }
        case .proposal:
            tab?.owl?.chatCue(.proposing)
        case .phase(let p):
            tab?.owl?.chatCue(p == .thinking ? .asked : p == .searching ? .searching : .streaming)
        }
    }

    /// Streamed text into the last (Cedric) entry and the transcript's end.
    private func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !pendingText.isEmpty, let id = docID else { return }
        let t = pendingText
        pendingText = ""
        streamed += t
        flushes += 1
        if var vs = verdictStream {
            // About a script: clamped before it shows (ScriptVerdictStream).
            let shown = vs.append(t)
            verdictStream = vs
            streamedRenders.append(shown)
            OwlChatStore.shared.replaceLast(OwlChatEntry(role: .owl, text: shown), in: id)
            if let storage = transcript.textStorage, storage.length >= 2 + (shownAnswer as NSString).length {
                let old = (shownAnswer as NSString).length
                storage.replaceCharacters(in: NSRange(location: storage.length - 2 - old, length: old),
                                          with: NSAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
                transcript.scrollToEndOfDocument(nil)
            }
            shownAnswer = shown
            return
        }
        OwlChatStore.shared.replaceLast(OwlChatEntry(role: .owl, text: streamed), in: id)
        // Before the trailing "\n\n" of the last entry.
        if let storage = transcript.textStorage, storage.length >= 2 {
            storage.insert(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]),
                           at: storage.length - 2)
            transcript.scrollToEndOfDocument(nil)
        }
    }

    private func startTypingIndicator() {
        stopTypingIndicator(renderAfter: false)
        typingIndicatorActive = true
        typingDots = "."
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.typingIndicatorActive else { return }
                self.typingDots = self.typingDots.count == 3 ? "." : self.typingDots + "."
                self.render()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        typingTimer = timer
    }

    private func stopTypingIndicator(renderAfter: Bool = true) {
        typingTimer?.invalidate()
        typingTimer = nil
        guard typingIndicatorActive else { return }
        typingIndicatorActive = false
        transcript.setAccessibilityLabel(String(localized: "Conversation"))
        if renderAfter { render() }
    }

    /// A flush timer or a request is pending (checks: none once closed).
    var hasTimers: Bool { flushTimer != nil || typingTimer != nil || task != nil }

    /// Times streamed text reached the transcript during this answer (checks).
    private(set) var flushes = 0
    /// Characters of answer shown so far (checks: streaming arrives in steps).
    var streamedCount: Int { streamed.count }

    private func finish(_ outcome: OwlChatOutcome?, error: String?, stopped: Bool = false, failed: Bool = false) {
        guard running else { return }
        stopTypingIndicator(renderAfter: false)
        flush()
        running = false
        chunkedReviewRunning = false
        reviewProgress = nil
        reviewScopeLabel = nil
        if let footerBeforeReview { footer.stringValue = footerBeforeReview; self.footerBeforeReview = nil }
        tab?.contextBar?.refreshStates()
        tab?.owl?.chatCue(stopped || task?.isCancelled == true ? .stopped : failed || outcome == nil ? .failed : .answered)
        task = nil
        lastOutcome = outcome
        if let id = docID {
            if let outcome {
                // An empty answer falls back to what streamed, guarded the same way.
                let text = OwlChatRunner.storedText(answer: outcome.answer, streamed: streamed, guard: safeClaimGuard, forced: forcedVerdict)
                OwlChatStore.shared.replaceLast(OwlChatEntry(role: .owl, text: text, proposals: outcome.proposals), in: id)
            } else if let error {
                // A script check cut short still never reads as "safe".
                let partial = !streamed.isEmpty
                    ? OwlChatRunner.storedText(answer: "", streamed: streamed, guard: safeClaimGuard, forced: forcedVerdict) : streamed
                let text = partial.isEmpty ? error : partial + " (" + error + ")"
                OwlChatStore.shared.replaceLast(OwlChatEntry(role: .note, text: text), in: id)
            }
            if let note = pendingInlineNote {
                OwlChatStore.shared.append(OwlChatEntry(role: .note, text: note), to: id)
                pendingInlineNote = nil
            }
        }
        render()
        updateButtons()
        if let ps = outcome?.proposals, !ps.isEmpty { showProposals(ps) }
        panel.makeFirstResponder(input)
        onFinish?(outcome)
    }

    @objc func stop(_ sender: Any?) {
        guard running else { return }
        task?.cancel()
        if chunkedReviewRunning {
            stopTypingIndicator()
            return
        }
        finish(nil, error: String(localized: "Stopped."))
    }

    // MARK: The proposed edits

    /// A card per proposal (at most `OwlTools.maxProposals`), each with Apply / Skip.
    func showProposals(_ ps: [OwlEditProposal]) {
        removeCards()
        let shown = Array(ps.prefix(OwlTools.maxProposals))
        for (i, p) in shown.enumerated() {
            let c = OwlEditCard(p, index: i, of: shown.count, target: self, apply: #selector(applyCard(_:)),
                                skip: #selector(skipCard(_:)), askAgain: #selector(askAgain(_:)))
            c.onLayout = { [weak self] in self?.layoutCards() }
            c.translatesAutoresizingMaskIntoConstraints = false
            cardsStack.addArrangedSubview(c)
            c.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
            cards.append(c)
        }
        refreshCards()
        cardsScroll.contentView.scroll(to: .zero)
    }

    /// The scroll view as tall as the cards (a stale note adds a line), at most about two cards.
    private func layoutCards() {
        cardsScroll.isHidden = cards.isEmpty
        cardsStack.layoutSubtreeIfNeeded()
        // Up to about two cards high; more scroll.
        cardsHeight.constant = cards.isEmpty ? 0 : min(cardsStack.fittingSize.height, 250)
    }

    private func removeCards() {
        for c in cards { cardsStack.removeArrangedSubview(c); c.removeFromSuperview() }
        cards = []
        layoutCards()
    }

    /// The tab's buffer was replaced (`setText`). Every card goes, with no
    /// "Skipped" note: the proposals were for the previous text. A `.text`
    /// card whose find is still unique would otherwise stay Apply-ready.
    func documentBufferReplaced() {
        let kept = OwlBufferReplacement.kept(cards.map(\.proposal))
        guard kept.count != cards.count else { return }
        removeCards()
    }

    /// Read-only: Apply never applies (a read-only tab, a followed file,
    /// large-document mode, extras paused; on iOS, read mode).
    private var documentIsReadOnly: Bool {
        guard let tab else { return true }
        return OwlEditAccess.readOnly(editable: tab.textView.isEditable, following: tab.tail != nil,
                                      largeDocument: tab.isLargeDocument, extrasPaused: tab.extrasPaused)
    }

    func state(of p: OwlEditProposal) -> OwlEditProposal.ApplyState {
        guard let tab else { return .stale }
        return p.state(text: tab.textView.string as NSString, generation: tab.doc.changeCount, readOnly: documentIsReadOnly)
    }

    /// Every card's Apply, against the document as it is now. One search
    /// per distinct find, and none at all when Apply is already refused.
    func refreshCards() {
        guard !cards.isEmpty, let tab else { layoutCards(); return }
        let result = OwlEditProposal.refresh(cards.map(\.proposal), text: tab.textView.string as NSString,
                                             generation: tab.doc.changeCount, readOnly: documentIsReadOnly)
        for (c, s) in zip(cards, result.states) {
            // The title names where the unique match is now, not where it was proposed.
            if case .ready(let range) = s {
                let span = OwlEditProposal.lineSpan(range, in: tab.lineIndex)
                c.setLocation(first: span.first, last: span.last)
            }
            c.show(s)
        }
        layoutCards()
    }

    /// The first card applies now (checks).
    var isProposalCurrent: Bool {
        guard let p = pending else { return false }
        if case .ready = state(of: p) { return true }
        return false
    }

    private func card(for sender: Any?) -> OwlEditCard? {
        guard let b = sender as? NSButton else { return cards.first }
        return cards.first { $0.applyButton === b || $0.skipButton === b || $0.askAgainButton === b }
    }

    @objc private func applyCard(_ sender: Any?) { if let c = card(for: sender) { apply(c) } }
    @objc private func skipCard(_ sender: Any?) { if let c = card(for: sender) { skip(c) } }

    /// Apply the first card (checks).
    @discardableResult
    @objc func applyProposal(_ sender: Any?) -> Bool { cards.first.map(apply) ?? false }

    /// Apply: one undo step, only where the proposal applies now (its text
    /// once in the document); otherwise the card says why and offers Ask Again.
    @discardableResult
    func apply(_ c: OwlEditCard) -> Bool {
        guard let tab else { return false }
        let now = state(of: c.proposal)
        guard case .ready(let range) = now else {
            c.show(now)
            NSSound.beep()
            return false
        }
        let p = c.proposal
        guard tab.replaceAsOneStep(range, with: p.replacement, actionName: String(localized: "Cedric’s Edit")) else { return false }
        let r = NSRange(location: range.location, length: (p.replacement as NSString).length)
        tab.textView.setSelectedRange(r)
        tab.reveal(r)
        remove(c)
        if let id = docID { OwlChatStore.shared.append(OwlChatEntry(role: .note, text: String(localized: "Applied. ⌘Z undoes it.")), to: id) }
        render()
        tab.owl?.chatCue(.applied)
        return true
    }

    func skip(_ c: OwlEditCard) {
        remove(c)
        if let id = docID {
            OwlChatStore.shared.append(OwlChatEntry(role: .note, text: String(localized: "Skipped.")), to: id)
            render()
        }
    }

    private func remove(_ c: OwlEditCard) {
        cardsStack.removeArrangedSubview(c)
        c.removeFromSuperview()
        cards.removeAll { $0 === c }
        refreshCards()
    }

    /// Every card goes (a new question, Clear); with a sender, a note says so.
    @objc func discardProposal(_ sender: Any?) {
        guard !cards.isEmpty else { return }
        removeCards()
        if sender != nil, let id = docID {
            OwlChatStore.shared.append(OwlChatEntry(role: .note, text: String(localized: "Skipped.")), to: id)
            render()
        }
    }

    @objc func askAgain(_ sender: Any?) {
        guard let r = lastRequest else { return }
        if r.inline {
            guard let tab, let action = r.action else { NSSound.beep(); return }
            guard let range = r.selection, let originalText = r.selectionText,
                  let selection = OwlInlineAssist.askAgainSelection(originalRange: range, originalText: originalText,
                                                                    currentText: tab.textView.string) else {
                NSSound.beep()
                if let id = docID {
                    OwlChatStore.shared.append(OwlChatEntry(role: .note,
                                                            text: String(localized: "The original selection is no longer in the document.")), to: id)
                    render()
                }
                return
            }
            // Use the recovered original selection; do not require the caret to still be over it.
            let enabled = tab.canAskCedric && running != true
            let ready = AskCedricEngine.isAvailable
            let allowed = action == .rewrite
                ? OwlInlineAssist.canRewrite(askEnabled: enabled, engineReady: ready, hasSelection: true,
                                             allowsTools: ready && OwlChatStore.shared.inlineAllowsTools)
                : OwlInlineAssist.canExplain(askEnabled: enabled, engineReady: ready, hasSelection: true)
            guard allowed else { NSSound.beep(); return }
            discardProposal(nil)
            ask(question: r.question, action: action, selection: selection, scope: .selection, inline: true)
            return
        }
        discardProposal(nil)
        ask(question: r.question, action: r.action)
    }

    private var recheckQueued = false

    /// The document changed: a card may have gone stale (or come back).
    /// Rechecked once per burst of typing, not per key, and only while the
    /// panel is visible and the tab is not in large mode.
    func documentEdited() {
        guard !recheckQueued, shouldRefreshCards() else { return }
        recheckQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + OwlCardRefresh.debounce) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recheckQueued = false
                guard self.shouldRefreshCards() else { return }
                self.refreshCards()
            }
        }
    }

    private func shouldRefreshCards() -> Bool {
        OwlCardRefresh.shouldRefresh(panelVisible: isShown, largeDocument: tab?.isLargeDocument == true,
                                     extrasPaused: tab?.extrasPaused == true, hasCards: !cards.isEmpty)
    }

    // MARK: History

    @objc func copyMarkdown(_ sender: Any?) {
        guard let id = docID else { return }
        let md = OwlChatEntry.markdown(OwlChatStore.shared.history(id), fileName: tab?.doc.fileURL?.lastPathComponent)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    @objc func clearHistory(_ sender: Any?) {
        guard !running, let id = docID else { return }
        OwlChatStore.shared.clear(id)
        discardProposal(nil)
        render()
    }

    /// A key in the question field: the owl listens (throttled in `OwlController.chatCue`).
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === input else { return }
        tab?.owl?.chatCue(.typed)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if running { stop(nil) } else { panel.performClose(nil) }
            return true
        }
        return false
    }
}

extension EditorWindowController {
    /// Cedric › Ask Cedric… is available: the setting is on, not in large mode.
    var canAskCedric: Bool { Settings.shared.owlChat && !extrasPaused }

    func openAskCedric() {
        guard canAskCedric else { NSSound.beep(); return }
        chatPanel().show()
    }

    func canInlineAssist(_ action: OwlQuickAction) -> Bool {
        let selected = textView.selectedRange().length > 0
        guard selected else { return false }
        let enabled = canAskCedric && owlChat?.running != true
        guard enabled else { return false }
        let ready = AskCedricEngine.isAvailable
        if action == .rewrite {
            return OwlInlineAssist.canRewrite(askEnabled: enabled, engineReady: ready, hasSelection: selected,
                                              allowsTools: ready && selected && OwlChatStore.shared.inlineAllowsTools)
        }
        return OwlInlineAssist.canExplain(askEnabled: enabled, engineReady: ready, hasSelection: selected)
    }

    func inlineAssist(_ action: OwlQuickAction) {
        guard canInlineAssist(action) else { NSSound.beep(); return }
        let selection = textView.selectedRange()
        let panel = chatPanel()
        panel.show()
        panel.ask(question: action == .explain ? String(localized: "Explain Selection") : String(localized: "Rewrite Selection"),
                  action: action, selection: selection, scope: .selection, inline: true)
    }

    /// Cedric › Check Script for Risks…: a script (shell, PowerShell,
    /// batch, .reg, Python, Ruby), not in large mode. Needs no AI: the
    /// offline scan always runs; the model's review follows when Ask
    /// Cedric is on with an engine ready.
    var canCheckScriptSafety: Bool { ScriptSafety.isScript(doc.language) && !extrasPaused }

    func checkScriptSafety() {
        guard canCheckScriptSafety else { NSSound.beep(); return }
        confirmAskingCedric { [weak self] in
            guard let self else { return }
            let p = self.chatPanel()
            p.show()
            p.checkScriptSafety()
        }
    }
}

extension EditorWindowController {
    /// Cedric › Check Grammar with Cedric, and the owl's button.
    var canCheckGrammarWithAI: Bool { grammar.mayCheckWithAI }
    func checkGrammarWithAI() {
        guard canCheckGrammarWithAI else { NSSound.beep(); return }
        confirmAskingCedric { [weak self] in self?.grammar.checkWithAI(userAsked: true) }
    }
}

/// Top-down layout for the cards' scroll view.
private final class CardsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
