import AppKit
import CedricCore

/// The slim bar above a large document: what was paused and a button to
/// turn it back on.
final class LargeDocumentBar: NSView {
    let label = NSTextField(labelWithString: "")
    let button = NSButton(title: String(localized: "Turn On Anyway"), target: nil, action: nil)
    var onTurnOn: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(turnOn)
        let icon = NSImageView(image: NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, label, spacer, button])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `writingMode`: the tab has View › Writing Mode on, paused here too.
    func show(_ reason: LargeDocument.Reason, writingMode: Bool = false) {
        switch (reason, writingMode) {
        case (.longLine, false): label.stringValue = String(localized: "Very long lines: colouring, spell check and the owl are paused for speed.")
        case (.size, false): label.stringValue = String(localized: "Large file: colouring, spell check and the owl are paused for speed.")
        case (.longLine, true): label.stringValue = String(localized: "Very long lines: colouring, spell check, the owl and Writing Mode are paused for speed.")
        case (.size, true): label.stringValue = String(localized: "Large file: colouring, spell check, the owl and Writing Mode are paused for speed.")
        }
        button.toolTip = writingMode
            ? String(localized: "Colour this document, let the owl look at it and turn Writing Mode back on. Typing may lag.")
            : String(localized: "Colour this document and let the owl look at it. Typing may lag.")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds: fill only our part.
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func turnOn() { onTurnOn?() }
}

/// Large mode (LargeDocument in CedricCore): entered when a document is
/// opened, reloaded or restored large, or when an edit makes a line too
/// long; left only when the text is replaced with a document that isn't
/// large (typing a long line shorter again doesn't flicker it off).
extension EditorWindowController {
    /// Large and the user hasn't asked for the extras back: colouring,
    /// spell check and the owl's rules and AI pause.
    var extrasPaused: Bool { (largeReason != nil || largePending) && !largeOverride }

    /// The owl's rules and AI stay off for this tab (unless clicked).
    var owlIdleForSpeed: Bool { extrasPaused }

    /// `chunks`: TextKit sees long lines in chunks (LargeDocument.needsChunks);
    /// nil keeps the current choice. Only large mode chunks.
    func applyLargeMode(_ reason: LargeDocument.Reason?, newText: Bool, chunks: Bool? = nil) {
        let wasPaused = extrasPaused
        let wasChunked = textView.contentStorage?.chunkLimit != nil
        largeReason = reason
        largePending = false
        if newText { largeOverride = false }
        let chunk = reason != nil && (chunks ?? wasChunked) ? LargeDocument.chunkLength : nil
        // Folding is off in large mode (the chunks can't skip hidden lines).
        if reason != nil { foldingContextChanged() }
        textView.contentStorage?.chunkLimit = chunk
        if (chunk != nil) != wasChunked, !newText {
            // The text stays; TextKit drops its paragraphs and lays out the chunks (in every pane).
            for tv in panes.map(\.textView) {
                guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { continue }
                tlm.invalidateLayout(for: tcm.documentRange)
                tv.needsLayout = true
                tv.needsDisplay = true
            }
        }
        if let reason, extrasPaused { largeBar.show(reason, writingMode: !editing.writing.isOff) }
        largeBar.isHidden = !extrasPaused
        colorizer.paused = extrasPaused
        if !newText { updateGutterWidth() } // the fold column comes and goes
        // Spell checking (Spelling.swift) follows extrasPaused.
        spelling.apply()
        grammar.apply()
        if extrasPaused != wasPaused {
            OwlHub.shared.largeModeChanged(self)
            // Cards from before the paste would still show Apply. A whole
            // replacement drops them in setText; an edit that trips large
            // mode does not.
            if !newText { owlChat?.refreshCards() }
        }
        writingLargeModeChanged()
        // An edit made the document large: the prose font (if any) gives way to the monospaced one.
        // A whole-text replacement syncs in setText, after the new text is stored, and only once
        // the appearance has already been applied (the initial load applies it once, just after).
        if !newText, textView.font != editorFont { applyAppearance() }
    }

    /// "Turn On Anyway".
    func turnOnExtras() {
        largeOverride = true
        applyLargeMode(largeReason, newText: false)
        OwlHub.shared.largeModeChanged(self)
        colorizer.recolorAll()
        if owl != nil { OwlHub.shared.activity(in: self) }
    }

    /// After an edit of lines `lines`: a pasted or typed line over the
    /// threshold turns large mode on (once per run loop turn, after
    /// TextKit has finished with the edit).
    func checkLargeAfterEdit(lines: Range<Int>) {
        if let reason = largeReason, !largePending, textView.contentStorage?.chunkLimit == nil,
           LargeDocument.needsChunks(afterEditOf: lines, in: lineIndex) {
            // A large file of short lines (no chunks) just got a long line:
            // chunks from the next turn, once TextKit is done with the edit.
            largePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyLargeMode(reason, newText: false, chunks: true)
            }
            return
        }
        guard largeReason == nil, !largePending, let reason = LargeDocument.reason(afterEditOf: lines, in: lineIndex) else { return }
        // Paused from now (no sniff, spell check or owl for this edit).
        // Any edit card shows Apply off before the bar appears on the next
        // turn. TextKit switches to chunks once it's done with the edit.
        largePending = true
        owlChat?.refreshCards()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.largeReason == nil else { return }
            self.applyLargeMode(reason, newText: false,
                                chunks: LargeDocument.needsChunks(afterEditOf: lines, in: self.lineIndex))
        }
    }
}
