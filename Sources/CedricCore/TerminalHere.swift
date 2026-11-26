import Foundation

/// File › Open in Terminal Here and the folder sidebar's Open in Terminal
/// Here: which folder Terminal opens at. The app hands that folder's URL
/// to NSWorkspace with Terminal's app URL (no shell command, no
/// AppleScript, so spaces and quotes in the path need no escaping).
public enum TerminalHere {
    public static let terminalBundleID = "com.apple.Terminal"

    /// A document's folder; nil for an untitled document (the command is off).
    public static func folder(forDocument url: URL?) -> URL? { FolderTree.enclosingFolder(of: url) }

    /// A sidebar row: a folder itself, a file's own folder.
    public static func folder(forItem url: URL, isDirectory: Bool) -> URL? {
        guard url.isFileURL, !url.path.isEmpty else { return nil }
        return isDirectory ? URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true) : FolderTree.enclosingFolder(of: url)
    }
}
