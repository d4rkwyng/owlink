import Foundation
import Testing
@testable import CedricCore

@Suite struct EditedIndicatorTests {
    @Test func cleanTitleIsExactlyTheName() {
        #expect(EditedIndicator.windowTitle(displayName: "notes.md", isDirty: false) == "notes.md")
        #expect(EditedIndicator.windowTitle(displayName: "Untitled", isDirty: false) == "Untitled")
        // A name that already ends in a bullet is left as it is.
        #expect(EditedIndicator.windowTitle(displayName: "list •", isDirty: false) == "list •")
    }

    @Test func dirtyTitleEndsInTheMark() {
        #expect(EditedIndicator.windowTitle(displayName: "notes.md", isDirty: true) == "notes.md •")
        #expect(EditedIndicator.windowTitle(displayName: "Untitled 2", isDirty: true) == "Untitled 2 •")
        #expect(EditedIndicator.mark == " •")
    }

    @Test func accessibilityTitleSaysEdited() {
        #expect(EditedIndicator.accessibilityTitle(displayName: "notes.md", isDirty: false, edited: "Edited") == "notes.md")
        #expect(EditedIndicator.accessibilityTitle(displayName: "notes.md", isDirty: true, edited: "Edited") == "notes.md, Edited")
        #expect(EditedIndicator.accessibilityTitle(displayName: "Untitled", isDirty: true, edited: "Bearbeitet") == "Untitled, Bearbeitet")
    }
}

@Suite struct EditedStateTests {
    @Test func newUntitledIsCleanAndEmptyAgainIsClean() {
        var s = EditedState()
        #expect(!s.isDirty)
        s.textChanged(to: "a")
        #expect(s.isDirty)
        // Undo back to empty.
        s.textChanged(to: "")
        #expect(!s.isDirty)
    }

    @Test func undoBackToTheSavedTextIsClean() {
        var s = EditedState()
        s.saved("alpha\n")
        #expect(!s.isDirty)
        s.textChanged(to: "xalpha\n")
        #expect(s.isDirty)
        // Same length, different text: still unsaved.
        s.textChanged(to: "alphb\n")
        #expect(s.isDirty)
        s.textChanged(to: "alpha\n")
        #expect(!s.isDirty)
        // Redo away and back again.
        s.textChanged(to: "xalpha\n")
        #expect(s.isDirty)
        s.textChanged(to: "alpha\n")
        #expect(!s.isDirty)
    }

    @Test func theBaselineIsACopyNotTheLiveBuffer() {
        let buffer = NSMutableString(string: "saved")
        var s = EditedState()
        s.saved(buffer)
        buffer.append(" and typed")
        s.textChanged(to: buffer)
        #expect(s.isDirty)
        buffer.setString("saved")
        s.textChanged(to: buffer)
        #expect(!s.isDirty)
    }

    @Test func aSaveMovesTheBaseline() {
        var s = EditedState()
        s.saved("one")
        s.textChanged(to: "two")
        s.saved("two")
        #expect(!s.isDirty)
        // Undo after a save: the old text is now the unsaved one.
        s.textChanged(to: "one")
        #expect(s.isDirty)
    }

    @Test func aFormatChangeStaysUnsavedUntilSaved() {
        var s = EditedState()
        s.saved("text\n")
        s.noteFormatChange()
        #expect(s.isDirty && s.formatChanged)
        // Typing and undoing doesn't clear a line-ending or encoding change.
        s.textChanged(to: "text\nx")
        s.textChanged(to: "text\n")
        #expect(s.isDirty)
        s.saved("text\n")
        #expect(!s.isDirty && !s.formatChanged)
    }

    @Test func sessionAndMissingBuffersStayUnsaved() {
        var s = EditedState()
        s.saved("restored")
        s.forceDirty()
        #expect(s.isDirty && s.forced)
        s.textChanged(to: "restored!")
        s.textChanged(to: "restored")
        #expect(s.isDirty)
        s.saved("restored")
        #expect(!s.isDirty && !s.forced)
    }

    @Test func anUnknownBaselineIsUnsavedAfterAnyChange() {
        var s = EditedState(savedText: nil)
        #expect(!s.isDirty)
        s.textChanged(to: "")
        #expect(s.isDirty)
        var t = EditedState()
        t.saved(nil)
        t.textChanged(to: "same")
        #expect(t.isDirty)
    }
}

/// 0.5.4 QA, should round 2: the text has every break as LF, so a CRLF
/// deleted and Return typed back at the same place was the saved text
/// again: the tab clean, and autosave and closing skipped a change a save
/// writes. The breaks count toward unsaved too.
@Suite struct EditedStateBreaksTests {
    @Test func aChangedBreakIsUnsavedUntilItIsBackOrSaved() {
        let saved = LineBreaks(dominant: .lf, others: [LineBreaks.entry(1, .crlf)])
        var e = EditedState(savedText: "a\nb\n")
        e.saved("a\nb\n" as NSString, breaks: saved)
        #expect(!e.isDirty)
        // The CRLF deleted, an LF typed back: same text, other breaks.
        var now = saved
        now.replace(NSRange(location: 1, length: 1), newLength: 0)
        now.replace(NSRange(location: 1, length: 0), newLength: 1)
        e.textChanged(to: "a\nb\n")
        e.breaksChanged(to: now)
        #expect(!e.textDiffers)
        #expect(e.isDirty, "the break changed: unsaved")
        // Undo gives the CRLF back: clean again.
        e.breaksChanged(to: saved)
        #expect(!e.isDirty)
        // Saved with the LF: that is the baseline now.
        e.breaksChanged(to: now)
        e.saved("a\nb\n" as NSString, breaks: now)
        #expect(!e.isDirty)
        e.breaksChanged(to: now)
        #expect(!e.isDirty)
        // No odd break either way is the same as none at all.
        var plain = EditedState(savedText: "x")
        plain.breaksChanged(to: LineBreaks(dominant: .lf))
        #expect(!plain.isDirty)
        // A fingerprinted (long) baseline keeps its breaks too.
        var long = EditedState(savedText: nil, snapshotLimit: 4, chunk: 4)
        long.saved("abcdef\n" as NSString, breaks: saved)
        long.breaksChanged(to: now)
        #expect(long.isDirty)
    }
}
