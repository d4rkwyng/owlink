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
        if let kept = keptLineBreaks, kept.range == old {
            // An edit that kept every line: its breaks are the ones it had.
            keptLineBreaks = nil
            doc.lineBreaks?.place(kept.kinds, newlinesIn: edited, of: storage.string as NSString)
        }
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
        defer { pendingBreaks = []; undoInserted = []; pendingFormatSnapshot = nil }
        var encodingMoved = false
        if let snapshot = pendingFormatSnapshot {
            encodingMoved = snapshot.encoding != doc.encoding || snapshot.encodingGuessed != doc.encodingGuessed
            doc.restore(snapshot)
        } else if !pendingBreaks.isEmpty, !undoInserted.isEmpty, doc.lineBreaks != nil, let storage = textView.textStorage {
            restorePendingBreaks(within: undoInserted, in: storage.string as NSString)
        } else {
            return
        }
        // Unsaved or saved again by the breaks themselves (EditedState).
        let wasDirty = doc.isDirty
        doc.noteBreaksChange()
        if wasDirty != doc.isDirty { updateTitle() }
        updateStatus()
        // The encoding bar (a guess) follows the encoding that came back.
        if encodingMoved { refreshFileNotices() } else { refreshLineEndingNoticeIfChanged() }
    }

    /// What the line endings are now (LineBreaks.summary): the most common
    /// kind and whether another is left, from the breaks there are now,
    /// not the file's as opened.
    var lineEndingShown: (ending: LineEnding, mixed: Bool) {
        guard let breaks = doc.lineBreaks else { return (doc.lineEnding, false) }
        return breaks.summary(newlines: max(0, lineIndex.lineCount - 1))
    }

    /// The mixed bar follows the breaks: shown again when undo brings an
    /// odd one back, gone when the last one goes.
    func refreshLineEndingNoticeIfChanged() {
        guard doc.lineBreaks != nil || lastLineEndingShown?.mixed == true else { return }
        let shown = lineEndingShown
        if let last = lastLineEndingShown, last.ending == shown.ending, last.mixed == shown.mixed { return }
        refreshFileNotices()
    }

    /// Reload (and Revert to Saved) replaced the text as one undoable edit:
    /// its ⌘Z brings back the old text with `before`'s format (line breaks,
    /// encoding and BOM, the guess: DocumentFormat), and its redo the
    /// reloaded file's. Before 0.6.1 only the breaks came back, and a save
    /// after ⌘Z wrote the old text in the reloaded version's encoding.
    /// Both are given, never read when the record runs: a redo runs
    /// this record after its text change, which has already taken the
    /// breaks out of the map, so the next undo got a stripped map back
    /// (Revert, ⌘Z, ⌘⇧Z, ⌘Z lost every odd break).
    func registerFormatSnapshotUndo(restoring before: DocumentFormat, redoing after: DocumentFormat) {
        guard let um = textView.undoManager, um.isUndoRegistrationEnabled else { return }
        um.registerUndo(withTarget: self) { tab in
            MainActor.assumeIsolated {
                tab.pendingFormatSnapshot = before
                tab.registerFormatSnapshotUndo(restoring: after, redoing: before)
            }
        }
    }
}
