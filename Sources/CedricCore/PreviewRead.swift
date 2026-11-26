import Foundation
import Darwin

/// Reading a file the preview's `cedric-doc:` handler approved (Astra
/// review, 0.6 batch 4). The approval (`PreviewFolder.approved`) works on
/// paths; between it and the read a folder or file can be swapped for a
/// symbolic link or another file. So the read never reopens the path: it
/// opens the approved root, looks the file up beneath that descriptor
/// with the kernel keeping the lookup inside (`Beneath`), checks what it
/// opened (a regular file; with page script on, an image, font or CSS
/// file outside any dot folder, judged on the opened file's real path)
/// and reads that same descriptor. Anything it can't establish fails
/// closed (nil).
public enum PreviewRead {
    /// The largest file served (a page asset, not a disk image).
    public static let maxBytes = 512 << 20

    /// `file`'s parts below `root`, by the paths as given or else as
    /// resolved; nil when it isn't below `root` either way.
    static func components(of file: URL, below root: URL) -> [String]? {
        func rel(_ f: String, _ r: String) -> [String]? {
            let base = r.hasSuffix("/") ? r : r + "/"
            guard f.hasPrefix(base) else { return nil }
            let parts = f.dropFirst(base.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return parts.isEmpty || !parts.allSatisfy(Beneath.isName) ? nil : parts
        }
        return rel(file.standardizedFileURL.path, root.standardizedFileURL.path)
            ?? rel(PreviewFolder.resolved(file.standardizedFileURL).path, PreviewFolder.resolved(root.standardizedFileURL).path)
    }

    /// The path the kernel has for what `fd` has open.
    static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Whether `parts` (below a root) is one a page with script on may
    /// load: no dot file or dot folder, and an image, font or CSS name.
    static func scriptSafe(_ parts: [String]) -> Bool {
        guard let last = parts.last, !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        return PreviewFolder.scriptSafeExtensions.contains((last as NSString).pathExtension.lowercased())
    }

    /// `file`'s bytes, read beneath `root` as described above, or nil.
    /// `walk` forces the component walk (tests), as in `Beneath.open`.
    public static func data(_ file: URL, beneath root: URL, scriptOn: Bool, walk: Bool = !Beneath.kernelEnforced) -> Data? {
        guard let parts = components(of: file, below: root), !scriptOn || scriptSafe(parts) else { return nil }
        let rootFD = Darwin.open(root.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        defer { close(rootFD) }
        // Non-blocking, so a FIFO swapped in can't hang the open.
        let fd = Beneath.open(parts, beneath: rootFD, flags: O_RDONLY | O_NONBLOCK, followLast: true, walk: walk)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxBytes else { return nil }
        if scriptOn {
            // What was opened, by its real path: below the root's, and
            // still an image, font or CSS file outside dot folders.
            guard let r = path(of: rootFD), let f = path(of: fd) else { return nil }
            let base = r.hasSuffix("/") ? r : r + "/"
            guard f.hasPrefix(base), scriptSafe(f.dropFirst(base.count).split(separator: "/").map(String.init)) else { return nil }
        }
        _ = fcntl(fd, F_SETFL, 0)
        var out = Data()
        out.reserveCapacity(Int(st.st_size))
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            out.append(buf, count: n)
            if out.count > maxBytes { return nil }
        }
        return out
    }
}
