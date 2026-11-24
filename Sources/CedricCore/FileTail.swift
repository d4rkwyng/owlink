import Foundation

/// File › Follow File: watches a file with a DispatchSource and reports
/// what was appended, or the whole new content after it was truncated,
/// replaced or rotated (deleted or renamed, then recreated).
public final class FileTail: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// New text at the end (line endings normalised to LF).
        case appended(String)
        /// The file was truncated or replaced: this is all of it now.
        case reset(String)
    }

    public let url: URL
    public let encoding: TextEncoding
    private let queue = DispatchQueue(label: "cedric.filetail")
    private let callbackQueue: DispatchQueue
    private let handler: @Sendable (Event, Shown) -> Void
    // Touched only on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private var offset: UInt64
    private var inode: UInt64 = 0
    private var pending = Data()
    private var stopped = false
    /// The last reset showed lossy text: appends after it aren't the
    /// file's bytes either, until the next faithful reset.
    private var lossy = false

    /// What the text shown after an event stands for.
    public struct Shown: Sendable, Equatable {
        /// The file's first `bytes` bytes, byte for byte. Bytes held back
        /// (half a character, a CR that may start a CRLF) are not counted,
        /// so a viewer that stamps its tab with this size can't later save
        /// over them as if it had shown them. Nil: the shown text isn't the
        /// file's bytes (a reset that couldn't decode, shown as UTF-8 with
        /// replacements, and the appends after it).
        public let bytes: UInt64?
        /// The stamp of the file these bytes were read from, taken from
        /// the descriptor they were read through, before reading, and
        /// sized to `bytes` (DiskStamp.showing). Not the path's stamp when
        /// the event reaches the viewer: a file put in its place since
        /// (same size, an atomic replace) has another identity and date,
        /// and stamping with those would let ⌘S write the old text over it.
        public let stamp: DiskStamp
    }

    /// `offset`: how many bytes of the file the caller already shows.
    public convenience init(url: URL, encoding: TextEncoding = .utf8, offset: UInt64, callbackQueue: DispatchQueue = .main,
                            handler: @escaping @Sendable (Event) -> Void) {
        self.init(url: url, encoding: encoding, offset: offset, callbackQueue: callbackQueue, stamped: { e, _ in handler(e) })
    }

    /// `update` gets each event with Shown.bytes.
    public convenience init(url: URL, encoding: TextEncoding = .utf8, offset: UInt64, callbackQueue: DispatchQueue = .main,
                            update: @escaping @Sendable (Event, _ shown: UInt64?) -> Void) {
        self.init(url: url, encoding: encoding, offset: offset, callbackQueue: callbackQueue, stamped: { e, s in update(e, s.bytes) })
    }

    /// `stamped` gets each event with what the text shown after it stands
    /// for: how many of the file's bytes, and the stamp they were read at.
    public init(url: URL, encoding: TextEncoding = .utf8, offset: UInt64, callbackQueue: DispatchQueue = .main,
                stamped: @escaping @Sendable (Event, Shown) -> Void) {
        self.url = url
        self.encoding = encoding
        self.offset = offset
        self.callbackQueue = callbackQueue
        self.handler = stamped
    }

    /// The whole file and its stamp, both from one descriptor: the stamp
    /// is taken (fstat) before the bytes are read, so a file changed or
    /// put in its place meanwhile never carries the stamp of bytes it
    /// doesn't hold (a later check sees a change instead). Follow File's
    /// first read, and every reset.
    public static func readStamped(_ url: URL) throws -> (Data, DiskStamp) {
        let (fh, st) = try openRegular(url)
        defer { try? fh.close() }
        return (try fh.readToEnd() ?? Data(), DiskStamp(st))
    }

    /// Opens `url` for reading (without waiting on a FIFO) and stats the
    /// descriptor: a regular file only.
    static func openRegular(_ url: URL) throws -> (FileHandle, stat) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError.error(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path,
                                                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]) }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            try? fh.close()
            throw CocoaError.error(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (fh, st)
    }

    deinit { source?.cancel(); retry?.cancel() }

    public func start() {
        queue.async { [self] in
            inode = Self.fileInfo(url)?.inode ?? 0
            watch()
            check()
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            source?.cancel(); source = nil
            retry?.cancel(); retry = nil
        }
    }

    /// Checks the file now (the watcher calls this; tests may too).
    public func poll() { queue.async { [self] in check() } }

    /// How many of this process's file descriptors are open on `url`'s
    /// file (by its real path), for the tests and checks that a stopped
    /// tail leaves none behind.
    public static func descriptorsOpen(on url: URL) -> Int {
        guard let real = realpath(url.path, nil) else { return 0 }
        let want = String(cString: real)
        free(real)
        // The open descriptors (not 0..<getdtablesize(), which can be huge).
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return 0 }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return 0 }
        var n = 0
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for info in fds.prefix(Int(got) / stride) where fcntl(info.proc_fd, F_GETPATH, &buf) == 0 {
            if String(cString: buf) == want { n += 1 }
        }
        return n
    }

    static func fileInfo(_ url: URL) -> (size: UInt64, inode: UInt64)? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(st.st_size), UInt64(st.st_ino))
    }

    /// A file descriptor or timer is live (false after `stop`, once the
    /// source's cancel handler has closed its descriptor).
    public var isWatching: Bool { queue.sync { source != nil || retry != nil } }

    private func watch() {
        source?.cancel(); source = nil
        guard !stopped else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { waitForFile(); return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
                                                          queue: queue)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            let ev = s.data
            if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                // Rotated: the old file is gone; follow the path.
                s.cancel()
                self.source = nil
                self.waitForFile()
            } else {
                self.check()
            }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    /// The path has no file (mid-rotation): look again every 250 ms.
    private func waitForFile() {
        guard !stopped, retry == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, Self.fileInfo(self.url) != nil else { return }
            self.retry?.cancel(); self.retry = nil
            self.watch()
            self.check()
        }
        retry = t
        t.resume()
    }

    private func check() {
        // One descriptor for all of it: its stat (taken before reading:
        // the stamp each event carries) and the bytes. Stat-ing the path
        // and then opening it could read a file put there in between as
        // an append to the one before.
        guard !stopped, let (fh, st) = try? Self.openRegular(url) else { return }
        defer { try? fh.close() }
        let size = UInt64(st.st_size), stamp = DiskStamp(st)
        if UInt64(st.st_ino) != inode || size < offset {
            // Replaced or truncated: start over.
            let replaced = UInt64(st.st_ino) != inode
            inode = UInt64(st.st_ino)
            if replaced || source == nil { watch() }
            guard let read = try? fh.readToEnd() else { return }
            let data = read ?? Data()
            // The same decode Follow starts with: a character cut in half
            // at the end (the writer still busy) waits for the next append.
            if let (d, used) = Self.decodeWhole(data, as: encoding) {
                offset = UInt64(used)
                pending = Data()
                emit(.reset(d.text), shown: offset, stamp)
            } else {
                offset = UInt64(data.count)
                pending = Data()
                emit(.reset(String(decoding: data, as: UTF8.self)), shown: nil, stamp)
            }
            return
        }
        guard size > offset else { return }
        do {
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: Int(size - offset)), !chunk.isEmpty else { return }
            offset += UInt64(chunk.count)
            let bytes = pending + chunk
            pending = Data()
            // Hold back a character cut in half at the end.
            var text: String?
            if let (s, used) = Self.decodePrefix(bytes, encoding, { String(data: $0, encoding: encoding.foundation) }) {
                text = s
                pending = bytes.suffix(bytes.count - used)
            }
            guard var s = text, !s.isEmpty else { return }
            // A CR at the very end may be the first half of a CRLF.
            if s.hasSuffix("\r"), let cr = "\r".data(using: encoding.foundation) {
                s.removeLast()
                pending = cr + pending
            }
            guard !s.isEmpty else { return }
            emit(.appended(TextCodec.normalizeLineEndings(s)), shown: lossy ? nil : offset - UInt64(pending.count), stamp)
        } catch {
            return
        }
    }

    /// Decodes the longest prefix of `bytes` that ends on a whole character:
    /// the text and how many bytes it used. UTF-16 never counts an odd
    /// byte (Foundation would decode it by dropping it, and the next
    /// append would start out of alignment).
    static func decodePrefix<T>(_ bytes: Data, _ encoding: TextEncoding, _ decode: (Data) -> T?) -> (T, Int)? {
        let utf16 = encoding == .utf16LE || encoding == .utf16BE
        let first = utf16 ? bytes.count % 2 : 0
        for cut in stride(from: first, through: min(first + 3, bytes.count), by: utf16 ? 2 : 1) {
            if let t = decode(bytes.prefix(bytes.count - cut)) { return (t, bytes.count - cut) }
        }
        return nil
    }

    /// The whole file as Follow first shows it (and shows it again after a
    /// reset): the decoded text and the byte count it covers, which is the
    /// offset to follow from. A character cut in half at the end is left
    /// for the first append. Nil: the file isn't text in `encoding`.
    public static func decodeWhole(_ data: Data, as encoding: TextEncoding) -> (DecodedText, Int)? {
        decodePrefix(data, encoding) { TextCodec.decode($0, as: encoding) }
    }

    private func emit(_ e: Event, shown: UInt64?, _ stamp: DiskStamp) {
        lossy = shown == nil
        let h = handler, s = Shown(bytes: shown, stamp: stamp.showing(shown))
        callbackQueue.async { h(e, s) }
    }
}
