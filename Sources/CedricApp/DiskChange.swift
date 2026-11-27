import AppKit
import CedricCore

/// A slim bar above the editor: a message and a few buttons (the
/// "Changed on disk" bar, the closed-tab "not saved" notice). Built only
/// when first needed.
final class NoticeBar: NSView {
    let label = NSTextField(labelWithString: "")
    private(set) var buttons: [NSButton] = []
    private var actions: [() -> Void] = []
    private let row = NSStackView()

    init(symbol: String) {
        super.init(frame: .zero)
        clipsToBounds = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.setViews([icon, label, spacer], in: .leading)
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

    /// Replaces the message and the buttons.
    func show(_ text: String, buttons titles: [(String, () -> Void)]) {
        label.stringValue = text
        label.toolTip = text
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        actions = titles.map(\.1)
        for (i, (title, _)) in titles.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.tag = i
            row.addArrangedSubview(b)
            buttons.append(b)
        }
        isHidden = false
    }

    func button(_ title: String) -> NSButton? { buttons.first { $0.title == title } }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds: fill only our part.
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Saving over changes on disk, and noticing them. ⌘S first compares
/// the file on disk with what this tab last read or wrote (DiskStamp: date
/// and size); if it changed, a sheet (worded by DiskConflict: never
/// "another app" when Owlink knows it changed the file itself) asks:
/// Keep What’s in This Tab, Reload from Disk (one undoable edit) or Compare. When a window becomes key
/// (or the app active), a tab with unsaved edits whose file changed shows
/// the "Changed on disk" bar; a tab without edits reloads, as before.
/// Nothing is ever dropped silently. Works with the owl on or off.
extension EditorWindowController {
    /// Whether `url` changed on disk since this tab read or saved it.
    func fileChangedOnDisk(_ url: URL) -> Bool { fileChangedOnDisk(url, current: DiskStamp.of(url)) }

    /// As `fileChangedOnDisk(_:)`, against a stamp the caller already took.
    func fileChangedOnDisk(_ url: URL, current: DiskStamp?) -> Bool {
        guard url == doc.fileURL else { return false }
        return DiskStamp.changed(known: doc.diskStamp, current: current)
    }

    static var conflictKeep: String { DiskConflict.keepTitle }
    static var conflictReload: String { DiskConflict.reloadTitle }
    static var conflictCompare: String { DiskConflict.compareTitle }

    /// What Owlink knows about the change to `url` (DiskConflict.Cause).
    func diskConflictCause(_ url: URL) -> DiskConflict.Cause {
        let std = url.standardizedFileURL
        let others = (NSApp.delegate as? AppDelegate)?.tabs
            .filter { $0 !== self && $0.doc.fileURL?.standardizedFileURL == std }
            .compactMap { $0.doc.lastSavedStamp } ?? []
        return DiskConflict.cause(known: doc.diskStamp, lastSaved: doc.lastSavedStamp, failedSave: doc.failedSaveStamp,
                                  otherTabsSaved: others, current: DiskStamp.of(url))
    }

    /// The ⌘S conflict sheet. Keep (first, destructive) never takes
    /// Return; Cancel takes Escape.
    func askSaveConflict(_ url: URL) {
        guard let window else { return }
        guard window.attachedSheet == nil else { NSSound.beep(); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = DiskConflict.message(name: doc.displayName)
        a.informativeText = DiskConflict.detail(diskConflictCause(url))
        a.addButton(withTitle: Self.conflictKeep)
        a.addButton(withTitle: Self.conflictReload)
        a.addButton(withTitle: Self.conflictCompare)
        a.addButton(withTitle: String(localized: "Cancel"))
        a.buttons[0].hasDestructiveAction = true
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn: _ = self.write(toKeeping: url)
            case .alertSecondButtonReturn: self.reloadFromDisk()
            case .alertThirdButtonReturn: self.compareWithDisk()
            default: break
            }
        }
    }

    /// Keep What’s in This Tab: write over the file (the conflict was answered).
    func write(toKeeping url: URL) -> Bool {
        doc.noteDisk(DiskStamp.of(url))
        return save()
    }

    /// This tab's text beside the file on disk (read-only compare window).
    func compareWithDisk() {
        guard let url = doc.fileURL, let app = NSApp.delegate as? AppDelegate else { return }
        do {
            let (d, _) = try EditorDocument.read(url, encoding: doc.encoding)
            app.showCompare(host: self, leftName: String(localized: "\(doc.displayName) (this tab)"), leftText: text,
                            rightName: String(localized: "\(doc.displayName) (on disk)"), rightText: d.text)
        } catch {
            showError(error)
        }
    }

    // MARK: The "Changed on disk" bar

    func showDiskBar() {
        let bar: NoticeBar
        if let b = diskBar {
            bar = b
        } else {
            bar = NoticeBar(symbol: "exclamationmark.arrow.circlepath")
            stack.insertArrangedSubview(bar, at: 0)
            diskBar = bar
        }
        bar.show(String(localized: "“\(doc.displayName)” changed on disk. Your unsaved edits are still here."), buttons: [
            (String(localized: "Reload"), { [weak self] in self?.reloadFromDisk() }),
            (String(localized: "Keep Mine"), { [weak self] in self?.keepMineOverDisk() }),
        ])
        bar.setAccessibilityLabel(bar.label.stringValue)
    }

    // MARK: Deleted or moved away

    static var missingKeep: String { String(localized: "Keep Open") }
    static var missingSave: String { String(localized: "Save") }
    static var missingSaveAs: String { String(localized: "Save As…") }
    static var missingClose: String { String(localized: "Close") }

    /// The open file is gone from its path (deleted, or moved or renamed
    /// by another app). The text stays in the tab and the tab becomes
    /// unsaved, so the session keeps it (quit, close, relaunch) until it
    /// is saved somewhere. The bar offers Keep Open, Save (recreate it
    /// where it was), Save As… and Close (a hot close: ⇧⌘T brings it
    /// back). Shown once per disappearance; a file that comes back
    /// untouched drops it, one that comes back changed gets the
    /// "Changed on disk" bar.
    func showFileMissing() {
        guard !doc.missingOnDisk else { return }
        doc.missingOnDisk = true
        if !doc.isDirty {
            doc.markDirtyFromSession()
            updateTitle()
            updateStatus()
            onChange?(self)
        }
        let bar: NoticeBar
        if let b = diskBar {
            bar = b
        } else {
            bar = NoticeBar(symbol: "exclamationmark.arrow.circlepath")
            stack.insertArrangedSubview(bar, at: 0)
            diskBar = bar
        }
        bar.show(String(localized: "“\(doc.displayName)” was deleted or moved. Its text is still here, unsaved."), buttons: [
            (Self.missingKeep, { [weak self] in
                self?.hideDiskBar()
                if let self { self.window?.makeFirstResponder(self.textView) }
            }),
            (Self.missingSave, { [weak self] in _ = self?.save() }),
            (Self.missingSaveAs, { [weak self] in _ = self?.saveAs() }),
            (Self.missingClose, { [weak self] in self?.window?.performClose(nil) }),
        ])
        bar.setAccessibilityLabel(bar.label.stringValue)
        NSAccessibility.post(element: bar, notification: .announcementRequested,
                             userInfo: [.announcement: bar.label.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hideDiskBar() {
        diskBar?.isHidden = true
    }

    /// Keep Mine: the next ⌘S writes this tab's text without asking.
    func keepMineOverDisk() {
        if let url = doc.fileURL { doc.noteDisk(DiskStamp.of(url)) }
        doc.changedOnDisk = false
        hideDiskBar()
        window?.makeFirstResponder(textView)
    }

    // MARK: One-off notices

    func showNotice(_ text: String, buttons: [(String, () -> Void)]) {
        let bar: NoticeBar
        if let b = noticeBar {
            bar = b
        } else {
            bar = NoticeBar(symbol: "info.circle")
            stack.insertArrangedSubview(bar, at: 0)
            noticeBar = bar
        }
        bar.show(text, buttons: buttons + [(String(localized: "Dismiss"), { [weak self] in self?.noticeBar?.isHidden = true })])
    }
}

extension AppDelegate {
    /// A read-only compare window for two texts, tabbed with `host`.
    func showCompare(host: EditorWindowController, leftName: String, leftText: String, rightName: String, rightText: String) {
        let c = CompareWindowController(leftName: leftName, leftText: leftText, rightName: rightName, rightText: rightText,
                                        palette: host.palette)
        compareWindows.append(c)
        c.onClose = { [weak self] c in self?.compareWindows.removeAll { $0 === c } }
        if let w = c.window {
            if let h = host.window, h.isVisible {
                h.addTabbedWindow(w, ordered: .above)
                adoptFloat(of: h, for: w)
            } else { w.center() }
            w.makeKeyAndOrderFront(nil)
        }
    }
}
