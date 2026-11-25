import Foundation

/// How a Mac tab shows unsaved edits: a trailing " •" on the window title
/// (and so on the native tab's label) beside AppKit's own edited dot. The
/// document's name itself never carries the mark (alerts, menus, the
/// session and the sidebar use it).
public enum EditedIndicator {
    /// The mark after the name when the tab has unsaved edits.
    public static let mark = " •"

    /// The window (and tab) title: exactly `displayName` when clean.
    public static func windowTitle(displayName: String, isDirty: Bool) -> String {
        isDirty ? displayName + mark : displayName
    }

    /// What VoiceOver reads for the window: the name, then `edited` (the
    /// localized word "Edited") when there are unsaved edits.
    public static func accessibilityTitle(displayName: String, isDirty: Bool, edited: String) -> String {
        isDirty ? "\(displayName), \(edited)" : displayName
    }
}

/// Whether a tab has unsaved edits, by its text rather than a count of
/// changes: undo or redo back to the text last saved (or opened) is clean
/// again. A change that only shows on save (encoding, line endings) and a
/// buffer that is unsaved by definition (restored from the session, a file
/// deleted on disk) stay unsaved until the next save.
///
/// A text longer than `snapshotLimit` is not copied: a 1 GB log was a
/// second 1 GB (and 0.8 s) at every open and save. It keeps chunk hashes
/// of the saved text (`TextFingerprint`) and the span the edits since then
/// can have touched (`noteEdit`, from every change to the storage); when
/// the length is back to the saved one, only the chunks under that span
/// are hashed again and compared.
public struct EditedState {
    /// The text at the last save, open or clean reload; nil when unknown
    /// (then any text change is unsaved until the next save) or kept as
    /// `savedPrint` instead.
    private var savedText: NSString?
    /// A long saved text's chunk hashes, instead of `savedText`.
    private var savedPrint: TextFingerprint?
    /// With `savedPrint`: where the text can differ from the saved one, in
    /// the current text's offsets. Before it the two are the same; after it
    /// they are the same shifted by the change in length. Nil: no edit.
    private var touched: Range<Int>?
    /// The text differed from `savedText` at the last change.
    public private(set) var textDiffers = false
    /// Encoding or line endings changed: written on save, not visible in the text.
    public private(set) var formatChanged = false
    /// Unsaved whatever the text says (session buffer, missing file).
    public private(set) var forced = false
    /// A mixed file's odd line breaks at the baseline (LineBreaks.others;
    /// empty when none), and whether they differ now: the text has every
    /// break as LF, so a CRLF deleted and Return typed back in its place
    /// gave the saved text again, the tab clean, and autosave and closing
    /// skipped a change that a save writes (an LF where the CRLF was).
    private var savedBreaks: [Int] = []
    public private(set) var breaksDiffer = false
    /// Longer saved texts (UTF-16 units) are kept as a fingerprint.
    public let snapshotLimit: Int
    /// The fingerprint's chunk length.
    let chunk: Int

    /// Above this length (UTF-16 units, 32 MB of UTF-16) the saved text is
    /// a fingerprint, not a copy.
    public static let snapshotLimit = 16 * 1024 * 1024

    /// A new document: clean, with `savedText` as its text ("" for a new
    /// untitled tab, so typing and undoing back to empty is clean).
    public init(savedText: String? = "", snapshotLimit: Int = EditedState.snapshotLimit, chunk: Int = TextFingerprint.defaultChunk) {
        self.snapshotLimit = snapshotLimit
        self.chunk = chunk
        saved(savedText.map { NSString(string: $0) })
    }

    public var isDirty: Bool { textDiffers || breaksDiffer || formatChanged || forced }

    /// Whether the saved text is kept as a fingerprint (not a copy).
    public var keepsFingerprint: Bool { savedPrint != nil }

    /// Saved (or opened, or reloaded clean): `text` is the new baseline.
    /// Keeps an immutable copy, never the caller's mutable storage, or for
    /// a long text its fingerprint.
    /// `breaks`: the text's odd line breaks as saved (nil: none).
    public mutating func saved(_ text: NSString?, breaks: LineBreaks? = nil) {
        savedBreaks = breaks?.others ?? []
        if let text, text.length > snapshotLimit {
            baseline(TextFingerprint(text, chunk: chunk))
        } else {
            savedText = text?.copy() as? NSString
            savedPrint = nil
            touched = nil
            clearFlags()
        }
    }

    /// Saved, with the text's fingerprint already made (off the main
    /// thread, while opening). Its chunk length is used as it is.
    public mutating func saved(fingerprint: TextFingerprint, breaks: LineBreaks? = nil) {
        savedBreaks = breaks?.others ?? []
        baseline(fingerprint)
    }

    private mutating func baseline(_ print: TextFingerprint) {
        savedText = nil
        savedPrint = print
        touched = nil
        clearFlags()
    }

    private mutating func clearFlags() {
        textDiffers = false
        breaksDiffer = false
        formatChanged = false
        forced = false
    }

    /// The text's storage changed: `range` is what the changed part covers
    /// now and `delta` the change in length (NSTextStorage's editedRange
    /// and changeInLength). Every change must come here, before
    /// `textChanged`, while a fingerprint is kept.
    public mutating func noteEdit(_ range: NSRange, delta: Int) {
        guard savedPrint != nil else { return }
        let newEnd = range.location + range.length
        let oldEnd = newEnd - delta
        guard let t = touched else { touched = range.location..<newEnd; return }
        let upper = t.upperBound <= range.location ? t.upperBound : t.upperBound >= oldEnd ? t.upperBound + delta : newEnd
        touched = min(t.lowerBound, range.location)..<max(upper, newEnd)
    }

    /// The text changed (an edit, undo or redo): compare with the baseline.
    /// The length first, so most edits cost nothing more.
    public mutating func textChanged(to text: NSString?) {
        if let savedPrint {
            guard let text, text.length == savedPrint.length else { textDiffers = true; return }
            guard let t = touched else { textDiffers = false; return }
            textDiffers = !savedPrint.matches(text, in: t)
            if !textDiffers { touched = nil }
            return
        }
        guard let savedText, let text else { textDiffers = true; return }
        textDiffers = savedText.length != text.length || !savedText.isEqual(text)
    }

    /// The odd line breaks may have changed (an edit, undo or redo):
    /// unsaved while they aren't the saved ones, whatever the text says.
    public mutating func breaksChanged(to breaks: LineBreaks?) {
        breaksDiffer = (breaks?.others ?? []) != savedBreaks
    }

    /// Encoding or line endings changed (applied on save).
    public mutating func noteFormatChange() { formatChanged = true }

    /// Unsaved by definition until the next save.
    public mutating func forceDirty() { forced = true }
}

/// A text's UTF-16 contents as one 64-bit hash per chunk: what EditedState
/// keeps of a long saved text. Made off the main thread when a large file
/// opens; an immutable string may be read from any thread.
public struct TextFingerprint: Sendable, Equatable {
    public let length: Int
    public let chunk: Int
    let hashes: [UInt64]

    /// 64 K units (128 KB) a chunk: 16,384 hashes for a 1 GB file.
    public static let defaultChunk = 65_536

    public init(_ text: NSString, chunk: Int = TextFingerprint.defaultChunk) {
        precondition(chunk > 0 && chunk % 4 == 0)
        length = text.length
        self.chunk = chunk
        let count = (length + chunk - 1) / chunk
        let buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out: [UInt64] = []
        out.reserveCapacity(count)
        for k in 0..<count { out.append(Self.hash(text, chunk: k, of: chunk, length: length, buffer: buffer)) }
        hashes = out
    }

    /// Whether `text` (as long as the fingerprinted one) has the same
    /// chunks over `range`.
    func matches(_ text: NSString, in range: Range<Int>) -> Bool {
        guard text.length == length else { return false }
        guard !range.isEmpty, range.lowerBound < length else { return true }
        let buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        let last = (min(range.upperBound, length) - 1) / chunk
        for k in (range.lowerBound / chunk)...last where Self.hash(text, chunk: k, of: chunk, length: length, buffer: buffer) != hashes[k] {
            return false
        }
        return true
    }

    static func hash(_ text: NSString, chunk k: Int, of size: Int, length: Int, buffer: UnsafeMutablePointer<UInt16>) -> UInt64 {
        let start = k * size, count = min(size, length - start)
        text.getCharacters(buffer, range: NSRange(location: start, length: count))
        return hash(buffer, count: count)
    }

    /// Four lanes of multiply-and-fold over 8-byte words, then the tail and
    /// the count. Not cryptographic: it tells an edited chunk from the
    /// saved one, which an accidental 64-bit collision would need to fool.
    static func hash(_ p: UnsafePointer<UInt16>, count: Int) -> UInt64 {
        let m: UInt64 = 0x9FB2_1C65_1E98_DF25
        var a: UInt64 = 0x9E37_79B9_7F4A_7C15, b: UInt64 = 0xC2B2_AE3D_27D4_EB4F
        var c: UInt64 = 0x1656_67B1_9E37_79F9, d: UInt64 = 0x27D4_EB2F_1656_67C5
        @inline(__always) func mix(_ h: inout UInt64, _ w: UInt64) { h = (h ^ w) &* m; h ^= h >> 29 }
        let raw = UnsafeRawPointer(p)
        var k = 0
        while k + 16 <= count {
            mix(&a, raw.loadUnaligned(fromByteOffset: k * 2, as: UInt64.self))
            mix(&b, raw.loadUnaligned(fromByteOffset: k * 2 + 8, as: UInt64.self))
            mix(&c, raw.loadUnaligned(fromByteOffset: k * 2 + 16, as: UInt64.self))
            mix(&d, raw.loadUnaligned(fromByteOffset: k * 2 + 24, as: UInt64.self))
            k += 16
        }
        while k < count { mix(&a, UInt64(p[k]) | 0x1_0000); k += 1 }
        var h = UInt64(count)
        for lane in [a, b, c, d] { mix(&h, lane) }
        return h
    }
}
