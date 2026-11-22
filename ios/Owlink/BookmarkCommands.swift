import UIKit
import CedricCore

// Bookmarks on iOS (the Mac's EditingFeatures): toggle the caret's line,
// Next / Previous (wrapping), Clear. Kept per open document only; the
// markers are drawn in the line-number gutter, where a tap toggles a line.
extension EditorViewController {
    /// The caret's line (0-based).
    var caretLine: Int {
        let location = textView.selectedRange.location
        return lineIndex.line(containing: location == NSNotFound ? 0 : min(location, lineIndex.length))
    }

    /// Bookmark Line, or Remove Bookmark when the caret's line has one.
    var bookmarkLineTitle: String {
        bookmarks.contains(caretLine) ? String(localized: "Remove Bookmark") : String(localized: "Bookmark Line")
    }

    /// Not an edit: works read-only too.
    func toggleBookmark(line: Int? = nil) {
        let target = line ?? caretLine
        guard target >= 0, target < max(1, lineIndex.lineCount) else { return }
        bookmarks.toggle(target)
        bookmarksChanged()
    }

    /// Moves the caret to the next or previous bookmark, wrapping. None:
    /// nothing happens.
    func goToBookmark(next: Bool) {
        guard let line = next ? bookmarks.next(after: caretLine) : bookmarks.previous(before: caretLine) else { return }
        revealLine(line + 1)
    }

    func clearBookmarks() {
        guard !bookmarks.isEmpty else { return }
        bookmarks.removeAll()
        bookmarksChanged()
    }

    /// Redraws the gutter (shown while there are bookmarks).
    func bookmarksChanged() {
        layoutGutter()
    }

    @objc func toggleBookmarkMenu(_ sender: Any?) { toggleBookmark() }
    @objc func nextBookmarkMenu(_ sender: Any?) { goToBookmark(next: true) }
    @objc func previousBookmarkMenu(_ sender: Any?) { goToBookmark(next: false) }
    @objc func clearBookmarksMenu(_ sender: Any?) { clearBookmarks() }

    /// The ⋯ menu's Bookmarks submenu; titles and enablement as on the Mac.
    func bookmarksMenu() -> UIMenu {
        let none = bookmarks.isEmpty
        func item(_ title: String, _ id: String, _ symbol: String, enabled: Bool,
                  _ perform: @escaping (EditorViewController) -> Void) -> UIAction {
            let a = UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                guard let self else { return }
                perform(self)
            }
            a.accessibilityIdentifier = id
            if !enabled { a.attributes = .disabled }
            return a
        }
        return UIMenu(title: String(localized: "Bookmarks"), image: UIImage(systemName: "bookmark"), children: [
            item(bookmarkLineTitle, "editor.bookmarkLine", "bookmark", enabled: true) { $0.toggleBookmark() },
            item(String(localized: "Next Bookmark"), "editor.nextBookmark", "chevron.down", enabled: !none) { $0.goToBookmark(next: true) },
            item(String(localized: "Previous Bookmark"), "editor.previousBookmark", "chevron.up", enabled: !none) { $0.goToBookmark(next: false) },
            item(String(localized: "Clear Bookmarks"), "editor.clearBookmarks", "bookmark.slash", enabled: !none) { $0.clearBookmarks() },
        ])
    }
}
