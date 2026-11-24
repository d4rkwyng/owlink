import AppKit
import CedricCore

/// One proposed edit in Ask Cedric (0.4.1): the reason, the change as a
/// before/after diff, and Apply / Skip. Apply is enabled only while the
/// proposal applies to the live document (`OwlEditProposal.state`) and the
/// whole replacement has been on screen: a diff taller than the preview
/// stays disabled until Show all. A read-only document never applies.
/// The panel does the applying (`OwlChatPanel.apply(_:)`).
@MainActor
final class OwlEditCard: NSStackView {
    let proposal: OwlEditProposal
    let titleLabel = NSTextField(labelWithString: "")
    /// "Proposed, not applied": the app says so, whatever the model wrote.
    /// The card goes on Apply, and the transcript says "Applied."
    let badgeLabel = NSTextField(labelWithString: OwlProposalWording.badge)
    let reasonLabel = NSTextField(wrappingLabelWithString: "")
    let warningLabel = NSTextField(labelWithString: "")
    let diffView = NSTextView()
    let staleLabel = NSTextField(wrappingLabelWithString: "")
    /// The edit validation's warnings (OwlEditCheck); hidden when there are none.
    let checkLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var applyButton: NSButton!
    private(set) var skipButton: NSButton!
    private(set) var askAgainButton: NSButton!
    private(set) var showAllButton: NSButton!
    private(set) var state: OwlEditProposal.ApplyState = .stale

    /// "Text changed or isn’t unique; ask again."
    static let staleText = String(localized: "Text changed or isn’t unique; ask again.")
    static let readOnlyText = String(localized: "This document is read-only, so the change can’t be applied.")

    private let diffRowTexts: [String]
    private let cardIndex: Int
    private let cardCount: Int
    private let warnsInvisible: Bool
    private var diffHeight: NSLayoutConstraint!
    private var measuredChars = 0
    private var needsShowAll: Bool
    private var hasShownAll = false
    private var layoutNoteQueued = false
    /// The panel lays the card list out again after Show all, or after the
    /// first width measurement changes how tall the diff is.
    var onLayout: (() -> Void)?

    private static let rowHeight: CGFloat = 16
    private static let diffChrome: CGFloat = 12
    /// The opened diff, tall enough to read, still inside the card list.
    private static let expandedCap: CGFloat = 220
    private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let markFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    init(_ p: OwlEditProposal, index: Int, of count: Int, target: AnyObject,
         apply: Selector, skip: Selector, askAgain: Selector) {
        proposal = p
        let rows = p.diffLines
        diffRowTexts = rows.map(\.text)
        cardIndex = index
        cardCount = count
        warnsInvisible = OwlEditInvisibles.contains(p.original) || OwlEditInvisibles.contains(p.replacement)
        needsShowAll = OwlEditReview.needsShowAll(rows: rows.map(\.text), charsPerRow: OwlEditReview.fallbackCharsPerRow)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        detachesHiddenViews = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        titleLabel.stringValue = title(first: p.firstLine, last: p.lastLine)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .systemOrange
        reasonLabel.stringValue = OwlProposalWording.guardReason(p.reason)
        reasonLabel.font = .systemFont(ofSize: 11)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.isHidden = p.reason.isEmpty

        warningLabel.stringValue = OwlEditInvisibles.warning
        warningLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        warningLabel.textColor = .systemPurple
        warningLabel.isHidden = !warnsInvisible

        diffView.isEditable = false
        diffView.isSelectable = true
        diffView.isRichText = true
        diffView.font = Self.bodyFont
        diffView.isVerticallyResizable = true
        diffView.isHorizontallyResizable = false
        diffView.autoresizingMask = [.width]
        diffView.textContainer?.widthTracksTextView = true
        diffView.textContainer?.lineBreakMode = .byCharWrapping
        diffView.textStorage?.setAttributedString(Self.attributedDiff(rows))
        // VoiceOver reads the whole change, with invisible characters named.
        diffView.setAccessibilityLabel(String(localized: "Before and after"))
        diffView.setAccessibilityValue(p.spokenDiff)
        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        diffHeight = scroll.heightAnchor.constraint(equalToConstant: collapsedHeight)
        diffHeight.isActive = true

        showAllButton = NSButton(title: String(localized: "Show all"), target: self, action: #selector(showAll(_:)))
        showAllButton.bezelStyle = .inline
        showAllButton.controlSize = .small
        showAllButton.font = .systemFont(ofSize: 11)
        showAllButton.setAccessibilityLabel(String(localized: "Show all"))
        showAllButton.isHidden = !needsShowAll

        staleLabel.font = .systemFont(ofSize: 11)
        staleLabel.textColor = .systemOrange
        staleLabel.isHidden = true

        checkLabel.stringValue = p.check.warningText ?? ""
        checkLabel.font = .systemFont(ofSize: 11)
        checkLabel.textColor = .systemOrange
        checkLabel.isHidden = p.check.warningText == nil

        func small(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: target, action: action)
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.bezelStyle = .rounded
            return b
        }
        applyButton = small(String(localized: "Apply"), apply)
        skipButton = small(String(localized: "Skip"), skip)
        askAgainButton = small(String(localized: "Ask Again"), askAgain)
        askAgainButton.isHidden = true
        applyButton.isEnabled = false
        let lines = Self.linesPhrase(first: p.firstLine, last: p.lastLine)
        applyButton.setAccessibilityLabel(String(localized: "Apply the change to \(lines)"))
        skipButton.setAccessibilityLabel(String(localized: "Skip the change to \(lines)"))
        let buttons = NSStackView(views: [applyButton, skipButton, askAgainButton])
        buttons.spacing = 6

        let header = NSStackView(views: [titleLabel, badgeLabel])
        header.spacing = 6
        header.alignment = .firstBaseline
        for v in [header, reasonLabel, warningLabel, checkLabel, scroll, showAllButton, staleLabel, buttons] as [NSView] {
            addArrangedSubview(v)
        }
        scroll.widthAnchor.constraint(equalTo: widthAnchor, constant: -12).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The diff with `⟨U+XXXX⟩` drawn in a distinct style where the
    /// proposal hides a character. Ranges are applied to the line before
    /// the row prefix, so they stay on the token.
    private static func attributedDiff(_ rows: [(kind: LineDiff.RowKind, text: String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let markColor = NSColor.systemPurple
        let markBG = NSColor.systemPurple.withAlphaComponent(0.28)
        for row in rows {
            let rendered = OwlEditInvisibles.render(row.text)
            let (prefix, bg): (String, NSColor) = row.kind == .removed
                ? ("- ", NSColor.systemRed.withAlphaComponent(0.18))
                : row.kind == .added ? ("+ ", NSColor.systemGreen.withAlphaComponent(0.18)) : ("  ", .clear)
            let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor, .backgroundColor: bg]
            let body = NSMutableAttributedString(string: rendered.text, attributes: base)
            let mark: [NSAttributedString.Key: Any] = [.font: markFont, .foregroundColor: markColor, .backgroundColor: markBG]
            for r in rendered.invisibleRanges { body.addAttributes(mark, range: r) }
            let line = NSMutableAttributedString(string: prefix, attributes: base)
            line.append(body)
            line.append(NSAttributedString(string: "\n", attributes: base))
            out.append(line)
        }
        return out
    }

    private var collapsedHeight: CGFloat {
        CGFloat(min(OwlEditReview.visibleRows, max(1, diffRowTexts.count))) * Self.rowHeight + Self.diffChrome
    }

    /// Collapsed while the replacement is still hidden. Once the measured
    /// width says it fits, or the user has opened it, the scroll is as
    /// tall as the text (capped after Show all).
    private func fittedHeight(chars: Int) -> (needs: Bool, height: CGFloat) {
        let collapsed = collapsedHeight
        let needs = OwlEditReview.needsShowAll(rows: diffRowTexts, charsPerRow: chars)
        if needs, !hasShownAll { return (true, collapsed) }
        let full = contentHeight()
        if hasShownAll {
            let opened = full > 1 ? min(max(collapsed, full), Self.expandedCap) : min(max(collapsed, diffHeight.constant), Self.expandedCap)
            return (needs, opened)
        }
        if full > 1 { return (false, max(collapsed, full)) }
        return (false, collapsed)
    }

    private func contentHeight() -> CGFloat {
        guard let container = diffView.textContainer, let lm = diffView.layoutManager else { return 0 }
        lm.ensureLayout(for: container)
        return ceil(lm.usedRect(for: container).height) + Self.diffChrome
    }

    override func layout() {
        super.layout()
        guard let container = diffView.textContainer else { return }
        let width = diffView.bounds.width - container.lineFragmentPadding * 2
        guard width > 20 else { return }
        let sample = ("0" as NSString).size(withAttributes: [.font: Self.bodyFont]).width
        guard sample > 0.5 else { return }
        let chars = max(8, Int(width / sample))
        guard chars != measuredChars else { return }
        measuredChars = chars
        let fit = fittedHeight(chars: chars)
        let needsChanged = fit.needs != needsShowAll
        let heightChanged = abs(fit.height - diffHeight.constant) > 0.5
        guard needsChanged || heightChanged else { return }
        needsShowAll = fit.needs
        if heightChanged { diffHeight.constant = fit.height }
        if needsChanged { show(state) }
        noteLayout()
    }

    private func noteLayout() {
        guard !layoutNoteQueued else { return }
        layoutNoteQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutNoteQueued = false
                self.onLayout?()
            }
        }
    }

    /// Opens the whole replacement. Apply may enable only after this.
    @objc private func showAll(_ sender: Any?) {
        hasShownAll = true
        let full = contentHeight()
        diffHeight.constant = min(max(collapsedHeight, full > 1 ? full : diffHeight.constant), Self.expandedCap)
        show(state)
        noteLayout()
    }

    private static func linesPhrase(first: Int, last: Int) -> String {
        first == last ? String(localized: "line \(first)") : String(localized: "lines \(first)–\(last)")
    }

    private func title(first: Int, last: Int) -> String {
        let lines = Self.linesPhrase(first: first, last: last)
        if cardCount > 1 { return String(localized: "Change \(cardIndex + 1) of \(cardCount), \(lines)") }
        return first == last
            ? String(localized: "Proposed change to line \(first)")
            : String(localized: "Proposed change to lines \(first)–\(last)")
    }

    private func updateButtonLabels(first: Int, last: Int) {
        let lines = Self.linesPhrase(first: first, last: last)
        applyButton.setAccessibilityLabel(String(localized: "Apply the change to \(lines)"))
        skipButton.setAccessibilityLabel(String(localized: "Skip the change to \(lines)"))
    }

    /// Where the unique match is now. The title and the Apply / Skip
    /// labels follow it; the warning, when there is one, stays.
    func setLocation(first: Int, last: Int) {
        titleLabel.stringValue = title(first: first, last: last)
        updateButtonLabels(first: first, last: last)
        updateAccessLabel()
    }

    private func updateAccessLabel() {
        var label = titleLabel.stringValue + ". " + badgeLabel.stringValue
        if !proposal.reason.isEmpty { label += ": " + OwlProposalWording.guardReason(proposal.reason) }
        if warnsInvisible { label += ". " + OwlEditInvisibles.warning }
        if let f = proposal.check.failureText { label += ". " + f }
        if let w = proposal.check.warningText { label += ". " + w }
        setAccessibilityLabel(label)
    }

    /// Shows where the proposal stands. Apply stays off until a long
    /// replacement has been opened, with no stale or read-only message
    /// for that wait alone.
    func show(_ s: OwlEditProposal.ApplyState) {
        state = s
        let ready: Bool
        switch s {
        case .ready:
            ready = true
            staleLabel.isHidden = true
            askAgainButton.isHidden = true
        case .stale:
            ready = false
            staleLabel.stringValue = Self.staleText
            staleLabel.isHidden = false
            askAgainButton.isHidden = false
        case .readOnly:
            ready = false
            staleLabel.stringValue = Self.readOnlyText
            staleLabel.isHidden = false
            askAgainButton.isHidden = true
        case .failsValidation(let why):
            // "Doesn't parse: …": Apply stays off.
            ready = false
            staleLabel.stringValue = why
            staleLabel.isHidden = false
            askAgainButton.isHidden = true
        }
        applyButton.isEnabled = OwlEditReview.applyEnabled(ready: ready, needsShowAll: needsShowAll, hasShownAll: hasShownAll)
        showAllButton.isHidden = !needsShowAll || hasShownAll
        var help: [String] = []
        if !staleLabel.isHidden { help.append(staleLabel.stringValue) }
        if needsShowAll, !hasShownAll { help.append(String(localized: "Show all to review the full replacement.")) }
        setAccessibilityHelp(help.isEmpty ? nil : help.joined(separator: " "))
    }

    var isReady: Bool { if case .ready = state { return true }; return false }
}
