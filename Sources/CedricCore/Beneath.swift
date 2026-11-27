import Foundation
import Darwin

/// Paths looked up beneath a folder's descriptor, with the kernel keeping
/// the lookup inside it (Astra review, 0.6). Where the kernel enforces
/// `O_RESOLVE_BENEATH` (macOS 15 and later) the relative path is opened in
/// one call: a symbolic link that stays inside is followed, one that leads
/// out (absolute, or `..` past the folder) fails. Elsewhere the path is
/// walked one component at a time with `O_NOFOLLOW | O_DIRECTORY`, so a
/// symbolic link to a folder is refused (fails closed). The last
/// component is never followed. No path strings are compared.
public enum Beneath {
    /// `O_RESOLVE_BENEATH` from sys/fcntl.h, written as its value: older
    /// SDKs (Swift 6.1's) may not name it.
    static let resolveBeneath: Int32 = 0x0000_1000

    /// `ENOTCAPABLE` from sys/errno.h (Darwin 107), written as its value:
    /// the macOS 15 SDK (Swift 6.1's) doesn't name it. What a lookup or
    /// rename the kernel keeps beneath a folder fails with when it would
    /// leave it.
    public static let notCapable: Int32 = 107

    /// Whether this kernel enforces `O_RESOLVE_BENEATH`: `..` beneath
    /// /usr must be refused while `bin` opens. A kernel that ignored the
    /// flag would open `..`, and the component walk is used instead.
    public static let kernelEnforced: Bool = {
        let usr = Darwin.open("/usr", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard usr >= 0 else { return false }
        defer { close(usr) }
        let up = openat(usr, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC | resolveBeneath)
        if up >= 0 { close(up); return false }
        let bin = openat(usr, "bin", O_RDONLY | O_DIRECTORY | O_CLOEXEC | resolveBeneath)
        guard bin >= 0 else { return false }
        close(bin)
        return true
    }()

    /// A file's identity: device and inode.
    public struct FileID: Equatable, Sendable {
        public let dev: dev_t
        public let ino: ino_t
        init(_ st: stat) { dev = st.st_dev; ino = st.st_ino }

        /// What `fd` has open.
        public init?(fd: Int32) {
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            self.init(st)
        }

        /// What `name` in the folder `dir` is (a symbolic link itself, not followed).
        public init?(at dir: Int32, _ name: String) {
            var st = stat()
            guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            self.init(st)
        }

        /// What `path` leads to now (`followLast`: a final symbolic link is followed).
        public init?(path: String, followLast: Bool) {
            var st = stat()
            guard (followLast ? stat(path, &st) : lstat(path, &st)) == 0 else { return nil }
            self.init(st)
        }
    }

    /// One file or folder name: not empty, not `.` or `..`, no `/` or NUL.
    /// Checked as the UTF-8 bytes the kernel gets, not as Swift text: a
    /// slash followed by a combining mark is one Swift character, so a text
    /// search misses it, but Darwin still splits the name at that byte
    /// (Astra batch 4 A, batch 5 must-fix 1).
    public static func isName(_ s: String) -> Bool {
        let b = s.utf8
        return !b.isEmpty && !b.elementsEqual(".".utf8) && !b.elementsEqual("..".utf8)
            && !b.contains(0x2f) && !b.contains(0)
    }

    /// Opens `components` beneath the folder `root` has open, with `flags`
    /// (plus `O_NOFOLLOW | O_CLOEXEC`) and `mode` for the last one.
    /// Returns the descriptor, or -1 with `errno` set (`EINVAL` for an
    /// empty list or a component that isn't one name). `walk` forces the
    /// component walk (tests; it is the default where the kernel doesn't
    /// enforce beneath lookups). `followLast`: a final symbolic link is
    /// followed too, only where the kernel keeps that inside the folder;
    /// the component walk still refuses it.
    public static func open(_ components: [String], beneath root: Int32, flags: Int32, mode: mode_t = 0o666,
                            followLast: Bool = false, walk: Bool = !kernelEnforced) -> Int32 {
        guard let last = components.last, components.allSatisfy(isName) else { errno = EINVAL; return -1 }
        let lastFlags = flags | O_NOFOLLOW | O_CLOEXEC
        if !walk {
            let beneathFlags = (followLast ? lastFlags & ~O_NOFOLLOW : lastFlags) | resolveBeneath
            return openat(root, components.joined(separator: "/"), beneathFlags, mode)
        }
        var dir = root
        for c in components.dropLast() {
            let next = openat(dir, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let err = errno
            if dir != root { close(dir) }
            guard next >= 0 else { errno = err; return -1 }
            dir = next
        }
        let fd = openat(dir, last, lastFlags, mode)
        let err = errno
        if dir != root { close(dir) }
        errno = err
        return fd
    }
}
