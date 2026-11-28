import AppKit
import CedricCore
import os

/// A folder sidebar click until the clicked file's text is on screen: one
/// os_signpost interval, "click to text shown" (OpenSignpost's subsystem
/// and category), from the click to the first display pass of that file's
/// text view (EditorTextView.drawBackground). The phases in between have
/// their own intervals (AppDelegate.open, makeTab, the tab's setup).
/// A file that opens in a viewer tab, or not at all, ends the interval at
/// the next click instead.
@MainActor
enum SidebarOpenTrace {
    private static var pending: (file: URL, state: OSSignpostIntervalState)?
    /// Checks only: called when the clicked file's text is first drawn.
    static var onShownForChecks: ((URL) -> Void)?

    static func clicked(_ file: URL, double: Bool = false) {
        if double { OpenSignpost.event("double click received") } else { OpenSignpost.event("click received") }
        if let p = pending { OpenSignpost.signposter.endInterval("click to text shown", p.state) }
        pending = (file.standardizedFileURL, OpenSignpost.signposter.beginInterval("click to text shown"))
    }

    /// A text view drew: if it shows the clicked file, the interval ends.
    static func drew(_ view: EditorTextView) {
        guard let p = pending,
              (view.window?.windowController as? EditorWindowController)?.doc.fileURL?.standardizedFileURL == p.file else { return }
        pending = nil
        OpenSignpost.signposter.endInterval("click to text shown", p.state)
        onShownForChecks?(p.file)
    }
}
