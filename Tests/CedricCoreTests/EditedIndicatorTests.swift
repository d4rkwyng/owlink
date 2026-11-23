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
