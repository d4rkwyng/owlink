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
    /// How many of the file's bytes have been read: those shown and the
    /// `heldCount` after them. A file shorter than this was truncated. Not the
    /// bytes shown: with a held CR counted out of it, `old\r` rewritten in
    /// place as `new` looked unchanged, and the LF that came next showed
    /// `old\n`, stamped as the file (Sol, 0.5.4 QA round 4).
    private var offset: UInt64
    /// The file being followed (device and inode): the start's, from the
    /// read Follow began with, then each reset's. Another file there is a
    /// rotation, even one that came before the watcher started.
    private var identity: DiskStamp.FileID?
    /// The most common line ending of the text shown (the start's, then
    /// each reset's): appended breaks of another kind are noted against it.
    private var dominant: LineEnding
    /// How many bytes at the end of `offset` were read but not shown (half
    /// a character, a CR that may start a CRLF). Only the count is kept:
    /// the next append rereads them from the file with the new bytes, so
    /// a writer that rewrote them meanwhile is shown as the file has them
    /// (0.5.4 QA leftovers 2: kept bytes decoded a rewritten `C2` → `C3 A9`
    /// as `©`, or a CR rewritten as `X\n` as a CRLF, stamped as the file),
    /// and no slice of a whole read is kept alive until the next append.
    private var heldCount: UInt64 = 0
    private var stopped = false
    /// The last reset showed lossy text: appends after it aren't the
    /// file's bytes either, until the next faithful reset.
    private var lossy = false
    /// Tests only: how many of the next reset reads fail (as a read error
    /// would), on this tail alone.
    private var failingResetReads = 0
    /// A truncation or replacement was seen and its reset read failed:
    /// the next check resets whatever the size is then. 0.5.4 before
    /// review 3 forgot it, so a file truncated and grown past the old
    /// offset again before the next check had its new bytes from there
    /// appended to the old text, stamped as current.
    private var resetPending = false

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
        /// A reset's line ending (its most common kind); nil for an append.
        public var lineEnding: LineEnding? = nil
        /// The breaks that aren't the shown text's most common kind
        /// (LineBreaks): a reset's whole text's (nil: one kind only); an
        /// append's, by offsets in the appended text (nil: none). Appended
        /// text comes with every break as LF, so without this a followed
        /// file's CRLF appended to an LF log, or a rotated file's own
        /// breaks, were saved as the wrong kind after Follow stopped.
        public var lineBreaks: LineBreaks? = nil
        /// A reset's encoding, as its own bytes decoded (decodeWhole):
        /// UTF-8 with a BOM or without, as the new file has it, never as
        /// the file before (a rotation). Nil for an append, and for a reset
        /// that couldn't decode (the text isn't the file's bytes).
        /// 0.5.4 before release review 5 dropped it, so a save after Follow stopped
        /// added the old file's BOM to a rotated file without one, or
        /// dropped the new file's.
        public var encoding: TextEncoding? = nil
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
    /// `startedFrom`: the stamp of the read the caller shows (its first
    /// `offset` bytes): a file put in its place before the tail starts
    /// watching is a reset, not an append to it. `lineEnding`: that text's
    /// most common line ending. `held`: how many bytes that read had past
    /// the `offset` it shows (what decodeWhole left out): they count as
    /// read, so the file cut below them is a reset, and are reread with the
    /// first append.
    public init(url: URL, encoding: TextEncoding = .utf8, offset: UInt64, held: UInt64 = 0,
                callbackQueue: DispatchQueue = .main, startedFrom: DiskStamp? = nil, lineEnding: LineEnding = .lf,
                stamped: @escaping @Sendable (Event, Shown) -> Void) {
        self.url = url
        self.encoding = encoding
        self.offset = offset + held
        self.heldCount = held
        self.identity = startedFrom?.identity
        self.dominant = lineEnding
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
            // Without the start's own identity, the file there now (as
            // before: a rotation before this point goes unseen).
            if identity == nil, let info = Self.fileInfo(url) {
                identity = DiskStamp.FileID(device: info.device, inode: info.inode)
            }
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

    /// Tests only: the next `count` reset reads fail.
    func failResetReads(_ count: Int) { queue.sync { failingResetReads = count } }

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

    static func fileInfo(_ url: URL) -> (size: UInt64, inode: UInt64, device: UInt64)? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(st.st_size), UInt64(st.st_ino), DiskStamp(st).identity?.device ?? 0)
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
        if resetPending || stamp.identity != identity || size < offset {
            // Replaced or truncated: start over.
            let replaced = stamp.identity != identity
            if replaced || source == nil { watch() }
            // Empty now (truncated to nothing, or rotated to a new empty
            // file) is a reset too: readToEnd says nil at the end, which
            // left the old text and offset in place.
            let data: Data
            do {
                if failingResetReads > 0 { failingResetReads -= 1; throw CocoaError(.fileReadUnknown) }
                data = try fh.readToEnd() ?? Data()
            } catch {
                // Still to do, however the file looks at the next check.
                resetPending = true
                return
            }
            resetPending = false
            // The new file is the one followed only once it is read: had
            // its identity been taken before a failed read, the next check
            // appended its bytes past the old offset to the old file's
            // text, stamped as the new file (Sol round 3).
            identity = stamp.identity
            // The same decode Follow starts with: a character cut in half
            // at the end (the writer still busy) waits for the next append.
            if let (d, used) = Self.decodeWhole(data, as: encoding) {
                // All of it read; what wasn't shown is held, as an append
                // holds it.
                offset = UInt64(data.count)
                heldCount = UInt64(data.count - used)
                dominant = d.lineEnding
                emit(.reset(d.text), shown: UInt64(used), stamp, lineEnding: d.lineEnding, breaks: d.mixedLineEndings ? d.lineBreaks : nil,
                     encoding: d.encoding)
            } else {
                offset = UInt64(data.count)
                heldCount = 0
                let raw = String(decoding: data, as: UTF8.self)
                let le = TextCodec.detectLineEnding(raw).0
                dominant = le
                emit(.reset(TextCodec.normalizeLineEndings(raw)), shown: nil, stamp, lineEnding: le, breaks: nil)
            }
            return
        }
        guard size > offset else { return }
        do {
            // From the end of the text shown: the held bytes are read again
            // with the new ones, through this descriptor, as they are now.
            let start = offset - heldCount
            try fh.seek(toOffset: start)
            // Shorter than what was read (cut since the fstat): the next
            // check resets.
            guard let bytes = try fh.read(upToCount: Int(size - start)), UInt64(bytes.count) > heldCount else { return }
            // A UTF-8 BOM written to a file of which nothing is shown yet
            // (followed empty, or a reset to nothing): that version's own
            // BOM, so the whole file is read as a reset, which decodes it
            // and carries its encoding, rather than appended as text
            // (U+FEFF on one macOS, dropped on another, and the tab kept
            // the encoding it had: a save lost the BOM).
            if start == 0, encoding.base == .utf8, bytes.starts(with: TextEncoding.utf8BOM.bom) {
                resetPending = true
                check()
                return
            }
            offset = start + UInt64(bytes.count)
            heldCount = 0
            // Hold back a character cut in half at the end (all of it while
            // no whole character has come yet).
            var text: String?
            if let (s, used) = Self.decodePrefix(bytes, encoding, { Self.decodeAppended($0, encoding) }) {
                text = s
                heldCount = UInt64(bytes.count - used)
            } else {
                // Bytes that aren't text in this encoding are skipped, so
                // the text no longer stands for the file's bytes: no size
                // from here on until a faithful reset (a later append
                // stamped the whole file and ⌘S dropped them silently).
                lossy = true
            }
            guard var s = text, !s.isEmpty else { return }
            // A CR at the very end may be the first half of a CRLF.
            if s.hasSuffix("\r"), let cr = "\r".data(using: encoding.foundation) {
                s.removeLast()
                heldCount += UInt64(cr.count)
            }
            guard !s.isEmpty else { return }
            var rec: TextCodec.BreakRecorder? = TextCodec.BreakRecorder(dominant: dominant, ascii: false)
            let appended = TextCodec.normalizeLineEndings(s, recording: &rec)
            let odd = rec.map { LineBreaks(dominant: dominant, others: $0.others) }
            emit(.appended(appended), shown: lossy ? nil : offset - heldCount, stamp,
                 lineEnding: nil, breaks: odd?.isMixed == true ? odd : nil)
        } catch {
            return
        }
    }

    /// Appended bytes as text, nil if they aren't text in `encoding`. They
    /// come after bytes already shown, so a U+FEFF at their start is text,
    /// never a BOM: UTF-8 is checked and decoded by the project's own
    /// strict decoder (TextCodec.isValidUTF8, then the standard library,
    /// which keeps U+FEFF), the same on every macOS. Foundation's UTF-8
    /// decoding drops a leading U+FEFF on macOS 26, and Follow stamped the
    /// bytes as shown all the same: a second BOM appended on its own was
    /// missing from the tab, and ⌘S wrote the file three bytes short.
    /// UTF-16 the same way (TextCodec.decodeUTF16: its byte order, every
    /// U+FEFF kept, a surrogate not in a pair refused), so it no longer
    /// depends on what Foundation does with a U+FEFF on a given macOS.
    /// The 8-bit encodings have no BOM and map every byte (or refuse it)
    /// the same way: Foundation.
    static func decodeAppended(_ bytes: Data, _ encoding: TextEncoding) -> String? {
        switch encoding.base {
        case .utf8, .utf8BOM:
            guard TextCodec.isValidUTF8(bytes) else { return nil }
            return bytes.withUnsafeBytes { String(decoding: $0.bindMemory(to: UInt8.self), as: UTF8.self) }
        case .utf16LE: return TextCodec.decodeUTF16(bytes, bigEndian: false)
        case .utf16BE: return TextCodec.decodeUTF16(bytes, bigEndian: true)
        case .latin1, .windows1252, .macRoman: return String(data: bytes, encoding: encoding.foundation)
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
    /// for the first append. So is a CR at the very end, as an append
    /// holds it: it may be the first half of a CRLF the writer hasn't
    /// finished, and taken as a break of its own it made that CRLF two
    /// breaks once the LF came (0.5.4 before review 3). Nil: the file
    /// isn't text in `encoding`. Read in its base (TextEncoding.base):
    /// whether there is a UTF-8 BOM is up to `data`, never to the file
    /// followed before.
    /// The CR is found in the bytes before decoding, so the text is
    /// decoded once (a second whole decode, while the first was still
    /// live, doubled the work and the peak memory of starting Follow).
    public static func decodeWhole(_ data: Data, as encoding: TextEncoding) -> (DecodedText, Int)? {
        let decode = { (d: Data) in TextCodec.decode(d, as: encoding.base) }
        if let end = heldCR(data, encoding), let (d, used) = decodePrefix(data.prefix(end), encoding, decode), used == end {
            return (d, used)
        }
        return decodePrefix(data, encoding, decode)
    }

    /// Where a CR that ends `data`'s whole characters starts (UTF-16: the
    /// CR may come before an odd byte, the first half of an LF). Nil: no
    /// such CR.
    static func heldCR(_ data: Data, _ encoding: TextEncoding) -> Int? {
        guard let cr = "\r".data(using: encoding.foundation), !cr.isEmpty else { return nil }
        let utf16 = encoding == .utf16LE || encoding == .utf16BE
        let end = data.count - (utf16 ? data.count % 2 : 0)
        guard end >= cr.count, data[data.startIndex + end - cr.count ..< data.startIndex + end].elementsEqual(cr) else { return nil }
        return end - cr.count
    }

    private func emit(_ e: Event, shown: UInt64?, _ stamp: DiskStamp, lineEnding: LineEnding?, breaks: LineBreaks?,
                      encoding: TextEncoding? = nil) {
        lossy = shown == nil
        let h = handler, s = Shown(bytes: shown, stamp: stamp.showing(shown), lineEnding: lineEnding, lineBreaks: breaks,
                                   encoding: encoding)
        callbackQueue.async { h(e, s) }
    }
}
