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
        // One name by its bytes (Beneath.isName): a slash before a combining mark is still a separator.
        guard Beneath.isName(name) else {
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
    /// it: for callers holding paths (the tests). `root` is opened and the
    /// file made beneath it as `FolderRoot.createFile` does; `folder`'s
    /// place in `root` only names the components (the kernel keeps the
    /// lookup inside `root`, so a parent that leads out is refused).
    public static func createFile(named name: String, in folder: URL, within root: URL,
                                  walk: Bool = !Beneath.kernelEnforced) throws -> URL {
        _ = try destination(in: folder, name: name)
        let pinned = try FolderRoot(root)
        guard let rel = FolderTree.relativePath(of: folder, in: root)
                ?? FolderTree.relativePath(of: folder.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath()) else {
            throw FolderRoot.outsideError(folder.appendingPathComponent(name), folder: folder.lastPathComponent)
        }
        return try pinned.createFile(FolderTree.components(rel) + [name], walk: walk)
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

/// The folder open in the sidebar, pinned by a descriptor when it is
/// opened (Astra review, 0.6). A note made from a wiki link is created
/// from this descriptor, never from the folder's saved path looked up
/// again: if the folder was moved or replaced at its path, the note goes
/// in the folder that was opened, and the caller is told rather than
/// shown a different file. The descriptor is `O_EVTONLY`, so it doesn't
/// keep the folder's volume from being ejected.
public final class FolderRoot: @unchecked Sendable {
    /// The path the folder was opened at (what the sidebar shows).
    public let url: URL
    private let fd: Int32

    public init(_ url: URL) throws {
        let fd = open(url.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
        self.url = url
        self.fd = fd
    }

    deinit { close(fd) }

    /// Makes the empty file `components` (each one name; the last is the
    /// file) beneath this folder: looked up beneath the descriptor
    /// (`Beneath.open`: a folder that leads out is refused), created with
    /// `O_CREAT | O_EXCL | O_NOFOLLOW` (an existing file or link of that
    /// name is never replaced or followed). Where the kernel can't keep a
    /// lookup inside (`walk`, the default there; tests force it), only a
    /// single name directly in this folder is made: a parent opened on the
    /// way could be moved before the file is created in it, so a note in a
    /// subfolder is refused before anything is made (Astra batch 3,
    /// must-fix 2). Returns the file's URL under `url` once that path is
    /// checked to be the file made (device and inode); throws if it isn't
    /// (the folder was moved or replaced), so the caller opens nothing.
    public func createFile(_ components: [String], walk: Bool = !Beneath.kernelEnforced) throws -> URL {
        let target = components.reduce(url) { $0.appendingPathComponent($1) }
        if walk, components.count > 1, components.allSatisfy(Beneath.isName) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
                NSFilePathErrorKey: target.path,
                NSLocalizedDescriptionKey: String(localized: "This version of macOS can’t make a note in a subfolder safely, so “\(components.joined(separator: "/"))” wasn’t created. A note can be made directly in the open folder “\(url.lastPathComponent)”."),
            ])
        }
        let made = Beneath.open(components, beneath: fd, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o666, walk: walk)
        guard made >= 0 else {
            let err = errno
            // ENOTCAPABLE (Beneath.notCapable): the lookup left the folder.
            if err == Beneath.notCapable || err == ELOOP {
                throw Self.outsideError(target, folder: target.deletingLastPathComponent().lastPathComponent)
            }
            if err == EINVAL {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "Enter a single file or folder name.")])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSFilePathErrorKey: target.path])
        }
        let id = Beneath.FileID(fd: made)
        close(made)
        guard let id, Beneath.FileID(path: target.path, followLast: false) == id else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSFilePathErrorKey: target.path,
                NSLocalizedDescriptionKey: String(localized: "The open folder “\(url.lastPathComponent)” was moved or replaced, so the new note wasn’t opened."),
            ])
        }
        return target
    }

    static func outsideError(_ target: URL, folder: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSFilePathErrorKey: target.path,
            NSLocalizedDescriptionKey: String(localized: "The folder “\(folder)” leads outside the open folder, so the note wasn’t created."),
        ])
    }
}
