import UIKit
import CedricCore

/// Not valid UTF-8: Owlink read the file as an 8-bit encoding it guessed
/// (TextCodec.guessEightBit). A slim notice says so and offers Reopen with
/// Encoding… and Keep, as the Mac's encoding bar (0.5.4): a save would
/// otherwise lock in a wrong guess without a word. It doesn't block typing,
/// and the status bar says "Latin-1 (guessed)" until one is chosen.
final class EncodingNoticeBar: UIView {
    let label = UILabel()
    let reopenButton = UIButton(type: .system)
    let keepButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground.withAlphaComponent(0.97)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        accessibilityIdentifier = "editor.encodingNotice"
        let icon = UIImageView(image: UIImage(systemName: "questionmark.circle"))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        for (b, title, id) in [(reopenButton, EditorViewController.reopenWithEncodingTitle, "editor.encodingNotice.reopen"),
                               (keepButton, String(localized: "Keep"), "editor.encodingNotice.keep")] {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            b.titleLabel?.adjustsFontForContentSizeCategory = true
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.accessibilityIdentifier = id
        }
        reopenButton.showsMenuAsPrimaryAction = true
        let buttons = UIStackView(arrangedSubviews: [reopenButton, keepButton])
        buttons.spacing = 12
        let row = UIStackView(arrangedSubviews: [icon, label, buttons])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A narrow phone: the buttons go under the text.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if let row = subviews.first as? UIStackView {
            let narrow = traitCollection.horizontalSizeClass == .compact || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            row.axis = narrow ? .vertical : .horizontal
            row.alignment = narrow ? .leading : .center
        }
    }
}

extension EditorViewController {
    static var reopenWithEncodingTitle: String { String(localized: "Reopen with Encoding…") }

    /// The notice's text for the file's guessed encoding.
    var encodingNoticeText: String {
        String(localized: "This file isn’t valid UTF-8, so Owlink opened it as \(document.encoding.shortName) (a guess).")
    }

    /// Shows, updates or hides the notice for the document now (after
    /// every load: open, a reload after a change elsewhere, a reopen).
    func refreshEncodingNotice() {
        guard isViewLoaded else { return }
        guard document.encodingGuessed, !encodingNoticeKept else {
            encodingNotice?.isHidden = true
            return
        }
        let bar = encodingNotice ?? makeEncodingNotice()
        bar.label.text = encodingNoticeText
        bar.accessibilityLabel = encodingNoticeText
        bar.reopenButton.menu = reopenWithEncodingMenu(inline: true)
        if bar.isHidden {
            bar.isHidden = false
            UIAccessibility.post(notification: .announcement, argument: encodingNoticeText)
        }
    }

    private func makeEncodingNotice() -> EncodingNoticeBar {
        let bar = EncodingNoticeBar()
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.keepButton.addAction(UIAction { [weak self] _ in self?.keepGuessedEncoding() }, for: .primaryActionTriggered)
        // Under a failed save's strip, which matters more.
        view.insertSubview(bar, belowSubview: saveErrorBanner)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -10),
        ])
        encodingNotice = bar
        return bar
    }

    /// Keep: the guessed encoding is the user's now (no longer "guessed").
    func keepGuessedEncoding() {
        document.encodingGuessed = false
        encodingNoticeKept = true
        refreshEncodingNotice()
        updateStatus()
    }

    /// Reopen with Encoding…: in the notice, and in More › Encoding and
    /// Line Endings (it reads the file's bytes again, unlike Save As
    /// Encoding, which writes them differently).
    func reopenWithEncodingMenu(inline: Bool = false) -> UIMenu {
        let items = TextEncoding.allCases.map { e in
            let a = UIAction(title: e.displayName, state: e == document.encoding ? .on : .off) { [weak self] _ in
                self?.confirmReopen(with: e)
            }
            a.accessibilityIdentifier = "editor.reopenEncoding.\(e.rawValue)"
            return a
        }
        let title = inline ? String(localized: "Reopen with Encoding") : Self.reopenWithEncodingTitle
        let menu = UIMenu(title: title, image: inline ? nil : UIImage(systemName: "arrow.triangle.2.circlepath"), children: items)
        if !editGate.isEditable { for case let a as UIAction in menu.children where a.state != .on { a.attributes = .disabled } }
        return menu
    }

    /// Unsaved changes are replaced by the file read again: asked first
    /// (Undo brings them back either way).
    func confirmReopen(with e: TextEncoding) {
        guard document.hasUnsavedChanges else { reopen(with: e); return }
        let a = UIAlertController(title: String(localized: "Reopen “\(document.displayName)” as \(e.displayName)?"),
                                  message: String(localized: "The text is read again from the file, so your unsaved changes are replaced. You can undo this with Undo."),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: String(localized: "Reopen"), style: .destructive) { [weak self] _ in self?.reopen(with: e) })
        present(a, animated: true)
    }

    /// The file's bytes read again as `e`, as one undoable change of text
    /// and encoding (the encoding is then the user's pick, not a guess).
    /// Nothing changes when they aren't valid in `e`.
    @discardableResult
    func reopen(with e: TextEncoding) -> Bool {
        guard let data = document.bytesForReopen(), let decoded = TextCodec.decode(data, as: e) else {
            toast(String(localized: "\(document.displayName) can’t be read as \(e.displayName)."))
            return false
        }
        if decoded.text != textView.text {
            guard explicitChangeAllowed() else { return false }
            replaceAllText(with: decoded.text)
        }
        let change = FormatChange(from: .init(encoding: document.encoding, lineEnding: document.lineEnding,
                                              mixedLineEndings: document.mixedLineEndings),
                                  to: .init(encoding: decoded.encoding, lineEnding: decoded.lineEnding,
                                            mixedLineEndings: decoded.mixedLineEndings))
        if change.to != change.from { applyFormat(change, actionName: String(localized: "Reopen with Encoding")) }
        document.encodingGuessed = false
        encodingNoticeKept = true
        refreshEncodingNotice()
        updateStatus()
        return true
    }
}
