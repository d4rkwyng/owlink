import AppKit

/// Files and folders dropped on a window. A file opens in a tab and a
/// folder in the folder sidebar, both through `AppDelegate.open`, as when
/// they are dropped on the Dock icon.
@MainActor
enum FileDrop {
    /// The existing file and folder URLs a drag carries.
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func open(_ urls: [URL]) {
        for u in urls { (NSApp.delegate as? AppDelegate)?.open(u, background: true) }
    }
}

/// An editor window's content view: takes file and folder drops anywhere
/// the views inside don't (the gutter, the status bar, the bars), so a
/// folder dropped on the window opens in the folder sidebar. The text
/// view handles drops on the text itself (EditorTextView).
final class FileDropStackView: NSStackView {
    var onDropFiles: (([URL]) -> Void)?

    func acceptFileDrops() { registerForDraggedTypes([.fileURL]) }

    private func files(_ info: NSDraggingInfo) -> [URL] { onDropFiles == nil ? [] : FileDrop.urls(info) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { files(sender).isEmpty ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { files(sender).isEmpty ? [] : .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !files(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty, let onDropFiles else { return false }
        // After the drag session ends (a new tab inside it upsets AppKit's drag bookkeeping).
        DispatchQueue.main.async { onDropFiles(urls) }
        return true
    }
}
