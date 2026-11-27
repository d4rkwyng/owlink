import Foundation

/// The temp files the `cedric` script hands to the app through cedric://
/// URLs: `untitled=` (stdin, read into a new tab, then deleted) and
/// `wait=` (the -w marker, deleted when the tab closes). Any app or web
/// page can send such a URL, so a path is accepted only if it is exactly
/// what the script makes, `mktemp "$TMPDIR/cedric-stdin.XXXXXX"`:
///
/// - its folder, opened once, is the user's own temp folder
///   (NSTemporaryDirectory) by device and inode, and the file is opened
///   relative to that folder's descriptor;
/// - its name is the prefix and mktemp's random letters and digits only;
/// - it is a regular file (lstat: not a symlink), with one link (not a
///   hard link to a file elsewhere), owned by this user.
///
/// Anything else is refused: not read, never deleted.
public enum CLIHandoff {
    public enum Kind: Sendable {
        /// `cedric -`: stdin. `cedric -w`: the marker. `auth`: the token,
        /// handed over in a 0600 file (not on `open`'s command line, which
        /// other users can read with ps).
        case stdin, wait, auth
        public var prefix: String {
            switch self {
            case .stdin: return "cedric-stdin."
            case .wait: return "cedric-wait."
            case .auth: return "cedric-auth."
            }
        }
    }

    /// A file that passed: where it is, which inode it was, and (for
    /// stdin) what it held, read from the checked descriptor.
    public struct Handoff: Sendable, Equatable {
        public let url: URL
        public let device: UInt64
        public let inode: UInt64
        public let data: Data?
    }

    /// The checked hand-off for `path`, or nil (refused). The file is
    /// opened with O_NOFOLLOW and checked on the descriptor (fstat), so
    /// what is read is what was checked.
    public static func inspect(_ path: String, kind: Kind, tempDirs: [String] = [NSTemporaryDirectory()],
                               uid: uid_t = getuid(), read: Bool = false, maxBytes: Int = 64 << 20) -> Handoff? {
        // Absolute by its first byte; split at the last "/" byte (a text
        // test takes a slash before a combining mark for part of a name).
        let bytes = Array(path.utf8)
        guard bytes.first == 0x2f, !bytes.contains(0), let slash = bytes.lastIndex(of: 0x2f) else { return nil }
        let nameBytes = bytes[(slash + 1)...], prefix = Array(kind.prefix.utf8)
        guard nameBytes.starts(with: prefix) else { return nil }
        let random = nameBytes.dropFirst(prefix.count)
        // mktemp's letters and digits: ASCII bytes only.
        guard random.count >= 6, random.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) })
        else { return nil }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard Beneath.isName(name) else { return nil }
        let parentBytes = slash == 0 ? [UInt8(0x2f)] : Array(bytes[..<slash])
        // The folder holding it, opened once; it must be one of `tempDirs`
        // by device and inode (the same folder, however either path is
        // spelled), never by comparing the paths' text.
        let dfd = (parentBytes + [0]).withUnsafeBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        }
        guard dfd >= 0 else { return nil }
        defer { close(dfd) }
        guard let dirID = Beneath.FileID(fd: dfd),
              let allowed = tempDirs.first(where: { Beneath.FileID(path: $0, followLast: true) == dirID }),
              let dir = realpath(allowed) else { return nil }
        // The checked name, relative to that very folder.
        let fd = openat(dfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == uid else { return nil }
        var data: Data?
        if read {
            guard st.st_size <= maxBytes else { return nil }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            data = (try? h.readToEnd()) ?? Data()
        }
        // Named under the allowed folder's resolved path; `remove` deletes
        // it only while that name is still this inode.
        let file = (dir == "/" ? "" : dir) + "/" + name
        return Handoff(url: URL(fileURLWithPath: file), device: UInt64(st.st_dev), inode: UInt64(st.st_ino), data: data)
    }

    /// The canonical file URL for `path`, or nil (refused).
    public static func accept(_ path: String, kind: Kind, tempDirs: [String] = [NSTemporaryDirectory()],
                              uid: uid_t = getuid()) -> URL? {
        inspect(path, kind: kind, tempDirs: tempDirs, uid: uid)?.url
    }

    /// Deletes the hand-off file only if it is still the same inode (not
    /// swapped for a link or another file since it was checked). True if deleted.
    @discardableResult
    public static func remove(_ h: Handoff, uid: uid_t = getuid()) -> Bool {
        var st = stat()
        guard lstat(h.url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == uid,
              UInt64(st.st_dev) == h.device, UInt64(st.st_ino) == h.inode else { return false }
        return unlink(h.url.path) == 0
    }

    /// The token in the script's `auth=` hand-off file, which is then
    /// deleted (used once). Nil when the file isn't the script's (same
    /// checks as stdin: the user's temp folder, regular, one link, owned),
    /// or it is readable by others.
    public static func takeAuth(_ path: String, tempDirs: [String] = [NSTemporaryDirectory()], uid: uid_t = getuid()) -> String? {
        guard let h = inspect(path, kind: .auth, tempDirs: tempDirs, uid: uid, read: true, maxBytes: 256), let data = h.data else { return nil }
        var st = stat()
        let privateFile = lstat(h.url.path, &st) == 0 && st.st_mode & 0o077 == 0
        remove(h, uid: uid)
        guard privateFile else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `cedric-auth.*` files older than `age` seconds left in the
    /// temp folder by a URL that never reached the app.
    public static func sweepAuth(tempDir: String = NSTemporaryDirectory(), age: TimeInterval = 60, now: Date = Date()) {
        guard let dir = realpath(tempDir), let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for item in items where item.hasPrefix(Kind.auth.prefix) {
            let path = dir + "/" + item
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
                  now.timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) > age else { continue }
            unlink(path)
        }
    }

    /// The path with `..` and every symlink resolved; nil if it doesn't exist.
    public static func realpath(_ path: String) -> String? {
        guard let r = Darwin.realpath(path, nil) else { return nil }
        defer { free(r) }
        let s = String(cString: r)
        return s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}

/// The shared secret that marks a cedric:// URL as coming from the
/// `cedric` script: a random token in a file only this user can read
/// (~/Library/Application Support/Cedric/cli-token, 0600). The script
/// adds `token=` to every URL; a web page or another user can't know it.
/// Whoever runs first (the script or the app) creates it.
public enum CLIToken {
    /// In-process override for the checks (set by DevChecks code, never
    /// from outside the process).
    nonisolated(unsafe) public static var overrideURL: URL?

    public static var defaultURL: URL {
        if let overrideURL { return overrideURL }
        #if DEBUG
        // Debug builds only; a release build ignores it.
        if let p = DevEnvironment.values["CEDRIC_CLI_TOKEN_FILE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Cedric/cli-token")
    }

    /// A new token in place of the old one, at every launch, so one seen
    /// once is not good for ever. Written to a private temp file and
    /// renamed over the old one (atomic: a reader sees the old token or
    /// the new one, never half). Nil if it couldn't be written.
    @discardableResult
    public static func rotate(at url: URL = defaultURL) -> String? {
        let dir = url.deletingLastPathComponent()
        guard (try? PrivateDirectory.make(dir)) != nil else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        guard (try? PrivateDirectory.writePrivateFile(Data((token + "\n").utf8), to: url)) != nil else { return nil }
        return read(url) == token ? token : nil
    }

    /// After a rotation, the token before it still counts this long: a
    /// `cedric` run that started the app may have read it just before.
    public static let rotationGrace: TimeInterval = 30

    /// An empty token file older than this was left by a run that died
    /// between making and filling it: it is replaced.
    public static let staleEmptyAge: TimeInterval = 5

    /// The token, created if missing; nil if it can't be read or made, or
    /// if the file isn't this user's own private regular file. Written to
    /// a private temp file and hard-linked into place (as the `cedric`
    /// script does), so nobody reads a half-written token and a token
    /// already there is never replaced, except a stale empty one.
    public static func ensure(at url: URL = defaultURL) -> String? {
        if let t = read(url) { return t }
        let dir = url.deletingLastPathComponent()
        try? PrivateDirectory.make(dir)
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        var template = Array((dir.path + "/.cli-token.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return read(url) }
        let tmp = String(cString: template)
        defer { unlink(tmp) }
        let line = token + "\n"
        let wrote = line.withCString { write(fd, $0, strlen($0)) } == line.utf8.count
        close(fd)
        guard wrote else { return read(url) }
        // link() never replaces: a stale empty file goes first, only if it
        // is still empty and still the same file.
        if let stale = staleEmpty(url) {
            var st = stat()
            if lstat(url.path, &st) == 0, st.st_size == 0, st.st_ino == stale.ino, st.st_dev == stale.dev { unlink(url.path) }
        }
        _ = link(tmp, url.path)
        return read(url)
    }

    /// `url` is this user's empty regular file, last changed more than
    /// `staleEmptyAge` ago.
    static func staleEmpty(_ url: URL) -> (ino: ino_t, dev: dev_t)? {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_size == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        guard Date().timeIntervalSince1970 - mtime > staleEmptyAge else { return nil }
        return (st.st_ino, st.st_dev)
    }

    public static func read(_ url: URL) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return nil }
        let data = (try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()) ?? Data()
        let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 32 ? t : nil
    }

    /// Constant-time comparison of a URL's token with the secret.
    public static func matches(_ given: String?, _ secret: String?) -> Bool {
        guard let g = given.map({ Array($0.utf8) }), let s = secret.map({ Array($0.utf8) }), !s.isEmpty, g.count == s.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(g, s) { diff |= a ^ b }
        return diff == 0
    }

    /// `text` with any token= value and the secret itself blanked, for
    /// anything logged or shown.
    public static func redacted(_ text: String, secret: String? = nil) -> String {
        var t = text
        if let secret, !secret.isEmpty { t = t.replacingOccurrences(of: secret, with: "•••") }
        return t.replacingOccurrences(of: #"(?i)(token(=|%3D))[^&\s)]*"#, with: "$1•••", options: .regularExpression)
    }

    /// The line logged when a cedric:// URL is refused (never with the token).
    public static func refusal(_ why: String, secret: String? = nil) -> String {
        "cedric://: refused (" + redacted(why, secret: secret) + ")"
    }
}
