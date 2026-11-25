import Foundation

/// The encodings Cedric reads and writes.
public enum TextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case latin1
    case windows1252
    case macRoman

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return String(localized: "UTF-8 with BOM")
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return String(localized: "Latin-1 (ISO 8859-1)")
        case .windows1252: return String(localized: "Windows-1252 (Western)")
        case .macRoman: return String(localized: "Mac Roman")
        }
    }

    /// The name without its long form ("Latin-1"), for "Latin-1 (guessed)".
    public var shortName: String {
        switch self {
        case .latin1: return "Latin-1"
        case .windows1252: return "Windows-1252"
        default: return displayName
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        case .utf8, .latin1, .windows1252, .macRoman: return []
        }
    }

    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .latin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        case .macRoman: return .macOSRoman
        }
    }
}

public enum LineEnding: String, CaseIterable, Codable, Sendable {
    case lf, crlf, cr

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    public var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// A file's text as Cedric edits it: decoded, with line endings
/// normalised to "\n", plus what to write back.
public struct DecodedText: Sendable {
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// The file mixed line endings (`lineEnding` is the most common).
    public var mixedLineEndings: Bool
    /// The bytes look like a binary file (`TextCodec.looksBinary`).
    public var looksBinary = false
    /// Not valid UTF-8, no BOM and not UTF-16: `encoding` is a guess at
    /// an 8-bit one (`guessEightBit`). Never when an encoding was asked for.
    public var encodingGuessed = false
    /// Mixed line endings only: the breaks that aren't `lineEnding`, so a
    /// save writes each back as it was (LineBreaks). Made in the same pass
    /// that turns CR and CRLF into LF, not a pass of its own.
    public var lineBreaks: LineBreaks?
}

public enum TextCodec {
    /// Detects the encoding: a BOM, else valid UTF-8, else UTF-16 by its
    /// pattern of zero bytes, else one of the 8-bit Western encodings
    /// (`guessEightBit`).
    public static func detectEncoding(_ data: Data) -> TextEncoding {
        if let bomOrUTF16 = detectBOMOrUTF16(data) { return bomOrUTF16 }
        if isValidUTF8(data) { return .utf8 }
        return guessEightBit(data)
    }

    /// The encoding a BOM names, else UTF-16 without one (`guessUTF16`).
    static func detectBOMOrUTF16(_ data: Data) -> TextEncoding? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        return guessUTF16(data)
    }

    /// How much of a file `looksBinary` reads.
    public static let binarySample = 8_192

    /// Whether `data` looks like a binary file rather than text: in its
    /// first 8 KB, a NUL byte, or more than 10% control characters (other
    /// than tab, line breaks, form feed, backspace and escape, which logs
    /// and terminal output use). Text Cedric reads is never binary: a
    /// UTF-8 or UTF-16 byte-order mark, or UTF-16 without one (its zero
    /// bytes fall in one parity, `guessUTF16`).
    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(binarySample)
        guard !sample.isEmpty else { return false }
        let head = [UInt8](sample.prefix(3))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
        if guessUTF16(sample) != nil { return false }
        var controls = 0
        for b in sample {
            if b == 0 { return true }
            if (b < 0x20 && b != 9 && b != 10 && b != 13 && b != 12 && b != 8 && b != 0x1B) || b == 0x7F { controls += 1 }
        }
        return controls * 10 > sample.count
    }

    /// Not UTF-8: Windows-1252, Mac Roman or Latin-1, from the bytes over
    /// 0x7F in the first 64 KB. Each candidate is scored on what those
    /// bytes decode to: lowercase letters and common punctuation (curly
    /// quotes, dashes, …, €) count for it; control characters, symbols
    /// (√, ◊, ‡) and a capital letter straight after a lowercase one
    /// ("donÕt", "cafÈ") count against. Ties go to Windows-1252, which
    /// reads like Latin-1 for 0xA0–0xFF; Latin-1 is kept when no byte is
    /// in 0x80–0x9F (where the two differ), as before.
    static func guessEightBit(_ data: Data) -> TextEncoding {
        var win = 0, mac = 0
        var c1 = false
        var prev: UInt8 = 0
        for b in data.prefix(65536) {
            if b >= 0x80 {
                if b < 0xA0 { c1 = true }
                let lowerBefore = prev >= 0x61 && prev <= 0x7A
                win += EightBit.score(EightBit.windows[Int(b) - 0x80], lowerBefore: lowerBefore)
                mac += EightBit.score(EightBit.mac[Int(b) - 0x80], lowerBefore: lowerBefore)
            }
            prev = b
        }
        if mac > win { return .macRoman }
        return c1 ? .windows1252 : .latin1
    }

    /// Mostly-ASCII UTF-16 without a BOM: zero bytes in one parity.
    static func guessUTF16(_ data: Data) -> TextEncoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (k, byte) in sample.enumerated() where byte == 0 {
            if k % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros * 10 > half * 6, evenZeros * 10 < half { return .utf16LE }
        if evenZeros * 10 > half * 6, oddZeros * 10 < half { return .utf16BE }
        return nil
    }

    static func isValidUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { scanUTF8($0).valid }
    }

    /// What one pass over UTF-8 bytes found (`scanUTF8`).
    struct UTF8Scan: Equatable {
        /// Valid UTF-8 (overlongs, surrogates, past U+10FFFF and truncated
        /// sequences are not). The counts stop at the first invalid byte.
        var valid = true
        /// No byte over 0x7F.
        var ascii = true
        /// Line breaks: "\n" alone, "\r\n", "\r" alone.
        var lf = 0, crlf = 0, cr = 0
    }

    /// One pass over `bytes`: UTF-8 validity, whether they are all ASCII,
    /// and the line endings. Eight bytes at a time while they are ASCII
    /// with no CR (the usual log or source file); byte by byte through
    /// anything else.
    static func scanUTF8(_ bytes: UnsafeRawBufferPointer) -> UTF8Scan {
        var s = UTF8Scan()
        guard let base = bytes.baseAddress else { return s }
        let n = bytes.count
        let b = base.assumingMemoryBound(to: UInt8.self)
        let high: UInt64 = 0x8080_8080_8080_8080, low7: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        let lfs: UInt64 = 0x0A0A_0A0A_0A0A_0A0A, crs: UInt64 = 0x0D0D_0D0D_0D0D_0D0D
        /// Bit 7 of each byte of `w` that is zero (exact: no carries between bytes).
        @inline(__always) func zeroBytes(_ w: UInt64) -> UInt64 { ~(((w & low7) &+ low7) | w) & high }
        var i = 0
        while i < n {
            if i + 8 <= n {
                let w = base.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                if w & high == 0, zeroBytes(w ^ crs) == 0 {
                    s.lf += zeroBytes(w ^ lfs).nonzeroBitCount
                    i += 8
                    continue
                }
            }
            let c = b[i]
            if c < 0x80 {
                if c == 13 {
                    if i + 1 < n, b[i + 1] == 10 { s.crlf += 1; i += 2; continue }
                    s.cr += 1
                } else if c == 10 {
                    s.lf += 1
                }
                i += 1
                continue
            }
            s.ascii = false
            let len: Int
            if c & 0xE0 == 0xC0 { len = 2; if c < 0xC2 { s.valid = false; return s } }
            else if c & 0xF0 == 0xE0 { len = 3 }
            else if c & 0xF8 == 0xF0 { len = 4; if c > 0xF4 { s.valid = false; return s } }
            else { s.valid = false; return s }
            if i + len > n { s.valid = false; return s }
            for k in 1..<len where b[i + k] & 0xC0 != 0x80 { s.valid = false; return s }
            let c1 = b[i + 1]
            if len == 3 {
                if c == 0xE0 && c1 < 0xA0 { s.valid = false; return s }    // overlong
                if c == 0xED && c1 >= 0xA0 { s.valid = false; return s }   // surrogates
            } else if len == 4 {
                if c == 0xF0 && c1 < 0x90 { s.valid = false; return s }
                if c == 0xF4 && c1 >= 0x90 { s.valid = false; return s }
            }
            i += len
        }
        return s
    }

    /// The most common line ending, and whether more than one kind occurs.
    static func lineEnding(lf: Int, crlf: Int, cr: Int) -> (LineEnding, mixed: Bool) {
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let ending: LineEnding = crlf > lf && crlf >= cr ? .crlf : cr > lf && cr > crlf ? .cr : .lf
        return (ending, kinds > 1)
    }

    /// With `shareBytes`, text at least this long (bytes, all ASCII, no
    /// CR) is read straight from the data's bytes rather than copied into a
    /// new string: a 1 GB log was a 1 GB copy on top of the editor's own.
    /// Below it, a copy.
    static let sharedBytesMinimum = 16 * 1024 * 1024

    /// The file's bytes as they are now, in memory of their own (read, not
    /// mapped): the bytes `decode(_:shareBytes:)` may keep. A mapped file
    /// shows a later write through it, so a same-length rewrite while it
    /// was checked, indexed and copied gave text that wasn't the bytes
    /// checked, and a truncation faulted reading past the end.
    ///
    /// Only a regular file, judged by what was opened: a path checked
    /// before and swapped for a FIFO since blocked `open` (no writer) or
    /// `read` forever, on the large-open queue or a synchronous restore.
    /// So the open doesn't wait (O_NONBLOCK), the opened file is checked
    /// (fstat), and only then are reads made blocking again.
    ///
    /// `maxBytes`: a file larger than this when opened (its size by the
    /// opened descriptor, not a size seen earlier), or one that grows past
    /// it while read, is refused (`fileReadTooLarge`, `isTooLarge`) with
    /// no more than `maxBytes + 1` bytes ever held: Find in Files' size
    /// limit came from its directory walk, so a file that grew or was
    /// replaced since was read whole however large.
    public static func snapshot(of url: URL, maxBytes: Int? = nil) throws -> Data {
        try snapshotStamped(of: url, maxBytes: maxBytes).data
    }

    /// `snapshot(of:maxBytes:)` and the stamp of the file it read, from
    /// the same open descriptor (`fstat` before the read): a stamp taken
    /// from the path could be another file's (a link retargeted, an
    /// atomic replace) than the bytes read.
    public static func snapshotStamped(of url: URL, maxBytes: Int? = nil) throws -> (data: Data, stamp: DiskStamp) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw readError(url, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw readError(url, errno) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw notRegularFile(url) }
        let limit = maxBytes.map { max($0, 0) }
        if let limit, Int(st.st_size) > limit { throw tooLarge(url) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw readError(url, errno) }
        return (try readAll(fd, url: url, sizeHint: Int(st.st_size), limit: limit), DiskStamp(st))
    }

    /// Everything left to read from `fd`, into memory of its own: room for
    /// `sizeHint` bytes, more if the file grows while read, but never more
    /// than `limit + 1` (enough to see it is too large: `tooLarge`).
    static func readAll(_ fd: Int32, url: URL, sizeHint: Int, limit: Int?) throws -> Data {
        let ceiling = limit.map { $0 + 1 } ?? Int.max
        var capacity = min(max(sizeHint, 0) + 1, ceiling)
        guard var buffer = malloc(capacity) else { throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path]) }
        var count = 0
        while true {
            if count == capacity {
                if capacity >= ceiling {
                    free(buffer)
                    throw tooLarge(url)
                }
                capacity = capacity > ceiling / 2 ? ceiling : capacity * 2
                guard let grown = realloc(buffer, capacity) else {
                    free(buffer)
                    throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path])
                }
                buffer = grown
            }
            let n = read(fd, buffer + count, min(capacity - count, Int(Int32.max)))
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                let e = errno
                free(buffer)
                throw readError(url, e)
            }
            count += n
        }
        if let limit, count > limit {
            free(buffer)
            throw tooLarge(url)
        }
        return Data(bytesNoCopy: buffer, count: count, deallocator: .free)
    }

    /// What tests run around a read (`readText`, Find in Files): `before`
    /// just before a file's bytes are read, `after` once they're read and
    /// before they're decoded, to swap or change the file there. Passed
    /// per call or per search, never kept globally: tests run in parallel.
    public struct ReadHooks: Sendable {
        public var before: (@Sendable (URL) -> Void)?
        public var after: (@Sendable (URL) -> Void)?
        public init(before: (@Sendable (URL) -> Void)? = nil, after: (@Sendable (URL) -> Void)? = nil) {
            self.before = before
            self.after = after
        }
    }

    /// The file at `url` read (`snapshot(of:)`, bytes of its own) and
    /// decoded (`decode`); nil if the bytes aren't text in that encoding.
    /// Reload, reopening and Find in Files read this way: mapped, a file
    /// rewritten in place while it was scanned and converted gave text
    /// with line-ending notes from other bytes (a same-size rewrite that
    /// keeps the CRLF count and adds a lone CR fits the room the scan gave,
    /// so nothing noticed), which a later save wrote back; and a file
    /// truncated meanwhile faulted on the pages past its end. A path
    /// swapped for a FIFO since it was checked is refused, not waited on
    /// (reading it mapped blocked Reload or the search for good).
    public static func readText(at url: URL, as encoding: TextEncoding? = nil, shareBytes: Bool = false,
                                hooks: ReadHooks? = nil) throws -> DecodedText? {
        try readTextStamped(at: url, as: encoding, shareBytes: shareBytes, hooks: hooks).text
    }

    /// `readText` and the stamp of the file the bytes came from (the same
    /// descriptor: `snapshotStamped`).
    public static func readTextStamped(at url: URL, as encoding: TextEncoding? = nil, shareBytes: Bool = false,
                                       hooks: ReadHooks? = nil) throws -> (text: DecodedText?, stamp: DiskStamp) {
        hooks?.before?(url)
        let (data, stamp) = try snapshotStamped(of: url)
        hooks?.after?(url)
        return (decode(data, as: encoding, shareBytes: shareBytes), stamp)
    }

    /// Too large to read (`snapshot`'s `maxBytes`).
    static func tooLarge(_ url: URL) -> CocoaError {
        CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url,
                                                 NSUnderlyingErrorKey: POSIXError(.EFBIG)])
    }

    /// Whether `error` is `snapshot` refusing a file over its `maxBytes`.
    public static func isTooLarge(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .fileReadTooLarge
    }

    /// A FIFO, device or directory where a file was expected.
    static func notRegularFile(_ url: URL) -> CocoaError {
        CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url,
                                                NSLocalizedDescriptionKey: String(localized: "It isn’t a regular file."),
                                                NSUnderlyingErrorKey: POSIXError(.EFTYPE)])
    }

    /// The error Foundation's reading gives for `code` (its message).
    static func readError(_ url: URL, _ code: Int32) -> CocoaError {
        let kind: CocoaError.Code = code == ENOENT ? .fileReadNoSuchFile : code == EACCES || code == EPERM ? .fileReadNoPermission : .fileReadUnknown
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url,
                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }

    /// Decodes `data` (as `encoding`, or the detected one) and normalises
    /// its line endings. Nil if the bytes aren't valid in that encoding.
    /// UTF-16 with an odd number of bytes after the BOM (a truncated
    /// download) is nil too, as a lone surrogate is: Foundation decoded it
    /// without the last byte, so ⌘S dropped that byte with no notice.
    ///
    /// UTF-8 (the usual case) takes one pass over the bytes (`scanUTF8`)
    /// for validity and line endings, and at most one copy: the bytes with
    /// CR and CRLF turned into LF, or with `shareBytes` none for a large
    /// all-ASCII file with no CR (`sharedBytesMinimum`). The text then
    /// keeps `data` alive and reads it in place, so `data` must be bytes
    /// nothing else changes: memory of its own (`snapshot(of:)`), never a
    /// mapped file. And best for a caller that copies the text and lets it
    /// go (opening a file into a tab): kept, it keeps all of `data`.
    public static func decode(_ data: Data, as encoding: TextEncoding? = nil, shareBytes: Bool = false) -> DecodedText? {
        var enc: TextEncoding
        var scanned: UTF8Scan?
        var guessed = false
        if let encoding {
            enc = encoding
        } else if let found = detectBOMOrUTF16(data) {
            enc = found
        } else {
            let scan = data.withUnsafeBytes { scanUTF8($0) }
            if scan.valid { enc = .utf8; scanned = scan } else { enc = guessEightBit(data); guessed = true }
        }
        var body = data
        if !enc.bom.isEmpty, data.starts(with: enc.bom) { body = data.dropFirst(enc.bom.count) }
        if enc == .utf8 || enc == .utf8BOM {
            // Foundation's UTF-8 decoding drops one leading BOM ("as UTF-8"
            // on a file with one, or a second BOM after the first): kept.
            if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3); scanned = nil }
            return decodeUTF8(body, scan: scanned, encoding: enc, looksBinary: looksBinary(data), shareBytes: shareBytes)
        }
        if enc == .utf16LE || enc == .utf16BE, body.count % 2 != 0 { return nil }
        var decoded = String(data: body, encoding: enc.foundation)
        // A guessed 8-bit encoding that can't decode a byte past the sample
        // (0x81 in Windows-1252): Latin-1 decodes any bytes.
        if decoded == nil, encoding == nil, enc == .windows1252 || enc == .macRoman {
            enc = .latin1
            decoded = String(data: body, encoding: .isoLatin1)
        }
        guard let raw = decoded else { return nil }
        let (ending, mixed) = detectLineEnding(raw)
        var breaks: BreakRecorder? = mixed ? BreakRecorder(dominant: ending, ascii: false) : nil
        let text = normalizeLineEndings(raw, recording: &breaks)
        return DecodedText(text: text, encoding: enc, lineEnding: ending, mixedLineEndings: mixed,
                           looksBinary: looksBinary(data), encodingGuessed: guessed,
                           lineBreaks: breaks.map { LineBreaks(dominant: ending, others: $0.others) })
    }

    /// UTF-8 `body` (no BOM) as text, from one scan (`scan`, when the
    /// caller already made it over exactly these bytes). Nil if invalid.
    static func decodeUTF8(_ body: Data, scan known: UTF8Scan?, encoding: TextEncoding, looksBinary binary: Bool,
                           shareBytes: Bool) -> DecodedText? {
        let scan = known ?? body.withUnsafeBytes { scanUTF8($0) }
        guard scan.valid else { return nil }
        let (ending, mixed) = lineEnding(lf: scan.lf, crlf: scan.crlf, cr: scan.cr)
        let text: String
        // Mixed: the breaks that aren't `ending`, as lfOnly writes them.
        var breaks: BreakRecorder? = mixed ? BreakRecorder(dominant: ending, ascii: scan.ascii) : nil
        if scan.crlf + scan.cr == 0 {
            if shareBytes, scan.ascii, !binary, body.count >= sharedBytesMinimum, let shared = sharedASCII(body) {
                text = shared
            } else {
                text = body.withUnsafeBytes { String(decoding: $0.bindMemory(to: UInt8.self), as: UTF8.self) }
            }
        } else {
            // The room is sized from the scan. Bytes that changed since (a
            // mapped file rewritten in place, CRLF pairs gone) need more:
            // `lfOnly` never writes past it and says so, and the text is
            // made again from a copy of the bytes as they are now.
            var fits = true
            text = body.withUnsafeBytes { raw in
                let length = max(0, raw.count - scan.crlf)
                if scan.ascii, !binary, length >= sharedBytesMinimum,
                   let buffer = malloc(max(1, length))?.assumingMemoryBound(to: UInt8.self) {
                    if let written = lfOnly(raw, into: buffer, capacity: length, recording: &breaks),
                       let s = NSString(bytesNoCopy: buffer, length: written, encoding: String.Encoding.ascii.rawValue,
                                        deallocator: { p, _ in free(p) }) {
                        return s as String
                    }
                    free(buffer)
                    breaks = mixed ? BreakRecorder(dominant: ending, ascii: scan.ascii) : nil
                }
                return String(unsafeUninitializedCapacity: length) { out in
                    guard let p = out.baseAddress,
                          let written = lfOnly(raw, into: p, capacity: length, recording: &breaks) else {
                        fits = false
                        return 0
                    }
                    return written
                }
            }
            if !fits {
                let copy = body.withUnsafeBytes { Data($0) }
                return decodeUTF8(copy, scan: nil, encoding: encoding, looksBinary: binary, shareBytes: false)
            }
        }
        return DecodedText(text: text, encoding: encoding, lineEnding: ending, mixedLineEndings: mixed, looksBinary: binary,
                           lineBreaks: breaks.map { LineBreaks(dominant: ending, others: $0.others) })
    }

    /// All-ASCII `data` as a string that reads its bytes in place (kept
    /// alive by the string; mapped file pages cost no memory of their own).
    static func sharedASCII(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let keep = data
            let s = NSString(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: raw.count,
                             encoding: String.Encoding.ascii.rawValue, deallocator: { _, _ in withExtendedLifetime(keep) {} })
            return s.map { $0 as String }
        }
    }

    /// Copies `raw` into `out` with CRLF and lone CR as LF (as replacing
    /// "\r\n" then "\r" did); returns the bytes written, or nil when
    /// `out` (room for `capacity` bytes) was too small: then it wrote only
    /// `capacity` bytes, never past them. Room for `raw.count` bytes less
    /// one per CRLF is enough, unless `raw` changed since its CRLFs were
    /// counted (a mapped file rewritten in place). With `recording`, each
    /// break that isn't its `dominant` kind is noted there.
    static func lfOnly(_ raw: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int? {
        var none: BreakRecorder?
        return lfOnly(raw, into: out, capacity: capacity, recording: &none)
    }

    /// The breaks `lfOnly` writes that aren't `dominant`, as
    /// LineBreaks.others: by the UTF-16 offset of their "\n" in the text it
    /// writes (counted over the bytes written, unless they are all ASCII).
    struct BreakRecorder {
        let dominant: LineEnding
        /// The text is all ASCII: a byte offset is the UTF-16 offset.
        let ascii: Bool
        var others: [Int] = []
        /// UTF-16 units in the first `counted` bytes written.
        private var units = 0, counted = 0

        init(dominant: LineEnding, ascii: Bool) {
            self.dominant = dominant
            self.ascii = ascii
        }

        /// The "\n" written at byte `o` of `out` was `le`.
        mutating func note(_ le: LineEnding, at o: Int, in out: UnsafeMutablePointer<UInt8>) {
            guard le != dominant else { return }
            if !ascii { advance(to: o, in: out) }
            others.append(LineBreaks.entry(ascii ? o : units, le))
        }

        /// Counts the UTF-16 units of the bytes written up to `o`, from
        /// where it last stopped. `lfOnly` calls it as it writes each run,
        /// so a break noted near the end of a large non-ASCII file doesn't
        /// read back over everything written before it.
        mutating func advance(to o: Int, in out: UnsafeMutablePointer<UInt8>) {
            guard o > counted else { return }
            var u = units
            for k in counted..<o {
                let c = out[k]
                if c & 0xC0 != 0x80 { u += c >= 0xF0 ? 2 : 1 }
            }
            units = u
            counted = o
        }
    }

    static func lfOnly(_ raw: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<UInt8>, capacity: Int,
                       recording: inout BreakRecorder?) -> Int? {
        guard let base = raw.baseAddress else { return 0 }
        let n = raw.count
        let b = base.assumingMemoryBound(to: UInt8.self)
        var i = 0, o = 0
        while i < n {
            var run: Int
            if let cr = memchr(b + i, 13, n - i) { run = UnsafeRawPointer(cr) - UnsafeRawPointer(b + i) } else { run = n - i }
            let full = run > capacity - o
            if full { run = capacity - o }
            (out + o).update(from: b + i, count: run)
            // Not mostly LF: each LF in the run is one of the others.
            if recording != nil, recording?.dominant != .lf {
                var p = o
                while p < o + run, let lf = memchr(out + p, 10, o + run - p) {
                    p = UnsafeMutableRawPointer(lf) - UnsafeMutableRawPointer(out)
                    recording?.note(.lf, at: p, in: out)
                    p += 1
                }
            }
            o += run
            i += run
            // Counted while the run is fresh, not when the next odd break
            // comes (it may be most of the file later).
            if let rec = recording, !rec.ascii { recording?.advance(to: o, in: out) }
            if full { return nil }
            guard i < n else { break }
            guard o < capacity else { return nil }
            out[o] = 10
            let crlf = i + 1 < n && b[i + 1] == 10
            recording?.note(crlf ? .crlf : .cr, at: o, in: out)
            o += 1
            i += crlf ? 2 : 1
        }
        return o
    }

    /// The most common line ending, and whether more than one kind occurs.
    /// A file with no line breaks counts as LF.
    public static func detectLineEnding(_ text: String) -> (LineEnding, mixed: Bool) {
        var copy = text
        let scan = copy.withUTF8 { scanUTF8(UnsafeRawBufferPointer($0)) }
        return lineEnding(lf: scan.lf, crlf: scan.crlf, cr: scan.cr)
    }

    /// CRLF and CR → LF.
    public static func normalizeLineEndings(_ text: String) -> String {
        var none: BreakRecorder?
        return normalizeLineEndings(text, recording: &none)
    }

    static func normalizeLineEndings(_ text: String, recording: inout BreakRecorder?) -> String {
        var copy = text
        return copy.withUTF8 { b -> String in
            let raw = UnsafeRawBufferPointer(b)
            // No CR: nothing to convert, and nothing to note unless LF
            // isn't the kind to note against (an append to a CRLF file).
            guard let base = raw.baseAddress,
                  memchr(base, 13, raw.count) != nil || (recording != nil && recording?.dominant != .lf) else { return text }
            // Room for every byte: LF-only text is never longer.
            return String(unsafeUninitializedCapacity: raw.count) {
                lfOnly(raw, into: $0.baseAddress!, capacity: raw.count, recording: &recording) ?? raw.count
            }
        }
    }

    /// Encodes LF-normalised text for saving: line endings converted, BOM
    /// added. Nil if a character can't be represented (Latin-1).
    public static func encode(_ text: String, encoding: TextEncoding, lineEnding: LineEnding) -> Data? {
        var s = text
        if lineEnding != .lf {
            let m = NSMutableString(string: text)
            m.replaceOccurrences(of: "\n", with: lineEnding.string, options: .literal, range: NSRange(location: 0, length: m.length))
            s = m as String
        }
        guard let body = s.data(using: encoding.foundation, allowLossyConversion: false) else { return nil }
        // Foundation's .utf16LittleEndian/BigEndian write no BOM; add ours.
        return encoding.bom.isEmpty ? body : Data(encoding.bom) + body
    }

    /// Whether `text` can be saved in `encoding` without loss.
    public static func canEncode(_ text: String, as encoding: TextEncoding) -> Bool {
        switch encoding {
        case .latin1: return text.unicodeScalars.allSatisfy { $0.value < 256 }
        case .windows1252, .macRoman: return text.canBeConverted(to: encoding.foundation)
        default: return true
        }
    }
}

/// What bytes 0x80–0xFF decode to in the 8-bit encodings, for the guess.
enum EightBit {
    static let windows = table(.windowsCP1252)
    static let mac = table(.macOSRoman)

    static func table(_ enc: String.Encoding) -> [Unicode.Scalar?] {
        (0x80...0xFF).map { b in String(data: Data([UInt8(b)]), encoding: enc)?.unicodeScalars.first }
    }

    static let rareCapitals = Set("ŠŒŽŸ".unicodeScalars)
    static let punctuation = Set("‘’“”‚„–—…€•«»‹›¡¿°·©®™§¶\u{A0}".unicodeScalars)

    static func score(_ s: Unicode.Scalar?, lowerBefore: Bool) -> Int {
        guard let s else { return -3 }
        let p = s.properties
        if p.generalCategory == .control { return -3 }
        if p.isLowercase { return 1 }
        // Windows-1252's Š Œ Ž Ÿ are rare in real text: no evidence either way.
        if p.isUppercase { return lowerBefore ? -2 : rareCapitals.contains(s) ? 0 : 1 }
        if punctuation.contains(s) { return 1 }
        return -1
    }
}
