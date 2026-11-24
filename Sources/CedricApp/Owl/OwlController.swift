import AppKit
import CedricCore
import QuartzCore
import CedricAI

extension Notification.Name {
    /// The owl was moved: every tab's owl follows.
    static let cedricOwlPlacementChanged = Notification.Name("CedricOwlPlacementChanged")
}

/// Holds the owl and its bubble over the editor's bottom-right corner.
/// Clicks pass through everywhere else.
final class OwlOverlay: NSView {
    weak var controller: OwlController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    override func layout() {
        super.layout()
        controller?.layoutViews()
    }
}

/// One tab's owl: its poses, idle behaviour, the bubble and the popover.
///
/// Cost when idle: one one-shot `Timer` for the next blink or polish (4–9 s
/// away), and none at all while the owl is asleep, the window is hidden or
/// occluded, or the app is inactive. Blinks and flaps run a short frame
/// timer only while they play.
@MainActor
final class OwlController: NSObject, NSPopoverDelegate {
    static let size: CGFloat = 72

    private weak var tab: EditorWindowController?
    let overlay = OwlOverlay()
    let owl = OwlView(frame: NSRect(x: 0, y: 0, width: OwlController.size, height: OwlController.size))
    private(set) var bubble: OwlBubble?
    private var presented: (hint: OwlHint, range: NSRange?, expected: String?)?
    /// The hint in the bubble and its range in the document (checks).
    var presentedHint: (hint: OwlHint, documentRange: NSRange?)? { presented.map { ($0.hint, $0.range) } }
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private(set) var lastTyping = Date()
    private var popover: NSPopover?
    let sleepAfter: TimeInterval = DevEnvironment.values["CEDRIC_OWL_SLEEP_AFTER"].flatMap(Double.init) ?? 300
    /// Owl and bubble faded because the caret is near them.
    private(set) var owlFaded = false
    private(set) var bubbleFaded = false
    /// Counts for the idle-cost check.
    private(set) var idleTicks = 0

    init(tab: EditorWindowController) {
        self.tab = tab
        super.init()
        overlay.controller = self
        overlay.addSubview(owl)
        owl.onClick = { [weak self] in
            // Asleep: a click wakes him.
            if let self, self.owl.pose == .sleepy {
                self.lastTyping = Date()
                self.owl.setPose(.idle)
                self.updateTimer()
            }
            // Large documents: the owl only looks when clicked; with
            // nothing to say he shows his popover as usual.
            if let tab = self?.tab, tab.owlIdleForSpeed {
                OwlHub.shared.userAsked(in: tab) { [weak self] in self?.showPopover() }
            } else {
                self?.showPopover()
            }
        }
        owl.onDoubleClick = { [weak self] in self?.closePopover(); self?.resetPosition() }
        owl.onDragBegan = { [weak self] in self?.dragBegan() }
        owl.onDragMoved = { [weak self] d in self?.dragMoved(d) }
        owl.onDragEnded = { [weak self] in self?.dragEnded() }
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            })
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: tab.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            })
        }
        observers.append(nc.addObserver(forName: .cedricOwlPlacementChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.owl.isDragging else { return }
                self.overlay.needsLayout = true
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                OwlView.reduceMotion = OwlView.currentReduceMotion()
                self?.reduceMotionChanged()
            }
        })
        if Self.firstOwlAt == nil { Self.firstOwlAt = Date() }
        updateTimer()
        scheduleWave()
    }

    /// Reduce Motion turned on or off: lasting states become still (or
    /// move again), and the idle timer is redone.
    func reduceMotionChanged() {
        if OwlView.reduceMotion, owl.isPlaying, !owl.inState { owl.stopSequence() }
        if chatMood != .idle { renderChat() }
        idleTimer?.invalidate()
        idleTimer = nil
        updateTimer()
    }

    // MARK: Hello

    /// The wave plays once per launch, in the first owl, a second after the first frame.
    private static var waved = false
    private(set) static var wavedAt: Date?

    private func scheduleWave() {
        guard !Self.waved else { return }
        Self.waved = true
        AfterFirstFrame.run { [weak self] in
            let t = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.canAnimate, !OwlView.reduceMotion, self.bubble == nil, !self.chatBusy,
                          !self.typedSinceLaunch, self.owl.pose == .idle else { return }
                    self.owl.wave()
                    Self.wavedAt = Date()
                }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        idleTimer?.invalidate()
        idleTimer = nil
        owl.stopSequence()
        popover?.close()
        overlay.removeFromSuperview()
    }

    // MARK: Layout

    func layoutViews() {
        let b = overlay.bounds
        let size = NSSize(width: Self.size, height: Self.size)
        if let drag = dragStart {
            let o = OwlPlacement.clamp(NSPoint(x: drag.x + dragDelta.width, y: drag.y + dragDelta.height), size: size, in: b)
            owl.frame = NSRect(origin: o, size: size)
        } else if !settling {
            owl.frame = NSRect(origin: Settings.shared.owlPlacement.origin(in: b, size: size), size: size)
        }
        if let bg = tab?.palette.background {
            let c = NSColor(hex: bg)
            owl.onDarkBackground = (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) < 0.4
        }
        layoutBubble()
    }

    private func layoutBubble() {
        guard let bubble else { return }
        let size = bubble.fit()
        let place = OwlPlacement.bubble(owl: owl.frame, size: size, in: overlay.bounds, avoid: hintedRect())
        bubble.tailOnTop = place.tailOnTop
        bubble.tailAtLeft = place.tailAtLeft
        bubble.frame = place.frame
    }

    /// The lines the presented hint is about, in the overlay's
    /// coordinates (nil when it has no range or isn't on screen), so the
    /// bubble doesn't cover them in a small window.
    func hintedRect() -> CGRect? {
        guard let range = presented?.range, let tv = tab?.primaryTextView, let window = tv.window,
              let vis = tv.visibleCharacterRange else { return nil }
        let len = (tv.string as NSString).length
        let start = max(range.location, vis.location), end = min(NSMaxRange(range), NSMaxRange(vis), len)
        guard NSMaxRange(range) <= len, start <= end else { return nil }
        // Its first and last line on screen (TextKit is asked only about those).
        let first = tv.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        let last = tv.firstRect(forCharacterRange: NSRange(location: end, length: 0), actualRange: nil)
        guard first != .zero, last != .zero else { return nil }
        let a = overlay.convert(window.convertFromScreen(first), from: nil)
        let b = overlay.convert(window.convertFromScreen(last), from: nil)
        let minY = min(a.minY, b.minY), maxY = max(a.maxY, b.maxY, minY + 12)
        return CGRect(x: overlay.bounds.minX, y: minY, width: overlay.bounds.width, height: maxY - minY)
    }

    // MARK: Dragging

    /// The owl's frame origin when the drag began, and the pointer's movement since.
    private var dragStart: NSPoint?
    private var dragDelta = NSSize.zero
    /// The snap animation is running: layout leaves his frame alone.
    private var settling = false
    var isDragging: Bool { dragStart != nil }

    private func dragBegan() {
        closePopover()
        dragStart = owl.frame.origin
        dragDelta = .zero
        // Full strength while you hold him.
        owlFaded = false
        owl.alphaValue = 1
    }

    private func dragMoved(_ d: NSSize) {
        dragDelta = d
        layoutViews()
    }

    private func dragEnded() {
        let size = owl.frame.size
        let place = OwlPlacement.snapped(origin: owl.frame.origin, size: size, in: overlay.bounds)
        dragStart = nil
        dragDelta = .zero
        moveTo(place)
    }

    /// Double-click, or "Reset Position" in his popover: back bottom right.
    func resetPosition() {
        moveTo(.default)
    }

    /// Saves the placement and slides him there.
    func moveTo(_ place: OwlPlacement) {
        Settings.shared.owlPlacement = place
        let target = NSRect(origin: place.origin(in: overlay.bounds, size: owl.frame.size), size: owl.frame.size)
        if canAnimate, !OwlView.reduceMotion {
            settling = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                owl.animator().frame = target
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.settling = false
                    self?.layoutViews()
                }
            })
        } else {
            owl.frame = target
        }
        layoutBubble()
        NotificationCenter.default.post(name: .cedricOwlPlacementChanged, object: self)
        // Never left sitting on the caret: fade if he landed near it.
        caretMoved(byUser: true)
    }

    // MARK: Idle behaviour

    /// The in-process check runs with the screen locked, where the window
    /// server reports every window occluded and the app inactive.
    /// CEDRIC_OWL_ASSUME_VISIBLE=1: also for measuring idle cost with the screen locked.
    static var assumeVisible = DevEnvironment.values["CEDRIC_OWL_ASSUME_VISIBLE"] == "1"

    /// The window can be seen and the app is in front.
    var canAnimate: Bool {
        if Self.assumeVisible { return tab?.window?.isVisible == true }
        guard let w = tab?.window, NSApp.isActive, !NSApp.isHidden, w.isVisible, !w.isMiniaturized else { return false }
        return w.occlusionState.contains(.visible)
    }

    var timerScheduled: Bool { idleTimer?.isValid == true }

    func updateTimer() {
        guard canAnimate else {
            idleTimer?.invalidate()
            idleTimer = nil
            owl.stopSequence()
            return
        }
        // Back on screen while the model works: his chat loop again.
        if chatMood.isWorking, !owl.inState { renderChat() }
        if owl.pose == .sleepy { return }
        if !chatBusy, Date().timeIntervalSince(lastTyping) >= sleepAfter { owl.setPose(.sleepy); return }
        if idleTimer?.isValid != true { scheduleIdle() }
    }

    private func scheduleIdle() {
        let untilSleep = sleepAfter - Date().timeIntervalSince(lastTyping)
        // Reduce Motion: no idle animation, only the one timer to fall asleep.
        let next = OwlMotion.idleDelay(untilSleep: untilSleep, reduceMotion: OwlView.reduceMotion, random: Double.random(in: 0...1))
        let t = Timer(timeInterval: next, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    /// The idle timer's tick, now (checks).
    func idleTickNow() { idleTimer?.invalidate(); idleTick() }

    private func idleTick() {
        idleTimer = nil
        idleTicks += 1
        guard canAnimate else { return }
        if introduceAskCedric() { scheduleIdle(); return }
        if Date().timeIntervalSince(lastTyping) >= sleepAfter, !chatBusy {
            if bubble == nil { owl.setPose(.sleepy) }
            return // asleep: no timer until typing wakes it
        }
        // While Ask Cedric drives him, his own idle animations wait.
        if owl.pose == .idle, !owl.inState, !OwlView.reduceMotion, !chatBusy {
            if typedSinceLook, Date().timeIntervalSince(lastTyping) >= 1, let i = gazeTowardCaret() {
                // Typing stopped: a look toward where the user is writing.
                typedSinceLook = false
                owl.glance(i)
                looks += 1
            } else {
                switch Int.random(in: 0..<8) {
                case 0: owl.polish()
                case 1, 2: owl.glance([0, 2, 4, 6][Int.random(in: 0..<4)])
                default: owl.blink()
                }
            }
        }
        scheduleIdle()
    }

    // MARK: Ask Cedric, introduced once

    static let askIntroID = "askCedric.intro"
    static let askIntroKey = "askCedricIntroShown"
    private static var introduced = false
    private static var firstOwlAt: Date?

    /// Once per user (ever): when Ask Cedric is on, a while after launch
    /// and after typing has paused, the owl says he can be asked. Closing
    /// the bubble is enough; it never comes back. Not in large documents,
    /// over another bubble, or while quiet. Off in the checks
    /// (CEDRIC_NO_SESSION_SAVE) unless CEDRIC_ASK_HINT=1, which also
    /// ignores the saved "shown" flag; CEDRIC_ASK_HINT_AFTER sets the wait
    /// (default 45 s from the first owl).
    @discardableResult
    func introduceAskCedric() -> Bool {
        let env = DevEnvironment.values
        let forced = env["CEDRIC_ASK_HINT"] == "1"
        guard !Self.introduced, env["CEDRIC_ASK_HINT"] != "0", forced || env["CEDRIC_NO_SESSION_SAVE"] == nil,
              let tab, bubble == nil, !popoverShown, !chatOpen, !chatBusy, !OwlHub.shared.coordinator.isQuiet, !tab.extrasPaused else { return false }
        let after = env["CEDRIC_ASK_HINT_AFTER"].flatMap(Double.init) ?? 45
        guard Date().timeIntervalSince(Self.firstOwlAt ?? Date()) >= after, Date().timeIntervalSince(lastTyping) >= min(3, after) else { return false }
        let defaults = UserDefaults.standard
        if !forced, defaults.bool(forKey: Self.askIntroKey) { Self.introduced = true; return false }
        guard tab.canAskCedric else { return false }
        Self.introduced = true
        defaults.set(true, forKey: Self.askIntroKey)
        let hint = OwlHint(id: Self.askIntroID, kind: .tip, title: String(localized: "You can ask me about this file"),
                           detail: String(localized: "Click me or press ⌥⌘/ to ask a question, explain a line or check a script.")
                               + " " + AskCedricEngine.privacy(autoGrammar: false).introSentence,
                           source: "rules")
        present(hint, context: tab.owlContextWindow().context)
        return true
    }

    /// The user typed since the owl last looked at the caret.
    private var typedSinceLook = false
    private var typedSinceLaunch = false
    /// Looks toward the caret (checks).
    private(set) var looks = 0

    /// The gaze frame from the owl toward the caret, nil if it can't be placed.
    func gazeTowardCaret() -> Int? {
        guard let tv = tab?.primaryTextView, let window = tv.window else { return nil }
        let sel = tv.selectedRange()
        if tv.contentStorage?.chunkLimit != nil { return nil }   // large mode: never ask TextKit
        let screen = tv.firstRect(forCharacterRange: NSRange(location: sel.location + sel.length, length: 0), actualRange: nil)
        guard screen != .zero else { return nil }
        let caret = overlay.convert(window.convertFromScreen(screen), from: nil)
        return OwlArt.gazeIndex(dx: caret.midX - owl.frame.midX, dy: caret.midY - owl.frame.midY)
    }

    func noteTyping() {
        // Never animate while the user types: a gesture in progress stops
        // (the chat's too: it is over).
        if owl.isPlaying, !owl.inState { owl.stopSequence() }
        if chatMood.isGesture { chatMood = .idle }
        chatGesture = false
        typedSinceLook = true
        typedSinceLaunch = true
        lastTyping = Date()
        if owl.pose == .sleepy { owl.setPose(.idle) }
        updateTimer()
        caretMoved(byUser: true)
    }

    func noteSave() {
        guard !chatBusy else { return }
        owl.flap()
    }

    // MARK: Ask Cedric drives him

    /// Ask Cedric's mood for him (`OwlChatMood`): the chat panel has no owl
    /// of its own; this one, wherever the user put him, reacts. While the
    /// chat is busy (`chatBusy`) its poses win: his idle animations, hint
    /// gestures and unasked-for hints wait, and resume when the chat is
    /// idle or closed. No timer of its own: gestures and loops use the
    /// owl view's frame timer, only while they play.
    private(set) var chatMood: OwlChatMood = .idle
    /// Every mood the chat put him in (checks).
    private(set) var chatMoodLog: [OwlChatMood] = []
    /// A chat gesture is under way (a wave, listen, nod or flap).
    private var chatGesture = false
    private var lastListen: Date?
    private var lastWave: Date?
    /// The Ask Cedric panel while it is open: he glances toward it.
    private weak var chatWindow: NSWindow?

    var chatBusy: Bool { OwlChatMood.isBusy(chatMood, gesturePlaying: chatGesture && owl.isPlaying) }
    var chatOpen: Bool { chatWindow?.isVisible == true }
    /// A chat gesture is playing on him (checks).
    var chatGesturePlaying: Bool { chatGesture && owl.isPlaying }

    /// His frame on screen, nil when he can't be seen (hidden, no window).
    var screenFrame: NSRect? {
        guard !owl.isHidden, !overlay.isHidden, let w = owl.window, w.isVisible else { return nil }
        return w.convertToScreen(owl.convert(owl.bounds, to: nil))
    }

    /// The panel opened (`OwlChatPanel.show`).
    func chatOpened(_ panel: NSWindow, engineReady: Bool) {
        chatWindow = panel
        chatCue(.opened(engineReady: engineReady))
    }

    /// The panel closed: his own again.
    func chatClosed() {
        chatWindow = nil
        chatCue(.closed)
    }

    func chatCue(_ c: OwlChatMood.Cue) {
        let next = OwlChatMood.next(c, from: chatMood)
        switch c {
        case .typed:
            // Throttled: one listen per `listenInterval`, never every keystroke.
            guard next == .listen, OwlChatMood.listenDue(lastListen: lastListen, now: Date()) else { return }
            lastListen = Date()
        case .opened(true):
            // A wave when the panel opens, at most once a minute.
            guard OwlChatMood.waveDue(lastWave: lastWave, now: Date()) else {
                if !chatMood.isWorking, chatMood != .idle { enterChat(.idle) }
                return
            }
            lastWave = Date()
        default: break
        }
        // Chatting is activity: he doesn't fall asleep in the middle of it.
        if case .opened = c { lastTyping = Date() }
        if c == .typed || c == .asked { lastTyping = Date() }
        // The same lasting state again (another text piece): nothing to redo.
        if next == chatMood, !next.isGesture { return }
        enterChat(next)
    }

    private func enterChat(_ m: OwlChatMood) {
        chatMood = m
        chatMoodLog.append(m)
        if chatMoodLog.count > 64 { chatMoodLog.removeFirst(chatMoodLog.count - 64) }
        renderChat()
    }

    /// Draws the chat's mood on him: a still, a gesture or a loop. Off
    /// screen or under Reduce Motion: stills only, no timer.
    private func renderChat() {
        chatGesture = false
        if chatMood == .idle {
            // His own again: the bubble's pose if one is up, his idle timer.
            owl.setPose(bubble != nil ? .talking : .idle)
            updateTimer()
            return
        }
        let still = OwlView.reduceMotion || !canAnimate
        let display = OwlChatMood.display(chatMood, reduceMotion: still, gaze: chatMood == .listen ? gazeTowardChat() : nil)
        switch display {
        case .still(let s):
            owl.setPose(Self.pose(s))
            // A gesture shown as its still is over at once.
            if chatMood.isGesture { chatMood = .idle; updateTimer() }
        case .gesture(let strip, let idx, let every):
            let f = Self.frames(strip)
            let pick = idx.compactMap { f.indices.contains($0) ? f[$0] : nil }
            owl.setPose(.idle)   // ends a loop under way
            chatGesture = owl.gesture(pick, every: every) { [weak self] in
                MainActor.assumeIsolated { self?.chatGestureEnded() }
            }
            if !chatGesture { chatMood = .idle; updateTimer() }
        case .loop(let strip, let every):
            owl.setPose(.thinking)
            owl.loop(Self.frames(strip), every: every)
        }
    }

    private func chatGestureEnded() {
        chatGesture = false
        chatCue(.settled)
    }

    private static func pose(_ s: OwlChatMood.Still) -> OwlArt.Pose {
        switch s {
        case .idle: return .idle
        case .talking: return .talking
        case .thinking: return .thinking
        case .sleepy: return .sleepy
        }
    }

    private static func frames(_ s: OwlChatMood.Strip) -> [NSImage] {
        switch s {
        case .wave: return OwlArt.strip(.wave)
        case .look: return OwlArt.strip(.look)
        case .think: return OwlArt.strip(.think)
        case .search: return OwlArt.strip(.search)
        case .write: return OwlArt.strip(.write)
        case .nod: return OwlArt.strip(.nod)
        case .flap: return OwlArt.flap
        }
    }

    /// The look-strip frame from him toward the open panel.
    private func gazeTowardChat() -> Int? {
        guard let panel = chatWindow, panel.isVisible, let me = screenFrame else { return nil }
        return OwlArt.gazeIndex(dx: panel.frame.midX - me.midX, dy: panel.frame.midY - me.midY)
    }

    /// An edit was accepted (a hint's Fix it).
    func nod() {
        guard canAnimate, bubble == nil, !chatBusy else { return }
        owl.nod()
    }

    /// Nothing found where the user asked: a quiet "no" (a glance aside and back).
    func shake() {
        guard canAnimate, bubble == nil, !chatBusy else { return }
        owl.glance(4)
    }

    func setThinking(_ on: Bool) {
        guard bubble == nil, !chatBusy else { return }
        owl.setPose(on ? .thinking : .idle)
        if on { owl.loop(OwlArt.strip(.think), every: 0.35) }
    }

    // MARK: Keeping out of the way

    /// Just turned on: shown at full strength, whatever the window's
    /// occlusion state or where the caret is, until the user next types
    /// or moves the caret.
    private(set) var holdVisible = true

    /// Called when the owl is turned on (Cedric › Show Cedric, or a
    /// new tab with the owl on): lay it out and show it now.
    func appeared() {
        holdVisible = true
        owlFaded = false
        owl.isHidden = false
        owl.alphaValue = 1
        overlay.isHidden = false
        overlay.alphaValue = 1
        if owl.pose == .sleepy { owl.setPose(.idle) }
        overlay.superview?.needsLayout = true
        overlay.superview?.layoutSubtreeIfNeeded()
        layoutViews()
        owl.needsDisplay = true
    }

    /// Fades the owl (and the bubble) while the caret is close to them.
    /// `byUser`: a selection change or typing (ends the just-turned-on hold).
    func caretMoved(byUser: Bool = false) {
        if byUser { holdVisible = false }
        guard !holdVisible || bubble != nil, !isDragging else { return }
        guard let tv = tab?.primaryTextView, let window = tv.window else { return }
        let sel = tv.selectedRange()
        let caretAt = sel.location + sel.length
        // In a chunked long line (large mode), a caret scrolled out of
        // view can't be near the owl. (Asking TextKit for its rect lays
        // out up to it, which re-anchored the viewport there: scrolling
        // stalled near the caret.)
        let caret: NSRect
        if tv.contentStorage?.chunkLimit != nil, let vis = tv.visibleCharacterRange, !NSLocationInRange(caretAt, NSRange(location: vis.location, length: vis.length + 1)) {
            caret = NSRect(x: -10_000, y: -10_000, width: 0, height: 0)
        } else {
            let screen = tv.firstRect(forCharacterRange: NSRange(location: caretAt, length: 0), actualRange: nil)
            guard screen != .zero else { return }
            caret = overlay.convert(window.convertFromScreen(screen), from: nil)
        }
        let nearOwl = caret.insetBy(dx: -28, dy: -18).intersects(owl.frame)
        let nearBubble = bubble.map { caret.insetBy(dx: -12, dy: -12).intersects($0.frame) } ?? false
        if nearOwl != owlFaded {
            owlFaded = nearOwl
            fade(owl, to: nearOwl ? 0.12 : 1)
        }
        if let bubble, nearBubble != bubbleFaded {
            bubbleFaded = nearBubble
            fade(bubble, to: nearBubble ? 0.15 : 1)
        }
    }

    private func fade(_ v: NSView, to alpha: CGFloat) {
        if canAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                v.animator().alphaValue = alpha
            }
        } else {
            v.alphaValue = alpha
        }
    }

    // MARK: Hints

    /// Shows a hint the coordinator picked (from the rules or the AI).
    /// `context.textStart` maps the hint's range (context-window
    /// coordinates) back into the document.
    func present(_ hint: OwlHint, context: OwlContext) {
        guard let tab else { return }
        var docRange: NSRange?, expected: String?
        if let r = hint.range {
            let ctx = context.text as NSString
            guard NSMaxRange(r) <= ctx.length else { return }
            docRange = OwlCoordinator.documentRange(hint, context: context) ?? r
            expected = ctx.substring(with: r)
        }
        presented = (hint, docRange, expected)
        // Offered once per file, ever.
        if hint.id == SafetyRules.downloadedScriptID, let path = tab.doc.fileURL?.path { DownloadedScriptOffers.note(path) }
        showBubble(hint, buttons: buttons(for: hint, tab: tab))
    }

    // MARK: Recent hints, again

    /// Hints shown again from the popover (checks).
    private(set) var replays = 0

    /// A row under "Recent hints" was chosen: the hint again, in the same
    /// bubble, without asking any provider (it is already in the
    /// coordinator's shown set, so `isEligible` would say no). Its own tab
    /// if that is another open one (brought to the front); its stored title
    /// and detail here if its document is closed. A range that no longer
    /// holds the text it had: title and detail only, never dropped.
    func replay(_ shown: OwlCoordinator.Shown) {
        closePopover()
        guard let tab else { return }
        if shown.documentID != tab.doc.id,
           let other = (NSApp.delegate as? AppDelegate)?.tabs.first(where: { $0.doc.id == shown.documentID }),
           let owl = other.owl {
            other.window?.makeKeyAndOrderFront(nil)
            owl.showAgain(shown, document: other.textView.string as NSString, own: true)
            return
        }
        let mine = shown.documentID == tab.doc.id
        showAgain(shown, document: mine ? tab.textView.string as NSString : nil, own: mine)
    }

    /// `own`: the hint is about this tab's document (its actions apply);
    /// otherwise (its document is closed) only OK.
    func showAgain(_ shown: OwlCoordinator.Shown, document: NSString?, own: Bool) {
        guard let tab else { return }
        let r = OwlCoordinator.replay(shown, document: document)
        replays += 1
        presented = (r.hint, r.documentRange, r.expected)
        let buttons = own ? buttons(for: r.hint, tab: tab)
            : [OwlBubble.Button(title: String(localized: "OK"), isDefault: true) { [weak self] in self?.hideBubble() }]
        showBubble(r.hint, buttons: buttons)
    }

    // MARK: Typos

    static let typoFixID = "spelling.fixTypos"
    static let wholeJSONInvalidID = "rules.json-whole-invalid"

    /// Prose with three or more fixable misspellings in view: "Fix 3
    /// typos?", applying the first suggestion for each as one undo step
    /// (through `applyPresented`, like any hint with a replacement). Once
    /// per document unless snoozed; never over another bubble, while
    /// quiet, or when turned off with "Don't show again".
    @discardableResult
    func offerTypoFix(_ spelling: EditorSpelling, tab: EditorWindowController) -> Bool {
        let hub = OwlHub.shared
        guard bubble == nil, !popoverShown, !chatBusy, !hub.coordinator.isQuiet else { return false }
        let window = tab.owlContextWindow()
        let ctx = window.context
        let probe = OwlHint(id: Self.typoFixID, kind: .fix, title: "", source: "rules")
        guard hub.coordinator.isEligible(probe, documentID: tab.doc.id) else { return false }
        // Only in prose: in a log or a list of settings, Fix All would
        // rewrite data (`dur=0ms` → `due=0ms`).
        guard SpellScope.offersTypoFix(ctx.text as NSString, language: tab.doc.language,
                                       fileName: tab.doc.fileURL?.lastPathComponent) else { return false }
        // Only what the owl can see in his context window.
        let ctxRange = NSRange(location: ctx.textStart, length: (ctx.text as NSString).length)
        let found = spelling.misspellings(in: ctxRange)
        guard let fix = spelling.typoFix(found) else { return false }
        let local = NSRange(location: fix.range.location - ctx.textStart, length: fix.range.length)
        guard local.location >= 0, NSMaxRange(local) <= (ctx.text as NSString).length else { return false }
        let hint = OwlHint(id: Self.typoFixID, kind: .fix, title: String(localized: "Fix \(fix.count) typos?"),
                           detail: String(localized: "Fix Typos… goes through them one by one; Fix All uses the first suggestion for each, as one undo step."),
                           range: local, replacement: fix.replacement, source: "rules")
        hub.coordinator.markShown(hint, documentID: tab.doc.id, context: ctx)
        present(hint, context: ctx)
        return true
    }

    private func buttons(for hint: OwlHint, tab: EditorWindowController) -> [OwlBubble.Button] {
        let hub = OwlHub.shared
        if hint.id == RulesHintProvider.letterID {
            return [.init(title: String(localized: "No thanks, I’m an owl"), isDefault: false) { [weak self] in self?.hideBubble() }]
        }
        if hint.id == Self.askIntroID {
            return [.init(title: String(localized: "Ask Cedric…"), isDefault: true) { [weak self, weak tab] in
                        self?.hideBubble(); tab?.openAskCedric() },
                    .init(title: String(localized: "Got it"), isDefault: false) { [weak self] in self?.hideBubble() }]
        }
        if GrammarMap.isGrammarHint(hint.id) {
            // Grammar (Grammar.swift): Fix it (one undo step), the
            // step-through, and off for this file or everywhere. The close
            // box is "Not now".
            var out: [OwlBubble.Button] = []
            if hint.replacement != nil {
                out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self] in _ = self?.applyPresented() })
            }
            out.append(.init(title: String(localized: "Fix Grammar…"), isDefault: hint.replacement == nil) { [weak self, weak tab] in
                self?.hideBubble(); tab?.startGrammarStep()
            })
            out.append(.init(title: String(localized: "Not in This File"), isDefault: false) { [weak self, weak tab] in
                tab?.grammar.hintsOffHere = true; self?.hideBubble()
            })
            out.append(.init(title: String(localized: "Don’t show again"), isDefault: false) { [weak self] in
                hub.coordinator.neverShowAgain(GrammarMap.globalID); self?.hideBubble()
            })
            return out
        }
        var out: [OwlBubble.Button] = []
        if StyleCheck.isStyleHint(hint.id) {
            // Style Check: Fix it (a cut or the short form), Show Me for a
            // cliché, and Ignore this word (Settings' exceptions, saved).
            if hint.replacement != nil {
                out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self] in _ = self?.applyPresented() })
            } else if hint.range != nil {
                out.append(.init(title: String(localized: "Show Me"), isDefault: true) { [weak self] in self?.showPresented() })
            }
            out.append(.init(title: String(localized: "Ignore this word"), isDefault: false) { [weak self] in
                if let p = StyleCheck.phrase(fromHintID: hint.id), !Settings.shared.styleCheckExceptions.contains(p) {
                    Settings.shared.styleCheckExceptions.append(p)
                }
                self?.hideBubble()
            })
            out.append(.init(title: String(localized: "Not now"), isDefault: false) { [weak self] in
                hub.coordinator.snooze(hint.id); self?.hideBubble()
            })
            return out
        }
        if hint.id == RulesHintProvider.jsonID, hint.replacement == nil {
            // A long one-line JSON file, only its start in view: Fix it
            // checks and formats the whole file.
            out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self, weak tab] in
                self?.hideBubble()
                tab?.formatWholeJSON { [weak self, weak tab] problem in
                    guard let self, let tab else { return }
                    let h = OwlHint(id: Self.wholeJSONInvalidID, kind: .warning,
                                    title: String(localized: "The whole file isn’t valid JSON, so it wasn’t formatted."),
                                    detail: problem, source: "rules")
                    self.present(h, context: tab.owlContextWindow().context)
                }
            })
        } else if hint.id == Self.typoFixID {
            // One at a time (the step-through), or all at once as before.
            out.append(.init(title: String(localized: "Fix Typos…"), isDefault: true) { [weak self, weak tab] in
                self?.hideBubble(); tab?.startSpellStep()
            })
            // Shown again after the text changed: no replacement, no Fix All.
            if hint.replacement != nil {
                out.append(.init(title: String(localized: "Fix All"), isDefault: false) { [weak self] in _ = self?.applyPresented() })
            }
        } else if hint.replacement != nil {
            out.append(.init(title: String(localized: "Fix it"), isDefault: true) { [weak self, weak tab] in
                guard let self, self.applyPresented() else { return }
                // A to-do list in checkboxes reads best coloured as Markdown.
                if hint.id == RulesHintProvider.todoListID, let tab, tab.doc.language == .plain { tab.setLanguageWithUndo(.markdown) }
            })
            if hint.id == RulesHintProvider.duplicateWordID {
                // Where it is, before fixing blind: selects the doubled words.
                out.append(.init(title: String(localized: "Show Me"), isDefault: false) { [weak self] in self?.showPresented() })
            }
        } else if hint.id == SafetyRules.downloadedScriptID {
            // A downloaded script: the offline check (then the AI's, when on).
            out.append(.init(title: String(localized: "Check Script for Risks…"), isDefault: true) { [weak self, weak tab] in
                self?.hideBubble(); tab?.checkScriptSafety()
            })
        } else if let le = RulesHintProvider.lineEndingFix(hint) {
            // A shell script with CRLF: switch the file's line endings.
            out.append(.init(title: String(localized: "Use \(le.displayName)"), isDefault: true) { [weak self, weak tab] in
                tab?.convertLineEndingsWithUndo(to: le); self?.hideBubble()
            })
        } else if let language = RulesHintProvider.guessedLanguage(hint) {
            out.append(.init(title: String(localized: "Use \(language.displayName)"), isDefault: true) { [weak self, weak tab] in
                tab?.setLanguage(language); self?.hideBubble()
            })
        } else if hint.range != nil, hint.id != RulesHintProvider.reloadID, hint.id != RulesHintProvider.saveCopyID {
            out.append(.init(title: String(localized: "Show Me"), isDefault: true) { [weak self] in self?.showPresented() })
        } else if hint.id == RulesHintProvider.reloadID {
            out.append(.init(title: String(localized: "Reload"), isDefault: true) { [weak self, weak tab] in tab?.reloadFromDisk(); self?.hideBubble() })
        } else if hint.id == RulesHintProvider.saveCopyID {
            out.append(.init(title: String(localized: "Save a Copy…"), isDefault: true) { [weak self, weak tab] in self?.hideBubble(); tab?.saveCopy() })
        }
        out.append(.init(title: String(localized: "Not now"), isDefault: false) { [weak self] in
            hub.coordinator.snooze(hint.id); self?.hideBubble()
        })
        out.append(.init(title: String(localized: "Don’t show again"), isDefault: false) { [weak self] in
            hub.coordinator.neverShowAgain(hint.id); self?.hideBubble()
        })
        return out
    }

    private func showBubble(_ hint: OwlHint, buttons: [OwlBubble.Button]) {
        bubble?.removeFromSuperview()
        let onlyButton = hint.id == RulesHintProvider.letterID
        let grammar = GrammarMap.isGrammarHint(hint.id)
        let b = OwlBubble(hint: hint, buttons: buttons, onClose: onlyButton ? nil : { [weak self] in
            if grammar { OwlHub.shared.coordinator.snooze(hint.id) }
            self?.hideBubble()
        })
        overlay.addSubview(b, positioned: .above, relativeTo: owl)
        bubble = b
        bubbleFaded = false
        // While Ask Cedric is busy its pose stays (the bubble still shows).
        if !chatBusy { owl.setPose(.talking) }
        layoutViews()
        caretMoved()
        // He points at the lines the hint is about.
        if canAnimate, !chatBusy, let r = hintedRect() {
            owl.point(OwlArt.pointIndex(dx: r.midX - owl.frame.midX, dy: r.midY - owl.frame.midY))
        }
    }

    func hideBubble() {
        bubble?.removeFromSuperview()
        bubble = nil
        presented = nil
        bubbleFaded = false
        if !chatBusy { owl.setPose(chatMood == .sleepy ? .sleepy : .idle) }
        updateTimer()
    }

    /// Show Me: selects the text the hint is about and scrolls to it, if
    /// it is still what the provider saw.
    @discardableResult
    func showPresented() -> Bool {
        defer { hideBubble() }
        guard let p = presented, let range = p.range, let expected = p.expected, let tv = tab?.textView else { return false }
        let ns = tv.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == expected else { NSSound.beep(); return false }
        // A doubled word: the words themselves ("the the"), not the span
        // the fix rewrites (which starts after the first one).
        let target = p.hint.id == RulesHintProvider.duplicateWordID
            ? RulesHintProvider.doubledWordFocus(ns, hintRange: range) ?? range : range
        tv.setSelectedRange(target)
        tv.scrollRangeToVisible(target)
        tv.window?.makeFirstResponder(tv)
        return true
    }

    /// Apply: the replacement as one undo step, only if the text it was
    /// computed from is still there.
    @discardableResult
    func applyPresented() -> Bool {
        defer { hideBubble() }
        guard let p = presented, let range = p.range, let expected = p.expected, let rep = p.hint.replacement,
              let tv = tab?.textView, let storage = tv.textStorage else { return false }
        let ns = tv.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == expected else {
            NSSound.beep()
            return false
        }
        let edit = OwlEdit.minimal(in: ns, range: range, replacement: rep)
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
        // In the theme's base attributes, like typed text: never the colour
        // of the text it replaces (the highlighter recolours it shortly).
        storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: tab?.baseAttributes() ?? [:]))
        tv.didChangeText()
        tv.breakUndoCoalescing()
        tv.undoManager?.setActionName(p.hint.title)
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.nod() } }
        return true
    }

    // MARK: Popover

    private func showPopover() {
        if let popover, popover.isShown { popover.close(); return }
        let hub = OwlHub.shared
        let vc = NSViewController()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        // Ask Cedric first: what clicking the owl is most often for.
        if let tab, tab.canAskCedric {
            let chat = NSButton(title: String(localized: "Ask about this file…"), target: self, action: #selector(askCedric))
            chat.bezelColor = .controlAccentColor
            chat.toolTip = String(localized: "Questions, quick actions and proposed edits about this text (⌥⌘/).")
            stack.addArrangedSubview(chat)
        } else if let tab, !tab.extrasPaused, !Settings.shared.owlChatTurnedOff, !AskCedricEngine.isAvailable {
            let setup = NSButton(title: String(localized: "Set Up Ask Cedric…"), target: self, action: #selector(setUpAskCedric))
            setup.toolTip = String(localized: "Ask Cedric needs a local AI engine: Apple Intelligence, the built-in model, or LM Studio / Ollama.")
            stack.addArrangedSubview(setup)
        }
        if let tab, tab.canCheckScriptSafety {
            let safe = NSButton(title: String(localized: "Check Script for Risks…"), target: self, action: #selector(scriptSafety))
            safe.toolTip = String(localized: "An offline scan for risky commands, then the AI’s review when Ask Cedric is on.")
            stack.addArrangedSubview(safe)
        }
        // Explain & tidy (OwlTools.swift): on the selection, and the file's TODOs.
        if let tab, !tab.isLargeDocument {
            if tab.canExplainRegex {
                let b = NSButton(title: String(localized: "Explain Regex"), target: self, action: #selector(explainRegex))
                b.toolTip = String(localized: "What the selected regular expression matches, piece by piece (offline).")
                stack.addArrangedSubview(b)
            }
            if tab.canDecodeSelection {
                let b = NSButton(title: String(localized: "Decode Selection"), target: self, action: #selector(decodeSelection))
                b.toolTip = String(localized: "Shows a JWT’s header and payload, base64 as text, or a Unix time as a date. Nothing is checked or sent.")
                stack.addArrangedSubview(b)
            }
            let todos = NSButton(title: String(localized: "Find TODOs"), target: self, action: #selector(findTodos))
            todos.toolTip = String(localized: "The TODO, FIXME, HACK and XXX notes in this file.")
            stack.addArrangedSubview(todos)
        }
        if stack.arrangedSubviews.count > 0 { stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!) }
        let head = NSTextField(labelWithString: String(localized: "Recent hints"))
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(head)
        if let status = hub.ai.statusLine(autoReviewCapped: tab?.autoReviewCapped == true) {
            let l = NSTextField(wrappingLabelWithString: status)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 260
            stack.addArrangedSubview(l)
        }
        // Over the auto-review cap: a quiet line, never a modal on open.
        if let tab, tab.autoReviewCapped {
            let l = NSTextField(wrappingLabelWithString: AutoReviewCap.note(tab.autoReviewSize))
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 260
            l.identifier = Self.autoReviewNoteID
            stack.addArrangedSubview(l)
        }
        let recent = hub.coordinator.recent
        if recent.isEmpty {
            let none = NSTextField(labelWithString: String(localized: "None yet. Cedric is watching quietly."))
            none.textColor = .secondaryLabelColor
            none.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(none)
        }
        let f = DateFormatter()
        f.timeStyle = .short
        for r in recent {
            // A button that looks like the label it was: shows the hint again.
            let time = f.string(from: r.date)
            var spoken = "\(time), \(r.hint.title)"
            if let d = r.hint.detail, !d.isEmpty {
                spoken += ". " + (d.count > 120 ? String(d.prefix(120)) + "…" : d)
            }
            let row = OwlRecentHintRow(text: "\(time)  \(r.hint.title)", accessibilityText: spoken,
                                       toolTip: r.hint.detail) { [weak self] in self?.replay(r) }
            stack.addArrangedSubview(row)
        }
        let quiet: NSButton
        if hub.coordinator.isQuiet {
            quiet = NSButton(title: String(localized: "Resume Hints"), target: self, action: #selector(resume))
        } else {
            quiet = NSButton(title: String(localized: "Quiet for 1 Hour"), target: self, action: #selector(quietHour))
        }
        quiet.controlSize = .small
        if hub.canAskAI, let tab, !tab.owlIdleForSpeed {
            let ask = NSButton(title: String(localized: "Ask AI Now"), target: self, action: #selector(askAINow))
            ask.controlSize = .small
            ask.toolTip = String(localized: "Checks the text in view with the AI once, now.")
            stack.addArrangedSubview(ask)
        }
        // Grammar found in view: the owl clicked shows it now, whatever the rate limit.
        if let tab, tab.grammar.issuesInView > 0 {
            let g = NSButton(title: String(localized: "Grammar Hint"), target: self, action: #selector(grammarHintNow))
            g.controlSize = .small
            g.toolTip = String(localized: "Shows a grammar suggestion for the text in view.")
            stack.addArrangedSubview(g)
        }
        if let tab, tab.canCheckGrammarWithAI {
            let g = NSButton(title: String(localized: "Check Grammar with Cedric"), target: self, action: #selector(grammarWithAI))
            g.controlSize = .small
            g.toolTip = String(localized: "Asks the AI engine about the grammar of the prose in view; the macOS checker stays on too.")
            stack.addArrangedSubview(g)
        }
        let hide = NSButton(title: String(localized: "Hide Cedric"), target: self, action: #selector(hideOwl))
        hide.controlSize = .small
        let reset = NSButton(title: String(localized: "Reset Position"), target: self, action: #selector(resetFromPopover))
        reset.controlSize = .small
        reset.isEnabled = Settings.shared.owlPlacement != .default
        let row = NSStackView(views: [quiet, reset, hide])
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(row)
        // The popover is as wide as its widest row plus the insets. The
        // wrapping labels ask for 260 pt, and the three buttons together are
        // wider than that (more so in German or French), so without this the
        // button row spilled past both edges of the popover and was clipped.
        for b in [quiet, reset, hide] { b.setContentCompressionResistancePriority(.required, for: .horizontal) }
        row.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: max(220, row.fittingSize.width + inset)).isActive = true
        vc.view = stack
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.delegate = self
        p.show(relativeTo: owl.bounds, of: owl, preferredEdge: .maxY)
        popover = p
        // Tab reaches the recent hints (custom views join the loop once it
        // is recalculated).
        stack.window?.autorecalculatesKeyViewLoop = true
        stack.window?.recalculateKeyViewLoop()
    }

    static let autoReviewNoteID = NSUserInterfaceItemIdentifier("owl.autoReviewNote")

    /// The open popover's recent-hint rows, top first (checks).
    var popoverRecentRows: [OwlRecentHintRow] {
        var out: [OwlRecentHintRow] = []
        func walk(_ v: NSView) {
            if let r = v as? OwlRecentHintRow { out.append(r); return }
            v.subviews.forEach(walk)
        }
        if let root = popover?.contentViewController?.view { walk(root) }
        return out
    }

    /// The popover's quiet auto-review note, if shown (checks).
    var popoverAutoReviewNote: String? {
        func find(_ v: NSView) -> NSTextField? {
            if let t = v as? NSTextField, t.identifier == Self.autoReviewNoteID { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        guard let root = popover?.contentViewController?.view else { return nil }
        return find(root)?.stringValue
    }

    /// The popover's window (checks: its snapshot).
    var popoverWindow: NSWindow? { popover?.contentViewController?.view.window }

    var popoverShown: Bool { popover?.isShown == true }
    /// A button in the open popover (the checks).
    func popoverButton(_ title: String) -> NSButton? {
        func find(_ v: NSView?) -> NSButton? {
            guard let v else { return nil }
            if let b = v as? NSButton, b.title == title { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return find(popover?.contentViewController?.view)
    }
    /// Whether every button in the open popover lies inside it (the checks:
    /// the bottom row once spilled past both edges).
    var popoverButtonsFit: Bool {
        guard let root = popover?.contentViewController?.view else { return false }
        root.layoutSubtreeIfNeeded()
        var ok = true
        func walk(_ v: NSView) {
            if let b = v as? NSButton {
                let r = b.convert(b.bounds, to: root)
                if r.minX < root.bounds.minX - 0.5 || r.maxX > root.bounds.maxX + 0.5 { ok = false }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return ok
    }
    /// At once, no fade: he's being picked up, or reset.
    func closePopover() {
        popover?.animates = false
        popover?.close()
        popover = nil
    }

    @objc private func quietHour() {
        OwlHub.shared.coordinator.quiet(for: 3600)
        popover?.close()
        hideBubble()
    }

    @objc private func resume() {
        OwlHub.shared.endQuiet()
        popover?.close()
    }

    @objc func askAINow() {
        closePopover()   // at once: a fast answer must not find it still up
        guard let tab else { return }
        // Over the auto-review cap: a confirmation first (Cancel by default).
        tab.confirmAskingCedric { [weak tab] in
            guard let tab else { return }
            OwlHub.shared.askAI(in: tab)
        }
    }

    @objc func grammarWithAI() {
        closePopover()
        hideBubble()
        tab?.checkGrammarWithAI()
    }

    @objc func askCedric() {
        closePopover()
        tab?.openAskCedric()
    }

    @objc func explainRegex() {
        closePopover()
        tab?.explainRegexSelection()
    }

    @objc func decodeSelection() {
        closePopover()
        tab?.decodeSelection()
    }

    @objc func findTodos() {
        closePopover()
        tab?.showTodos()
    }

    @objc func scriptSafety() {
        closePopover()
        tab?.checkScriptSafety()
    }

    @objc func setUpAskCedric() {
        closePopover()
        (NSApp.delegate as? AppDelegate)?.showAISettings(nil)
    }

    @objc func grammarHintNow() {
        closePopover()
        hideBubble()
        tab?.grammar.offerHint(userAsked: true)
    }

    @objc private func resetFromPopover() {
        popover?.close()
        resetPosition()
    }

    @objc private func hideOwl() {
        popover?.close()
        Settings.shared.showOwl = false
    }
}

extension EditorWindowController {
    /// The owl's Fix it for a long one-line JSON file: validates and
    /// pretty-prints the whole text off the main thread, then replaces it
    /// as one undo step, if the text hasn't changed meanwhile. `invalid`
    /// gets the parser's message when the whole file isn't valid JSON.
    func formatWholeJSON(invalid: @escaping @MainActor (String) -> Void) {
        let text = textView.string
        guard (text as NSString).length <= LargeDocument.sizeThreshold, textView.isEditable else { NSSound.beep(); return }
        let count = doc.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RulesHintProvider.formatWholeJSON(text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.window != nil, self.doc.changeCount == count else { return }
                    switch result {
                    case .success(let pretty):
                        let all = NSRange(location: 0, length: (self.textView.string as NSString).length)
                        self.replaceAsOneStep(all, with: pretty, actionName: String(localized: "Format JSON"))
                        self.textView.setSelectedRange(NSRange(location: 0, length: 0))
                        self.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    case .failure(let e):
                        invalid(e.errorDescription ?? String(describing: e))
                    }
                }
            }
        }
    }
}
