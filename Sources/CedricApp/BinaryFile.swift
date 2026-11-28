import AppKit
import CedricCore

/// A file whose bytes look binary (TextCodec.looksBinary: NUL bytes or
/// many control characters in its first 8 KB). Shown as text it would be
/// Mac Roman noise, and saving it would rewrite its line endings and
/// encoding, so:
///
/// - `held`: opened, nothing shown yet; the bar says "This looks like a
///   binary file" with Open Anyway. The text view is empty and read-only.
/// - `readOnly`: Open Anyway: the decoded text, read-only; Save, Save As
///   and Save a Copy are off. The bar offers Allow Editing.
/// - `editable`: the user chose Allow Editing; the tab is a text tab from
///   here on (saving writes the text as shown, line endings and all).
enum BinaryFileState: Equatable {
    case held(String)
    case readOnly
    case editable
}

/// The slim bar above a binary file (LargeDocumentBar's pattern).
final class BinaryFileBar: NSView {
    let label = NSTextField(labelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    var onButton: (() -> Void)?

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
        button.action = #selector(pressed)
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil) ?? NSImage())
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

    func show(_ state: BinaryFileState) {
        switch state {
        case .held:
            label.stringValue = String(localized: "This looks like a binary file, not text. Showing it as text won’t make sense, and saving it from Owlink could damage it.")
            button.title = String(localized: "Open Anyway")
            button.toolTip = String(localized: "Show the bytes as text, read-only.")
        case .readOnly:
            label.stringValue = String(localized: "Binary file, shown as text and read-only. Saving is off so it can’t be damaged.")
            button.title = String(localized: "Allow Editing")
            button.toolTip = String(localized: "Edit and save it as text. Saving rewrites line endings and characters Owlink can’t show.")
        case .editable:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds: fill only our part.
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func pressed() { onButton?() }
}

extension EditorWindowController {
    /// Save, Save As and Save a Copy are off until Allow Editing.
    var binaryBlocksSave: Bool {
        guard let binary else { return false }
        return binary != .editable
    }

    /// Opened a file that looks binary: `text` (its decoding) waits for
    /// Open Anyway; the tab shows the bar over an empty, read-only view.
    func holdBinary(_ text: String) {
        binary = .held(text)
        setEditable(false)
        showBinaryBar()
    }

    /// Open Anyway: the decoded text, read-only. If the open path skipped
    /// the decode (0.6.1: a binary file's first 8 KB were enough to tell),
    /// the bytes are read and decoded now, with detection, and applied to
    /// the document (encoding and line endings).
    ///
    /// That read failing (the file gone, unreadable, a volume away)
    /// shows the error and changes nothing: the tab stays held, with Open
    /// Anyway to try again. Shown read-only with the empty placeholder and
    /// marked saved instead, Allow Editing and ⌘S wrote an empty file over
    /// the original, whose stamp the failed read never changed.
    func openBinaryAnyway() {
        guard case .held(let text) = binary else { return }
        var shown = text
        if shown.isEmpty, let url = doc.fileURL {
            do {
                let (d, mod) = try EditorDocument.read(url, shareBytes: true)
                doc.apply(d)
                doc.noteDisk(mod)
                shown = d.text
            } catch {
                showError(error)
                return
            }
        }
        binary = .readOnly
        setText(shown)
        doc.markSaved()
        setEditable(false)
        showBinaryBar()
        grammar.apply()
    }

    /// Allow Editing: a text tab from here on.
    func allowBinaryEditing() {
        guard binary == .readOnly else { return }
        binary = .editable
        setEditable(true)
        binaryBar?.isHidden = true
        grammar.apply()
    }

    private func showBinaryBar() {
        guard let binary else { return }
        let bar: BinaryFileBar
        if let b = binaryBar {
            bar = b
        } else {
            bar = BinaryFileBar()
            bar.onButton = { [weak self] in
                guard let self else { return }
                if case .held = self.binary { self.openBinaryAnyway() } else { self.allowBinaryEditing() }
            }
            stack.insertArrangedSubview(bar, at: 0)
            binaryBar = bar
        }
        bar.show(binary)
        bar.isHidden = binary == .editable
    }
}
