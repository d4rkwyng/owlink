import Foundation
import Darwin

public enum FolderActions {
    /// Finder-style: the last extension is left out for a file, the whole
    /// name is selected for a folder or a leading-dot name with no other "extension".
    public static func renameSelection(name: String, isDirectory: Bool) -> NSRange {
        let value = name as NSString
        guard !isDirectory, !value.pathExtension.isEmpty else {
            return NSRange(location: 0, length: value.length)
        }
        let base = value.deletingPathExtension as NSString
        return NSRange(location: 0, length: base.length == 0 ? value.length : base.length)
    }

    public static func destination(in parent: URL, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Enter a single file or folder name.")])
        }
        return parent.appendingPathComponent(name)
    }

    public static func create(in parent: URL, name: String, directory: Bool) throws -> URL {
        let url = try destination(in: parent, name: name)
        if directory {
            guard mkdir(url.path, 0o777) == 0 else { throw error(url) }
        } else {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            guard fd >= 0 else { throw error(url) }
            guard close(fd) == 0 else { throw error(url) }
        }
        return url
    }

    /// A new empty file `name` in `folder`, which must be `root` or inside
    /// it once symbolic links are resolved. The folder is opened first and
    /// judged from the opened descriptor (`F_GETPATH`, against `root`
    /// opened the same way); the file is then made relative to that
    /// descriptor with `O_EXCL | O_NOFOLLOW`, so a link swapped in after
    /// the check can't move it and an existing file is never replaced.
    public static func createFile(named name: String, in folder: URL, within root: URL) throws -> URL {
        let url = try destination(in: folder, name: name)
        let rfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rfd >= 0 else { throw error(root) }
        defer { close(rfd) }
        let dfd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { throw error(folder) }
        defer { close(dfd) }
        guard let r = realPath(rfd), let d = realPath(dfd), d == r || d.hasPrefix(r.hasSuffix("/") ? r : r + "/") else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: String(localized: "The folder “\(folder.lastPathComponent)” leads outside the open folder, so the note wasn’t created."),
            ])
        }
        let fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw error(url) }
        guard close(fd) == 0 else { throw error(url) }
        return url
    }

    /// The folder a descriptor has open (symbolic links resolved).
    static func realPath(_ fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    public static func rename(_ source: URL, name: String) throws -> URL {
        let destination = try destination(in: source.deletingLastPathComponent(), name: name)
        if source.lastPathComponent == name { return source }
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw error(destination) }
        return destination
    }

    public static func movedURL(_ url: URL, from source: URL, to destination: URL, directory: Bool) -> URL? {
        guard let relative = FolderTree.relativePath(of: url, in: source),
              directory || relative.isEmpty else { return nil }
        return relative.isEmpty ? destination : destination.appendingPathComponent(relative)
    }

    private static func error(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
