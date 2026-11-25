import AppKit
import CedricCore

/// A mixed file's own line breaks (LineBreaks) follow the text: each
/// change to the storage moves them with their "\n" (`trackLineBreaks`),
/// so a save writes every break that is still there as it was on disk,
/// whatever was typed, deleted or undone around it. A break an edit
/// deletes is kept with the undo step (`pendingBreaks`): when undo or redo
/// puts its text back, it comes back as it was, saved in between or not.
extension EditorWindowController {
    /// A change is about to be made, before NSTextView registers its undo:
    /// one that deletes an odd break starts an undo step of its own, so
    /// the record that gives the break back (`trackLineBreaks`) is undone
    /// with its text (typing coalesced into an earlier step would leave
    /// that record as a ⌘Z of its own that changes nothing).
    func textWillChange(_ ranges: [NSValue]) {
        guard !loading, let breaks = doc.lineBreaks, breaks.isMixed else { return }
        for v in ranges {
            let r = v.rangeValue
            let i = breaks.index(from: r.location)
            if i < breaks.others.count, breaks.others[i] >> 2 < NSMaxRange(r) {
                for pane in panes { pane.textView.breakUndoCoalescing() }
                return
            }
        }
    }

    /// The storage changed: `old` (before) is now `edited`.
    func trackLineBreaks(_ old: NSRange, _ edited: NSRange) {
        guard doc.lineBreaks != nil, let storage = textView.textStorage else { return }
        let removed = doc.lineBreaks?.replace(old, newLength: edited.length) ?? []
        if let um = textView.undoManager, um.isUndoing || um.isRedoing {
            let delta = edited.length - old.length
            undoInserted = undoInserted.map { $0.location >= NSMaxRange(old) ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
            if edited.length > 0 { undoInserted.append(edited) }
            if !pendingBreaks.isEmpty, edited.length > 0 { restorePendingBreaks(within: [edited], in: storage.string as NSString) }
        }
        guard !removed.isEmpty, let um = textView.undoManager, um.isUndoRegistrationEnabled else { return }
        let location = old.location
        um.registerUndo(withTarget: self) { tab in
            MainActor.assumeIsolated { tab.pendingBreaks.append((location, removed)) }
        }
    }

    private func restorePendingBreaks(within ranges: [NSRange], in text: NSString) {
        pendingBreaks = pendingBreaks.compactMap { p in
            var left = p.removed
            for r in ranges where !left.isEmpty {
                left = doc.lineBreaks?.restore(left, at: p.location, within: r, in: text) ?? left
            }
            return left.isEmpty ? nil : (p.location, left)
        }
    }

    /// An undo or redo is done: breaks whose record ran after their text
    /// came back (a step that registered its undo after the change) come
    /// back now, only where that undo or redo inserted text; Reload's ⌘Z
    /// sets the old text's breaks whole.
    func undoOrRedoEnded() {
        defer { pendingBreaks = []; undoInserted = []; pendingBreakSnapshot = nil }
        if let snapshot = pendingBreakSnapshot {
            doc.lineEnding = snapshot.0
            doc.lineBreaks = snapshot.1
        } else if !pendingBreaks.isEmpty, !undoInserted.isEmpty, doc.lineBreaks != nil, let storage = textView.textStorage {
            restorePendingBreaks(within: undoInserted, in: storage.string as NSString)
        } else {
            return
        }
        updateStatus()
    }

    /// Reload (and Revert to Saved) replaced the text as one undoable edit:
    /// its ⌘Z brings back the old text with `before`'s line breaks, and
    /// its redo the reloaded file's.
    func registerLineBreaksSnapshotUndo(_ before: (LineEnding, LineBreaks?)) {
        guard let um = textView.undoManager, um.isUndoRegistrationEnabled else { return }
        um.registerUndo(withTarget: self) { tab in
            MainActor.assumeIsolated {
                let now = (tab.doc.lineEnding, tab.doc.lineBreaks)
                tab.pendingBreakSnapshot = before
                tab.registerLineBreaksSnapshotUndo(now)
            }
        }
    }
}
