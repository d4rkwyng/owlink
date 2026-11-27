import AppKit
import CedricCore

/// The auto-review cap (`AutoReviewCap` in CedricCore: over 100 KB of
/// UTF-8 or 2,000 lines) for a tab. Over it, Cedric does nothing on his
/// own for the document:
///
/// - the AI scheduler never arms a check for it (`LocalAIOwlBridge`
///   `setAutoReviewCapped`, `wantsContext`), so opening, saving or leaving
///   it idle loads no model and sends nothing;
/// - no automatic AI grammar pass, no grammar pop-up and no "Fix N typos?"
///   offer (Grammar.swift, Spelling.swift);
/// - the owl's popover says so, quietly (`AutoReviewCap.note`).
///
/// The rules keep running: they read only the owl's 8 KB window
/// (`OwlContextWindow`) and never load a model.
///
/// Asking still works (Ask AI Now, Ask Cedric and its quick actions and
/// whole-file review, Check for Risks, Check Grammar with Cedric), after
/// `confirmAskingCedric`, once per opened text.
///
/// Not large mode: "Turn On Anyway" (LargeDocumentMode.swift) brings the
/// editor's extras back and leaves this cap alone.
extension EditorWindowController {
    var autoReviewCapped: Bool { autoReviewCapReason != nil }

    /// The document's size as the cap counts it (O(n): the UTF-8 count).
    var autoReviewSize: AutoReviewCap.Size {
        let ns = (textView.textStorage?.string ?? "") as NSString
        return AutoReviewCap.Size(utf8Bytes: ns.lengthOfBytes(using: String.Encoding.utf8.rawValue),
                                  lines: AutoReviewCap.lineCount(lineIndex))
    }

    /// After the text was replaced (`newText`: open, reload, restore) or
    /// edited. O(1) unless the document is between a third of the byte
    /// cap and the cap in UTF-16 units (then a UTF-8 count). The owl hub
    /// hears only when the verdict flips.
    func updateAutoReviewCap(newText: Bool) {
        if newText { autoReviewAskConfirmed = false }
        let storage = textView.textStorage
        let reason = AutoReviewCap.reason(utf16Length: lineIndex.length, lines: AutoReviewCap.lineCount(lineIndex)) {
            ((storage?.string ?? "") as NSString).lengthOfBytes(using: String.Encoding.utf8.rawValue)
        }
        let was = autoReviewCapped
        autoReviewCapReason = reason
        if was != autoReviewCapped { OwlHub.shared.autoReviewCapChanged(self) }
    }

    /// Before Cedric is asked about a document over the cap: a sheet that
    /// names its size and says auto-review is off; Cancel is the default
    /// (Return). "Ask Anyway" runs `proceed` and is remembered until the
    /// text is replaced. Under the cap, or already confirmed: `proceed`
    /// at once. `host`: the window to attach the sheet to (Ask Cedric's
    /// panel when asked from there; the tab's window otherwise).
    func confirmAskingCedric(over host: NSWindow? = nil, then proceed: @escaping @MainActor () -> Void) {
        guard autoReviewCapped, !autoReviewAskConfirmed else { proceed(); return }
        guard let w = host ?? window, w.attachedSheet == nil else { NSSound.beep(); return }
        let text = AutoReviewCap.confirmation(fileName: doc.displayName, size: autoReviewSize)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text.title
        alert.informativeText = text.message
        // Cancel is the sheet's default button (Return). NSAlert doesn't
        // make a first button titled Cancel the default on its own, so it
        // is set here (the sheet keeps it as its default button cell). Ask
        // Anyway has no key: it takes a deliberate click.
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        let ask = alert.addButton(withTitle: String(localized: "Ask Anyway"))
        cancel.keyEquivalent = "\r"
        ask.keyEquivalent = ""
        Self.autoReviewAlertsShown += 1
        alert.beginSheetModal(for: w) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertSecondButtonReturn, let self else { return }
                self.autoReviewAskConfirmed = true
                proceed()
            }
        }
    }

    /// How many times the confirmation was shown (checks).
    static var autoReviewAlertsShown = 0
}

extension OwlHub {
    /// A tab went over the auto-review cap or back under it: the AI's
    /// scheduler hears (it forgets the document and arms nothing for it
    /// while over) and a context waiting to be fed is dropped.
    func autoReviewCapChanged(_ tab: EditorWindowController) {
        let capped = tab.autoReviewCapped
        if capped { dropPendingFeed(tab.doc.id) }
        ai.setAutoReviewCapped(tab.doc.id, capped)
    }
}
