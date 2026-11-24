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
    private let handler: @Sendable (Event) -> Void
    // Touched only on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private var offset: UInt64
    private var inode: UInt64 = 0
    private var pending = Data()
    private var stopped = false

    /// `offset`: how many bytes of the file the caller already shows.
    public init(url: URL, encoding: TextEncoding = .utf8, offset: UInt64, callbackQueue: DispatchQueue = .main,
                handler: @escaping @Sendable (Event) -> Void) {
        self.url = url
        self.encoding = encoding
        self.offset = offset
        self.callbackQueue = callbackQueue
        self.handler = handler
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
        guard !stopped, let st = Self.fileInfo(url) else { return }
        if st.inode != inode || st.size < offset {
            // Replaced or truncated: start over.
            let replaced = st.inode != inode
            inode = st.inode
            if replaced || source == nil { watch() }
            guard let data = try? Data(contentsOf: url) else { return }
            // The same decode Follow starts with: a character cut in half
            // at the end (the writer still busy) waits for the next append.
            if let (d, used) = Self.decodeWhole(data, as: encoding) {
                offset = UInt64(used)
                pending = Data()
                emit(.reset(d.text))
            } else {
                offset = UInt64(data.count)
                pending = Data()
                emit(.reset(String(decoding: data, as: UTF8.self)))
            }
            return
        }
        guard st.size > offset, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.read(upToCount: Int(st.size - offset)), !chunk.isEmpty else { return }
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
            emit(.appended(TextCodec.normalizeLineEndings(s)))
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

    private func emit(_ e: Event) {
        let h = handler
        callbackQueue.async { h(e) }
    }
}
