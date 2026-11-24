import AppKit

/// One entry under "Recent hints" in the owl's popover: the same 11 pt
/// wrapping label as before ("10:42  Fix 3 typos?", at most 260 pt wide),
/// now a button. A click, or Return or Space while it has the focus ring,
/// shows the hint again in the owl's bubble. It is in the key view loop
/// (Tab reaches it) and VoiceOver reads it as a button named with the
/// time, the title and the start of the detail.
final class OwlRecentHintRow: NSView {
    let label: NSTextField
    private let action: () -> Void
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    /// `accessibilityText`: what VoiceOver says (time, title, detail).
    init(text: String, accessibilityText: String, toolTip: String?, action: @escaping () -> Void) {
        label = NSTextField(wrappingLabelWithString: text)
        self.action = action
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.preferredMaxLayoutWidth = 260
        label.translatesAutoresizingMaskIntoConstraints = false
        // The row is the element; the label inside isn't read twice.
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.toolTip = toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityText)
        setAccessibilityHelp(String(localized: "Shows this hint again."))
        focusRingType = .default
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -3, dy: -1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    override func becomeFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }
    override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}", " ": activate()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    /// The whole row is the button: a click on its label lands here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates, like `frame`.
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { activate() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || pressed else { return }
        NSColor.labelColor.withAlphaComponent(pressed ? 0.14 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    // MARK: Accessibility

    override func accessibilityPerformPress() -> Bool { activate(); return true }

    /// Shows the hint again (a click, Return, Space or VoiceOver's press).
    func activate() { action() }
}
