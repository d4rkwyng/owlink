import Foundation

/// How a Mac tab shows unsaved edits: a trailing " •" on the window title
/// (and so on the native tab's label) beside AppKit's own edited dot. The
/// document's name itself never carries the mark (alerts, menus, the
/// session and the sidebar use it).
public enum EditedIndicator {
    /// The mark after the name when the tab has unsaved edits.
    public static let mark = " •"

    /// The window (and tab) title: exactly `displayName` when clean.
    public static func windowTitle(displayName: String, isDirty: Bool) -> String {
        isDirty ? displayName + mark : displayName
    }

    /// What VoiceOver reads for the window: the name, then `edited` (the
    /// localized word "Edited") when there are unsaved edits.
    public static func accessibilityTitle(displayName: String, isDirty: Bool, edited: String) -> String {
        isDirty ? "\(displayName), \(edited)" : displayName
    }
}

/// Whether a tab has unsaved edits, by its text rather than a count of
/// changes: undo or redo back to the text last saved (or opened) is clean
/// again. A change that only shows on save (encoding, line endings) and a
/// buffer that is unsaved by definition (restored from the session, a file
/// deleted on disk) stay unsaved until the next save.
public struct EditedState {
    /// The text at the last save, open or clean reload; nil when unknown
    /// (then any text change is unsaved until the next save).
    private var savedText: NSString?
    /// The text differed from `savedText` at the last change.
    public private(set) var textDiffers = false
    /// Encoding or line endings changed: written on save, not visible in the text.
    public private(set) var formatChanged = false
    /// Unsaved whatever the text says (session buffer, missing file).
    public private(set) var forced = false

    /// A new document: clean, with `savedText` as its text ("" for a new
    /// untitled tab, so typing and undoing back to empty is clean).
    public init(savedText: String? = "") {
        self.savedText = savedText.map { NSString(string: $0) }
    }

    public var isDirty: Bool { textDiffers || formatChanged || forced }

    /// Saved (or opened, or reloaded clean): `text` is the new baseline.
    /// Keeps an immutable copy, never the caller's mutable storage.
    public mutating func saved(_ text: NSString?) {
        savedText = text?.copy() as? NSString
        textDiffers = false
        formatChanged = false
        forced = false
    }

    /// The text changed (an edit, undo or redo): compare with the baseline.
    /// The length first, so most edits cost nothing more.
    public mutating func textChanged(to text: NSString?) {
        guard let savedText, let text else { textDiffers = true; return }
        textDiffers = savedText.length != text.length || !savedText.isEqual(text)
    }

    /// Encoding or line endings changed (applied on save).
    public mutating func noteFormatChange() { formatChanged = true }

    /// Unsaved by definition until the next save.
    public mutating func forceDirty() { forced = true }
}
