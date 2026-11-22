import AppKit
import CedricCore

/// The find/replace bar above the editor: a find field, an optional
/// replace field, Regex / Match Case / Whole Word toggles, and the match
/// count. Searching is done by the window controller through `FindEngine`.
final class FindBar: NSView, NSSearchFieldDelegate {
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let regexBox = NSButton(checkboxWithTitle: String(localized: "Regex"), target: nil, action: nil)
    let caseBox = NSButton(checkboxWithTitle: String(localized: "Match Case"), target: nil, action: nil)
    let wordBox = NSButton(checkboxWithTitle: String(localized: "Whole Word"), target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    private var replaceRow: NSStackView!
    /// Find Previous / Find Next (chevrons; the checks read them).
    private(set) var prevButton: NSButton!
    private(set) var nextButton: NSButton!

    var onFind: ((_ backwards: Bool) -> Void)?
    var onChange: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?

    var options: FindOptions {
        FindOptions(regex: regexBox.state == .on, caseSensitive: caseBox.state == .on, wholeWord: wordBox.state == .on)
    }

    var showsReplace: Bool {
        get { !replaceRow.isHidden }
        set { replaceRow.isHidden = !newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        findField.placeholderString = String(localized: "Find")
        findField.setAccessibilityLabel(String(localized: "Find"))
        findField.sendsSearchStringImmediately = true
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldAction)
        replaceField.placeholderString = String(localized: "Replace")
        replaceField.setAccessibilityLabel(String(localized: "Replace"))
        replaceField.delegate = self
        for b in [regexBox, caseBox, wordBox] {
            b.target = self
            b.action = #selector(optionChanged)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        /// Previous / next: chevron symbols, named for VoiceOver (UX review #6;
        /// they were "‹" "›" text, read as punctuation).
        func chevron(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
            let b = button("", action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .semibold))
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel(label)
            return b
        }
        let prev = chevron("chevron.left", String(localized: "Find Previous"), #selector(previous))
        prev.toolTip = String(localized: "Find Previous (⇧⌘G)")
        prevButton = prev
        let next = chevron("chevron.right", String(localized: "Find Next"), #selector(nextMatch))
        next.toolTip = String(localized: "Find Next (⌘G)")
        nextButton = next
        let done = button(String(localized: "Done"), #selector(close))
        let findRow = NSStackView(views: [findField, prev, next, regexBox, caseBox, wordBox, status, done])
        findRow.spacing = 8
        let replaceOne = button(String(localized: "Replace"), #selector(replace))
        let replaceAll = button(String(localized: "Replace All"), #selector(replaceAllAction))
        replaceRow = NSStackView(views: [replaceField, replaceOne, replaceAll])
        replaceRow.spacing = 8
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let column = NSStackView(views: [findRow, replaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Only now: the two fields share an ancestor.
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
        ])
        showsReplace = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func findFieldAction() { onChange?() }
    @objc private func optionChanged() { onChange?() }
    @objc private func previous() { onFind?(true) }
    @objc private func nextMatch() { onFind?(false) }
    @objc private func replace() { onReplace?() }
    @objc private func replaceAllAction() { onReplaceAll?() }
    @objc private func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField { onReplace?() } else { onFind?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The status bar: caret position, selection, and pop-up menus for the
/// language, encoding and line ending.
/// The status bar's zoom: a borderless pull-down whose title is the zoom
/// ("110%"). Its items go up the responder chain, so the editor, an image
/// and a PDF each zoom their own way: Zoom In, Zoom Out, Actual Size (the
/// View menu's actions; their shortcuts are shown, the View menu handles
/// them) and 75–200 % (`zoomToPercent:`, the percent in `tag`).
final class ZoomPopUp: NSPopUpButton {
    static let percents = [75, 90, 100, 110, 125, 150, 200]

    init() {
        super.init(frame: .zero, pullsDown: true)
        setAccessibilityLabel(String(localized: "Zoom"))
        toolTip = String(localized: "Zoom")
        let menu = NSMenu()
        // Always enabled (the pop-up is hidden where there is no zoom).
        // Auto-enabling validated these nil-target items up the responder
        // chain after every event (NSWindow update): ~6 ms a keystroke in
        // a 100,000-line file.
        menu.autoenablesItems = false
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        func add(_ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : .command
            i.tag = tag
            menu.addItem(i)
        }
        add(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn(_:)), "=")
        add(String(localized: "Zoom Out"), #selector(AppDelegate.zoomOut(_:)), "-")
        add(String(localized: "Actual Size"), #selector(AppDelegate.zoomReset(_:)), "0")
        menu.addItem(.separator())
        for p in Self.percents { add("\(p)%", #selector(AppDelegate.zoomToPercent(_:)), tag: p) }
        self.menu = menu
        // The tick is ours (the size shown), not the last item picked.
        (cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The title ("110%"); empty hides the pop-up. A tick marks the
    /// matching size.
    override var stringValue: String {
        get { menu?.items.first?.title ?? "" }
        set {
            menu?.items.first?.title = newValue
            setTitle(newValue)
            isHidden = newValue.isEmpty
            for i in menu?.items ?? [] where i.action == #selector(AppDelegate.zoomToPercent(_:)) {
                i.state = "\(i.tag)%" == newValue ? .on : .off
            }
        }
    }

    /// The shortcuts in the menu are shown only: ⌘= / ⌘− / ⌘0 stay the
    /// View menu's (a pop-up would otherwise answer them first).
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

final class StatusBar: NSView {
    let position = NSTextField(labelWithString: "")
    /// Words, lines and characters of the document or the selection.
    /// A click opens the stats popover (StatsPopover.swift).
    let counts = CountsLabel(labelWithString: "")
    let languageButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let encodingButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let lineEndingButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The zoom ("110%"): a pull-down with Zoom In, Zoom Out, Actual Size
    /// and a few sizes. Hidden while its title is empty (tabs without zoom).
    let zoom = ZoomPopUp()
    /// The git branch (or short SHA) with a dot for uncommitted changes;
    /// a click shows a small menu (GitIntegration.swift). Hidden outside git.
    let gitButton = NSButton(title: "", target: nil, action: nil)
    var background: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        position.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        position.textColor = .secondaryLabelColor
        counts.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        counts.textColor = .secondaryLabelColor
        counts.lineBreakMode = .byTruncatingTail
        counts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [languageButton, encodingButton, lineEndingButton, zoom] {
            b.isBordered = false
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            (b.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        }
        // VoiceOver hears what each pop-up sets, then its value (the title):
        // "Language, Markdown (auto), pop-up button" (UX review #5).
        for (b, label, tip) in [
            (languageButton, String(localized: "Language"), String(localized: "Language: how this file is highlighted and indented")),
            (encodingButton, String(localized: "Text Encoding"), String(localized: "Text encoding: save or reopen this file with another encoding")),
            (lineEndingButton, String(localized: "Line Endings"), String(localized: "Line endings: convert this file’s line endings")),
        ] {
            b.setAccessibilityLabel(label)
            b.toolTip = tip
        }
        gitButton.isBordered = false
        gitButton.controlSize = .small
        gitButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gitButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: String(localized: "Git branch"))?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        gitButton.imagePosition = .imageLeading
        gitButton.contentTintColor = .secondaryLabelColor
        gitButton.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.setViews([position, counts, spacer, gitButton, zoom, languageButton, encodingButton, lineEndingButton], in: .leading)
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Under the editor column: past a folder sidebar on the left (when
        // there is room) and never under a docked preview on the right.
        leadingInset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leadingInset,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            trailingInset,
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private lazy var leadingInset = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var trailingInset = stack.trailingAnchor.constraint(equalTo: trailingAnchor)

    /// Keeps the items between `left` and `right` points in from the
    /// edges: the editor column, when a sidebar or preview shares the row.
    func setInsets(left: CGFloat, right: CGFloat) {
        guard leadingInset.constant != left || trailingInset.constant != -right else { return }
        leadingInset.constant = left
        trailingInset.constant = -right
        needsDisplay = true
    }

    /// The items' frame in the bar (the checks).
    var itemsFrame: NSRect { stack.frame }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        // The split's divider carried down to the bar, between the
        // editor's items and the docked preview's (empty) part.
        if trailingInset.constant < 0 {
            NSRect(x: bounds.width + trailingInset.constant, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// Fills a pull-down: the first item is the title shown.
    static func fill(_ b: NSPopUpButton, title: String, items: [(String, Any?, Bool)], target: AnyObject, action: Selector) {
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for (t, rep, checked) in items {
            if t == "-" { menu.addItem(.separator()); continue }
            if rep == nil, !checked {
                let header = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                continue
            }
            let item = NSMenuItem(title: t, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = rep
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        b.menu = menu
        b.title = title
    }
}
