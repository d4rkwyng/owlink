import AppKit
import CedricCore

/// Two things about a file Owlink can't settle on its own, said in a slim
/// bar like the read-only one (never a sheet; the text stays editable):
///
/// - Not valid UTF-8: Owlink read it as an 8-bit encoding it guessed
///   (TextCodec.guessEightBit). The bar says so and offers Reopen with
///   Encoding… (the same picker as Format › Reopen with Encoding…, ⌥⇧⌘R)
///   and Keep. The status bar says "Latin-1 (guessed)" until one is chosen.
/// - Mixed line endings: the bar says which kind is most common and
///   offers Convert to it (one undo step, applied on save) or Keep Mixed.
///   Saving keeps each line's own ending (LineBreaks) until a line ending
///   is picked, here or from the status bar.
///
/// Neither bar reads the file again: both come from what decoding already
/// found (DecodedText.encodingGuessed, .lineBreaks).
extension EditorWindowController {
    static var encodingNoticeKeep: String { String(localized: "Keep") }
    static var reopenWithEncodingTitle: String { String(localized: "Reopen with Encoding…") }
    static var lineEndingNoticeKeep: String { String(localized: "Keep Mixed") }
    static func convertLineEndingsTitle(_ le: LineEnding) -> String { String(localized: "Convert to \(le.displayName)") }

    /// Shows, updates or hides both bars for the tab's state now.
    func refreshFileNotices() {
        var held = false
        if case .held = binary { held = true }
        let quiet = held || tail != nil
        if doc.encodingGuessed, !encodingNoticeKept, !quiet {
            let bar = noticeBar(\.encodingBar, symbol: "questionmark.circle")
            bar.show(String(localized: "This file isn’t valid UTF-8, so Owlink opened it as \(doc.encoding.shortName) (a guess)."), buttons: [
                (Self.reopenWithEncodingTitle, { [weak self, weak bar] in
                    self?.showReopenEncodingPicker(from: bar?.button(Self.reopenWithEncodingTitle))
                }),
                (Self.encodingNoticeKeep, { [weak self] in self?.keepGuessedEncoding() }),
            ])
            bar.setAccessibilityLabel(bar.label.stringValue)
        } else {
            encodingBar?.isHidden = true
        }
        let shown = lineEndingShown
        lastLineEndingShown = shown
        if shown.mixed, doc.lineBreaks != nil, !lineEndingNoticeKept, !quiet {
            let bar = noticeBar(\.lineEndingBar, symbol: "arrow.turn.down.left")
            let le = shown.ending
            bar.show(String(localized: "This file has mixed line endings (mostly \(le.displayName))."), buttons: [
                (Self.convertLineEndingsTitle(le), { [weak self] in self?.convertLineEndingsWithUndo(to: le) }),
                (Self.lineEndingNoticeKeep, { [weak self] in self?.keepMixedLineEndings() }),
            ])
            bar.setAccessibilityLabel(bar.label.stringValue)
        } else {
            lineEndingBar?.isHidden = true
        }
    }

    private func noticeBar(_ key: ReferenceWritableKeyPath<EditorWindowController, NoticeBar?>, symbol: String) -> NoticeBar {
        if let b = self[keyPath: key] { return b }
        let bar = NoticeBar(symbol: symbol)
        stack.insertArrangedSubview(bar, at: 0)
        self[keyPath: key] = bar
        return bar
    }

    /// Keep: the guessed encoding is the user's now (no longer "guessed").
    func keepGuessedEncoding() {
        doc.encodingGuessed = false
        encodingNoticeKept = true
        refreshFileNotices()
        updateStatus()
        onChange?(self)
    }

    /// Keep Mixed: the bar goes; saving keeps each line's ending, as before.
    func keepMixedLineEndings() {
        lineEndingNoticeKept = true
        refreshFileNotices()
    }

    // MARK: Reopen with Encoding…

    /// Checks only (DevEnvironment.checksEnabled): gets the picker and
    /// where it would open instead of showing it (a menu tracks modally).
    static var checkEncodingPicker: ((NSMenu, NSView) -> Void)?

    /// The encodings to read the file as again: Format › Reopen with
    /// Encoding… (⌥⇧⌘R) and the encoding bar's button. Under `anchor`, else
    /// the status bar's encoding.
    func showReopenEncodingPicker(from anchor: NSView? = nil) {
        guard doc.fileURL != nil else { NSSound.beep(); return }
        let menu = reopenEncodingMenu()
        let view = anchor ?? (statusBar.encodingButton.isHidden ? textView : statusBar.encodingButton)
        if DevEnvironment.checksEnabled, let hook = Self.checkEncodingPicker { hook(menu, view); return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
    }

    func reopenEncodingMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Reopen with Encoding"))
        menu.autoenablesItems = false
        let header = NSMenuItem(title: String(localized: "Reopen with Encoding"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for enc in TextEncoding.allCases {
            let item = NSMenuItem(title: enc.displayName, action: #selector(reopenEncodingPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = enc.rawValue
            item.state = enc == doc.encoding ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func reopenEncodingPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let enc = TextEncoding(rawValue: raw) else { return }
        reopen(with: enc)
    }
}
