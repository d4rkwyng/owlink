import Foundation
import Darwin

public enum FolderActions {
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
